// Per-app options page for changing name, comment, version, and update method
module windows.options;

import std.exception : collectException;
import std.file : exists, readText, write, FileException, mkdirRecurse;
import std.process : execute, ProcessException;
import std.array : join, split;
import std.string : indexOf, splitLines, startsWith, strip, toStringz;
import std.path : buildPath;
import std.stdio : writeln;
import std.typecons : Yes;

import glib.error : ErrorWrap;
import gio.async_result : AsyncResult;
import gobject.object : ObjectWrap;
import gtk.alert_dialog : AlertDialog;
import gtk.box : Box;
import gtk.button : Button;
import gtk.c.functions : gtk_alert_dialog_new;
import gtk.entry : Entry;
import gtk.image : Image;
import gtk.label : Label;
import gtk.list_box : ListBox;
import gtk.list_box_row : ListBoxRow;
import gtk.scrolled_window : ScrolledWindow;
import gtk.separator : Separator;
import gtk.gesture_click : GestureClick;
import gtk.stack : Stack;
import gtk.switch_ : Switch;
import gtk.types : Align, Orientation, PolicyType, SelectionMode, StackTransitionType;
import gtk.window : Window;

import appimage.install : portableHomeDir, portableConfigDir, reapplyPortableExec;
import appimage.manifest : Manifest;
import types : InstallMethod;
import update.directlink : isDirectLink, extractDirectLinkUrl;
import update.githubrelease : isGitHubRelease;
import update.githubzsync : isGitHubZsync;
import update.githublinuxmanifest : isGitHubLinuxManifest;
import update.zsync : isZsync, extractZsyncUrl;
import update.pling : isPling, parsePlingId;
import windows.addupdate : buildAddUpdateMethodBox;
import windows.addupdate.helpers : isValidDirect, isValidGitHub, isValidPling, isValidZsync;
import windows.base : ANIM_DURATION_MS;
import constants : APPLICATIONS_SUBDIR, DESKTOP_SUFFIX, TAG_LATEST, TAG_LATEST_PRE, TAG_LATEST_ALL;
import lang : L;

// Pixel measurements for the options page layout
private enum Layout {
	pageMarginHorizontal = 20,
	pageMarginVertical = 16,
	groupSpacing = 18,
	rowPadding = 12,
	rowSideMargin = 14,
	rowSpacing = 8,
	cardIconSize = 32,
	cardIconMarginEnd = 14,
	cardTextSpacing = 3,
	checkIconMarginEnd = 8,
	checkMarkSize = 16,
	iconSize = 48,
	iconMarginBottom = 6,
	titleMarginBottom = 14,
	changeButtonHeight = 30,
	saveButtonWidth = 120,
	saveButtonHeight = 32,
	labelWidth = 110,
}

private string describeUpdateMethod(string updateInfo) {
	if (isGitHubZsync(updateInfo))
		return L("options.update.method.ghzsync");
	if (isGitHubRelease(updateInfo))
		return L("options.update.method.ghrelease");
	if (isGitHubLinuxManifest(updateInfo))
		return L("options.update.method.ghlinuxyml");
	if (isZsync(updateInfo))
		return L("options.update.method.zsync");
	if (isDirectLink(updateInfo))
		return L("options.update.method.direct");
	if (isPling(updateInfo))
		return L("options.update.method.pling");
	if (updateInfo.length)
		return L("options.update.unknown") ~ ": " ~ updateInfo.split("|")[0];
	return L("options.update.none");
}

// Patches a key= in [Desktop Entry], removing locale variants and preserving line endings
// Inserts the key after [Desktop Entry] if it was not there before
private void patchDesktopField(string path, string key, string value) {
	if (!exists(path))
		return;
	string raw = readText(path);
	string lineEnding = raw.indexOf("\r\n") >= 0 ? "\r\n" : "\n";
	auto allLines = raw.splitLines();
	string exactPrefix = key ~ "=";
	string localePrefix = key ~ "[";
	int sectionStart = -1;
	int sectionEnd = cast(int) allLines.length;
	foreach (i, line; allLines) {
		if (line == "[Desktop Entry]") {
			sectionStart = cast(int) i;
		} else if (sectionStart >= 0 && line.startsWith("[")) {
			sectionEnd = cast(int) i;
			break;
		}
	}
	if (sectionStart < 0)
		return;
	bool patched = false;
	string[] result;
	foreach (i, line; allLines) {
		if (i >= cast(size_t) sectionStart
			&& i < cast(size_t) sectionEnd) {
			if (!patched && line.startsWith(exactPrefix)) {
				result ~= exactPrefix ~ value;
				patched = true;
				continue;
			}
			if (line.startsWith(localePrefix))
				continue;
		}
		result ~= line;
	}
	if (!patched) {
		result = allLines[0 .. sectionStart + 1]
			~ [exactPrefix ~ value]
			~ allLines[sectionStart + 1 .. $];
	}
	try {
		write(path, result.join(lineEnding) ~ lineEnding);
	} catch (FileException error) {
		writeln("options: failed to patch desktop field ", key, ": ", error.msg);
	}
}

// Builds the per-app options page with grouped boxed-list fields and release type cards
Box buildOptionsBox(
	string appName,
	string sanitizedName,
	string appDirectory,
	void delegate(void delegate(), void delegate()) doWork,
	void delegate() onDisableBack,
	void delegate() onEnableBack,
	void delegate(
		void delegate()) setBackAction,
	void delegate() onDone) {

	auto navStack = new Stack;
	navStack.setTransitionDuration(ANIM_DURATION_MS);
	navStack.setHexpand(true);
	navStack.setVexpand(true);

	auto addUpdateSlot = new Box(Orientation.Vertical, 0);
	addUpdateSlot.setHexpand(true);
	addUpdateSlot.setVexpand(true);

	auto settingsBox = new Box(Orientation.Vertical, Layout.groupSpacing);
	settingsBox.setMarginStart(Layout.pageMarginHorizontal);
	settingsBox.setMarginEnd(Layout.pageMarginHorizontal);
	settingsBox.setMarginTop(Layout.pageMarginVertical);
	settingsBox.setMarginBottom(Layout.pageMarginVertical);
	settingsBox.setHexpand(true);

	auto scroll = new ScrolledWindow;
	scroll.setHexpand(true);
	scroll.setVexpand(true);
	scroll.setPolicy(PolicyType.Never, PolicyType.Automatic);
	scroll.setChild(settingsBox);

	auto headerIcon = Image.newFromIconName("preferences-system-symbolic");
	headerIcon.addCssClass("icon-dropshadow");
	headerIcon.setSizeRequest(Layout.iconSize, Layout.iconSize);
	headerIcon.setPixelSize(Layout.iconSize);
	headerIcon.setHalign(Align.Center);
	headerIcon.setMarginBottom(Layout.iconMarginBottom);
	settingsBox.append(headerIcon);

	auto titleLabel = new Label(appName);
	titleLabel.addCssClass("title-3");
	titleLabel.setHalign(Align.Center);
	titleLabel.setMarginBottom(Layout.titleMarginBottom);
	settingsBox.append(titleLabel);

	// Section heading label using the section-heading CSS class (small caps, dimmed)
	Label makeHeading(string text) {
		auto label = new Label(text);
		label.addCssClass("section-heading");
		label.setHalign(Align.Start);
		return label;
	}

	// Boxed-list row with a left label and right entry field, not activatable
	ListBoxRow makeInfoRow(string title, string placeholder, out Entry entry) {
		auto rowBox = new Box(Orientation.Horizontal, Layout.rowSpacing);
		rowBox.setMarginTop(Layout.rowPadding);
		rowBox.setMarginBottom(Layout.rowPadding);
		rowBox.setMarginStart(Layout.rowSideMargin);
		rowBox.setMarginEnd(Layout.rowSideMargin);
		auto label = new Label(title);
		label.setHalign(Align.Start);
		label.setXalign(0.0f);
		label.setValign(Align.Center);
		label.setSizeRequest(Layout.labelWidth, -1);
		rowBox.append(label);
		entry = new Entry;
		entry.setPlaceholderText(placeholder);
		entry.setHexpand(true);
		entry.setValign(Align.Center);
		rowBox.append(entry);
		auto row = new ListBoxRow;
		row.setChild(rowBox);
		row.setActivatable(false);
		return row;
	}

	// Selectable card row for the release type list, with a check icon on the left
	ListBoxRow makeTagCard(
		string iconName, string title, string subtitle, out Image checkMark) {
		checkMark = Image.newFromIconName("object-select-symbolic");
		checkMark.setPixelSize(Layout.checkMarkSize);
		checkMark.setValign(Align.Center);
		checkMark.setMarginEnd(Layout.checkIconMarginEnd);
		checkMark.setVisible(false);

		auto icon = Image.newFromIconName(iconName);
		icon.setPixelSize(Layout.cardIconSize);
		icon.setValign(Align.Center);
		icon.setMarginEnd(Layout.cardIconMarginEnd);

		auto titleLbl = new Label(title);
		titleLbl.addCssClass("heading");
		titleLbl.setHalign(Align.Start);

		auto subtitleLbl = new Label(subtitle);
		subtitleLbl.addCssClass("caption");
		subtitleLbl.addCssClass("dim-label");
		subtitleLbl.setHalign(Align.Start);

		auto textCol = new Box(Orientation.Vertical, Layout.cardTextSpacing);
		textCol.setValign(Align.Center);
		textCol.setHexpand(true);
		textCol.append(titleLbl);
		textCol.append(subtitleLbl);

		auto rowBox = new Box(Orientation.Horizontal, 0);
		rowBox.setMarginTop(Layout.rowPadding);
		rowBox.setMarginBottom(Layout.rowPadding);
		rowBox.setMarginStart(Layout.rowSideMargin);
		rowBox.setMarginEnd(Layout.rowSideMargin);
		rowBox.append(checkMark);
		rowBox.append(icon);
		rowBox.append(textCol);

		auto row = new ListBoxRow;
		row.setActivatable(false);
		row.setChild(rowBox);
		return row;
	}

	settingsBox.append(makeHeading(L("options.group.info")));
	auto infoList = new ListBox;
	infoList.addCssClass("boxed-list");
	infoList.setSelectionMode(SelectionMode.None);
	// Boxed-list row showing a static label value, not editable
	ListBoxRow makeDisplayRow(string title, out Label valueLabel) {
		auto rowBox = new Box(Orientation.Horizontal, Layout.rowSpacing);
		rowBox.setMarginTop(Layout.rowPadding);
		rowBox.setMarginBottom(Layout.rowPadding);
		rowBox.setMarginStart(Layout.rowSideMargin);
		rowBox.setMarginEnd(Layout.rowSideMargin);
		auto label = new Label(title);
		label.setHalign(Align.Start);
		label.setXalign(0.0f);
		label.setValign(Align.Center);
		label.setSizeRequest(Layout.labelWidth, -1);
		rowBox.append(label);
		valueLabel = new Label("");
		valueLabel.setHalign(Align.End);
		valueLabel.setHexpand(true);
		valueLabel.setValign(Align.Center);
		valueLabel.addCssClass("dim-label");
		rowBox.append(valueLabel);
		auto row = new ListBoxRow;
		row.setChild(rowBox);
		row.setActivatable(false);
		return row;
	}

	Entry nameEntry, commentEntry;
	Label versionDisplayLabel;
	infoList.append(makeInfoRow(
			L("options.name.title"), L("options.name.placeholder"), nameEntry));
	infoList.append(makeInfoRow(
			L("options.comment.title"), L("options.comment.placeholder"), commentEntry));
	infoList.append(makeDisplayRow(L("options.version.title"), versionDisplayLabel));
	settingsBox.append(infoList);

	settingsBox.append(makeHeading(L("options.group.update")));

	// Shows the current update method alongside the Change button
	auto methodList = new ListBox;
	methodList.addCssClass("boxed-list");
	methodList.setSelectionMode(SelectionMode.None);
	auto methodRowBox = new Box(Orientation.Horizontal, Layout.rowSpacing);
	methodRowBox.setMarginTop(Layout.rowPadding);
	methodRowBox.setMarginBottom(Layout.rowPadding);
	methodRowBox.setMarginStart(Layout.rowSideMargin);
	methodRowBox.setMarginEnd(Layout.rowSideMargin);
	auto updateMethodLabel = new Label("");
	updateMethodLabel.setHalign(Align.Start);
	updateMethodLabel.setXalign(0.0f);
	updateMethodLabel.setHexpand(true);
	auto changeButton = Button.newWithLabel(L("options.update.change"));
	changeButton.addCssClass("pill");
	changeButton.setValign(Align.Center);
	methodRowBox.append(updateMethodLabel);
	methodRowBox.append(changeButton);
	auto methodLBRow = new ListBoxRow;
	methodLBRow.setChild(methodRowBox);
	methodLBRow.setActivatable(false);
	methodList.append(methodLBRow);
	settingsBox.append(methodList);

	// GitHub repository URL and asset pattern inputs
	auto gitHubList = new ListBox;
	gitHubList.addCssClass("boxed-list");
	gitHubList.setSelectionMode(SelectionMode.None);
	gitHubList.setVisible(false);
	Entry gitHubRepositoryEntry, gitHubPatternEntry;
	gitHubList.append(makeInfoRow(
			L("options.update.repo.title"),
			L("options.update.repo.placeholder"),
			gitHubRepositoryEntry));
	gitHubList.append(makeInfoRow(
			L("options.update.pattern.title"),
			L("options.update.pattern.placeholder"),
			gitHubPatternEntry));
	settingsBox.append(gitHubList);

	// Release type heading and selectable card list
	auto releaseHeading = makeHeading(L("options.update.release.title"));
	releaseHeading.setVisible(false);
	settingsBox.append(releaseHeading);

	auto releaseList = new ListBox;
	releaseList.addCssClass("boxed-list");
	releaseList.setSelectionMode(SelectionMode.None);
	releaseList.setVisible(false);
	Image checkLatest, checkLatestPre, checkLatestAll, checkSpecific;
	auto rowLatest = makeTagCard(
		"emblem-ok-symbolic",
		L("options.update.release.latest"),
		L("options.update.release.latest.sub"),
		checkLatest);
	auto rowLatestPre = makeTagCard(
		"emblem-important-symbolic",
		L("options.update.release.pre"),
		L("options.update.release.pre.sub"),
		checkLatestPre);
	auto rowLatestAll = makeTagCard(
		"view-more-symbolic",
		L("options.update.release.all"),
		L("options.update.release.all.sub"),
		checkLatestAll);
	auto rowSpecific = makeTagCard(
		"bookmark-new-symbolic",
		L("options.update.release.specific"),
		L("options.update.release.specific.sub"),
		checkSpecific);
	releaseList.append(rowLatest);
	releaseList.append(rowLatestPre);
	releaseList.append(rowLatestAll);
	releaseList.append(rowSpecific);
	settingsBox.append(releaseList);

	// Specific tag entry, shown only when the Specific Tag card is selected
	auto customTagList = new ListBox;
	customTagList.addCssClass("boxed-list");
	customTagList.setSelectionMode(SelectionMode.None);
	customTagList.setVisible(false);
	Entry customTagEntry;
	customTagList.append(makeInfoRow(
			L("options.update.tag.title"), L("options.update.tag.placeholder"), customTagEntry));
	settingsBox.append(customTagList);

	// Product ID field for Pling Store method
	auto plingList = new ListBox;
	plingList.addCssClass("boxed-list");
	plingList.setSelectionMode(SelectionMode.None);
	plingList.setVisible(false);
	Entry plingProductIdEntry;
	plingList.append(makeInfoRow(
			L("options.update.pling.id.title"),
			L("options.update.pling.id.placeholder"), plingProductIdEntry));
	settingsBox.append(plingList);

	// URL field for zsync and direct-link methods
	auto urlList = new ListBox;
	urlList.addCssClass("boxed-list");
	urlList.setSelectionMode(SelectionMode.None);
	urlList.setVisible(false);
	Entry urlEntry;
	urlList.append(makeInfoRow(
			L("options.update.url.title"), L("options.update.url.placeholder"), urlEntry));
	settingsBox.append(urlList);

	settingsBox.append(makeHeading(L("options.group.portable")));
	auto portableList = new ListBox;
	portableList.addCssClass("boxed-list");
	portableList.setSelectionMode(SelectionMode.None);

	auto portableHomeSwitch = new Switch;
	portableHomeSwitch.setValign(Align.Center);
	auto portableHomeRowBox = new Box(Orientation.Horizontal, Layout.rowSpacing);
	portableHomeRowBox.setMarginTop(Layout.rowPadding);
	portableHomeRowBox.setMarginBottom(Layout.rowPadding);
	portableHomeRowBox.setMarginStart(Layout.rowSideMargin);
	portableHomeRowBox.setMarginEnd(Layout.rowSideMargin);
	auto portableHomeLabel = new Label(L("options.portable.home.title"));
	portableHomeLabel.setHalign(Align.Start);
	portableHomeLabel.setValign(Align.Center);
	portableHomeLabel.setHexpand(true);
	portableHomeRowBox.append(portableHomeLabel);
	auto browseHomeButton = Button.newWithLabel(L("button.browse"));
	browseHomeButton.addCssClass("pill");
	browseHomeButton.setValign(Align.Center);
	portableHomeRowBox.append(browseHomeButton);
	portableHomeRowBox.append(portableHomeSwitch);
	auto portableHomeRow = new ListBoxRow;
	portableHomeRow.setActivatable(false);
	portableHomeRow.setChild(portableHomeRowBox);
	portableList.append(portableHomeRow);

	auto portableConfigSwitch = new Switch;
	portableConfigSwitch.setValign(Align.Center);
	auto portableConfigRowBox = new Box(Orientation.Horizontal, Layout.rowSpacing);
	portableConfigRowBox.setMarginTop(Layout.rowPadding);
	portableConfigRowBox.setMarginBottom(Layout.rowPadding);
	portableConfigRowBox.setMarginStart(Layout.rowSideMargin);
	portableConfigRowBox.setMarginEnd(Layout.rowSideMargin);
	auto portableConfigLabel = new Label(L("options.portable.config.title"));
	portableConfigLabel.setHalign(Align.Start);
	portableConfigLabel.setValign(Align.Center);
	portableConfigLabel.setHexpand(true);
	portableConfigRowBox.append(portableConfigLabel);
	auto browseConfigButton = Button.newWithLabel(L("button.browse"));
	browseConfigButton.addCssClass("pill");
	browseConfigButton.setValign(Align.Center);
	portableConfigRowBox.append(browseConfigButton);
	portableConfigRowBox.append(portableConfigSwitch);
	auto portableConfigRow = new ListBoxRow;
	portableConfigRow.setActivatable(false);
	portableConfigRow.setChild(portableConfigRowBox);
	portableList.append(portableConfigRow);
	settingsBox.append(portableList);

	auto portableHomeNote = new Label(L("options.portable.home.note"));
	portableHomeNote.addCssClass("caption");
	portableHomeNote.addCssClass("dim-label");
	portableHomeNote.setHalign(Align.Start);
	portableHomeNote.setWrap(true);
	portableHomeNote.setMarginStart(Layout.rowSideMargin);
	settingsBox.append(portableHomeNote);

	auto portableConfigNote = new Label(L("options.portable.config.note"));
	portableConfigNote.addCssClass("caption");
	portableConfigNote.addCssClass("dim-label");
	portableConfigNote.setHalign(Align.Start);
	portableConfigNote.setWrap(true);
	portableConfigNote.setMarginStart(Layout.rowSideMargin);
	settingsBox.append(portableConfigNote);

	auto saveButton = Button.newWithLabel(L("button.save"));
	saveButton.setSizeRequest(Layout.saveButtonWidth, Layout.saveButtonHeight);
	saveButton.addCssClass("pill");
	saveButton.setHalign(Align.End);
	saveButton.setSensitive(false);
	settingsBox.append(saveButton);

	navStack.addNamed(scroll, "settings");
	navStack.addNamed(addUpdateSlot, "addupdate");
	navStack.setVisibleChildName("settings");

	string currentName, currentComment;
	string currentRepository;
	string currentPattern;
	string currentTag;
	string currentUrl;
	string currentPlingProductId;
	string currentUpdateInfo;
	bool currentPortableHome;
	bool currentPortableConfig;
	InstallMethod currentInstallMethod = InstallMethod.AppImage;
	int selectedTagIndex = 0;
	auto knownTags = [TAG_LATEST, TAG_LATEST_PRE, TAG_LATEST_ALL];
	ListBoxRow[] releaseRowArr = [
		rowLatest, rowLatestPre, rowLatestAll, rowSpecific
	];
	Image[] releaseCheckArr = [
		checkLatest, checkLatestPre, checkLatestAll, checkSpecific
	];
	string desktopPath = buildPath(
		appDirectory, APPLICATIONS_SUBDIR, sanitizedName ~ DESKTOP_SUFFIX);

	// Updates which release type card appears selected and shows/hides the custom tag entry
	void selectTagRow(int tagRowIndex) {
		foreach (i, row; releaseRowArr) {
			if (i == tagRowIndex)
				row.addCssClass("open-row");
			else
				row.removeCssClass("open-row");
			releaseCheckArr[i].setVisible(i == tagRowIndex);
		}
		customTagList.setVisible(tagRowIndex == 3);
		selectedTagIndex = tagRowIndex;
	}

	void updateSaveSensitive() {
		if (!nameEntry.getText().strip().length) {
			saveButton.setSensitive(false);
			return;
		}
		bool dirty =
			nameEntry.getText() != currentName ||
			commentEntry.getText() != currentComment;
		if (gitHubList.getVisible()) {
			string newTag = selectedTagIndex < 3
				? knownTags[selectedTagIndex] : customTagEntry.getText();
			dirty = dirty
				|| gitHubRepositoryEntry.getText() != currentRepository
				|| gitHubPatternEntry.getText() != currentPattern
				|| newTag != currentTag;
			if (!isValidGitHub(gitHubRepositoryEntry.getText())) {
				saveButton.setSensitive(false);
				return;
			}
		}
		if (urlList.getVisible()) {
			dirty = dirty || urlEntry.getText() != currentUrl;
			bool urlOk = isZsync(currentUpdateInfo)
				? isValidZsync(urlEntry.getText()) : isValidDirect(urlEntry.getText());
			if (!urlOk) {
				saveButton.setSensitive(false);
				return;
			}
		}
		if (plingList.getVisible()) {
			dirty = dirty
				|| plingProductIdEntry.getText().strip() != currentPlingProductId;
			if (!isValidPling(plingProductIdEntry.getText())) {
				saveButton.setSensitive(false);
				return;
			}
		}
		dirty = dirty
			|| portableHomeSwitch.getActive() != currentPortableHome
			|| portableConfigSwitch.getActive() != currentPortableConfig;
		saveButton.setSensitive(dirty);
	}

	void loadState() {
		auto installedAppManifest = Manifest.loadFromAppDir(appDirectory);
		if (installedAppManifest is null)
			return;
		currentName = installedAppManifest.appName;
		currentComment = installedAppManifest.appComment;
		currentUpdateInfo = installedAppManifest.updateInfo;
		nameEntry.setText(currentName);
		commentEntry.setText(currentComment);
		versionDisplayLabel.setLabel(
			installedAppManifest.releaseVersion.length
				? installedAppManifest.releaseVersion : "-");
		updateMethodLabel.setLabel(describeUpdateMethod(currentUpdateInfo));
		gitHubList.setVisible(false);
		releaseHeading.setVisible(false);
		releaseList.setVisible(false);
		customTagList.setVisible(false);
		urlList.setVisible(false);
		plingList.setVisible(false);
		if (isGitHubRelease(currentUpdateInfo)
			|| isGitHubZsync(currentUpdateInfo)) {
			auto parts = currentUpdateInfo.split("|");
			currentRepository =
				parts.length >= 3 ? parts[1] ~ "/" ~ parts[2] : "";
			currentTag = parts.length >= 4 ? parts[3] : TAG_LATEST;
			currentPattern = parts.length >= 5 ? parts[4] : "";
			gitHubRepositoryEntry.setText(currentRepository);
			gitHubPatternEntry.setText(currentPattern);
			gitHubList.setVisible(true);
			releaseHeading.setVisible(true);
			releaseList.setVisible(true);
			int tagRowIndex = 3;
			foreach (i, knownTag; knownTags) {
				if (knownTag == currentTag) {
					tagRowIndex = cast(int) i;
					break;
				}
			}
			customTagEntry.setText(tagRowIndex == 3 ? currentTag : "");
			selectTagRow(tagRowIndex);
		} else if (isZsync(currentUpdateInfo)) {
			currentUrl = extractZsyncUrl(currentUpdateInfo);
			urlEntry.setText(currentUrl);
			urlList.setVisible(true);
		} else if (isDirectLink(currentUpdateInfo)) {
			currentUrl = extractDirectLinkUrl(currentUpdateInfo);
			urlEntry.setText(currentUrl);
			urlList.setVisible(true);
		} else if (isPling(currentUpdateInfo)) {
			currentPlingProductId = parsePlingId(currentUpdateInfo);
			plingProductIdEntry.setText(currentPlingProductId);
			plingList.setVisible(true);
		}
		currentPortableHome = installedAppManifest.portableHome;
		currentPortableConfig = installedAppManifest.portableConfig;
		currentInstallMethod = installedAppManifest.installMethod;
		portableHomeSwitch.setActive(currentPortableHome);
		portableConfigSwitch.setActive(currentPortableConfig);
	}

	loadState();

	// Wire click handlers for each release type card
	auto clickLatest = new GestureClick;
	rowLatest.addController(clickLatest);
	clickLatest.connectPressed((int pressCount, double xCoordinate, double yCoordinate, GestureClick gesture) {
		selectTagRow(0);
		updateSaveSensitive();
	});
	auto clickLatestPre = new GestureClick;
	rowLatestPre.addController(clickLatestPre);
	clickLatestPre.connectPressed((int pressCount, double xCoordinate, double yCoordinate, GestureClick gesture) {
		selectTagRow(1);
		updateSaveSensitive();
	});
	auto clickLatestAll = new GestureClick;
	rowLatestAll.addController(clickLatestAll);
	clickLatestAll.connectPressed((int pressCount, double xCoordinate, double yCoordinate, GestureClick gesture) {
		selectTagRow(2);
		updateSaveSensitive();
	});
	auto clickSpecific = new GestureClick;
	rowSpecific.addController(clickSpecific);
	clickSpecific.connectPressed((int pressCount, double xCoordinate, double yCoordinate, GestureClick gesture) {
		selectTagRow(3);
		updateSaveSensitive();
	});

	nameEntry.connectChanged(() { updateSaveSensitive(); });
	commentEntry.connectChanged(() { updateSaveSensitive(); });
	gitHubRepositoryEntry.connectChanged(() { updateSaveSensitive(); });
	gitHubPatternEntry.connectChanged(() { updateSaveSensitive(); });
	customTagEntry.connectChanged(() { updateSaveSensitive(); });
	urlEntry.connectChanged(() { updateSaveSensitive(); });
	plingProductIdEntry.connectChanged(() { updateSaveSensitive(); });
	portableHomeSwitch.connectStateSet((bool state) {
		updateSaveSensitive();
		return false;
	});
	portableConfigSwitch.connectStateSet((bool state) {
		updateSaveSensitive();
		return false;
	});
	browseHomeButton.connectClicked(() {
		string target = portableHomeDir(appDirectory);
		collectException(mkdirRecurse(target));
		try {
			execute(["xdg-open", target]);
		} catch (ProcessException) {
		}
	});
	browseConfigButton.connectClicked(() {
		string target = portableConfigDir(appDirectory);
		collectException(mkdirRecurse(target));
		try {
			execute(["xdg-open", target]);
		} catch (ProcessException) {
		}
	});

	saveButton.connectClicked(() {
		auto installedAppManifest = Manifest.loadFromAppDir(appDirectory);
		if (installedAppManifest is null)
			return;
		string newName = nameEntry.getText();
		string newComment = commentEntry.getText();
		if (newName != currentName) {
			installedAppManifest.appName = newName;
			patchDesktopField(desktopPath, "Name", newName);
			currentName = newName;
		}
		if (newComment != currentComment) {
			installedAppManifest.appComment = newComment;
			patchDesktopField(desktopPath, "Comment", newComment);
			currentComment = newComment;
		}
		if (gitHubList.getVisible()) {
			string newRepository = gitHubRepositoryEntry.getText();
			string newPattern = gitHubPatternEntry.getText();
			string newTag = selectedTagIndex < 3
				? knownTags[selectedTagIndex] : customTagEntry.getText();
			if (newRepository != currentRepository
			|| newPattern != currentPattern
			|| newTag != currentTag) {
				auto repositoryParts = newRepository.split("/");
				string ownerName =
					repositoryParts.length >= 1 ? repositoryParts[0] : "";
				string repositoryName =
					repositoryParts.length >= 2 ? repositoryParts[1] : "";
				auto parts = currentUpdateInfo.split("|");
				if (parts.length == 5) {
					parts[1] = ownerName;
					parts[2] = repositoryName;
					parts[3] = newTag;
					parts[4] = newPattern;
					currentUpdateInfo = parts.join("|");
					installedAppManifest.updateInfo = currentUpdateInfo;
					currentRepository = newRepository;
					currentPattern = newPattern;
					currentTag = newTag;
				}
			}
		} else if (urlList.getVisible()) {
			string newUrl = urlEntry.getText();
			if (newUrl != currentUrl) {
				auto parts = currentUpdateInfo.split("|");
				if (parts.length == 2) {
					parts[1] = newUrl;
					currentUpdateInfo = parts.join("|");
					installedAppManifest.updateInfo = currentUpdateInfo;
					currentUrl = newUrl;
				}
			}
		} else if (plingList.getVisible()) {
			string newPlingProductId = plingProductIdEntry.getText().strip();
			if (newPlingProductId != currentPlingProductId) {
				// Product ID changed so drop the old baseline
				// The next update check will compare against the installed file instead
				currentUpdateInfo = "pling-v1-zsync|" ~ newPlingProductId;
				installedAppManifest.updateInfo = currentUpdateInfo;
				currentPlingProductId = newPlingProductId;
			}
		}
		bool newPortableHome = portableHomeSwitch.getActive();
		bool newPortableConfig = portableConfigSwitch.getActive();
		if (newPortableHome != currentPortableHome
		|| newPortableConfig != currentPortableConfig) {
			reapplyPortableExec(
				desktopPath, appDirectory, sanitizedName,
				currentInstallMethod, newPortableHome, newPortableConfig);
			if (newPortableHome)
				collectException(mkdirRecurse(portableHomeDir(appDirectory)));
			if (newPortableConfig)
				collectException(mkdirRecurse(portableConfigDir(appDirectory)));
			installedAppManifest.portableHome = newPortableHome;
			installedAppManifest.portableConfig = newPortableConfig;
			currentPortableHome = newPortableHome;
			currentPortableConfig = newPortableConfig;
		}
		installedAppManifest.save();
		saveButton.setSensitive(false);
	});

	void goBack() {
		if (!saveButton.getSensitive()) {
			onDone();
			return;
		}
		auto parentWin = cast(Window) navStack.getRoot();
		auto dlg = new AlertDialog(cast(void*) gtk_alert_dialog_new(
				"%s".ptr, L("dialog.unsaved.title").toStringz()), Yes.Take);
		dlg.setDetail(L("dialog.unsaved.body"));
		dlg.setButtons([L("button.discard"), L("button.cancel")]);
		dlg.setDefaultButton(1);
		dlg.setCancelButton(1);
		dlg.setModal(true);
		dlg.choose(parentWin, null, (ObjectWrap src, AsyncResult res) {
			try {
				if (dlg.chooseFinish(res) == 0)
					onDone();
			} catch (ErrorWrap) {
			}
		});
	}

	void backToSettings() {
		onEnableBack();
		loadState();
		navStack.setTransitionType(StackTransitionType.SlideRight);
		navStack.setVisibleChildName("settings");
		setBackAction(() { goBack(); });
	}

	changeButton.connectClicked(() {
		auto previous = addUpdateSlot.getFirstChild();
		if (previous !is null)
			addUpdateSlot.remove(previous);
		addUpdateSlot.append(buildAddUpdateMethodBox(
			appName,
			sanitizedName,
			doWork,
			onDisableBack,
			onEnableBack,
			setBackAction,
			() { backToSettings(); }
		));
		setBackAction(() { backToSettings(); });
		navStack.setTransitionType(StackTransitionType.SlideLeft);
		navStack.setVisibleChildName("addupdate");
	});

	setBackAction(() { goBack(); });

	auto outer = new Box(Orientation.Vertical, 0);
	outer.setHexpand(true);
	outer.setVexpand(true);
	outer.append(navStack);
	return outer;
}
