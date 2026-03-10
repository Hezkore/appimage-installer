// Scrollable list of installed AppImages and orphaned desktop entries
//
module windows.manage;

import std.file : isSymlink;
import std.string : endsWith, fromStringz, indexOf;
import std.typecons : No;
import std.uni : toLower;

import core.atomic : atomicLoad, atomicOp;
import core.thread : Thread;

import glib.global : idleAdd, timeoutAdd;
import glib.types : PRIORITY_DEFAULT;
import gtk.box : Box;
import gtk.button : Button;
import adw.header_bar : HeaderBar;
import adw.toolbar_view : ToolbarView;
import gtk.css_provider : CssProvider;
import gtk.gesture_click : GestureClick;
import gtk.image : Image;
import gtk.label : Label;
import gtk.list_box : ListBox;
import gtk.list_box_row : ListBoxRow;
import gtk.progress_bar : ProgressBar;
import gtk.revealer : Revealer;
import gtk.scrolled_window : ScrolledWindow;
import gtk.menu_button : MenuButton;
import gtk.popover : Popover;
import gtk.separator : Separator;
import gtk.search_entry : SearchEntry;
import gtk.spinner : Spinner;
import gtk.stack : Stack;
import gtk.types : Align, Orientation, PolicyType, RevealerTransitionType;
import gtk.types : SelectionMode, StackTransitionType;
import gtk.widget : Widget;
import gtk.drop_target : DropTarget;

import gdk.types : DragAction;
import gio.c.functions : g_file_get_path;
import gio.c.types : GFile;
import gio.file : GioFile = File;
import gio.file_monitor : FileMonitor;
import glib.c.functions : g_free;
import gobject.value : Value;

import application : App;
import windows.base : AppWindow, makeBackButton, makeLangBox, REVEAL_MS, makeIcon;
import windows.base : CONTENT_REVEAL_DELAY_MS;
import windows.manage.scan : InstalledApp, scanInstalledApps, buildEmptyBox, isStillInstalled;
import windows.manage.row : AppRowResult, Layout;
import windows.manage.row : makeReloadCallback, bindToggleClick, buildAppRow;
import windows.manage.watcher : startWatcher, hasAnyActiveApps;
import windows.manage.watcher : watcherHideOrphanSection = hideOrphanSectionIfEmpty;
import windows.manage.add : buildAddAppBox;
import windows.settings : buildSettingsBox;
import appimage.manifest : Manifest;
import update.checker : checkOneApp, checkInstallerUpdate;
import update.dispatch : applyUpdateWithProgress;
import apputils : readInstallerUpdateVersion, writeInstallerUpdateFlag,
	clearInstallerUpdateFlag, downloadAndInstallSelf;
import lang : L;

// Measurements specific to the manage window section headers and list layout
private enum ManageLayout {
	sectionLabelIndent = 4,
	sectionLabelTopMargin = 10,
	sectionLabelBottomMargin = 6,
	iconStaggerInitial = 50,
	orphanSectionTopMargin = 16,
	addCardPadding = 10,
	addCardIconSize = 16,
	addCardIconMargin = 10,
	installerProgressPulseMs = 80,
	updateAllProgressPollMs = 100,
	menuPopoverPadding = 4,
	menuPopoverSpacing = 2,
	menuItemRowSpacing = 8,
	menuSeparatorMargin = 2,
	contentRowSpacing = 4,
}

// Widgets for the self-update banner at the top of the manage window
private struct InstallerUpdateSection {
	Revealer revealer;
	Label subLabel;
	Button button;
}

// Widgets for the update-all banner that appears when multiple updates are available
private struct UpdateAllSection {
	Revealer revealer;
	Button button;
	Label countLabel;
}

private Box makeSectionHeader(string text) {
	auto sectionLabel = new Label(text);
	sectionLabel.setHalign(Align.Start);
	sectionLabel.setMarginStart(ManageLayout.sectionLabelIndent);
	sectionLabel.setMarginTop(ManageLayout.sectionLabelTopMargin);
	sectionLabel.setMarginBottom(ManageLayout.sectionLabelBottomMargin);
	sectionLabel.addCssClass("section-heading");
	auto box = new Box(Orientation.Horizontal, 0);
	box.setHexpand(true);
	box.append(sectionLabel);
	return box;
}

private void appendAppGroup(
	ManageWindow win,
	InstalledApp[] group,
	size_t iconOffset,
	ListBox target,
	ref AppRowResult[] results) {
	foreach (i, ref entry; group) {
		auto result = buildAppRow(win, entry);
		results ~= result;
		target.append(result.row);
		uint delay = cast(uint)(
			(iconOffset + i) * Layout.iconStaggerMs
				+ ManageLayout.iconStaggerInitial);
		timeoutAdd(
			PRIORITY_DEFAULT,
			delay,
			makeReloadCallback(result.reloadRow));
	}
}

// Counts non-orphan rows that have a pending update
private int countUpdatable(AppRowResult[] rows) {
	int count = 0;
	foreach (ref appRow; rows)
		if (!appRow.entry.isOrphan && appRow.entry.updateAvailable && appRow
			.entry.updateInfo.length)
			count++;
	return count;
}

// Starts a background update thread for one app row and wires progress into the row widgets
// remaining is decremented on the GTK thread when the update finishes
private void launchRowUpdate(
	InstalledApp entry,
	ProgressBar progressBar,
	Label statusLabel,
	Label updateLabel,
	int* remaining,
	Button updateAllBtn,
	Button checkBtn,
	Revealer updateAllRevealer,
	AppRowResult[] allRows,
	bool delegate() shouldCancel = null) {
	double progress = 0.0;
	string statusText = "update.direct.status.start";
	bool done = false;

	progressBar.setFraction(0.0);
	progressBar.show();
	updateLabel.hide();
	statusLabel.removeCssClass("warning");
	statusLabel.show();
	statusLabel.setText(L(statusText));

	timeoutAdd(PRIORITY_DEFAULT, ManageLayout.updateAllProgressPollMs, () {
		if (done || (shouldCancel !is null && shouldCancel()))
			return false;
		progressBar.setFraction(progress);
		statusLabel.setText(L(statusText));
		return true;
	});

	auto thread = new Thread({
		string error;
		bool wasUpdated;
		bool ok = applyUpdateWithProgress(
			entry, progress, statusText, wasUpdated, error, shouldCancel);
		bool capturedOk = ok;
		string capturedError = error;
		idleAdd(PRIORITY_DEFAULT, () {
			done = true;
			if (shouldCancel !is null && shouldCancel())
				return false;
			progressBar.setFraction(1.0);
			progressBar.hide();
			if (capturedOk) {
				statusLabel.hide();
				updateLabel.setVisible(false);
				auto installedAppManifest =
				Manifest.loadFromAppDir(entry.appDirectory);
				if (installedAppManifest !is null
				&& installedAppManifest.updateAvailable) {
					installedAppManifest.updateAvailable = false;
					installedAppManifest.save();
				}
			} else {
				statusLabel.addCssClass("warning");
				statusLabel.setText(L("manage.installer.update.failed", capturedError));
			}
			(*remaining)--;
			if (*remaining <= 0) {
				updateAllBtn.setSensitive(true);
				checkBtn.setSensitive(true);
				int count = 0;
				foreach (ref r; allRows)
					if (r.updateLabel !is null && r.updateLabel.getVisible())
						count++;
				updateAllRevealer.setRevealChild(count >= 2);
			}
			return false;
		});
	});
	thread.isDaemon = true;
	thread.start();
}

// Lists installed AppImages and orphaned desktop entries, with actions for each
class ManageWindow : AppWindow {
	private enum int NAV_SLIDE_MS = 300;

	package InstalledApp[] installedApps;
	package Box manageContent;
	package Box emptyStateBox;
	package Stack navStack;
	package Box subSlot;

	package Revealer bannerRevealer;
	package Label bannerLabel;
	package Revealer installerUpdateRevealer;
	package Label installerUpdateSubLabel;
	package string installerUpdateVersion;
	package Button installerUpdateButton;
	package FileMonitor[] appMonitors;

	package ListBox installedListBox;
	package ListBox orphanListBox;
	package Box orphanSectionBox;
	package Box installedSectionHeader;
	package Box orphanDivider;

	package bool watcherRunning;
	package AppRowResult[] rowResults;
	package shared int filterGeneration = 0;

	private SearchEntry searchBar;
	private Button searchButton;
	private Button checkButton;
	private MenuButton menuButton;
	private bool searchIsOpen;
	private DropTarget activeDropTarget;

	// Runs a background thread to filter row visibility by text
	// Cancels itself via filterGeneration if a newer search fires before this one finishes
	private void scheduleFilter(string text) {
		int capturedGeneration = atomicOp!"+="(this.filterGeneration, 1);
		auto results = this.rowResults;
		auto apps = this.installedApps;

		auto filterThread = new Thread({
			string lower = text.toLower();
			bool[] visibility = new bool[apps.length];
			foreach (i, ref app; apps)
				visibility[i] = !lower.length
					|| app.appName.toLower()
					.indexOf(lower) >= 0
					|| app.appComment.toLower().indexOf(lower) >= 0;

			if (atomicLoad(this.filterGeneration) != capturedGeneration)
				return;

			idleAdd(PRIORITY_DEFAULT, () {
				if (atomicLoad(this.filterGeneration) != capturedGeneration)
					return false;
				foreach (i, ref rowResult; results)
					rowResult.row.setVisible(visibility[i]);
				return false;
			});
		});
		filterThread.isDaemon = true;
		filterThread.start();
	}

	this(App app) {
		super(app);
		this.setResizable(true);
	}

	override void loadWindow() {
		import std.stdio : writeln;

		writeln("ManageWindow: scanning installed apps");
		this.installedApps = scanInstalledApps();
		this.installerUpdateVersion = readInstallerUpdateVersion();
	}

	// Rebuilds the UI in-place so no window is destroyed or recreated
	override protected void reloadWindow() {
		foreach (m; this.appMonitors)
			m.cancel();
		this.appMonitors = [];
		this.watcherRunning = false;
		this.rowResults = [];
		this.searchIsOpen = false;
		this.headerBar = new HeaderBar;
		this.toolbarView = new ToolbarView;
		this.toolbarView.addTopBar(this.headerBar);
		this.toolbarView.setContent(this.loadingBox);
		this.setContent(this.toolbarView);
		this.loadingSpinner.start();
		this.doThreadedWork(&this.loadWindow, &this.showWindow);
	}

	private void setupSearchBar() {
		this.searchBar = new SearchEntry;
		this.searchBar.setHexpand(true);
		this.searchBar.placeholderText = L("manage.search.placeholder");
		this.searchBar.connectSearchChanged(() {
			scheduleFilter(this.searchBar.getText());
		});

		this.searchBar.connectStopSearch(() {
			this.searchIsOpen = false;
			this.headerBar.setTitleWidget(null);
			this.searchBar.setText("");
			this.setFocus(null);
			scheduleFilter("");
		});

		this.searchButton = new Button;
		this.searchButton.setChild(Image.newFromIconName("system-search-symbolic"));
		this.searchButton.addCssClass("flat");
		this.searchButton.setValign(Align.Center);
		this.searchButton.setTooltipText(L("manage.search.tooltip"));
		this.searchButton.connectClicked(() {
			this.searchIsOpen = !this.searchIsOpen;
			if (this.searchIsOpen) {
				this.headerBar.setTitleWidget(this.searchBar);
				this.searchBar.grabFocus();
			} else {
				this.headerBar.setTitleWidget(null);
				this.searchBar.setText("");
				this.setFocus(null);
				scheduleFilter("");
			}
		});
	}

	private void setupHeaderButtons() {
		auto menuPopover = new Popover;
		auto menuPopoverBox = new Box(Orientation.Vertical, ManageLayout.menuPopoverSpacing);
		menuPopoverBox.setMarginTop(ManageLayout.menuPopoverPadding);
		menuPopoverBox.setMarginBottom(ManageLayout.menuPopoverPadding);
		menuPopoverBox.setMarginStart(ManageLayout.menuPopoverPadding);
		menuPopoverBox.setMarginEnd(ManageLayout.menuPopoverPadding);

		auto settingsItemRow = new Box(Orientation.Horizontal, ManageLayout.menuItemRowSpacing);
		settingsItemRow.append(Image.newFromIconName("preferences-system-symbolic"));
		auto settingsItemLabel = new Label(L("button.settings"));
		settingsItemLabel.setHexpand(true);
		settingsItemLabel.setHalign(Align.Start);
		settingsItemRow.append(settingsItemLabel);
		auto settingsItem = new Button;
		settingsItem.addCssClass("flat");
		settingsItem.setChild(settingsItemRow);
		settingsItem.connectClicked(() {
			menuPopover.popdown();
			this.slideToSub(buildSettingsBox(
				this,
				() => this.reloadWindow(),
				() {
					if (this.searchButton !is null)
						this.searchButton.show();
					if (this.menuButton !is null)
						this.menuButton.show();
					this.slideBackToManage();
				}));
		});
		menuPopoverBox.append(settingsItem);

		auto menuSep = new Separator(Orientation.Horizontal);
		menuSep.setMarginTop(ManageLayout.menuSeparatorMargin);
		menuSep.setMarginBottom(ManageLayout.menuSeparatorMargin);
		menuPopoverBox.append(menuSep);
		menuPopoverBox.append(makeLangBox(this, menuPopover));

		menuPopover.setChild(menuPopoverBox);
		this.menuButton = new MenuButton;
		this.menuButton.setIconName("open-menu-symbolic");
		this.menuButton.addCssClass("flat");
		this.menuButton.setValign(Align.Center);
		this.menuButton.setPopover(menuPopover);

		auto checkContentBox = new Box(Orientation.Horizontal, ManageLayout.contentRowSpacing);
		checkContentBox.append(
			makeIcon([
				"software-update-available-symbolic",
				"system-software-update-symbolic"
			]));
		checkContentBox.append(new Label(L("button.check_updates")));
		this.checkButton = new Button;
		this.checkButton.setChild(checkContentBox);
		this.checkButton.addCssClass("flat");
		this.checkButton.setValign(Align.Center);

		this.headerBar.packEnd(this.menuButton);
		this.headerBar.packEnd(this.searchButton);
		this.headerBar.packStart(this.checkButton);
	}

	private InstallerUpdateSection buildInstallerUpdateSection() {
		auto installerUpdateList = new ListBox;
		installerUpdateList.setHexpand(true);
		installerUpdateList.addCssClass("boxed-list");
		installerUpdateList.setSelectionMode(SelectionMode.None);
		installerUpdateList.setMarginBottom(
			ManageLayout.sectionLabelBottomMargin);

		auto installerUpdateRow = new ListBoxRow;
		installerUpdateRow.setActivatable(false);
		auto installerUpdateInner =
			new Box(Orientation.Horizontal, Layout.rowSpacing);
		installerUpdateInner.setMarginTop(Layout.rowMargin);
		installerUpdateInner.setMarginBottom(Layout.rowMargin);
		installerUpdateInner.setMarginStart(Layout.rowMargin);
		installerUpdateInner.setMarginEnd(Layout.rowMargin);

		auto installerIcon =
			makeIcon([
				"software-update-available-symbolic",
				"system-software-update-symbolic"
			]);
		installerIcon.setPixelSize(Layout.iconSize);
		auto installerNameBox =
			new Box(Orientation.Vertical, Layout.infoSpacing);
		installerNameBox.setHexpand(true);
		installerNameBox.setValign(Align.Center);
		auto installerNameLabel = new Label(L("window.title.installer"));
		installerNameLabel.setHalign(Align.Start);
		string initialSubText = this.installerUpdateVersion.length
			? L("manage.installer.update.version", this.installerUpdateVersion) : L(
				"manage.installer.update.label");
		auto installerSubLabel = new Label(initialSubText);
		installerSubLabel.setHalign(Align.Start);
		installerSubLabel.addCssClass("caption");
		installerSubLabel.addCssClass("warning");
		auto installerProgress = new ProgressBar;
		installerProgress.setHexpand(true);
		installerProgress.hide();
		installerNameBox.append(installerNameLabel);
		installerNameBox.append(installerSubLabel);
		installerNameBox.append(installerProgress);

		auto installerUpdateButton = new Button;
		installerUpdateButton.setLabel(L("button.update"));
		installerUpdateButton.addCssClass("suggested-action");
		installerUpdateButton.setValign(Align.Center);
		this.installerUpdateButton = installerUpdateButton;
		bool* installerDone = new bool(false);
		ManageWindow capturedWindow = this;
		installerUpdateButton.connectClicked(() {
			if (*installerDone) {
				capturedWindow.close();
				return;
			}
			string newVersion = this.installerUpdateVersion;
			if (!newVersion.length)
				return;
			auto spinner = new Spinner;
			spinner.setSpinning(true);
			installerUpdateButton.removeCssClass("suggested-action");
			installerUpdateButton.setChild(spinner);
			installerUpdateButton.setSensitive(false);
			Label capturedSubLabel = installerSubLabel;
			ProgressBar capturedProgress = installerProgress;
			Button capturedButton = installerUpdateButton;
			bool* progressRunning = new bool(true);
			capturedProgress.show();
			timeoutAdd(PRIORITY_DEFAULT,
				ManageLayout.installerProgressPulseMs, () {
				if (!*progressRunning) {
					capturedProgress.hide();
					return false;
				}
				capturedProgress.pulse();
				return true;
			});
			auto updateThread = new Thread({
				string dlError;
				void setStatus(string text) {
					string capturedText = text;
					idleAdd(PRIORITY_DEFAULT, () {
						capturedSubLabel.setText(capturedText);
						return false;
					});
				}

				bool ok = downloadAndInstallSelf(newVersion, &setStatus, dlError);
				string finalText = ok
				? L("manage.installer.update.done") : L("manage.installer.update.failed", dlError);
				bool capturedOk = ok;
				bool* capturedDone = installerDone;
				idleAdd(PRIORITY_DEFAULT, () {
					*progressRunning = false;
					capturedSubLabel.setText(finalText);
					if (capturedOk)
						clearInstallerUpdateFlag();
					*capturedDone = true;
					capturedButton.setLabel(L("button.close"));
					capturedButton.setSensitive(true);
					return false;
				});
			});
			updateThread.isDaemon = true;
			updateThread.start();
		});

		installerUpdateInner.append(installerIcon);
		installerUpdateInner.append(installerNameBox);
		installerUpdateInner.append(installerUpdateButton);
		installerUpdateRow.setChild(installerUpdateInner);
		installerUpdateList.append(installerUpdateRow);

		this.installerUpdateRevealer = new Revealer;
		this.installerUpdateRevealer.setTransitionType(
			RevealerTransitionType.SlideDown);
		this.installerUpdateRevealer.setTransitionDuration(REVEAL_MS);
		this.installerUpdateRevealer.setRevealChild(
			this.installerUpdateVersion.length > 0);
		this.installerUpdateRevealer.setHexpand(true);
		this.installerUpdateRevealer.setChild(installerUpdateList);
		this.installerUpdateSubLabel = installerSubLabel;

		return InstallerUpdateSection(
			this.installerUpdateRevealer,
			installerSubLabel,
			installerUpdateButton);
	}

	private UpdateAllSection buildUpdateAllSection() {
		auto updateAllButton = new Button;
		updateAllButton.setLabel(L("button.update_all"));
		updateAllButton.addCssClass("pill");
		updateAllButton.setValign(Align.Center);
		auto updateAllCountLabel = new Label("");
		updateAllCountLabel.addCssClass("caption");
		updateAllCountLabel.addCssClass("dim-label");
		updateAllCountLabel.setHalign(Align.Start);
		auto updateAllTitleLabel = new Label(L("manage.update_all.title"));
		updateAllTitleLabel.addCssClass("heading");
		updateAllTitleLabel.setHalign(Align.Start);
		auto updateAllInfoBox =
			new Box(Orientation.Vertical, Layout.infoSpacing);
		updateAllInfoBox.setHexpand(true);
		updateAllInfoBox.setValign(Align.Center);
		updateAllInfoBox.append(updateAllTitleLabel);
		updateAllInfoBox.append(updateAllCountLabel);
		auto updateAllIcon =
			makeIcon([
				"software-update-available-symbolic",
				"system-software-update-symbolic"
			]);
		updateAllIcon.setPixelSize(Layout.iconSize);
		updateAllIcon.setValign(Align.Center);
		auto updateAllInner = new Box(Orientation.Horizontal, Layout.rowSpacing);
		updateAllInner.setMarginTop(Layout.rowMargin);
		updateAllInner.setMarginBottom(Layout.rowMargin);
		updateAllInner.setMarginStart(Layout.rowMargin);
		updateAllInner.setMarginEnd(Layout.rowMargin);
		updateAllInner.append(updateAllIcon);
		updateAllInner.append(updateAllInfoBox);
		updateAllInner.append(updateAllButton);
		auto updateAllRow = new ListBoxRow;
		updateAllRow.setActivatable(false);
		updateAllRow.setChild(updateAllInner);
		auto updateAllList = new ListBox;
		updateAllList.setHexpand(true);
		updateAllList.addCssClass("boxed-list");
		updateAllList.setSelectionMode(SelectionMode.None);
		updateAllList.setMarginBottom(ManageLayout.sectionLabelBottomMargin);
		updateAllList.append(updateAllRow);
		auto updateAllRevealer = new Revealer;
		updateAllRevealer.setTransitionType(RevealerTransitionType.SlideDown);
		updateAllRevealer.setTransitionDuration(REVEAL_MS);
		updateAllRevealer.setHexpand(true);
		updateAllRevealer.setChild(updateAllList);
		return UpdateAllSection(
			updateAllRevealer,
			updateAllButton,
			updateAllCountLabel);
	}

	private ListBox buildAddList() {
		auto addList = new ListBox;
		addList.setHexpand(true);
		addList.addCssClass("boxed-list");
		addList.setSelectionMode(SelectionMode.None);
		addList.setMarginTop(ManageLayout.orphanSectionTopMargin);
		auto addRow = new ListBoxRow;
		auto addRowInner = new Box(Orientation.Horizontal, 0);
		addRowInner.setMarginTop(ManageLayout.addCardPadding);
		addRowInner.setMarginBottom(ManageLayout.addCardPadding);
		addRowInner.setMarginStart(ManageLayout.addCardPadding);
		addRowInner.setMarginEnd(ManageLayout.addCardPadding);
		auto addIcon = Image.newFromIconName("list-add-symbolic");
		addIcon.setPixelSize(ManageLayout.addCardIconSize);
		addIcon.setMarginEnd(ManageLayout.addCardIconMargin);
		auto addLabel = new Label(L("manage.add.row"));
		addLabel.addCssClass("dim-label");
		addLabel.setHalign(Align.Start);
		addRowInner.append(addIcon);
		addRowInner.append(addLabel);
		addRow.setChild(addRowInner);
		addList.append(addRow);
		addList.connectRowActivated((ListBoxRow activatedRow, ListBox listBox) {
			this.slideToSub(buildAddAppBox(this, () => this.slideBackToManage()));
		});
		return addList;
	}

	private Box buildBannerContent() {
		this.bannerRevealer = new Revealer;
		this.bannerRevealer.setTransitionType(RevealerTransitionType.SlideDown);
		this.bannerRevealer.setTransitionDuration(REVEAL_MS);
		this.bannerRevealer.setRevealChild(false);
		this.bannerRevealer.setHexpand(true);

		auto bannerBox = new Box(Orientation.Horizontal, 0);
		bannerBox.setHexpand(true);
		bannerBox.addCssClass("warning-banner");
		this.bannerLabel = new Label("");
		this.bannerLabel.addCssClass("heading");
		this.bannerLabel.setHexpand(true);
		this.bannerLabel.setHalign(Align.Center);
		bannerBox.append(this.bannerLabel);

		auto dismissButton = new Button;
		dismissButton.setChild(Image.newFromIconName("window-close-symbolic"));
		dismissButton.addCssClass("flat");
		dismissButton.addCssClass("banner-dismiss");
		auto capturedRevealer = this.bannerRevealer;
		dismissButton.connectClicked(() {
			capturedRevealer.setRevealChild(false);
		});
		bannerBox.append(dismissButton);

		this.bannerRevealer.setChild(bannerBox);
		auto content = new Box(Orientation.Vertical, 0);
		content.setHexpand(true);
		content.setVexpand(true);
		content.append(this.bannerRevealer);
		return content;
	}

	private void wireUpdateAllButton(
		UpdateAllSection section,
		AppRowResult[] results) {
		AppRowResult[] capturedForAll = results;
		Revealer capturedUpdateAllRevealer = section.revealer;
		Button capturedUpdateAllButton = section.button;
		section.button.connectClicked(() {
			int updatable = 0;
			foreach (ref r; capturedForAll)
				if (!r.entry.isOrphan && r.entry.updateAvailable
				&& r.entry.updateInfo.length)
					updatable++;
			if (updatable < 1)
				return;
			capturedUpdateAllButton.setSensitive(false);
			this.checkButton.setSensitive(false);
			int* remaining = new int(updatable);
			foreach (ref r; capturedForAll) {
				if (r.entry.isOrphan || !r.entry.updateAvailable
				|| !r.entry.updateInfo.length)
					continue;
				launchRowUpdate(
					r.entry,
					r.updateProgressBar,
					r.updateStatusLabel,
					r.updateLabel,
					remaining,
					capturedUpdateAllButton,
					this.checkButton,
					capturedUpdateAllRevealer,
					capturedForAll,
					() => cast(bool) atomicLoad(this.workCancelled));
			}
		});
	}

	private void wireCheckButton(
		AppRowResult[] results,
		InstallerUpdateSection installerSection,
		UpdateAllSection updateAllSection) {
		AppRowResult[] capturedForCheck = results;
		Revealer capturedInstallerRevealer = installerSection.revealer;
		Label capturedInstallerSubLabel = installerSection.subLabel;
		Label capturedUpdateAllCountLabel = updateAllSection.countLabel;
		Revealer capturedUpdateAllRevealer = updateAllSection.revealer;
		this.checkButton.connectClicked(() {
			auto checkingBox = new Box(Orientation.Horizontal, ManageLayout.contentRowSpacing);
			auto checkSpinner = new Spinner;
			checkSpinner.setSpinning(true);
			checkingBox.append(checkSpinner);
			checkingBox.append(new Label(L("button.checking_updates")));
			this.checkButton.setChild(checkingBox);
			this.checkButton.setSensitive(false);
			auto thread = new Thread({
				foreach (ref appRowResult; capturedForCheck) {
					if (appRowResult.entry.isOrphan
					|| appRowResult.updateLabel is null
					|| !appRowResult.entry.updateInfo.length)
						continue;
					string error;
					bool available = checkOneApp(appRowResult.entry, error);
					if (error.length)
						continue;
					Label capturedLabel = appRowResult.updateLabel;
					string capturedDir = appRowResult.entry.appDirectory;
					bool capturedAvailable = available;
					idleAdd(PRIORITY_DEFAULT, () {
						auto installedAppManifest =
						Manifest.loadFromAppDir(capturedDir);
						if (installedAppManifest !is null
						&& installedAppManifest.updateAvailable
						!= capturedAvailable) {
							installedAppManifest.updateAvailable =
							capturedAvailable;
							installedAppManifest.save();
						}
						capturedLabel.setVisible(capturedAvailable);
						return false;
					});
				}
				string installerLatestVer;
				string installerError;
				bool installerAvail =
				checkInstallerUpdate(installerLatestVer, installerError);
				if (installerAvail)
					writeInstallerUpdateFlag(installerLatestVer);
				string capturedLatestVer = installerLatestVer;
				bool capturedInstallerAvail = installerAvail;
				idleAdd(PRIORITY_DEFAULT, () {
					if (capturedInstallerAvail) {
						this.installerUpdateVersion = capturedLatestVer;
						capturedInstallerSubLabel.setText(
						L("manage.installer.update.version", capturedLatestVer));
						capturedInstallerRevealer.setRevealChild(true);
					}
					int updateCount = 0;
					foreach (ref rowResult; capturedForCheck)
						if (rowResult.updateLabel !is null && rowResult.updateLabel.getVisible())
							updateCount++;
					capturedUpdateAllCountLabel.setText(
					L("manage.update_all.subtitle", updateCount));
					capturedUpdateAllRevealer.setRevealChild(updateCount >= 2);
					auto restoredBox = new Box(Orientation.Horizontal, ManageLayout
					.contentRowSpacing);
					restoredBox.append(
					makeIcon([
						"software-update-available-symbolic",
						"system-software-update-symbolic"
					]));
					restoredBox.append(new Label(L("button.check_updates")));
					this.checkButton.setChild(restoredBox);
					this.checkButton.setSensitive(true);
					return false;
				});
			});
			thread.isDaemon = true;
			thread.start();
		});
	}

	private void wireRowRevealers(AppRowResult[] results) {
		Revealer[] revealers;
		CssProvider[] highlights;
		GestureClick[] clicks;
		ListBoxRow[] toggleRows;
		Image[] chevrons;
		Box[] mainRows;
		foreach (ref rowResult; results) {
			if (rowResult.revealer is null)
				continue;
			revealers ~= rowResult.revealer;
			highlights ~= rowResult.highlight;
			clicks ~= rowResult.click;
			toggleRows ~= rowResult.row;
			chevrons ~= rowResult.chevron;
			mainRows ~= rowResult.mainRow;
		}
		foreach (clickIndex; 0 .. clicks.length)
			bindToggleClick(
				clicks[clickIndex],
				clickIndex,
				revealers,
				highlights,
				toggleRows,
				chevrons,
				mainRows[clickIndex]);
		foreach (clickIndex; 0 .. clicks.length)
			clicks[clickIndex].connectPressed(
				(int pressCount, double xCoordinate,
					double yCoordinate, GestureClick gesture) {
				this.setFocus(null);
			});
	}

	override void showWindow() {
		import std.stdio : writeln;

		writeln("ManageWindow: building UI for ", this.installedApps.length, " apps");

		this.setTitle(L("window.title.manager"));
		this.setupSearchBar();
		this.setupHeaderButtons();

		InstalledApp[] installed, orphans;
		foreach (ref installedApp; this.installedApps)
			(installedApp.isOrphan ? orphans : installed) ~= installedApp;

		bool hasBoth = installed.length > 0 && orphans.length > 0;

		this.installedListBox = new ListBox;
		this.installedListBox.setHexpand(true);
		this.installedListBox.addCssClass("boxed-list");
		this.installedListBox.setSelectionMode(SelectionMode.None);
		this.orphanListBox = new ListBox;
		this.orphanListBox.setHexpand(true);
		this.orphanListBox.addCssClass("boxed-list");
		this.orphanListBox.setSelectionMode(SelectionMode.None);

		auto appList = new Box(Orientation.Vertical, 0);
		appList.setHexpand(true);
		appList.setMarginTop(Layout.rowMargin);
		appList.setMarginBottom(Layout.rowMargin);
		appList.setMarginStart(Layout.rowMargin);
		appList.setMarginEnd(Layout.rowMargin);

		AppRowResult[] results;
		auto installerSection = this.buildInstallerUpdateSection();
		appList.append(installerSection.revealer);
		auto updateAllSection = this.buildUpdateAllSection();
		appList.append(updateAllSection.revealer);

		this.installedSectionHeader =
			makeSectionHeader(L("manage.section.installed"));
		if (!hasBoth)
			this.installedSectionHeader.hide();
		appList.append(this.installedSectionHeader);
		appList.append(this.installedListBox);
		appendAppGroup(this, installed, 0, this.installedListBox, results);
		if (installed.length == 0)
			this.installedListBox.hide();

		this.orphanSectionBox = new Box(Orientation.Vertical, 0);
		this.orphanSectionBox.setHexpand(true);
		this.orphanSectionBox.setMarginTop(ManageLayout.orphanSectionTopMargin);
		this.orphanDivider = new Box(Orientation.Vertical, 0);
		this.orphanDivider.append(makeSectionHeader(L("manage.section.orphan")));
		if (!hasBoth)
			this.orphanDivider.hide();
		this.orphanSectionBox.append(this.orphanDivider);
		this.orphanSectionBox.append(this.orphanListBox);
		if (orphans.length == 0)
			this.orphanSectionBox.hide();
		appList.append(this.orphanSectionBox);
		if (orphans.length > 0)
			appendAppGroup(
				this,
				orphans,
				installed.length,
				this.orphanListBox,
				results);

		appList.append(this.buildAddList());

		this.rowResults = results;

		// Set initial "Update All" count but keep revealer hidden until the content settles
		int initialUpdateCount = countUpdatable(results);
		if (initialUpdateCount >= 2) {
			updateAllSection.countLabel.setText(
				L("manage.update_all.subtitle", initialUpdateCount));
			Revealer delayedRevealer = updateAllSection.revealer;
			timeoutAdd(PRIORITY_DEFAULT, CONTENT_REVEAL_DELAY_MS, () {
				delayedRevealer.setRevealChild(true);
				return false;
			});
		}

		this.wireUpdateAllButton(updateAllSection, results);
		this.wireCheckButton(results, installerSection, updateAllSection);
		this.wireRowRevealers(results);

		auto scroll = new ScrolledWindow;
		scroll.setHexpand(true);
		scroll.setVexpand(true);
		scroll.setPolicy(PolicyType.Never, PolicyType.Automatic);
		scroll.setChild(appList);

		auto content = this.buildBannerContent();
		content.append(scroll);
		this.manageContent = content;

		this.subSlot = new Box(Orientation.Vertical, 0);
		this.subSlot.setHexpand(true);
		this.subSlot.setVexpand(true);

		this.navStack = new Stack;
		this.navStack.setHexpand(true);
		this.navStack.setVexpand(true);
		this.navStack.setTransitionDuration(NAV_SLIDE_MS);
		this.navStack.setTransitionType(StackTransitionType.SlideLeft);
		this.emptyStateBox = buildEmptyBox(
			() {
			this.slideToSub(
				buildAddAppBox(this, () => this.slideBackToManage()));
		});

		this.navStack.addNamed(content, "manage");
		this.navStack.addNamed(this.subSlot, "sub");
		this.navStack.addNamed(this.emptyStateBox, "empty");
		this.navStack.setVisibleChildName("manage");
		if (this.installedApps.length == 0) {
			this.navStack.setVisibleChildName("empty");
			this.searchButton.hide();
			this.checkButton.hide();
		}
		this.toolbarView.setContent(this.navStack);

		this.setupDropTarget();

		startWatcher(this);
		this.connectDestroy(() {
			foreach (m; this.appMonitors)
				m.cancel();
		});
	}

	// Registers a DropTarget on this window for .AppImage files
	private void setupDropTarget() {
		if (this.activeDropTarget !is null)
			this.removeController(this.activeDropTarget);
		this.activeDropTarget = new DropTarget(
			GioFile._getGType(), DragAction.Copy);
		this.addController(this.activeDropTarget);
		this.activeDropTarget.connectDrop(
			(Value dropValue, double x, double y) {
			auto droppedObject = dropValue.getObject();
			if (droppedObject is null)
				return false;
			auto rawPath = g_file_get_path(
				cast(GFile*) droppedObject._cPtr(No.Dup));
			if (rawPath is null)
				return false;
			string path = fromStringz(rawPath).idup;
			g_free(rawPath);
			if (!path.endsWith(".AppImage")
			&& !path.endsWith(".appimage"))
				return false;
			this.openFileForInstall(path);
			return true;
		});
	}

	// Opens an InstallWindow for the given AppImage file
	// If updateInfo is given, it overrides the ELF update info in the manifest
	package void openFileForInstall(string path, string updateInfo = "") {
		import appimage : AppImage;
		import windows.install : InstallWindow;

		auto appImage = new AppImage(path);
		if (updateInfo.length > 0)
			appImage.pendingUpdateInfo = updateInfo;
		auto installWindow = new InstallWindow(this.app, appImage);
		// When the user closes the install window, open a fresh manager
		installWindow.onCloseCallback = () {
			installWindow.close();
			auto nextManage = new ManageWindow(this.app);
			nextManage.present();
			nextManage.loadingSpinner.start();
			nextManage.doThreadedWork(
				&nextManage.loadWindow, &nextManage.showWindow);
		};
		installWindow.present();
		installWindow.loadingSpinner.start();
		installWindow.doThreadedWork(
			&installWindow.loadWindow, &installWindow.showWindow);
		this.close();
	}

	// Hides the orphan section when all orphan rows are gone Called by cleanup button click handlers in manage/row.d
	package void hideOrphanSectionIfEmpty() {
		watcherHideOrphanSection(this);
	}

	// Replaces subSlot content and slides navStack left to the sub page
	package void slideToSub(Widget content) {
		foreach (m; this.appMonitors)
			m.cancel();
		this.appMonitors = [];
		if (this.searchIsOpen) {
			this.searchIsOpen = false;
			this.headerBar.setTitleWidget(null);
			this.searchBar.setText("");
			scheduleFilter("");
		}
		if (this.searchButton !is null)
			this.searchButton.hide();
		if (this.checkButton !is null)
			this.checkButton.hide();
		if (this.menuButton !is null)
			this.menuButton.hide();

		auto previousChild = this.subSlot.getFirstChild();
		if (previousChild !is null)
			this.subSlot.remove(previousChild);
		this.subSlot.append(content);
		this.navStack.setTransitionType(StackTransitionType.SlideLeft);
		this.navStack.setVisibleChildName("sub");
	}

	// Reveals the installer update card so it is ready when the user navigates back
	public void setInstallerUpdateAvailable(string newVersion) {
		this.installerUpdateVersion = newVersion;
		if (this.installerUpdateSubLabel !is null)
			this.installerUpdateSubLabel.setText(
				L("manage.installer.update.version", newVersion));
		this.installerUpdateRevealer.setRevealChild(true);
	}

	// Reveals the installer update card and schedules the update button click
	public void revealInstallerUpdate(string newVersion) {
		this.setInstallerUpdateAvailable(newVersion);
		Button capturedBtn = this.installerUpdateButton;
		idleAdd(PRIORITY_DEFAULT, () {
			if (capturedBtn !is null)
				capturedBtn.activate();
			return false;
		});
	}

	// Slides navStack right back to the manage page
	package void slideBackToManage() {
		foreach (ref app; this.installedApps)
			if (!app.isOrphan && !isStillInstalled(app))
				app.isOrphan = true;

		bool isEmpty = !hasAnyActiveApps(this) && !this.orphanSectionBox.getVisible();

		if (!isEmpty)
			startWatcher(this);
		if (!isEmpty && this.searchButton !is null)
			this.searchButton.show();
		if (!isEmpty && this.checkButton !is null)
			this.checkButton.show();
		if (!isEmpty && this.menuButton !is null)
			this.menuButton.show();
		this.navStack.setTransitionType(StackTransitionType.SlideRight);
		this.navStack.setVisibleChildName(isEmpty ? "empty" : "manage");
	}
}
