module windows.uninstall;

import core.atomic : atomicLoad, atomicStore;
import std.file : exists, isDir, isSymlink, remove, rmdirRecurse, FileException;
import std.string : toStringz;
import std.path : buildPath;
import std.process : spawnProcess, wait, ProcessException;
import std.stdio : writeln;

import appimage.icon : findInstalledIconPaths;
import apputils : xdgDataHome;

import gio.async_result : AsyncResult;
import glib.global : timeoutAdd;
import glib.types : PRIORITY_DEFAULT;
import gobject.object : ObjectWrap;
import gtk.alert_dialog : AlertDialog;
import gtk.box : Box;
import gtk.button : Button;
import gtk.c.functions : gtk_alert_dialog_new;
import gtk.image : Image;
import gtk.label : Label;
import gtk.progress_bar : ProgressBar;
import gtk.revealer : Revealer;
import gtk.stack : Stack;
import gtk.types : Align, Justification, Orientation, RevealerTransitionType, StackTransitionType;
import std.typecons : Yes;

import application : App;
import constants : DESKTOP_SUFFIX;
import windows.base : AppWindow, makeSlideDownRevealer;
import windows.base : ACTION_BTN_WIDTH, ACTION_BTN_HEIGHT, ANIM_DURATION_MS;
import lang : L;

// Long enough that the user sees the button before clicking
private enum AnimationDelay {
	iconDelayMs = 80,
	buttonDelayMs = 750
}

// Milestones in the uninstall sequence, used as progress bar fractions
private enum Progress : double {
	afterAppDir = 0.33,
	afterIcons = 0.66,
	afterDesktop = 0.85
}

private enum int PROGRESS_POLL_MS = 80;
private enum int PROGRESS_START_DELAY_MS = 250;

// Pixel sizes and character limits for the uninstall UI
private enum Layout {
	innerSpacing = 8,
	sectionSpacing = 16,
	sectionMargin = 48,
	buttonMarginTop = 16,
	descMaxChars = 52,
	progressBarExtraWidth = 64,
	progressBarMarginOffset = 4,
	progressBarMarginBottom = 8,
}

// Removes the app directory, icon files, and the desktop symlink
// Runs a best effort icon cache update and writes progress for the GTK thread
private void performUninstall(
	string appDirectory, string installedIconName, string desktopSymlink,
	shared double* progress) {

	atomicStore(*progress, 0.0);

	if (appDirectory.length && exists(appDirectory) && isDir(appDirectory)) {
		writeln("UninstallWindow: removing app directory: ", appDirectory);
		rmdirRecurse(appDirectory);
	}
	atomicStore(*progress, cast(double) Progress.afterAppDir);

	foreach (iconPath; findInstalledIconPaths(installedIconName)) {
		try {
			remove(iconPath);
		} catch (FileException error) {
			writeln("UninstallWindow: icon removal error: ", error.msg);
		}
	}
	atomicStore(*progress, cast(double) Progress.afterIcons);

	if (desktopSymlink.length) {
		try {
			if (isSymlink(desktopSymlink) || exists(desktopSymlink))
				remove(desktopSymlink);
		} catch (FileException error) {
			writeln("UninstallWindow: desktop symlink removal error: ", error.msg);
		}
	}
	atomicStore(*progress, cast(double) Progress.afterDesktop);

	try {
		string iconsDir = buildPath(xdgDataHome(), "icons", "hicolor");
		wait(spawnProcess(["gtk-update-icon-cache", "-f", "-t", iconsDir]));
	} catch (ProcessException error) {
		writeln("UninstallWindow: gtk-update-icon-cache: ", error.msg);
	}
	atomicStore(*progress, 1.0);
}

// Builds the uninstall confirmation UI with elements sliding in one by one
// Takes callbacks for threaded work and for back, success, and exit actions
package Box buildUninstallBox(
	string appName,
	string appDirectory,
	string installedIconName,
	string desktopSymlink,
	void delegate(void delegate(), void delegate()) doWork,
	void delegate() onDisableBack,
	void delegate() onEnableBack,
	void delegate() onUninstallSucceeded,
	void delegate() closeWindow) {

	// Icon area is a Stack(SlideUp) that keeps a fixed-height The trash slides up out and the checkmark slides up in
	auto trashImage = Image.newFromIconName("user-trash-symbolic");
	trashImage.addCssClass("icon-large");

	auto doneImage = Image.newFromIconName("emblem-default-symbolic");
	doneImage.addCssClass("icon-large");
	doneImage.addCssClass("success");

	auto iconStack = new Stack;
	iconStack.setTransitionType(StackTransitionType.SlideUp);
	iconStack.setTransitionDuration(ANIM_DURATION_MS);
	iconStack.setHalign(Align.Center);
	iconStack.addNamed(trashImage, "trash");
	iconStack.addNamed(doneImage, "done");
	iconStack.setVisibleChildName("trash");

	// Text area is a Stack(SlideLeft) that swaps confirm text for success text
	auto titleLabel = new Label(L("uninstall.confirm.title", appName));
	titleLabel.addCssClass("title-3");
	titleLabel.setHalign(Align.Center);

	auto descriptionLabel = new Label(L("uninstall.confirm.description", appName));
	descriptionLabel.setHalign(Align.Center);
	descriptionLabel.setJustify(Justification.Center);
	descriptionLabel.setWrap(true);
	descriptionLabel.setMaxWidthChars(Layout.descMaxChars);
	descriptionLabel.addCssClass("dim-label");

	auto headerBox = new Box(Orientation.Vertical, Layout.innerSpacing);
	headerBox.setHalign(Align.Center);
	headerBox.append(titleLabel);
	headerBox.append(descriptionLabel);

	auto doneTitleLabel = new Label(L("uninstall.done.title", appName));
	doneTitleLabel.addCssClass("title-3");
	doneTitleLabel.setHalign(Align.Center);

	auto doneDescriptionLabel = new Label(L("uninstall.done.description"));
	doneDescriptionLabel.setHalign(Align.Center);
	doneDescriptionLabel.setJustify(Justification.Center);
	doneDescriptionLabel.addCssClass("dim-label");

	auto doneBox = new Box(Orientation.Vertical, Layout.innerSpacing);
	doneBox.setHalign(Align.Center);
	doneBox.append(doneTitleLabel);
	doneBox.append(doneDescriptionLabel);

	auto textStack = new Stack;
	textStack.setTransitionType(StackTransitionType.SlideLeft);
	textStack.setTransitionDuration(ANIM_DURATION_MS);
	textStack.setHalign(Align.Center);
	textStack.addNamed(headerBox, "header");
	textStack.addNamed(doneBox, "done");
	textStack.setVisibleChildName("header");

	// Icon and text share a single revealer so the title is never pushed by the icon sliding in
	auto iconTextBox = new Box(Orientation.Vertical, Layout.sectionSpacing);
	iconTextBox.setHalign(Align.Center);
	iconTextBox.append(iconStack);
	iconTextBox.append(textStack);
	auto contentRevealer = makeSlideDownRevealer(ANIM_DURATION_MS);
	contentRevealer.setChild(iconTextBox);

	// Action area is a Stack(SlideDown) that swaps the button for the progress bar on click
	auto uninstallButton = Button.newWithLabel(L("button.uninstall"));
	uninstallButton.setSizeRequest(ACTION_BTN_WIDTH, ACTION_BTN_HEIGHT);
	uninstallButton.setHalign(Align.Center);
	uninstallButton.setMarginTop(Layout.buttonMarginTop);
	uninstallButton.addCssClass("destructive-action");
	uninstallButton.addCssClass("pill");

	auto progressBar = new ProgressBar;
	progressBar.setSizeRequest(
		ACTION_BTN_WIDTH + Layout.progressBarExtraWidth, -1);
	progressBar.setHalign(Align.Center);
	progressBar.setMarginTop(
		uninstallButton.getMarginTop() + Layout.progressBarMarginOffset);
	progressBar.setMarginBottom(Layout.progressBarMarginBottom);

	auto actionStack = new Stack;
	actionStack.setTransitionType(StackTransitionType.SlideDown);
	actionStack.setTransitionDuration(ANIM_DURATION_MS);
	actionStack.addNamed(uninstallButton, "button");
	actionStack.addNamed(progressBar, "progress");
	actionStack.setVisibleChildName("button");

	auto actionRevealer = makeSlideDownRevealer(ANIM_DURATION_MS);
	actionRevealer.setChild(actionStack);

	auto section = new Box(Orientation.Vertical, Layout.sectionSpacing);
	section.setVexpand(true);
	section.setValign(Align.Center);
	section.setHalign(Align.Center);
	section.setMarginStart(Layout.sectionMargin);
	section.setMarginEnd(Layout.sectionMargin);
	section.append(contentRevealer);
	section.append(actionRevealer);

	shared bool* succeeded = new shared bool(false);
	shared double* progress = new shared double(0.0);

	uninstallButton.connectClicked(() {
		// Button slides down, progress bar enters from the top
		progressBar.setFraction(0.0);
		actionStack.setVisibleChildName("progress");
		onDisableBack();

		// Wait for the swap animation, then start work and begin polling
		timeoutAdd(PRIORITY_DEFAULT, PROGRESS_START_DELAY_MS, {
			doWork(
			{
				try {
					performUninstall(
					appDirectory, installedIconName, desktopSymlink, progress);
					atomicStore(*succeeded, true);
				} catch (FileException error) {
					writeln("UninstallWindow: uninstall failed: ", error.msg);
					atomicStore(*progress, 1.0);
				}
			},
			{
				progressBar.setFraction(1.0);
				onEnableBack();

				if (atomicLoad(*succeeded)) {
					onUninstallSucceeded();

					// Wait 250ms at full progress then slide the action area away
					timeoutAdd(PRIORITY_DEFAULT, PROGRESS_START_DELAY_MS, {
						actionRevealer.setRevealChild(false);
						timeoutAdd(PRIORITY_DEFAULT, ANIM_DURATION_MS, {
							iconStack.setVisibleChildName("done");
							textStack.setVisibleChildName("done");
							return false;
						});
						return false;
					});
				} else {
					auto dialog = new AlertDialog(cast(void*) gtk_alert_dialog_new(
					"%s".ptr, L("uninstall.error.title").toStringz()), Yes.Take);
					dialog.setDetail(L("uninstall.error.detail", appName));
					dialog.setButtons([L("button.close")]);
					dialog.setDefaultButton(0);
					dialog.setModal(true);
					dialog.choose(null, null, (ObjectWrap source, AsyncResult result) {
						closeWindow();
					});
				}
			});

			// Poll progress on the GTK main thread until the background work sets it to 1.0
			timeoutAdd(PRIORITY_DEFAULT, PROGRESS_POLL_MS, {
				double p = atomicLoad(*progress);
				progressBar.setFraction(p);
				return p < 1.0;
			});

			return false;
		});
	});

	timeoutAdd(PRIORITY_DEFAULT, AnimationDelay.iconDelayMs, {
		contentRevealer.setRevealChild(true);
		return false;
	});
	timeoutAdd(PRIORITY_DEFAULT, AnimationDelay.buttonDelayMs, {
		actionRevealer.setRevealChild(true);
		return false;
	});

	auto root = new Box(Orientation.Vertical, 0);
	root.setHexpand(true);
	root.setVexpand(true);
	root.append(section);
	return root;
}

// Standalone window used when the CLI starts in uninstall mode
// Has no back button as there is no previous view to return to
class UninstallWindow : AppWindow {
	private string appName;
	private string appDirectory;
	private string sanitizedName;
	private string iconName;
	private string desktopSymlink;

	this(
		App app, string appName, string appDirectory,
		string sanitizedName, string iconName,
		string desktopSymlink = "") {
		super(app);
		this.appName = appName;
		this.appDirectory = appDirectory;
		this.sanitizedName = sanitizedName;
		this.iconName = iconName;
		this.desktopSymlink = desktopSymlink;
		this.setTitle(appName.length ? appName : L("window.title.uninstall"));
	}

	override void loadWindow() {
	}

	override void showWindow() {
		this.loadingSpinner.stop();

		string symlinkPath = this.desktopSymlink.length
			? this.desktopSymlink
			: buildPath(xdgDataHome(), "applications",
				this.iconName ~ DESKTOP_SUFFIX);

		this.setChild(buildUninstallBox(
				this.appName,
				this.appDirectory,
				this.iconName,
				symlinkPath,
				(void delegate() work, void delegate() done) {
				this.doThreadedWork(work, done);
			},
				() { /* no back button in standalone CLI mode */ },
				() { /* no back button in standalone CLI mode */ }, // User reads the result message then manually closes the window
				() {},
				() { this.app.quit(); }
		));
	}
}
