// Page for switching between AppImage and Extracted install modes
//
module windows.optimize;

import core.atomic : atomicLoad, atomicStore;
import std.exception : collectException;
import std.file : exists, remove, FileException, rename, rmdirRecurse,
	mkdirRecurse, dirEntries, SpanMode, isSymlink, setAttributes, getSize;
import std.path : buildPath, baseName;
import std.stdio : writeln;
import std.process : execute, Config;

import gio.async_result : AsyncResult;
import gio.file : GioFile = File;
import glib.error : ErrorWrap;
import glib.global : timeoutAdd;
import glib.types : PRIORITY_DEFAULT;
import gobject.object : ObjectWrap;
import gtk.gesture_click : GestureClick;
import gtk.box : Box;
import gtk.button : Button;
import gtk.file_dialog : FileDialog;
import gtk.image : Image;
import gtk.list_box : ListBox;
import gtk.list_box_row : ListBoxRow;
import gtk.label : Label;
import gtk.progress_bar : ProgressBar;
import gtk.revealer : Revealer;
import gtk.stack : Stack;
import gtk.window : Window;
import gtk.types : Align, Justification, Orientation, RevealerTransitionType;
import gtk.types : SelectionMode, StackTransitionType;

import appimage : AppImage;
import apputils : installBaseDir, readableFileSize;
import appimage.manifest : Manifest;
import appimage.install : clearAppDirExceptMeta, rewriteDesktopForModeSwitch;
import types : InstallMethod;
import windows.base : applyCssToWidget, makeSlideDownRevealer, REVEAL_MS;
import windows.base : ACTION_BTN_WIDTH, ACTION_BTN_HEIGHT;
import windows.optimize.helpers;
import constants : APPLICATIONS_SUBDIR, DESKTOP_SUFFIX, APPIMAGE_EXEC_MODE;
import lang : L;

// Pixel measurements and spacing for the optimize page layout
private enum Layout {
	pageSpacing = 12,
	pageBottomMargin = 32,
	pageSideMargin = 48,
	headingMarginBottom = 4,
	cardSpacing = 4,
	keepHeadMarginBottom = 8,
	buttonMarginTop = 16,
	descMaxChars = 52,
	descMarginTop = 10,
	descMarginBottom = 14,
	browseExtraWidth = 48,
}

// Lets the user switch between AppImage (Space) and Extracted (Speed) install modes
// doWork runs on a background thread, onMethodChanged fires on success, onDone on dismiss
Box buildOptimizeBox(
	string appName,
	string appDirectory,
	string sanitizedName,
	InstallMethod currentMethod,
	ubyte appImageType,
	Window parentWindow,
	void delegate(void delegate(), void delegate()) doWork,
	void delegate() onDisableBack,
	void delegate() onEnableBack,
	void delegate(InstallMethod) onMethodChanged,
	void delegate() onDone) {

	// AppImage mode stores the AppImage in the root of appDirectory Extracted mode stores it in the metadata subdir
	string resolvedSource;
	if (currentMethod == InstallMethod.AppImage) {
		string candidate = buildPath(appDirectory, sanitizedName ~ ".AppImage");
		if (exists(candidate))
			resolvedSource = candidate;
	} else {
		string candidate = buildPath(
			appDirectory, APPLICATIONS_SUBDIR, sanitizedName ~ ".AppImage");
		if (exists(candidate))
			resolvedSource = candidate;
	}
	bool sourceAvailable = resolvedSource.length > 0;

	auto outer = new Box(Orientation.Vertical, 0);
	outer.setHexpand(true);
	outer.setVexpand(true);

	auto stack = new Stack;
	stack.setHexpand(true);
	stack.setVexpand(true);
	stack.setTransitionDuration(SLIDE_MS);
	stack.setTransitionType(StackTransitionType.SlideLeft);
	outer.append(stack);

	// Choice page Align.Fill with equal vexpand spacers above and below splits surplus space
	// evenly This keeps the heading centered even as row revealers grow downward
	auto choicePage = new Box(Orientation.Vertical, Layout.pageSpacing);
	choicePage.setVexpand(true);
	choicePage.setValign(Align.Fill);
	choicePage.setHalign(Align.Center);
	choicePage.setMarginBottom(Layout.pageBottomMargin);
	choicePage.setMarginStart(Layout.pageSideMargin);
	choicePage.setMarginEnd(Layout.pageSideMargin);

	auto choiceTopSpacer = new Box(Orientation.Vertical, 0);
	choiceTopSpacer.setVexpand(true);
	choicePage.append(choiceTopSpacer);

	auto headingLabel = new Label(L("optimize.storage.title", appName));
	headingLabel.addCssClass("title-3");
	headingLabel.setHalign(Align.Center);
	headingLabel.setMarginBottom(Layout.headingMarginBottom);
	choicePage.append(headingLabel);

	auto optionsBox = new Box(Orientation.Vertical, Layout.cardSpacing);
	optionsBox.setSizeRequest(CONTENT_WIDTH, -1);
	optionsBox.setHalign(Align.Center);

	InstallMethod selected = currentMethod;
	Button optimizeButton;

	string spaceDesc = sourceAvailable
		? L("optimize.space.description") : L("optimize.space.no_source");

	auto optionsList = new ListBox;
	optionsList.addCssClass("boxed-list");
	optionsList.setSelectionMode(SelectionMode.None);
	optionsList.setHexpand(true);

	// Each row's content is in its own Revealer so rows slide in without the row hiding/showing
	Image spaceCheck, speedCheck;
	auto spaceRowRevealer = makeSlideDownRevealer(REVEAL_MS);
	spaceRowRevealer.setHalign(Align.Fill);
	spaceRowRevealer.setChild(makeOptionRowContent("package-x-generic-symbolic", L(
			"optimize.space.name"),
			currentMethod == InstallMethod.AppImage, spaceDesc, spaceCheck));
	auto spaceRow = new ListBoxRow;
	spaceRow.setActivatable(false);
	spaceRow.setChild(spaceRowRevealer);

	auto speedRowRevealer = makeSlideDownRevealer(REVEAL_MS);
	speedRowRevealer.setHalign(Align.Fill);
	speedRowRevealer.setChild(makeOptionRowContent(
			"preferences-system-time-symbolic",
			L("optimize.speed.name"),
			currentMethod == InstallMethod.Extracted,
			L("optimize.speed.description"), speedCheck));
	auto speedRow = new ListBoxRow;
	speedRow.setActivatable(false);
	speedRow.setChild(speedRowRevealer);

	optionsList.append(spaceRow);
	optionsList.append(speedRow);
	optionsBox.append(optionsList);
	choicePage.append(optionsBox);

	// Mark the initial selection
	if (currentMethod == InstallMethod.AppImage)
		spaceRow.addCssClass("open-row");
	else
		speedRow.addCssClass("open-row");

	// Content slides in via Revealers without needing any manual hide calls

	optimizeButton = Button.newWithLabel(L("button.optimize"));
	optimizeButton.setSizeRequest(ACTION_BTN_WIDTH, ACTION_BTN_HEIGHT);
	optimizeButton.setHalign(Align.Center);
	optimizeButton.setMarginTop(Layout.buttonMarginTop);
	optimizeButton.setSensitive(false);
	optimizeButton.addCssClass("pill");

	auto optimizeButtonRevealer = new Revealer;
	optimizeButtonRevealer.setTransitionType(RevealerTransitionType.SlideDown);
	optimizeButtonRevealer.setTransitionDuration(REVEAL_MS);
	optimizeButtonRevealer.setRevealChild(false);
	optimizeButtonRevealer.setHalign(Align.Center);
	optimizeButtonRevealer.setChild(optimizeButton);
	choicePage.append(optimizeButtonRevealer);

	// Equal bottom spacer that pairs with choiceTopSpacer to keep the heading centered
	auto choiceBottomSpacer = new Box(Orientation.Vertical, 0);
	choiceBottomSpacer.setVexpand(true);
	choicePage.append(choiceBottomSpacer);

	timeoutAdd(PRIORITY_DEFAULT, cast(uint) OPTION_DELAY_MS, {
		spaceRowRevealer.setRevealChild(true);
		return false;
	});
	timeoutAdd(PRIORITY_DEFAULT,
		cast(uint)(OPTION_DELAY_MS + CARD_STAGGER_MS), {
		speedRowRevealer.setRevealChild(true);
		return false;
	});
	timeoutAdd(PRIORITY_DEFAULT,
		cast(uint)(OPTION_DELAY_MS + CARD_STAGGER_MS + ACTION_DELAY_MS), {
		optimizeButtonRevealer.setRevealChild(true);
		return false;
	});

	// Select the row that matches the current install method
	auto spaceClick = new GestureClick;
	spaceRow.addController(spaceClick);
	spaceClick.connectPressed((int pressCount, double xCoordinate, double yCoordinate, GestureClick gesture) {
		selected = InstallMethod.AppImage;
		spaceCheck.setVisible(true);
		speedCheck.setVisible(false);
		spaceRow.addCssClass("open-row");
		speedRow.removeCssClass("open-row");
		optimizeButton.setSensitive(selected != currentMethod);
	});
	auto speedClick = new GestureClick;
	speedRow.addController(speedClick);
	speedClick.connectPressed((int pressCount, double xCoordinate, double yCoordinate, GestureClick gesture) {
		selected = InstallMethod.Extracted;
		spaceCheck.setVisible(false);
		speedCheck.setVisible(true);
		spaceRow.removeCssClass("open-row");
		speedRow.addCssClass("open-row");
		optimizeButton.setSensitive(selected != currentMethod);
	});

	// Confirm page that asks whether to keep the AppImage when switching to Extracted mode
	auto keepPage = makeCentredPage();

	auto keepHeadLabel = new Label(L("optimize.keep.title"));
	keepHeadLabel.addCssClass("title-3");
	keepHeadLabel.setHalign(Align.Center);
	keepHeadLabel.setMarginBottom(Layout.keepHeadMarginBottom);
	keepPage.append(keepHeadLabel);

	if (resolvedSource.length) {
		string sizeText = "";
		try {
			sizeText = readableFileSize(getSize(resolvedSource));
		} catch (FileException) {
		}
		if (sizeText.length) {
			auto keepSizeLabel = new Label(L("optimize.keep.size", sizeText));
			keepSizeLabel.addCssClass("dim-label");
			keepSizeLabel.setHalign(Align.Center);
			keepSizeLabel.setMarginBottom(Layout.descMarginBottom);
			keepPage.append(keepSizeLabel);
		}
	}

	auto keepCardsBox = new Box(Orientation.Vertical, Layout.cardSpacing);
	keepCardsBox.setSizeRequest(CONTENT_WIDTH, -1);
	keepCardsBox.setHalign(Align.Center);

	bool keepSelected = true;
	Button keepGoButton;

	auto keepList = new ListBox;
	keepList.addCssClass("boxed-list");
	keepList.setSelectionMode(SelectionMode.None);
	keepList.setHexpand(true);

	Image keepYesCheck, keepNoCheck;
	auto keepYesRowRevealer = makeSlideDownRevealer(REVEAL_MS);
	keepYesRowRevealer.setHalign(Align.Fill);
	keepYesRowRevealer.setChild(makeOptionRowContent("document-save-symbolic",
			L("optimize.keep.yes"), true, L("optimize.keep.yes.description"), keepYesCheck));
	auto keepYesRow = new ListBoxRow;
	keepYesRow.setActivatable(false);
	keepYesRow.setChild(keepYesRowRevealer);

	auto keepNoRowRevealer = makeSlideDownRevealer(REVEAL_MS);
	keepNoRowRevealer.setHalign(Align.Fill);
	keepNoRowRevealer.setChild(makeOptionRowContent("edit-delete-symbolic",
			L("optimize.keep.no"), false, L("optimize.keep.no.description"), keepNoCheck));
	auto keepNoRow = new ListBoxRow;
	keepNoRow.setActivatable(false);
	keepNoRow.setChild(keepNoRowRevealer);

	keepList.append(keepYesRow);
	keepList.append(keepNoRow);
	keepYesRow.addCssClass("open-row");
	keepCardsBox.append(keepList);
	keepPage.append(keepCardsBox);

	keepGoButton = Button.newWithLabel(L("button.optimize"));
	keepGoButton.setSizeRequest(ACTION_BTN_WIDTH, ACTION_BTN_HEIGHT);
	keepGoButton.setHalign(Align.Center);
	keepGoButton.setMarginTop(Layout.buttonMarginTop);
	keepGoButton.addCssClass("pill");

	auto keepGoButtonRevealer = new Revealer;
	keepGoButtonRevealer.setTransitionType(RevealerTransitionType.SlideDown);
	keepGoButtonRevealer.setTransitionDuration(REVEAL_MS);
	keepGoButtonRevealer.setRevealChild(false);
	keepGoButtonRevealer.setHalign(Align.Center);
	keepGoButtonRevealer.setChild(keepGoButton);
	keepPage.append(keepGoButtonRevealer);

	auto keepYesClick = new GestureClick;
	keepYesRow.addController(keepYesClick);
	keepYesClick.connectPressed((int pressCount, double xCoordinate, double yCoordinate, GestureClick gesture) {
		keepSelected = true;
		keepYesCheck.setVisible(true);
		keepNoCheck.setVisible(false);
		keepYesRow.addCssClass("open-row");
		keepNoRow.removeCssClass("open-row");
	});
	auto keepNoClick = new GestureClick;
	keepNoRow.addController(keepNoClick);
	keepNoClick.connectPressed((int pressCount, double xCoordinate, double yCoordinate, GestureClick gesture) {
		keepSelected = false;
		keepYesCheck.setVisible(false);
		keepNoCheck.setVisible(true);
		keepYesRow.removeCssClass("open-row");
		keepNoRow.addCssClass("open-row");
	});

	// Source locate page shown when the original AppImage cannot be found
	auto locatePage = makeCentredPage();

	// Title and description are immediately visible with only the button sliding in
	auto locButtonRevealer = makeSlideDownRevealer(REVEAL_MS);

	auto locateTitleLabel = new Label(L("optimize.locate.title"));
	locateTitleLabel.addCssClass("title-3");
	locateTitleLabel.setHalign(Align.Center);
	locatePage.append(locateTitleLabel);

	auto locateDescriptionLabel = new Label(L("optimize.locate.description"));
	locateDescriptionLabel.addCssClass("dim-label");
	locateDescriptionLabel.setHalign(Align.Center);
	locateDescriptionLabel.setWrap(true);
	locateDescriptionLabel.setMaxWidthChars(Layout.descMaxChars);
	locateDescriptionLabel.setJustify(Justification.Center);
	locateDescriptionLabel.setMarginTop(Layout.descMarginTop);
	locateDescriptionLabel.setMarginBottom(Layout.descMarginBottom);
	locatePage.append(locateDescriptionLabel);

	auto browseButton = Button.newWithLabel(L("optimize.locate.browse"));
	browseButton.setSizeRequest(
		ACTION_BTN_WIDTH + Layout.browseExtraWidth, ACTION_BTN_HEIGHT);
	browseButton.setHalign(Align.Center);
	locButtonRevealer.setChild(browseButton);
	locatePage.append(locButtonRevealer);

	auto resultWidgets = buildResultPage();
	auto statusIcon = resultWidgets.statusIcon;
	auto statusLabel = resultWidgets.statusLabel;
	auto barDescStack = resultWidgets.barDescStack;
	auto progressBar = resultWidgets.progressBar;
	auto resultDescriptionLabel = resultWidgets.resultDescriptionLabel;
	auto resultBarRevealer = resultWidgets.resultBarRevealer;

	// Type 1 (ISO 9660) AppImages cannot be extracted or optimized
	auto type1Page = makeCentredPage();
	auto type1Icon = Image.newFromIconName("dialog-information-symbolic");
	type1Icon.addCssClass("icon-large");
	type1Icon.setHalign(Align.Center);
	type1Icon.setMarginBottom(Layout.headingMarginBottom);
	type1Page.append(type1Icon);
	auto type1TitleLabel = new Label(L("optimize.type1.title"));
	type1TitleLabel.addCssClass("title-3");
	type1TitleLabel.setHalign(Align.Center);
	type1TitleLabel.setMarginBottom(Layout.headingMarginBottom);
	type1Page.append(type1TitleLabel);
	auto type1DescLabel = new Label(L("optimize.type1.description"));
	type1DescLabel.addCssClass("dim-label");
	type1DescLabel.setHalign(Align.Center);
	type1DescLabel.setWrap(true);
	type1DescLabel.setMaxWidthChars(Layout.descMaxChars);
	type1DescLabel.setJustify(Justification.Center);
	type1DescLabel.setMarginTop(Layout.descMarginTop);
	type1Page.append(type1DescLabel);

	stack.addNamed(choicePage, "choice");
	stack.addNamed(keepPage, "keep");
	stack.addNamed(locatePage, "locate");
	stack.addNamed(resultWidgets.resultPage, "result");
	stack.addNamed(type1Page, "type1");
	stack.setVisibleChildName(appImageType == 1 ? "type1" : "choice");

	// Slides to the result page and switches install mode without touching the
	// metadata subdirectory, keepCopy only applies when switching to Extracted
	void runOptimize(InstallMethod method, bool keepCopy) {
		if (!resolvedSource.length) {
			locButtonRevealer.setRevealChild(false);
			stack.setVisibleChildName("locate");
			timeoutAdd(PRIORITY_DEFAULT,
				cast(uint)(SLIDE_MS + ACTION_DELAY_MS), {
				locButtonRevealer.setRevealChild(true);
				return false;
			});
			return;
		}

		onDisableBack();
		stack.setVisibleChildName("result");

		auto workAppImage = new AppImage(resolvedSource);
		atomicStore(workAppImage.installProgress, 0.0);

		timeoutAdd(PRIORITY_DEFAULT,
			cast(uint)(SLIDE_MS + ACTION_DELAY_MS), {
			resultBarRevealer.setRevealChild(true);
			return false;
		});

		timeoutAdd(PRIORITY_DEFAULT, cast(uint) PROGRESS_POLL_MS, {
			double p = atomicLoad(workAppImage.installProgress);
			progressBar.setFraction(p);
			return p < 1.0;
		});

		timeoutAdd(PRIORITY_DEFAULT,
			cast(uint)(SLIDE_MS + ACTION_DELAY_MS + REVEAL_MS + 50), {
			doWork(
			{
				scope (exit)
					atomicStore(workAppImage.installProgress, 1.0);

				auto existing = Manifest.loadFromAppDir(appDirectory);
				bool portableHome = existing !is null && existing.portableHome;
				bool portableConfig = existing !is null && existing.portableConfig;
				string desktopPath = buildPath(
				appDirectory, APPLICATIONS_SUBDIR, sanitizedName ~ DESKTOP_SUFFIX);

				atomicStore(workAppImage.installProgress, 0.1);

				if (method == InstallMethod.Extracted) {
					string appimagesBaseDir = installBaseDir();
					string stagingDir = buildPath(
					appimagesBaseDir, "." ~ sanitizedName ~ ".staging");
					if (exists(stagingDir))
						collectException(rmdirRecurse(stagingDir));
					try {
						mkdirRecurse(stagingDir);
					} catch (FileException e) {
						writeln("optimize: staging dir failed: ", e.msg);
						return;
					}
					scope (exit)
						collectException(rmdirRecurse(stagingDir));

					setAttributes(resolvedSource, APPIMAGE_EXEC_MODE);
					auto extractResult = execute(
					[resolvedSource, "--appimage-extract"],
					null, Config.none, size_t.max, stagingDir);
					if (extractResult.status != 0) {
						writeln("optimize: extraction failed: ", extractResult.output);
						return;
					}
					atomicStore(workAppImage.installProgress, 0.5);

					string extractedRoot;
					foreach (entry; dirEntries(stagingDir, SpanMode.shallow)) {
						if (isSymlink(entry.name) || !entry.isDir)
							continue;
						extractedRoot = entry.name;
						break;
					}
					if (!extractedRoot.length) {
						writeln("optimize: no extracted root in ", stagingDir);
						return;
					}

					if (keepCopy) {
						string metaDest = buildPath(
						appDirectory, APPLICATIONS_SUBDIR,
						sanitizedName ~ ".AppImage");
						collectException(rename(resolvedSource, metaDest));
						collectException(setAttributes(metaDest, APPIMAGE_EXEC_MODE));
					}

					clearAppDirExceptMeta(appDirectory);
					atomicStore(workAppImage.installProgress, 0.7);

					foreach (entry; dirEntries(extractedRoot, SpanMode.shallow))
						rename(entry.name, buildPath(appDirectory, baseName(entry.name)));

					// Some AppImages ship a non-executable AppRun inside the squashfs
					string appRunPath = buildPath(appDirectory, "AppRun");
					if (exists(appRunPath))
						collectException(setAttributes(appRunPath, APPIMAGE_EXEC_MODE));

				} else {
					// AppImage is in the metadata dir so clear extracted files first
					// then move it to the appDir root
					clearAppDirExceptMeta(appDirectory);
					atomicStore(workAppImage.installProgress, 0.5);

					string appImageDest = buildPath(
					appDirectory, sanitizedName ~ ".AppImage");
					rename(resolvedSource, appImageDest);
					setAttributes(appImageDest, APPIMAGE_EXEC_MODE);
				}

				atomicStore(workAppImage.installProgress, 0.85);

				rewriteDesktopForModeSwitch(
				desktopPath, appDirectory, sanitizedName,
				currentMethod, method, portableHome, portableConfig);

				atomicStore(workAppImage.installProgress, 0.9);

				if (existing !is null) {
					existing.installMethod = method;
					existing.save();
				}

				workAppImage.installedAppDirectory = appDirectory;
			},
			{
				onEnableBack();
				bool success = workAppImage.installedAppDirectory.length > 0;

				// Set description text upfront so the crossfade shows the right content
				string spaceDescription = L("optimize.result.space");
				string speedDescription = L("optimize.result.speed");
				if (success) {
					resultDescriptionLabel.setLabel(
					method == InstallMethod.AppImage ? spaceDescription : speedDescription);
				} else {
					resultDescriptionLabel.setLabel(L("optimize.failed.description"));
				}

				timeoutAdd(PRIORITY_DEFAULT,
				cast(uint) ACTION_DELAY_MS, {
					if (success) {
						onMethodChanged(method);
						statusIcon.setFromIconName("emblem-default-symbolic");
						statusIcon.removeCssClass("error");
						statusIcon.addCssClass("success");
						statusLabel.setLabel(method == InstallMethod.AppImage
						? L("optimize.done.space") : L("optimize.done.speed"));
					} else {
						statusIcon.setFromIconName("dialog-error-symbolic");
						statusIcon.removeCssClass("success");
						statusIcon.addCssClass("error");
						statusLabel.setLabel(L("optimize.failed.title"));
					}
					// Bar slides out downward, description slides in from the top
					// No layout shift because the stack has a fixed allocated height
					barDescStack.setVisibleChildName("desc");
					return false;
				});
			});
			return false;
		});
	}

	// Optimize button routes to the right intermediate page or starts work immediately
	optimizeButton.connectClicked(() {
		if (selected == InstallMethod.Extracted) {
			if (!sourceAvailable) {
				// Need the AppImage to extract so ask the user to locate it
				locButtonRevealer.setRevealChild(false);
				stack.setVisibleChildName("locate");
				timeoutAdd(PRIORITY_DEFAULT,
					cast(uint)(SLIDE_MS + ACTION_DELAY_MS), {
					locButtonRevealer.setRevealChild(true);
					return false;
				});
			} else {
				// Ask whether to keep the AppImage after extraction
				keepYesRowRevealer.setRevealChild(false);
				keepNoRowRevealer.setRevealChild(false);
				keepGoButtonRevealer.setRevealChild(false);
				stack.setVisibleChildName("keep");
				timeoutAdd(PRIORITY_DEFAULT,
					cast(uint)(SLIDE_MS + OPTION_DELAY_MS), {
					keepYesRowRevealer.setRevealChild(true);
					return false;
				});
				timeoutAdd(PRIORITY_DEFAULT,
					cast(uint)(SLIDE_MS + OPTION_DELAY_MS + CARD_STAGGER_MS), {
					keepNoRowRevealer.setRevealChild(true);
					return false;
				});
				timeoutAdd(PRIORITY_DEFAULT,
					cast(uint)(SLIDE_MS + OPTION_DELAY_MS + CARD_STAGGER_MS
					+ ACTION_DELAY_MS), {
					keepGoButtonRevealer.setRevealChild(true);
					return false;
				});
			}
		} else if (!sourceAvailable) {
			// Space mode requires the AppImage so ask the user to locate it
			locButtonRevealer.setRevealChild(false);
			stack.setVisibleChildName("locate");
			timeoutAdd(PRIORITY_DEFAULT,
				cast(uint)(SLIDE_MS + ACTION_DELAY_MS), {
				locButtonRevealer.setRevealChild(true);
				return false;
			});
		} else {
			runOptimize(InstallMethod.AppImage, false);
		}
	});

	keepGoButton.connectClicked(() {
		runOptimize(InstallMethod.Extracted, keepSelected);
	});

	browseButton.connectClicked(() {
		auto fileDialog = new FileDialog;
		fileDialog.setTitle(L("optimize.locate.dialog_title"));
		fileDialog.open(parentWindow, null,
			(ObjectWrap source, AsyncResult asyncResult) {
			try {
				auto gioFile = fileDialog.openFinish(asyncResult);
				string path = gioFile.getPath();
				if (!path.length)
					return;
				resolvedSource = path;
				sourceAvailable = true;
				runOptimize(InstallMethod.AppImage, false);
			} catch (ErrorWrap error) {
				writeln("optimize: file dialog cancelled or failed: ", error.msg);
			}
		});
	});

	return outer;
}
