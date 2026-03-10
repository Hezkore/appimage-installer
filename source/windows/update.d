module windows.update;

import std.stdio : writeln;
import std.conv : to;
import std.string : startsWith, toStringz;
import std.array : split;
import std.typecons : Yes;
import core.atomic : atomicLoad;
import core.time : dur, MonoTime;
import core.thread : Thread;

import glib.global : timeoutAdd;
import glib.types : PRIORITY_DEFAULT;
import glib.error : ErrorWrap;
import gio.async_result : AsyncResult;
import gobject.object : ObjectWrap;
import gtk.alert_dialog : AlertDialog;
import gtk.box : Box;
import gtk.button : Button;
import gtk.c.functions : gtk_alert_dialog_new;
import gtk.image : Image;
import gtk.label : Label;
import gtk.progress_bar : ProgressBar;
import gtk.revealer : Revealer;
import gtk.spinner : Spinner;
import gtk.stack : Stack;
import gtk.types : Align, Justification, Orientation, Overflow, RevealerTransitionType;
import gtk.types : SelectionMode, StackTransitionType;
import gtk.window : Window;

import application : App;
import windows.base : AppWindow, makeSlideDownRevealer, makeBackButton, revealAfterDelay, makeIcon, setIconNames;
import windows.base : ACTION_BTN_WIDTH, ACTION_BTN_HEIGHT, ANIM_DURATION_MS;
import windows.base : CONTENT_REVEAL_DELAY_MS, ACTION_REVEAL_DELAY_MS;
import windows.addupdate : buildAddUpdateMethodBox;
import update.directlink : isDirectLink, extractDirectLinkUrl, performDirectLinkUpdate;
import update.zsync : isZsync, extractZsyncUrl, performZsyncUpdate, checkZsyncForUpdate;
import update.githubzsync : isGitHubZsync, checkGitHubZsyncForUpdate, performGitHubZsyncUpdate;
import update.githubrelease : isGitHubRelease, checkGitHubReleaseForUpdate, performGitHubReleaseUpdate;
import update.githublinuxmanifest : isGitHubLinuxManifest, checkGitHubLinuxManifestForUpdate;
import update.githublinuxmanifest : performGitHubLinuxManifestUpdate;
import update.pling : isPling, checkPlingForUpdate, performPlingUpdate;
import update.common : readManifestFields, retryInstallAfterSig,
	parseUpdateMethodKind, UpdateMethodKind;
import types : InstallMethod;
import appimage.manifest : Manifest;
import lang : L;

// Stagger delays so widgets appear in sequence rather than all at once
private enum AnimationDelay {
	progressPollMs = 100,
	checkMinMs = 250,
	doneDelayMs = 250,
}

// Pixel sizes and character limits shared across the update UI
private enum Layout {
	spinnerSize = 48,
	sectionMargin = 48,
	descMaxChars = 56,
	buttonMarginTop = 16,
	progressBarMarginTop = 8,
	progressBarExtraWidth = 32,
	innerSpacing = 8,
	sectionSpacing = 16,
}

private alias TimedAction = void delegate();

// One step in a sequenced reveal, a delay in milliseconds followed by an action
private struct TimedStep {
	int delayMs;
	TimedAction action;
}

private void runTimedSteps(TimedStep[] steps, size_t index = 0) {
	if (index >= steps.length)
		return;

	auto capturedSteps = steps;
	timeoutAdd(PRIORITY_DEFAULT, capturedSteps[index].delayMs, {
		capturedSteps[index].action();
		runTimedSteps(capturedSteps, index + 1);
		return false;
	});
}

private void runTimedSteps(
	TimedStep[] steps,
	bool delegate() shouldStop,
	size_t index = 0) {
	if (index >= steps.length)
		return;

	auto capturedSteps = steps;
	timeoutAdd(PRIORITY_DEFAULT, capturedSteps[index].delayMs, {
		if (shouldStop !is null && shouldStop())
			return false;
		capturedSteps[index].action();
		runTimedSteps(capturedSteps, shouldStop, index + 1);
		return false;
	});
}

// Builds the update UI with elements sliding in one by one
// Back navigation uses the header bar and onAddUpdateMethod wires the Add Update Method button
package Box buildUpdateBox(
	string appName,
	bool updateAvailable,
	string updateCheckError,
	string updateInfo,
	string installedVersion = "",
	void delegate() onAddUpdateMethod = null,
	void delegate() onForceUpdate = null) {
	string[] iconNames;
	string title, description;
	bool isUpToDate = false;
	Button actionButton;

	if (!updateInfo.length) {
		iconNames = [
			"software-update-available-symbolic",
			"system-software-update-symbolic",
		];
		title = L("update.title.no_method");
		description = L("update.no_method.description");

		actionButton = Button.newWithLabel(L("update.button.add_method"));
		actionButton.setSizeRequest(ACTION_BTN_WIDTH, ACTION_BTN_HEIGHT);
		actionButton.setTooltipText(L("update.no_method.tooltip"));
		actionButton.addCssClass("pill");
		actionButton.connectClicked(() {
			if (onAddUpdateMethod !is null)
				onAddUpdateMethod();
			else
				writeln("UpdateWindow: 'Add Update Method' not yet implemented.");
		});
	} else if (parseUpdateMethodKind(updateInfo) == UpdateMethodKind.Unknown) {
		iconNames = ["dialog-warning-symbolic"];
		title = L("update.title.unknown_method");
		string methodPrefix = updateInfo.split("|")[0];
		description = L("update.unknown_method.description", methodPrefix);
		actionButton = Button.newWithLabel(L("update.button.change_method"));
		actionButton.setSizeRequest(ACTION_BTN_WIDTH, ACTION_BTN_HEIGHT);
		actionButton.addCssClass("pill");
		actionButton.connectClicked(() {
			if (onAddUpdateMethod !is null)
				onAddUpdateMethod();
		});
	} else if (updateCheckError.length) {
		iconNames = ["dialog-warning-symbolic"];
		title = L("update.title.check_failed");
		description = L("update.failed.description", updateCheckError);
	} else if (updateAvailable) {
		iconNames = [
			"software-update-available-symbolic",
			"system-software-update-symbolic",
		];
		title = L("update.title.available");
		description = L("update.available.description", appName);

		actionButton = Button.newWithLabel(L("update.button.now"));
		actionButton.setSizeRequest(ACTION_BTN_WIDTH, ACTION_BTN_HEIGHT);
		actionButton.addCssClass("suggested-action");
		actionButton.addCssClass("pill");
		actionButton.connectClicked(() {
			// TODO: run appimageupdatetool to apply the update
			writeln("UpdateWindow: 'Update Now' not yet implemented.");
		});
	} else {
		iconNames = [
			"emblem-default-symbolic", "emblem-ok-symbolic",
			"object-select-symbolic"
		];
		title = L("update.title.up_to_date");
		description = installedVersion.length
			? L("update.up_to_date.description.versioned",
				appName, installedVersion) : L("update.up_to_date.description", appName);
		isUpToDate = true;
		if (onForceUpdate !is null) {
			actionButton = Button.newWithLabel(L("update.button.force"));
			actionButton.setSizeRequest(ACTION_BTN_WIDTH, ACTION_BTN_HEIGHT);
			actionButton.addCssClass("pill");
			actionButton.connectClicked(() { onForceUpdate(); });
		}
	}

	auto iconImage = makeIcon(iconNames);
	iconImage.addCssClass("icon-large");
	if (isUpToDate)
		iconImage.addCssClass("success");
	iconImage.setHalign(Align.Center);

	auto titleLabel = new Label(title);
	titleLabel.addCssClass("title-3");
	titleLabel.setHalign(Align.Center);

	auto descriptionLabel = new Label(description);
	descriptionLabel.setHalign(Align.Center);
	descriptionLabel.setJustify(Justification.Center);
	descriptionLabel.setWrap(true);
	descriptionLabel.setMaxWidthChars(Layout.descMaxChars);
	descriptionLabel.addCssClass("dim-label");

	// Icon, title and description slide in together so the title is never pushed by the icon
	auto iconTitleDescBox = new Box(Orientation.Vertical, Layout.innerSpacing);
	iconTitleDescBox.setHalign(Align.Center);
	iconTitleDescBox.append(iconImage);
	iconTitleDescBox.append(titleLabel);
	iconTitleDescBox.append(descriptionLabel);
	auto contentRevealer = makeSlideDownRevealer(ANIM_DURATION_MS);
	contentRevealer.setChild(iconTitleDescBox);

	Revealer buttonRevealer;
	if (actionButton !is null) {
		actionButton.setHalign(Align.Center);
		actionButton.setMarginTop(Layout.buttonMarginTop);
		buttonRevealer = makeSlideDownRevealer(ANIM_DURATION_MS);
		buttonRevealer.setChild(actionButton);
	}

	auto section = new Box(Orientation.Vertical, Layout.sectionSpacing);
	section.setVexpand(true);
	section.setValign(Align.Center);
	section.setHalign(Align.Center);
	section.setMarginStart(Layout.sectionMargin);
	section.setMarginEnd(Layout.sectionMargin);
	section.append(contentRevealer);
	if (buttonRevealer !is null)
		section.append(buttonRevealer);

	revealAfterDelay(contentRevealer, 0);
	if (buttonRevealer !is null)
		revealAfterDelay(buttonRevealer, ACTION_REVEAL_DELAY_MS);

	auto root = new Box(Orientation.Vertical, 0);
	root.setHexpand(true);
	root.setVexpand(true);
	// Two equal vexpand spacers around the section keep it vertically centered even as the content revealer grows
	auto topSpacer = new Box(Orientation.Vertical, 0);
	topSpacer.setVexpand(true);
	root.append(topSpacer);
	section.setVexpand(false);
	section.setValign(Align.Center);
	root.append(section);
	auto bottomSpacer = new Box(Orientation.Vertical, 0);
	bottomSpacer.setVexpand(true);
	root.append(bottomSpacer);
	return root;
}

// Builds the shared update-apply UI with SlideDown transitions on icon, text and progress bar
// updateDelegate runs on the background thread, all status keys are raw lang keys
private void buildUpdateFlow(
	Box contentSlot,
	string appName,
	string sanitizedName,
	string appDirectory,
	string installedVersion,
	string updatingKey,
	string initialStatusKey,
	string doneKey,
	string noUpdateKey,
	string failedKey,
	bool delegate(ref double, ref string, ref bool, out string) updateDelegate,
	void delegate(void delegate(), void delegate()) doWork,
	void delegate() onDisableBack = null,
	void delegate() onEnableBack = null,
	bool delegate() shouldCancel = null,
	bool skipAvailState = false) {

	// Icon area uses SlideDown to swap between available, spinner and result states
	auto availIconImg = makeIcon([
		"software-update-available-symbolic",
		"system-software-update-symbolic",
	]);
	availIconImg.addCssClass("icon-large");

	auto spinner = new Spinner;
	spinner.setSizeRequest(Layout.spinnerSize, Layout.spinnerSize);
	spinner.setHalign(Align.Center);

	auto doneIconImg = makeIcon([
		"emblem-default-symbolic", "emblem-ok-symbolic", "object-select-symbolic"
	]);
	doneIconImg.addCssClass("icon-large");

	auto iconStack = new Stack;
	iconStack.setTransitionType(StackTransitionType.SlideDown);
	iconStack.setTransitionDuration(ANIM_DURATION_MS);
	iconStack.setHalign(Align.Center);
	iconStack.addNamed(availIconImg, "avail");
	iconStack.addNamed(spinner, "spinner");
	iconStack.addNamed(doneIconImg, "done");
	iconStack.setVisibleChildName(skipAvailState ? "spinner" : "avail");
	if (skipAvailState)
		spinner.setSpinning(true);

	// Title slides between states, description is updated in-place beneath it
	auto availTitleLabel = new Label(L("update.title.available"));
	availTitleLabel.addCssClass("title-3");
	availTitleLabel.setHalign(Align.Center);

	auto updatingTitleLabel = new Label(L(updatingKey, appName));
	updatingTitleLabel.addCssClass("title-3");
	updatingTitleLabel.setHalign(Align.Center);

	auto doneTitleLabel = new Label("");
	doneTitleLabel.addCssClass("title-3");
	doneTitleLabel.setHalign(Align.Center);

	auto titleStack = new Stack;
	titleStack.setTransitionType(StackTransitionType.SlideDown);
	titleStack.setTransitionDuration(ANIM_DURATION_MS);
	titleStack.setHalign(Align.Center);
	titleStack.setOverflow(Overflow.Hidden);
	titleStack.addNamed(availTitleLabel, "avail");
	titleStack.addNamed(updatingTitleLabel, "updating");
	titleStack.addNamed(doneTitleLabel, "done");
	titleStack.setVisibleChildName(skipAvailState ? "updating" : "avail");

	auto availDescText = installedVersion.length
		? L("update.available.description.auto.versioned",
			appName, installedVersion) : L("update.available.description.auto", appName);
	auto descLabel = new Label(availDescText);
	descLabel.setHalign(Align.Center);
	descLabel.setJustify(Justification.Center);
	descLabel.setWrap(true);
	descLabel.setMaxWidthChars(Layout.descMaxChars);
	descLabel.addCssClass("dim-label");
	if (skipAvailState)
		descLabel.setVisible(false);

	auto textBox = new Box(Orientation.Vertical, Layout.innerSpacing);
	textBox.setHalign(Align.Center);
	textBox.append(titleStack);
	textBox.append(descLabel);

	// Progress bar lives in a hidden revealer below icon and text, slides in during update
	auto progressBar = new ProgressBar;
	progressBar.setSizeRequest(
		ACTION_BTN_WIDTH + Layout.progressBarExtraWidth, -1);
	progressBar.setHalign(Align.Center);
	progressBar.setShowText(true);
	progressBar.setText(L(initialStatusKey));
	auto progressRevealer = makeSlideDownRevealer(ANIM_DURATION_MS);
	progressRevealer.setChild(progressBar);

	auto iconTextBox = new Box(Orientation.Vertical, Layout.sectionSpacing);
	iconTextBox.setHalign(Align.Center);
	iconTextBox.append(iconStack);
	iconTextBox.append(textBox);

	auto section = new Box(Orientation.Vertical, Layout.sectionSpacing);
	section.setHalign(Align.Center);
	section.setMarginStart(Layout.sectionMargin);
	section.setMarginEnd(Layout.sectionMargin);
	section.append(iconTextBox);
	section.append(progressRevealer);

	auto contentRevealer = makeSlideDownRevealer(ANIM_DURATION_MS);
	contentRevealer.setChild(section);

	auto root = new Box(Orientation.Vertical, 0);
	root.setHexpand(true);
	root.setVexpand(true);
	auto topSpacer = new Box(Orientation.Vertical, 0);
	topSpacer.setVexpand(true);
	root.append(topSpacer);
	root.append(contentRevealer);
	auto bottomSpacer = new Box(Orientation.Vertical, 0);
	bottomSpacer.setVexpand(true);
	root.append(bottomSpacer);

	auto prev = contentSlot.getFirstChild();
	if (prev !is null)
		contentSlot.remove(prev);
	contentSlot.append(root);

	double updateProgress = 0.0;
	string updateProgressText = initialStatusKey;
	bool updateSuccess = false;
	bool wasUpdated = true;
	string updateError;

	bool isCancelled() {
		return shouldCancel !is null && shouldCancel();
	}

	void setUpdatingState() {
		if (isCancelled())
			return;
		iconStack.setVisibleChildName("spinner");
		spinner.setSpinning(true);
		titleStack.setVisibleChildName("updating");
		descLabel.setVisible(false);
	}

	void startProgressPoll() {
		timeoutAdd(PRIORITY_DEFAULT, AnimationDelay.progressPollMs, {
			if (isCancelled())
				return false;
			immutable int pct = cast(int)(updateProgress * 100);
			progressBar.setFraction(updateProgress);
			progressBar.setText(
				L(updateProgressText) ~ "  " ~ pct.to!string ~ "%");
			return updateProgress < 1.0;
		});
	}

	void showDoneState() {
		if (isCancelled())
			return;
		runTimedSteps([
			TimedStep(AnimationDelay.doneDelayMs, {
				progressRevealer.setRevealChild(false);
			}),
			TimedStep(ANIM_DURATION_MS + AnimationDelay.doneDelayMs, {
				setIconNames(doneIconImg, updateSuccess
					? [
						"emblem-default-symbolic", "emblem-ok-symbolic",
						"object-select-symbolic"
					] : ["dialog-warning-symbolic"]);
				if (updateSuccess)
					doneIconImg.addCssClass("success");
				doneTitleLabel.setLabel(updateSuccess
					? (wasUpdated ? L(doneKey) : L(noUpdateKey)) : L("update.title.check_failed"));
				if (updateSuccess && !wasUpdated) {
					auto installedAppManifest =
						Manifest.loadFromAppDir(appDirectory);
					if (installedAppManifest !is null
					&& installedAppManifest.updateAvailable) {
						installedAppManifest.updateAvailable = false;
						installedAppManifest.save();
					}
				}
				immutable string doneDesc =
					updateSuccess ? "" : L(failedKey, updateError);
				descLabel.setLabel(doneDesc);
				descLabel.setVisible(doneDesc.length > 0);
				titleStack.setVisibleChildName("done");
				iconStack.setVisibleChildName("done");
			}),
			TimedStep(ANIM_DURATION_MS, { spinner.setSpinning(false); }),
		], &isCancelled);
	}

	void delegate() doneHandler;
	doneHandler = () {
		if (isCancelled())
			return;
		if (onEnableBack !is null)
			onEnableBack();

		enum string SIG_INVALID_PFX = "sig:invalid:";
		if (!updateSuccess && updateError.startsWith(SIG_INVALID_PFX)) {
			string sigTempPath = updateError[SIG_INVALID_PFX.length .. $];
			string capturedSigPath = sigTempPath;
			auto win = cast(Window) contentSlot.getRoot();
			auto dlg = new AlertDialog(cast(void*) gtk_alert_dialog_new(
					"%s".ptr, L("update.sig.invalid.title").toStringz()), Yes.Take);
			dlg.setDetail(L("update.sig.invalid.body"));
			dlg.setButtons([
					L("update.sig.button.continue"), L("button.cancel")
				]);
			dlg.setDefaultButton(1);
			dlg.setCancelButton(1);
			dlg.setModal(true);
			dlg.choose(win, null, (ObjectWrap src, AsyncResult asyncResult) {
				if (isCancelled())
					return;
				try {
					int choice = dlg.chooseFinish(asyncResult);
					if (choice == 0) {
						setUpdatingState();
						progressRevealer.setRevealChild(true);
						progressBar.setFraction(0.0);
						updateProgress = 0.0;
						updateProgressText = initialStatusKey;
						updateSuccess = false;
						wasUpdated = true;
						updateError = "";
						startProgressPoll();
						InstallMethod retryMethod;
						string retryErr;
						readManifestFields(appDirectory, retryMethod, retryErr);
						string retryInitText = L(initialStatusKey);
						doWork({
							updateSuccess = retryInstallAfterSig(
							capturedSigPath, appDirectory, sanitizedName,
							retryMethod, updateProgress, 0.0, 1.0,
							updateProgressText,
							retryInitText, retryInitText,
							updateError, shouldCancel);
						}, doneHandler);
					} else {
						progressBar.setFraction(1.0);
						showDoneState();
					}
				} catch (ErrorWrap) {
					progressBar.setFraction(1.0);
					showDoneState();
				}
			});
			return;
		}

		progressBar.setFraction(1.0);
		showDoneState();
	};

	void startUpdateWork() {
		if (isCancelled())
			return;
		progressRevealer.setRevealChild(true);
		if (onDisableBack !is null)
			onDisableBack();
		startProgressPoll();
		doWork(
		{
			updateSuccess = updateDelegate(
				updateProgress, updateProgressText, wasUpdated, updateError);
		},
			doneHandler);
	}

	runTimedSteps([
		TimedStep(0, { contentRevealer.setRevealChild(true); }),
		TimedStep(skipAvailState ? 0 : CONTENT_REVEAL_DELAY_MS, {
			setUpdatingState();
		}),
		TimedStep(ANIM_DURATION_MS, { startUpdateWork(); }),
	], &isCancelled);
}

// Fills contentSlot with the Direct Link update flow
package void buildDirectLinkUpdateFlow(
	Box contentSlot,
	string appName,
	string sanitizedName,
	string appDirectory,
	string url,
	string installedVersion,
	void delegate(void delegate(), void delegate()) doWork,
	void delegate() onDisableBack = null,
	void delegate() onEnableBack = null,
	bool delegate() shouldCancel = null,
	bool force = false,
	bool skipAvailState = false) {
	buildUpdateFlow(
		contentSlot, appName, sanitizedName, appDirectory, installedVersion,
		"update.direct.updating",
		"update.direct.status.start",
		"update.direct.done",
		"update.direct.done.no_update",
		"update.direct.failed",
		(ref double progress, ref string statusText,
			ref bool wasUpdated, out string updateError) =>
			performDirectLinkUpdate(
				appDirectory, sanitizedName, url,
				progress, statusText, wasUpdated, updateError, shouldCancel, force),
			doWork, onDisableBack, onEnableBack, shouldCancel, skipAvailState);
}

// Fills contentSlot with the zsync update flow
package void buildZsyncUpdateFlow(
	Box contentSlot,
	string appName,
	string sanitizedName,
	string appDirectory,
	string metaUrl,
	string installedVersion,
	void delegate(void delegate(), void delegate()) doWork,
	void delegate() onDisableBack = null,
	void delegate() onEnableBack = null,
	bool delegate() shouldCancel = null,
	bool force = false,
	bool skipAvailState = false) {
	buildUpdateFlow(
		contentSlot, appName, sanitizedName, appDirectory, installedVersion,
		"update.zsync.updating",
		"update.zsync.status.start",
		"update.zsync.done",
		"update.zsync.done.no_update",
		"update.zsync.failed",
		(ref double progress, ref string statusText,
			ref bool wasUpdated, out string updateError) =>
			performZsyncUpdate(
				appDirectory, sanitizedName, metaUrl,
				progress, statusText, wasUpdated, updateError, shouldCancel, force),
			doWork, onDisableBack, onEnableBack, shouldCancel, skipAvailState);
}

// Fills contentSlot with the gh-releases-zsync update flow
package void buildGitHubZsyncUpdateFlow(
	Box contentSlot,
	string appName,
	string sanitizedName,
	string appDirectory,
	string updateInfo,
	string installedVersion,
	void delegate(void delegate(), void delegate()) doWork,
	void delegate() onDisableBack = null,
	void delegate() onEnableBack = null,
	bool delegate() shouldCancel = null,
	bool force = false,
	bool skipAvailState = false) {
	buildUpdateFlow(
		contentSlot, appName, sanitizedName, appDirectory, installedVersion,
		"update.zsync.updating",
		"update.zsync.status.start",
		"update.zsync.done",
		"update.zsync.done.no_update",
		"update.zsync.failed",
		(ref double progress, ref string statusText,
			ref bool wasUpdated, out string updateError) =>
			performGitHubZsyncUpdate(
				appDirectory, sanitizedName, updateInfo,
				progress, statusText, wasUpdated, updateError, shouldCancel, force),
			doWork, onDisableBack, onEnableBack, shouldCancel, skipAvailState);
}

// Fills contentSlot with the gh-releases direct update flow
package void buildGitHubReleaseUpdateFlow(
	Box contentSlot,
	string appName,
	string sanitizedName,
	string appDirectory,
	string updateInfo,
	string installedVersion,
	void delegate(void delegate(), void delegate()) doWork,
	void delegate() onDisableBack = null,
	void delegate() onEnableBack = null,
	bool delegate() shouldCancel = null,
	bool skipAvailState = false) {
	buildUpdateFlow(
		contentSlot, appName, sanitizedName, appDirectory, installedVersion,
		"update.gh.updating",
		"update.gh.status.start",
		"update.gh.done",
		"update.gh.done.no_update",
		"update.gh.failed",
		(ref double progress, ref string statusText,
			ref bool wasUpdated, out string updateError) =>
			performGitHubReleaseUpdate(
				appDirectory, sanitizedName, updateInfo,
				progress, statusText, wasUpdated, updateError, shouldCancel),
			doWork, onDisableBack, onEnableBack, shouldCancel, skipAvailState);
}

// Fills contentSlot with the gh-linux-yml update flow
package void buildGitHubLinuxManifestUpdateFlow(
	Box contentSlot,
	string appName,
	string sanitizedName,
	string appDirectory,
	string updateInfo,
	string installedVersion,
	void delegate(void delegate(), void delegate()) doWork,
	void delegate() onDisableBack = null,
	void delegate() onEnableBack = null,
	bool delegate() shouldCancel = null,
	bool skipAvailState = false) {
	buildUpdateFlow(
		contentSlot, appName, sanitizedName, appDirectory, installedVersion,
		"update.gh.updating",
		"update.gh.status.start",
		"update.gh.done",
		"update.gh.done.no_update",
		"update.gh.failed",
		(ref double progress, ref string statusText,
			ref bool wasUpdated, out string updateError) =>
			performGitHubLinuxManifestUpdate(
				appDirectory, sanitizedName, updateInfo,
				progress, statusText, wasUpdated, updateError, shouldCancel),
			doWork, onDisableBack, onEnableBack, shouldCancel, skipAvailState);
}

// Fills contentSlot with the Pling Store update flow
// onAfterUpdate runs on the GTK main thread and should refresh any stale in-memory state
package void buildPlingUpdateFlow(
	Box contentSlot,
	string appName,
	string sanitizedName,
	string appDirectory,
	string updateInfo,
	string installedVersion,
	void delegate(void delegate(), void delegate()) doWork,
	void delegate() onDisableBack = null,
	void delegate() onEnableBack = null,
	void delegate() onAfterUpdate = null,
	bool delegate() shouldCancel = null,
	bool force = false,
	bool skipAvailState = false) {
	buildUpdateFlow(
		contentSlot, appName, sanitizedName, appDirectory, installedVersion,
		"update.pling.updating",
		"update.pling.status.start",
		"update.pling.done",
		"update.pling.done.no_update",
		"update.pling.failed",
		(ref double progress, ref string statusText,
			ref bool wasUpdated, out string updateError) =>
			performPlingUpdate(
				appDirectory, sanitizedName, updateInfo,
				progress, statusText, wasUpdated, updateError, shouldCancel, force),
			(void delegate() work, void delegate() done) {
		doWork(work, () {
			done();
			if (onAfterUpdate !is null)
				onAfterUpdate();
		});
	},
		onDisableBack, onEnableBack, shouldCancel, skipAvailState);
}
// Spinner and label shown while the update check thread runs
package Box buildCheckingBox() {
	auto spinner = new Spinner;
	spinner.setSizeRequest(Layout.spinnerSize, Layout.spinnerSize);
	spinner.setHalign(Align.Center);
	spinner.setSpinning(true);

	auto label = new Label(L("update.checking.label"));
	label.setHalign(Align.Center);
	label.addCssClass("dim-label");

	auto checkingBox = new Box(Orientation.Vertical, Layout.sectionSpacing);
	checkingBox.setValign(Align.Center);
	checkingBox.setHalign(Align.Center);
	checkingBox.append(spinner);
	checkingBox.append(label);

	auto contentRevealer = makeSlideDownRevealer(ANIM_DURATION_MS);
	contentRevealer.setChild(checkingBox);

	auto outer = new Box(Orientation.Vertical, 0);
	outer.setHexpand(true);
	outer.setVexpand(true);
	outer.setValign(Align.Center);
	outer.setHalign(Align.Center);
	outer.append(contentRevealer);

	revealAfterDelay(contentRevealer, 0);

	auto root = new Box(Orientation.Vertical, 0);
	root.setHexpand(true);
	root.setVexpand(true);
	root.append(outer);
	return root;
}

// Standalone window used when the CLI starts in update mode
// Has no back button as there is no previous view to return to
class UpdateWindow : AppWindow {
	private string appName;
	private string sanitizedName;
	private string appDirectory;
	private string updateInfo;

	private bool updateAvailable;
	private string updateCheckError;
	private string installedVersion;

	this(
		App app, string appName, string sanitizedName,
		string appDirectory, string updateInfo) {
		super(app);
		this.appName = appName;
		this.sanitizedName = sanitizedName;
		this.appDirectory = appDirectory;
		this.updateInfo = updateInfo;
		this.setTitle(appName.length ? appName : L("window.title.update"));
	}

	override void loadWindow() {
		auto startTime = MonoTime.currTime;
		final switch (parseUpdateMethodKind(this.updateInfo)) {
		case UpdateMethodKind.DirectLink:
		case UpdateMethodKind.Unknown:
			break;
		case UpdateMethodKind.Zsync:
			checkZsyncForUpdate(this.appDirectory, this.sanitizedName,
				extractZsyncUrl(this.updateInfo), this.updateAvailable,
				this.updateCheckError,
				() => cast(bool) atomicLoad(this.workCancelled));
			break;
		case UpdateMethodKind.GitHubZsync:
			checkGitHubZsyncForUpdate(this.appDirectory, this.sanitizedName,
				this.updateInfo, this.updateAvailable, this.updateCheckError,
				() => cast(bool) atomicLoad(this.workCancelled));
			break;
		case UpdateMethodKind.GitHubRelease:
			checkGitHubReleaseForUpdate(this.appDirectory,
				this.updateInfo, this.updateAvailable, this.updateCheckError,
				() => cast(bool) atomicLoad(this.workCancelled));
			break;
		case UpdateMethodKind.GitHubLinuxManifest:
			checkGitHubLinuxManifestForUpdate(this.appDirectory,
				this.updateInfo, this.updateAvailable, this.updateCheckError,
				() => cast(bool) atomicLoad(this.workCancelled));
			break;
		case UpdateMethodKind.PlingV1Zsync:
			checkPlingForUpdate(this.appDirectory, this.sanitizedName,
				this.updateInfo, this.updateAvailable, this.updateCheckError,
				() => cast(bool) atomicLoad(this.workCancelled));
			break;
		}
		auto installedAppManifest =
			Manifest.loadFromAppDir(this.appDirectory);
		if (installedAppManifest !is null) {
			this.installedVersion = installedAppManifest.releaseVersion;
			if (!this.updateAvailable
				&& !this.updateCheckError.length
				&& installedAppManifest.updateAvailable) {
				installedAppManifest.updateAvailable = false;
				installedAppManifest.save();
			}
		}
		auto elapsed = MonoTime.currTime - startTime;
		auto minWait = dur!"msecs"(AnimationDelay.checkMinMs);
		if (elapsed < minWait)
			Thread.sleep(minWait - elapsed);
	}

	override void showWindow() {
		this.loadingSpinner.stop();

		enum int NAV_SLIDE_MS = 350;

		void delegate() currentBackAction;
		Button backButton;

		auto subSlot = new Box(Orientation.Vertical, 0);
		subSlot.setHexpand(true);
		subSlot.setVexpand(true);

		auto navStack = new Stack;
		navStack.setHexpand(true);
		navStack.setVexpand(true);
		navStack.setTransitionDuration(NAV_SLIDE_MS);

		void slideToSub(Box content) {
			auto previousChild = subSlot.getFirstChild();
			if (previousChild !is null)
				subSlot.remove(previousChild);
			subSlot.append(content);
			navStack.setTransitionType(StackTransitionType.SlideLeft);
			navStack.setVisibleChildName("sub");
		}

		void slideBackToUpdate() {
			navStack.setTransitionType(StackTransitionType.SlideRight);
			navStack.setVisibleChildName("update");
			this.headerBar.remove(backButton);
		}

		Box updateBox;
		final switch (parseUpdateMethodKind(this.updateInfo)) {
		case UpdateMethodKind.DirectLink: {
				auto dlSlot = new Box(Orientation.Vertical, 0);
				dlSlot.setHexpand(true);
				dlSlot.setVexpand(true);
				buildDirectLinkUpdateFlow(dlSlot,
					this.appName, this.sanitizedName, this.appDirectory,
					extractDirectLinkUrl(this.updateInfo), this.installedVersion,
					(void delegate() workDelegate, void delegate() doneDelegate) {
					this.doThreadedWork(workDelegate, doneDelegate);
				}, null, null, () => cast(bool) atomicLoad(this.workCancelled));
				updateBox = dlSlot;
				break;
			}
		case UpdateMethodKind.Zsync: {
				if (!this.updateAvailable && !this.updateCheckError.length) {
					updateBox = buildUpdateBox(
						this.appName, false, "", this.updateInfo, this.installedVersion);
				} else {
					auto dlSlot = new Box(Orientation.Vertical, 0);
					dlSlot.setHexpand(true);
					dlSlot.setVexpand(true);
					buildZsyncUpdateFlow(dlSlot,
						this.appName, this.sanitizedName, this.appDirectory,
						extractZsyncUrl(this.updateInfo), this.installedVersion,
						(void delegate() workDelegate, void delegate() doneDelegate) {
						this.doThreadedWork(workDelegate, doneDelegate);
					}, null, null, () => cast(bool) atomicLoad(this.workCancelled));
					updateBox = dlSlot;
				}
				break;
			}
		case UpdateMethodKind.GitHubZsync: {
				if (!this.updateAvailable && !this.updateCheckError.length) {
					updateBox = buildUpdateBox(
						this.appName, false, "", this.updateInfo, this.installedVersion);
				} else {
					auto dlSlot = new Box(Orientation.Vertical, 0);
					dlSlot.setHexpand(true);
					dlSlot.setVexpand(true);
					buildGitHubZsyncUpdateFlow(dlSlot,
						this.appName, this.sanitizedName, this.appDirectory,
						this.updateInfo, this.installedVersion,
						(void delegate() workDelegate, void delegate() doneDelegate) {
						this.doThreadedWork(workDelegate, doneDelegate);
					}, null, null, () => cast(bool) atomicLoad(this.workCancelled));
					updateBox = dlSlot;
				}
				break;
			}
		case UpdateMethodKind.GitHubRelease: {
				if (!this.updateAvailable && !this.updateCheckError.length) {
					updateBox = buildUpdateBox(
						this.appName, false, "", this.updateInfo, this.installedVersion);
				} else {
					auto dlSlot = new Box(Orientation.Vertical, 0);
					dlSlot.setHexpand(true);
					dlSlot.setVexpand(true);
					buildGitHubReleaseUpdateFlow(dlSlot,
						this.appName, this.sanitizedName, this.appDirectory,
						this.updateInfo, this.installedVersion,
						(void delegate() workDelegate, void delegate() doneDelegate) {
						this.doThreadedWork(workDelegate, doneDelegate);
					}, null, null, () => cast(bool) atomicLoad(this.workCancelled));
					updateBox = dlSlot;
				}
				break;
			}
		case UpdateMethodKind.GitHubLinuxManifest: {
				if (!this.updateAvailable && !this.updateCheckError.length) {
					updateBox = buildUpdateBox(
						this.appName, false, "", this.updateInfo, this.installedVersion);
				} else {
					auto dlSlot = new Box(Orientation.Vertical, 0);
					dlSlot.setHexpand(true);
					dlSlot.setVexpand(true);
					buildGitHubLinuxManifestUpdateFlow(dlSlot,
						this.appName, this.sanitizedName, this.appDirectory,
						this.updateInfo, this.installedVersion,
						(void delegate() workDelegate, void delegate() doneDelegate) {
						this.doThreadedWork(workDelegate, doneDelegate);
					}, null, null, () => cast(bool) atomicLoad(this.workCancelled));
					updateBox = dlSlot;
				}
				break;
			}
		case UpdateMethodKind.PlingV1Zsync: {
				if (!this.updateAvailable && !this.updateCheckError.length) {
					updateBox = buildUpdateBox(
						this.appName, false, "", this.updateInfo, this.installedVersion);
				} else {
					auto dlSlot = new Box(Orientation.Vertical, 0);
					dlSlot.setHexpand(true);
					dlSlot.setVexpand(true);
					buildPlingUpdateFlow(dlSlot,
						this.appName, this.sanitizedName, this.appDirectory,
						this.updateInfo, this.installedVersion,
						(void delegate() workDelegate, void delegate() doneDelegate) {
						this.doThreadedWork(workDelegate, doneDelegate);
					}, null, null, null, () => cast(bool) atomicLoad(this.workCancelled));
					updateBox = dlSlot;
				}
				break;
			}
		case UpdateMethodKind.Unknown: {
				updateBox = buildUpdateBox(
					this.appName, this.updateAvailable, this.updateCheckError, this.updateInfo,
					this.installedVersion,
					() {
					currentBackAction = () { slideBackToUpdate(); };
					backButton = makeBackButton(() { currentBackAction(); });
					this.headerBar.packStart(backButton);
					slideToSub(buildAddUpdateMethodBox(
						this.appName,
						this.sanitizedName,
						(void delegate() workDelegate, void delegate() doneDelegate) {
							this.doThreadedWork(workDelegate, doneDelegate);
						},
						() { backButton.setSensitive(false); },
						() { backButton.setSensitive(true); },
						(void delegate() backActionDelegate) {
							currentBackAction = backActionDelegate;
						},
						() { slideBackToUpdate(); }));
				});
				break;
			}
		}

		navStack.addNamed(updateBox, "update");
		navStack.addNamed(subSlot, "sub");
		navStack.setVisibleChildName("update");
		this.setChild(navStack);
	}
}
