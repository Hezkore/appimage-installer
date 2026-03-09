// Two-phase install window that verifies a file then runs the installation
//
module windows.install;

import std.path : buildPath;
import std.stdio : writeln;
import std.string : toStringz;

import apputils : xdgDataHome, installBaseDir;

import glib.global : timeoutAdd;
import glib.types : PRIORITY_DEFAULT;
import glib.error : ErrorWrap;
import gtk.box : Box;
import gtk.button : Button;
import gtk.menu_button : MenuButton;
import gtk.gesture_click : GestureClick;
import gtk.center_box : CenterBox;
import gtk.image : Image;
import gtk.label : Label;
import gtk.list_box : ListBox;
import gtk.list_box_row : ListBoxRow;
import gtk.progress_bar : ProgressBar;
import gtk.revealer : Revealer;
import gtk.alert_dialog : AlertDialog;
import gtk.c.functions : gtk_alert_dialog_new;
import gdk.c.functions : gdk_clipboard_set_text;
import gdk.c.types : GdkClipboard;
import gtk.stack : Stack;
import gtk.overlay : Overlay;
import gtk.separator : Separator;
import gtk.widget : Widget;
import gtk.types : Align, Orientation, RevealerTransitionType, SelectionMode, StackTransitionType;
import pango.types : EllipsizeMode;
import gio.async_result : AsyncResult;
import gobject.object : ObjectWrap;
import std.typecons : Yes, No;

import windows.install.helpers;
import windows.base : AppWindow, ACTION_BTN_WIDTH, ACTION_BTN_HEIGHT, REVEAL_MS, makeLangButton;
import windows.base : CONTENT_REVEAL_DELAY_MS, ACTION_REVEAL_DELAY_MS;
import application : App;
import appimage : AppImage;
import appimage.signature : SignatureStatus;
import lang : L;

// Two-phase flow to verify a file is safe before installing it and showing the app branding
class InstallWindow : AppWindow {
	// When set, the close button calls this instead of quitting the application
	// Used when the manage window holds the install flow in-place
	public void delegate() onCloseCallback;
	private enum int VERIFY_ICON_SIZE = 128;
	private enum int BANNER_DELAY_MS = 0;
	private enum int BUTTON_ENABLE_DELAY_MS = 1000;
	private enum int ICON_SWAP_DELAY_MS = 100;
	private enum int SHOW_BUTTON_DELAY_MS = ACTION_REVEAL_DELAY_MS;
	private enum int PROGRESS_POLL_MS = 100;
	// Pixel measurements and spacing for the install window UI
	private enum Layout {
		actionButtonStart = 8,
		actionButtonEnd = 16,
		innerSpacing = 8,
		titleTopMargin = 4,
		labelSideMargin = 16,
		infoListVertMargin = 16,
		progressBarExtraWidth = 32,
		ctaMarginTop = 32,
		loadingPadding = 2,
		// Static top margin applied to contentBox so content is always offset below the overlay banner
		bannerReserveHeight = 40,
	}

	Box mainLayout;
	Revealer bannerRevealer;
	Stack bannerStack;
	CenterBox bannerBox;
	Label bannerLabel;
	Stack contentStack;
	Box contentBox;
	Stack iconStack;
	Image genericIconImage;
	Label appTitleLabel;
	Label appDescriptionLabel;
	Revealer versionRevealer;
	Label versionLabel;
	Stack actionStack;
	ProgressBar installProgressBar;
	Revealer descRevealer;
	Revealer actionRevealer;
	Button actionButton;
	MenuButton langButton;
	Revealer fileInfoRevealer;
	Revealer gpgDetailRevealer;

	bool userHasVerified;
	AppImage appImage;

	this(App app, AppImage appImage) {
		super(app);
		this.appImage = appImage;
		this.userHasVerified = false;
	}

	// Keeps the install in progress uninterrupted if language is switched while installing
	protected override void reloadWindow() {
		if (this.userHasVerified)
			return;
		super.reloadWindow();
	}

	// Two-pass load does basic info first and waits for user verification before loading full details
	override void loadWindow() {
		if (this.appImage is null)
			return;

		if (this.userHasVerified) {
			writeln("loadWindow: loading full AppImage info");
			this.appImage.loadFullInfo();
		} else {
			writeln("loadWindow: loading basic AppImage info");
			this.appImage.loadBasicInfo();
		}
	}

	// Called after loadWindow() finishes, on the GTK main thread
	override void showWindow() {
		if (this.userHasVerified) {
			writeln("InstallWindow: showing install phase");
			showInstallView();
		} else {
			writeln("InstallWindow: showing verify phase");
			showVerifyView();
		}
	}

	private void showVerifyView() {
		this.setTitle(L("window.title.installer"));
		this.langButton = makeLangButton(this);
		this.headerBar.packEnd(this.langButton);

		// Action button placed in the banner (not the header)
		this.actionButton = Button.newWithLabel(L("button.continue"));
		this.actionButton.setTooltipText(L("install.continue.tooltip"));
		this.actionButton.setName("continueButton");
		this.actionButton.setSensitive(false);
		this.actionButton.addCssClass("suggested-action");
		this.actionButton.addCssClass("pill");
		this.actionButton.connectClicked({ onActionButtonClicked(); });

		this.mainLayout = new Box(Orientation.Vertical, 0);
		this.mainLayout.setHexpand(true);
		this.mainLayout.setVexpand(true);

		// The banner Revealer controls the slide direction (always top to bottom)
		// The inner Stack switches between verify and success content with a crossfade
		this.bannerRevealer = new Revealer;
		this.bannerRevealer.setTransitionType(RevealerTransitionType.SlideDown);
		this.bannerRevealer.setTransitionDuration(SLIDE_TRANSITION_MS);
		this.bannerRevealer.setRevealChild(false);
		this.bannerRevealer.setHexpand(true);

		this.bannerStack = new Stack;
		this.bannerStack.setHexpand(true);
		this.bannerStack.setTransitionType(StackTransitionType.Crossfade);
		this.bannerStack.setTransitionDuration(REVEAL_MS);
		this.bannerRevealer.setChild(this.bannerStack);

		// Verify banner uses CenterBox so the label is always truly centered regardless of button width
		this.bannerBox = new CenterBox;
		this.bannerBox.setHexpand(true);
		this.bannerBox.addCssClass("info-banner");

		this.bannerLabel = new Label(L("install.banner.verify"));
		this.bannerLabel.addCssClass("heading");
		this.bannerLabel.setValign(Align.Center);
		this.bannerBox.setCenterWidget(this.bannerLabel);

		this.actionButton.setHexpand(false);
		this.actionButton.setVexpand(false);
		this.actionButton.setHalign(Align.Center);
		this.actionButton.setValign(Align.Center);
		this.actionButton.setMarginStart(Layout.actionButtonStart);
		this.actionButton.setMarginEnd(Layout.actionButtonEnd);
		this.bannerBox.setEndWidget(this.actionButton);

		this.bannerStack.addTitled(this.bannerBox, "verify", "Verify");
		this.bannerStack.setVisibleChildName("verify");

		// Icon slides in from the top when switching to the app icon
		this.iconStack = new Stack;
		this.iconStack.setTransitionType(StackTransitionType.SlideDown);
		this.iconStack.setTransitionDuration(SLIDE_TRANSITION_MS);
		this.iconStack.setHalign(Align.Center);

		this.genericIconImage = Image.newFromIconName(
			this.appImage.defaultIconName);
		this.genericIconImage.pixelSize = VERIFY_ICON_SIZE;
		this.iconStack.addTitled(this.genericIconImage, "generic", "Generic");
		this.iconStack.setVisibleChildName("generic");

		// Uses the title-1 style from the start so the font size never changes between phases
		this.appTitleLabel = new Label(this.appImage.fileName);
		this.appTitleLabel.addCssClass("title-1");
		this.appTitleLabel.setHalign(Align.Center);
		this.appTitleLabel.setMarginTop(Layout.titleTopMargin);
		this.appTitleLabel.setMarginStart(Layout.labelSideMargin);
		this.appTitleLabel.setMarginEnd(Layout.labelSideMargin);

		// Description label wrapped in Revealer so it slides in without layout shift
		this.appDescriptionLabel = new Label("");
		this.appDescriptionLabel.setHexpand(true);
		this.appDescriptionLabel.setHalign(Align.Center);
		this.appDescriptionLabel.setMarginTop(Layout.innerSpacing);
		this.appDescriptionLabel.setMarginStart(Layout.labelSideMargin);
		this.appDescriptionLabel.setMarginEnd(Layout.labelSideMargin);
		this.appDescriptionLabel.addCssClass("body");
		this.appDescriptionLabel.addCssClass("dim-label");
		this.descRevealer = new Revealer;
		this.descRevealer.setTransitionType(RevealerTransitionType.SlideDown);
		this.descRevealer.setTransitionDuration(ACTION_TRANSITION_MS);
		this.descRevealer.setRevealChild(false);
		this.descRevealer.setChild(this.appDescriptionLabel);

		// Version label wrapped in Revealer to prevent a height jump when text appears
		this.versionLabel = new Label("");
		this.versionLabel.setHalign(Align.Center);
		this.versionLabel.addCssClass("dim-label");
		this.versionRevealer = new Revealer;
		this.versionRevealer.setTransitionType(RevealerTransitionType.SlideDown);
		this.versionRevealer.setTransitionDuration(ACTION_TRANSITION_MS);
		this.versionRevealer.setRevealChild(false);
		this.versionRevealer.setChild(this.versionLabel);

		// Action stack holds the progress bar during install and the button when installation completes
		this.actionStack = new Stack;
		this.actionStack.setTransitionType(StackTransitionType.SlideDown);
		this.actionStack.setTransitionDuration(ACTION_TRANSITION_MS);
		this.actionStack.addTitled(
			new Box(Orientation.Horizontal, 0), "hidden", "Hidden");
		this.actionStack.setVisibleChildName("hidden");

		this.installProgressBar = new ProgressBar;
		this.installProgressBar.setSizeRequest(
			ACTION_BTN_WIDTH + Layout.progressBarExtraWidth, -1);
		this.installProgressBar.setHalign(Align.Center);
		this.installProgressBar.setMarginTop(Layout.ctaMarginTop);
		this.actionStack.addTitled(
			this.installProgressBar, "installing", "Installing");

		this.actionRevealer = new Revealer;
		this.actionRevealer.setTransitionType(RevealerTransitionType.SlideDown);
		this.actionRevealer.setTransitionDuration(ACTION_TRANSITION_MS);
		this.actionRevealer.setRevealChild(false);
		this.actionRevealer.setChild(this.actionStack);

		// Static top margin offsets content below the overlay banner so it never moves
		this.contentBox = new Box(Orientation.Vertical, 0);
		this.contentBox.setHexpand(true);
		this.contentBox.setValign(Align.Center);
		this.contentBox.setMarginTop(Layout.bannerReserveHeight);
		this.contentBox.append(this.iconStack);
		this.contentBox.append(this.appTitleLabel);
		this.contentBox.append(this.descRevealer);
		this.contentBox.append(this.versionRevealer);
		this.contentBox.append(this.actionRevealer);

		this.contentStack = new Stack;
		this.contentStack.setHexpand(true);
		this.contentStack.setVexpand(true);
		this.contentStack.setTransitionDuration(SLIDE_TRANSITION_MS);
		this.contentStack.addNamed(this.contentBox, "summary");
		this.mainLayout.append(this.contentStack);

		// File metadata rows
		auto pathRow = buildInfoRow("folder-home", L("install.info.path"),
			this.appImage.filePath, this.appImage.filePath);
		auto sizeRow = buildInfoRow("drive", L("install.info.size"), this.appImage.fileSize);
		auto modifiedRow = buildInfoRow("view-calendar-week", L("install.info.modified"), this
				.appImage.fileModified);

		string sigIcon;
		string sigValue;
		final switch (this.appImage.signatureStatus) {
		case SignatureStatus.None:
			sigIcon = "security-low-symbolic";
			sigValue = L("install.info.signature.none");
			break;
		case SignatureStatus.Verified:
			sigIcon = "security-high-symbolic";
			sigValue = L("install.info.signature.verified");
			break;
		case SignatureStatus.Unverifiable:
			sigIcon = "security-medium-symbolic";
			sigValue = L("install.info.signature.unverifiable");
			break;
		case SignatureStatus.Invalid:
			sigIcon = "security-low-symbolic";
			sigValue = L("install.info.signature.invalid");
			break;
		case SignatureStatus.GpgMissing:
			sigIcon = "dialog-question-symbolic";
			sigValue = L("install.info.signature.gpgmissing");
			break;
		}
		bool sigHasSection = this.appImage.signatureStatus != SignatureStatus.None
			&& this.appImage.signatureStatus != SignatureStatus.GpgMissing;

		auto fileInfoList = new ListBox;
		fileInfoList.setSelectionMode(SelectionMode.None);
		fileInfoList.addCssClass("boxed-list");
		fileInfoList.setMarginTop(Layout.infoListVertMargin);
		fileInfoList.setMarginBottom(Layout.infoListVertMargin);
		fileInfoList.setMarginStart(INFO_MARGIN);
		fileInfoList.setMarginEnd(INFO_MARGIN);

		foreach (row; [pathRow, sizeRow, modifiedRow]) {
			auto listRow = new ListBoxRow;
			listRow.setChild(row);
			listRow.setActivatable(false);
			fileInfoList.append(listRow);
		}

		auto sigRow = buildInfoRow(sigIcon, L("install.info.signature"), sigValue);
		if (this.appImage.signatureStatus == SignatureStatus.Invalid) {
			// Walk icon → textColumn → valueLabel (second child of textColumn)
			auto textColumn = cast(Box) sigRow.getLastChild();
			if (textColumn !is null) {
				auto valueLabel = cast(Label) textColumn.getLastChild();
				if (valueLabel !is null) {
					valueLabel.removeCssClass("dim-label");
					valueLabel.addCssClass("error");
					valueLabel.addCssClass("heading");
				}
			}
		}
		auto sigListRow = new ListBoxRow;
		if (sigHasSection) {
			auto sigChevron = Image.newFromIconName("pan-end-symbolic");
			sigChevron.pixelSize = 24;
			sigChevron.addCssClass("row-chevron");
			sigChevron.setValign(Align.Center);
			sigChevron.setMarginEnd(16);
			sigRow.append(sigChevron);

			string keyId = this.appImage.signatureKeyId;
			string displayKey = keyId.length > 0
				? keyId : L("install.info.signature.detail.unknown");
			auto keyRowContent = buildInfoRow(
				"fingerprint-symbolic",
				L("install.info.signature.detail.keyid"),
				displayKey);
			if (keyId.length > 0) {
				keyRowContent.setTooltipText(
					L("install.info.signature.detail.copy.tooltip"));
				auto keyCopyGesture = new GestureClick;
				keyCopyGesture.connectReleased(
					(int nPress, double x, double y, GestureClick _) {
					auto clipboard = this.getDisplay().getClipboard();
					gdk_clipboard_set_text(
						cast(GdkClipboard*) clipboard._cPtr(No.Dup), keyId.toStringz());
				});
				keyRowContent.addController(keyCopyGesture);
			}

			this.gpgDetailRevealer = new Revealer;
			this.gpgDetailRevealer.setTransitionType(RevealerTransitionType.SlideDown);
			this.gpgDetailRevealer.setTransitionDuration(ACTION_TRANSITION_MS);
			this.gpgDetailRevealer.setRevealChild(false);

			auto detailWrap = new Box(Orientation.Vertical, 0);
			detailWrap.append(new Separator(Orientation.Horizontal));
			detailWrap.append(keyRowContent);
			this.gpgDetailRevealer.setChild(detailWrap);

			auto sigRowWrapper = new Box(Orientation.Vertical, 0);
			sigRowWrapper.append(sigRow);
			sigRowWrapper.append(this.gpgDetailRevealer);
			sigListRow.setChild(sigRowWrapper);
			sigListRow.setActivatable(true);

			auto clickCtrl = new GestureClick;
			clickCtrl.connectReleased((int nPress, double x, double y, GestureClick _) {
				bool open = this.gpgDetailRevealer.getRevealChild();
				this.gpgDetailRevealer.setRevealChild(!open);
				if (open) {
					sigListRow.removeCssClass("open-row");
					sigChevron.setFromIconName("pan-end-symbolic");
				} else {
					sigListRow.addCssClass("open-row");
					sigChevron.setFromIconName("pan-down-symbolic");
				}
			});
			sigListRow.addController(clickCtrl);
		} else {
			sigListRow.setChild(sigRow);
			sigListRow.setActivatable(false);
		}
		fileInfoList.append(sigListRow);

		// Wrap the list in a Revealer so it collapses smoothly when Continue is clicked
		auto listRevealer = new Revealer;
		listRevealer.setTransitionType(RevealerTransitionType.SlideUp);
		listRevealer.setTransitionDuration(ACTION_TRANSITION_MS);
		listRevealer.setRevealChild(true);
		listRevealer.setChild(fileInfoList);
		this.fileInfoRevealer = listRevealer;

		this.mainLayout.append(listRevealer);

		// bannerRevealer overlays the content from the top without pushing layout down
		this.bannerRevealer.setValign(Align.Start);
		auto overlay = new Overlay;
		overlay.setHexpand(true);
		overlay.setVexpand(true);
		overlay.setChild(this.mainLayout);
		overlay.addOverlay(this.bannerRevealer);
		this.setChild(overlay);

		timeoutAdd(PRIORITY_DEFAULT, BANNER_DELAY_MS, {
			this.bannerRevealer.setRevealChild(true);
			return false;
		});
		// Enable the button after a further delay (user must read the warning)
		timeoutAdd(PRIORITY_DEFAULT, BUTTON_ENABLE_DELAY_MS, {
			this.actionButton.setSensitive(true);
			return false;
		});
	}

	private void showInstallView() {
		if (this.appImage.appIconWidget !is null) {
			this.appImage.appIconWidget.pixelSize =
				this.genericIconImage.getPixelSize();
			this.iconStack.addTitled(this.appImage.appIconWidget, "app", "App");
			timeoutAdd(PRIORITY_DEFAULT, ICON_SWAP_DELAY_MS, {
				this.iconStack.setVisibleChildName("app");
				return false;
			});
		}

		// Collapse the file info and banner smoothly instead of removing them instantly
		if (this.fileInfoRevealer !is null)
			this.fileInfoRevealer.setRevealChild(false);
		if (this.gpgDetailRevealer !is null)
			this.gpgDetailRevealer.setRevealChild(false);
		this.bannerRevealer.setRevealChild(false);

		this.appTitleLabel.setLabel(this.appImage.appName);

		// Stagger desc and version so they slide in after the title is already static
		if (this.appImage.appComment.length) {
			this.appDescriptionLabel.setLabel(this.appImage.appComment);
			this.descRevealer.setRevealChild(true);
		}

		if (this.appImage.releaseVersion.length) {
			immutable string versionText = L(
				"app.version.format", this.appImage.releaseVersion);
			timeoutAdd(PRIORITY_DEFAULT, CONTENT_REVEAL_DELAY_MS, {
				this.versionLabel.setLabel(versionText);
				this.versionRevealer.setRevealChild(true);
				return false;
			});
		}

		this.installProgressBar.setText(
			L("install.progress.label", this.appImage.appName));
		this.installProgressBar.setShowText(true);
		this.installProgressBar.setFraction(0);

		if (this.appImage.isFullyLoaded) {
			timeoutAdd(PRIORITY_DEFAULT, SHOW_BUTTON_DELAY_MS, {
				// If the file is inside the managed appimages tree it is already the installed copy
				string managedBase = installBaseDir() ~ "/";
				if (this.appImage.filePath.length >= managedBase.length
				&& this.appImage.filePath[0 .. managedBase.length] == managedBase) {
					auto dialog = new AlertDialog(cast(void*) gtk_alert_dialog_new(
						"%s".ptr,
						L("install.dialog.reinstall.title", this.appImage.appName).toStringz()),
						Yes.Take);
					dialog.setDetail(L("install.dialog.managed.detail", this.appImage.appName));
					dialog.setButtons([L("button.close")]);
					dialog.setDefaultButton(0);
					dialog.setModal(true);
					dialog.choose(this, null, (ObjectWrap source, AsyncResult result) {
						this.close();
					});
					return false;
				}

				// Check for and present GPG signature warnings before offering install
				void checkVersionAndShowInstall() {
					string existingVersion = this.appImage.readInstalledVersion();
					if (existingVersion.length
					&& existingVersion == this.appImage.releaseVersion) {
						auto reinstallDlg = new AlertDialog(cast(void*) gtk_alert_dialog_new(
							"%s".ptr,
							L("install.dialog.reinstall.title", this.appImage.appName).toStringz()),
							Yes.Take);
						reinstallDlg.setDetail(L("install.dialog.reinstall.detail", existingVersion));
						reinstallDlg.setButtons([
							L("button.cancel"), L("button.overwrite")
						]);
						reinstallDlg.setDefaultButton(0);
						reinstallDlg.setModal(true);
						reinstallDlg.choose(this, null, (ObjectWrap source, AsyncResult result) {
							if (reinstallDlg.chooseFinish(result) == 1)
								showInstallButton();
							else
								this.close();
						});
					} else {
						showInstallButton();
					}
				}

				auto sigStatus = this.appImage.signatureStatus;
				if (sigStatus == SignatureStatus.Invalid) {
					auto sigDlg = new AlertDialog(cast(void*) gtk_alert_dialog_new(
						"%s".ptr, L("install.sig.invalid.title").toStringz()), Yes.Take);
					sigDlg.setDetail(L("install.sig.invalid.body", this.appImage.appName));
					sigDlg.setButtons([
						L("install.sig.button.continue"), L("button.cancel")
					]);
					sigDlg.setDefaultButton(1);
					sigDlg.setCancelButton(1);
					sigDlg.setModal(true);
					sigDlg.choose(this, null, (ObjectWrap source, AsyncResult result) {
						try {
							if (sigDlg.chooseFinish(result) == 0)
								checkVersionAndShowInstall();
							else
								this.close();
						} catch (ErrorWrap) {
							this.close();
						}
					});
					return false;
				}

				checkVersionAndShowInstall();
				return false;
			});
		}
	}

	private void showInstallButton() {
		this.actionButton.setLabel(L("button.install"));
		this.actionButton.setSizeRequest(ACTION_BTN_WIDTH, ACTION_BTN_HEIGHT);
		this.actionButton.setMarginTop(Layout.ctaMarginTop);
		this.actionButton.setHalign(Align.Center);
		this.actionStack.addTitled(this.actionButton, "ready", "Ready");
		this.actionRevealer.setRevealChild(true);
		this.actionStack.setVisibleChildName("ready");
		this.actionButton.setSensitive(true);
	}

	private void onActionButtonClicked() {
		this.actionButton.setSensitive(false);

		if (this.userHasVerified) {
			writeln("User confirmed installation");
			this.actionStack.setVisibleChildName("installing");
			this.appImage.installProgress = 0;
			timeoutAdd(PRIORITY_DEFAULT, PROGRESS_POLL_MS, {
				double progress = this.appImage.installProgress;
				this.installProgressBar.setFraction(progress);
				return progress < 1.0;
			});
			this.doThreadedWork(&runInstallation, &onInstallationComplete);
		} else {
			writeln("User accepted verification, loading full info");
			this.loadingBox.setMarginTop(Layout.loadingPadding);
			this.loadingBox.setMarginBottom(Layout.loadingPadding);
			this.bannerBox.setCenterWidget(this.loadingBox);
			this.bannerBox.setEndWidget(null);

			this.userHasVerified = true;
			if (this.langButton !is null)
				this.langButton.hide();
			this.doThreadedWork(&loadWindow, &showWindow);
		}
	}

	private void runInstallation() {
		this.appImage.install();
	}

	private void onInstallationComplete() {
		doInstallationComplete(this);
	}

}
