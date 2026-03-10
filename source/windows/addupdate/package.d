// Multi-step wizard for configuring an update method on an installed app
//
module windows.addupdate;

import core.thread : Thread;
import core.time : dur;

import glib.global : timeoutAdd;
import glib.types : PRIORITY_DEFAULT;
import gtk.box : Box;
import gtk.button : Button;
import gtk.entry : Entry;
import gtk.image : Image;
import gtk.label : Label;
import gtk.list_box : ListBox;
import gtk.list_box_row : ListBoxRow;
import gtk.revealer : Revealer;
import gtk.spinner : Spinner;
import gtk.stack : Stack;
import gtk.types : Align, Justification, Orientation, RevealerTransitionType;
import gtk.types : SelectionMode, StackTransitionType;

import std.file : FileException;
import std.json : JSONException;
import std.string : indexOf, startsWith, strip;
import windows.base : makeSlideDownRevealer, revealAfterDelay, revealWithStagger, makeIcon;
import windows.base : ACTION_BTN_WIDTH, ACTION_BTN_HEIGHT, ANIM_DURATION_MS;
import windows.base : CONTENT_REVEAL_DELAY_MS, ACTION_REVEAL_DELAY_MS, CARD_STAGGER_MS;
import windows.addupdate.helpers;
import update.githubzsync : findGitHubZsyncAsset;
import update.githublinuxmanifest : findLinuxManifestAsset;
import lang : L;

// Width for the manual update string entry
private enum int ENTRY_WIDTH = 300;

// Pixel measurements and spacing for the add update wizard pages
private enum Layout {
	pageSpacing = 16,
	pageMargin = 48,
	textBoxSpacing = 8,
	descMaxChars = 52,
	testDescMaxChars = 48,
	buttonMarginTop = 16,
	spinnerSize = 48,
}

// Multi-step wizard for configuring an update method
// setBackAction rewires the back button each step, onComplete fires when the wizard finishes
Box buildAddUpdateMethodBox(
	string appName,
	string sanitizedName,
	void delegate(void delegate(), void delegate()) doWork,
	void delegate() onDisableBack,
	void delegate() onEnableBack,
	void delegate(void delegate()) setBackAction,
	void delegate() onComplete) {

	auto navStack = new Stack;
	navStack.setTransitionDuration(ANIM_DURATION_MS);
	navStack.setHexpand(true);
	navStack.setVexpand(true);

	void goForward(string page) {
		navStack.setTransitionType(StackTransitionType.SlideLeft);
		navStack.setVisibleChildName(page);
	}

	void goBack(string page) {
		navStack.setTransitionType(StackTransitionType.SlideRight);
		navStack.setVisibleChildName(page);
	}

	auto chooseIcon = makeIcon([
		"software-update-available-symbolic", "system-software-update-symbolic"
	]);
	chooseIcon.addCssClass("icon-large");
	chooseIcon.setHalign(Align.Center);

	auto chooseTitleLabel = new Label(L("addupdate.title"));
	chooseTitleLabel.addCssClass("title-3");
	chooseTitleLabel.setHalign(Align.Center);

	auto chooseDescriptionLabel = new Label(L("addupdate.choose.description", appName));
	chooseDescriptionLabel.setHalign(Align.Center);
	chooseDescriptionLabel.setJustify(Justification.Center);
	chooseDescriptionLabel.setWrap(true);
	chooseDescriptionLabel.setMaxWidthChars(Layout.descMaxChars);
	chooseDescriptionLabel.addCssClass("dim-label");

	auto chooseTextBox = new Box(Orientation.Vertical, Layout.textBoxSpacing);
	chooseTextBox.setHalign(Align.Center);
	chooseTextBox.append(chooseTitleLabel);
	chooseTextBox.append(chooseDescriptionLabel);

	auto choiceList = new ListBox;
	choiceList.addCssClass("boxed-list");
	choiceList.setSelectionMode(SelectionMode.None);
	choiceList.setHexpand(true);

	auto githubRowRevealer = makeSlideDownRevealer(ANIM_DURATION_MS);
	githubRowRevealer.setHalign(Align.Fill);
	githubRowRevealer.setChild(makeChoiceRowContent(
			[
			"software-update-available-symbolic",
			"system-software-update-symbolic"
		],
		L("addupdate.method.github"), L("addupdate.method.github.subtitle")));
	auto gitHubRow = new ListBoxRow;
	gitHubRow.setChild(githubRowRevealer);

	auto zsyncRowRevealer = makeSlideDownRevealer(ANIM_DURATION_MS);
	zsyncRowRevealer.setHalign(Align.Fill);
	zsyncRowRevealer.setChild(makeChoiceRowContent(
			[
			"emblem-synchronizing-symbolic", "network-transmit-receive-symbolic"
		],
		L("addupdate.method.zsync"), L("addupdate.method.zsync.subtitle")));
	auto zsyncRow = new ListBoxRow;
	zsyncRow.setChild(zsyncRowRevealer);

	auto plingRowRevealer = makeSlideDownRevealer(ANIM_DURATION_MS);
	plingRowRevealer.setHalign(Align.Fill);
	plingRowRevealer.setChild(makeChoiceRowContent(
			[
				"web-browser-symbolic", "network-workgroup-symbolic"
			],
			L("addupdate.method.pling"), L("addupdate.method.pling.subtitle")));
	auto plingRow = new ListBoxRow;
	plingRow.setChild(plingRowRevealer);

	auto directRowRevealer = makeSlideDownRevealer(ANIM_DURATION_MS);
	directRowRevealer.setHalign(Align.Fill);
	directRowRevealer.setChild(makeChoiceRowContent(
			["folder-download-symbolic", "folder-symbolic"],
			L("addupdate.method.direct"), L("addupdate.method.direct.subtitle")));
	auto directRow = new ListBoxRow;
	directRow.setChild(directRowRevealer);

	choiceList.append(gitHubRow);
	choiceList.append(zsyncRow);
	choiceList.append(plingRow);
	choiceList.append(directRow);

	auto choosePage = new Box(Orientation.Vertical, Layout.pageSpacing);
	choosePage.setVexpand(true);
	choosePage.setValign(Align.Start);
	choosePage.setHalign(Align.Fill);
	choosePage.setHexpand(true);
	choosePage.setMarginTop(Layout.pageMargin);
	choosePage.setMarginStart(Layout.pageMargin);
	choosePage.setMarginEnd(Layout.pageMargin);
	choosePage.append(chooseIcon);
	choosePage.append(chooseTextBox);
	choosePage.append(choiceList);

	auto inputIcon = makeIcon([
		"software-update-available-symbolic",
		"system-software-update-symbolic",
	]);
	inputIcon.addCssClass("icon-large");
	inputIcon.setHalign(Align.Center);

	auto inputTitleLabel = new Label("");
	inputTitleLabel.addCssClass("title-3");
	inputTitleLabel.setHalign(Align.Center);

	auto inputDescriptionLabel = new Label("");
	inputDescriptionLabel.setHalign(Align.Center);
	inputDescriptionLabel.setJustify(Justification.Center);
	inputDescriptionLabel.setWrap(true);
	inputDescriptionLabel.setMaxWidthChars(Layout.descMaxChars);
	inputDescriptionLabel.addCssClass("dim-label");

	auto inputExampleLabel = new Label("");
	inputExampleLabel.setHalign(Align.Center);
	inputExampleLabel.setJustify(Justification.Center);
	inputExampleLabel.setWrap(true);
	inputExampleLabel.setMaxWidthChars(Layout.descMaxChars);
	inputExampleLabel.addCssClass("caption");
	inputExampleLabel.addCssClass("dim-label");

	auto inputTextBox = new Box(Orientation.Vertical, Layout.textBoxSpacing);
	inputTextBox.setHalign(Align.Center);
	inputTextBox.append(inputTitleLabel);
	inputTextBox.append(inputDescriptionLabel);
	inputTextBox.append(inputExampleLabel);

	auto inputEntry = new Entry;
	inputEntry.setHalign(Align.Center);
	inputEntry.setSizeRequest(ENTRY_WIDTH, -1);
	auto inputEntryRevealer = makeSlideDownRevealer(ANIM_DURATION_MS);
	inputEntryRevealer.setChild(inputEntry);

	auto nextButton = Button.newWithLabel(L("button.next"));
	nextButton.setSizeRequest(ACTION_BTN_WIDTH, ACTION_BTN_HEIGHT);
	nextButton.setHalign(Align.Center);
	nextButton.setMarginTop(Layout.buttonMarginTop);
	nextButton.setSensitive(false);
	nextButton.addCssClass("pill");
	auto nextButtonRevealer = makeSlideDownRevealer(ANIM_DURATION_MS);
	nextButtonRevealer.setChild(nextButton);

	auto inputPage = new Box(Orientation.Vertical, Layout.pageSpacing);
	inputPage.setVexpand(true);
	inputPage.setValign(Align.Start);
	inputPage.setHalign(Align.Center);
	inputPage.setMarginTop(Layout.pageMargin);
	inputPage.setMarginStart(Layout.pageMargin);
	inputPage.setMarginEnd(Layout.pageMargin);
	inputPage.append(inputIcon);
	inputPage.append(inputTextBox);
	inputPage.append(inputEntryRevealer);
	inputPage.append(nextButtonRevealer);

	auto testSpinner = new Spinner;
	testSpinner.setSizeRequest(Layout.spinnerSize, Layout.spinnerSize);
	testSpinner.setHalign(Align.Center);
	testSpinner.setSpinning(true);

	auto testTitleLabel = new Label(L("addupdate.verifying"));
	testTitleLabel.addCssClass("title-3");
	testTitleLabel.setHalign(Align.Center);

	auto testDescriptionLabel = new Label(L("addupdate.verify.description"));
	testDescriptionLabel.setHalign(Align.Center);
	testDescriptionLabel.setJustify(Justification.Center);
	testDescriptionLabel.setWrap(true);
	testDescriptionLabel.setMaxWidthChars(Layout.testDescMaxChars);
	testDescriptionLabel.addCssClass("dim-label");

	auto testContentBox = new Box(Orientation.Vertical, Layout.textBoxSpacing);
	testContentBox.setHalign(Align.Center);
	testContentBox.append(testSpinner);
	testContentBox.append(testTitleLabel);
	testContentBox.append(testDescriptionLabel);
	auto testContentRevealer = makeSlideDownRevealer(ANIM_DURATION_MS);
	testContentRevealer.setChild(testContentBox);

	auto testPage = new Box(Orientation.Vertical, Layout.pageSpacing);
	testPage.setVexpand(true);
	testPage.setValign(Align.Center);
	testPage.setHalign(Align.Center);
	testPage.setMarginStart(Layout.pageMargin);
	testPage.setMarginEnd(Layout.pageMargin);
	testPage.append(testContentRevealer);

	auto errorIcon = Image.newFromIconName("dialog-warning-symbolic");
	errorIcon.addCssClass("icon-large");
	errorIcon.addCssClass("warning");
	errorIcon.setHalign(Align.Center);

	auto errorTitleLabel = new Label(L("addupdate.failed.title"));
	errorTitleLabel.addCssClass("title-3");
	errorTitleLabel.setHalign(Align.Center);

	auto errorDescriptionLabel = new Label("");
	errorDescriptionLabel.setHalign(Align.Center);
	errorDescriptionLabel.setJustify(Justification.Center);
	errorDescriptionLabel.setWrap(true);
	errorDescriptionLabel.setMaxWidthChars(Layout.descMaxChars);
	errorDescriptionLabel.addCssClass("dim-label");

	auto errorContentBox = new Box(Orientation.Vertical, Layout.textBoxSpacing);
	errorContentBox.setHalign(Align.Center);
	errorContentBox.append(errorIcon);
	errorContentBox.append(errorTitleLabel);
	errorContentBox.append(errorDescriptionLabel);
	auto errorContentRevealer = makeSlideDownRevealer(ANIM_DURATION_MS);
	errorContentRevealer.setChild(errorContentBox);

	auto errorBackButton = Button.newWithLabel(L("button.back"));
	errorBackButton.setSizeRequest(ACTION_BTN_WIDTH, ACTION_BTN_HEIGHT);
	errorBackButton.setHalign(Align.Center);
	errorBackButton.setMarginTop(Layout.buttonMarginTop);
	errorBackButton.addCssClass("pill");
	auto errorBackButtonRevealer = makeSlideDownRevealer(ANIM_DURATION_MS);
	errorBackButtonRevealer.setChild(errorBackButton);

	auto errorPage = new Box(Orientation.Vertical, Layout.pageSpacing);
	errorPage.setVexpand(true);
	errorPage.setValign(Align.Center);
	errorPage.setHalign(Align.Center);
	errorPage.setMarginStart(Layout.pageMargin);
	errorPage.setMarginEnd(Layout.pageMargin);
	errorPage.append(errorContentRevealer);
	errorPage.append(errorBackButtonRevealer);

	auto httpIcon = makeIcon([
		"security-low-symbolic", "dialog-warning-symbolic"
	]);
	httpIcon.addCssClass("icon-large");
	httpIcon.addCssClass("warning");
	httpIcon.setHalign(Align.Center);

	auto httpTitleLabel = new Label(L("addupdate.http.warning.title"));
	httpTitleLabel.addCssClass("title-3");
	httpTitleLabel.setHalign(Align.Center);

	auto httpDescriptionLabel = new Label(L("addupdate.http.warning.description"));
	httpDescriptionLabel.setHalign(Align.Center);
	httpDescriptionLabel.setJustify(Justification.Center);
	httpDescriptionLabel.setWrap(true);
	httpDescriptionLabel.setMaxWidthChars(Layout.descMaxChars);
	httpDescriptionLabel.addCssClass("dim-label");

	auto httpContentBox = new Box(Orientation.Vertical, Layout.textBoxSpacing);
	httpContentBox.setHalign(Align.Center);
	httpContentBox.append(httpIcon);
	httpContentBox.append(httpTitleLabel);
	httpContentBox.append(httpDescriptionLabel);
	auto httpContentRevealer = makeSlideDownRevealer(ANIM_DURATION_MS);
	httpContentRevealer.setChild(httpContentBox);

	auto httpBackButton = Button.newWithLabel(L("button.back"));
	httpBackButton.setSizeRequest(ACTION_BTN_WIDTH, ACTION_BTN_HEIGHT);
	httpBackButton.setHalign(Align.Center);
	httpBackButton.setMarginTop(Layout.buttonMarginTop);
	httpBackButton.addCssClass("pill");
	auto httpBackButtonRevealer = makeSlideDownRevealer(ANIM_DURATION_MS);
	httpBackButtonRevealer.setChild(httpBackButton);

	auto httpContinueButton = Button.newWithLabel(L("addupdate.http.continue"));
	httpContinueButton.setSizeRequest(ACTION_BTN_WIDTH, ACTION_BTN_HEIGHT);
	httpContinueButton.setHalign(Align.Center);
	httpContinueButton.addCssClass("destructive-action");
	httpContinueButton.addCssClass("pill");
	auto httpContinueButtonRevealer = makeSlideDownRevealer(ANIM_DURATION_MS);
	httpContinueButtonRevealer.setChild(httpContinueButton);

	auto httpButtonBox = new Box(Orientation.Vertical, Layout.textBoxSpacing);
	httpButtonBox.setHalign(Align.Center);
	httpButtonBox.setMarginTop(Layout.buttonMarginTop);
	httpButtonBox.append(httpContinueButtonRevealer);
	httpButtonBox.append(httpBackButtonRevealer);

	auto httpPage = new Box(Orientation.Vertical, Layout.pageSpacing);
	httpPage.setVexpand(true);
	httpPage.setValign(Align.Center);
	httpPage.setHalign(Align.Center);
	httpPage.setMarginStart(Layout.pageMargin);
	httpPage.setMarginEnd(Layout.pageMargin);
	httpPage.append(httpContentRevealer);
	httpPage.append(httpButtonBox);

	// Set to true by the HTTP warning Continue button so the next click skips the warning
	bool httpConfirmed;

	auto successIcon = makeIcon([
		"emblem-default-symbolic", "emblem-ok-symbolic", "object-select-symbolic"
	]);
	successIcon.addCssClass("icon-large");
	successIcon.addCssClass("success");
	successIcon.setHalign(Align.Center);

	auto successTitleLabel = new Label(L("addupdate.success.title"));
	successTitleLabel.addCssClass("title-3");
	successTitleLabel.setHalign(Align.Center);

	auto successDescriptionLabel = new Label(L("addupdate.success.description"));
	successDescriptionLabel.setHalign(Align.Center);
	successDescriptionLabel.setJustify(Justification.Center);
	successDescriptionLabel.setWrap(true);
	successDescriptionLabel.setMaxWidthChars(Layout.descMaxChars);
	successDescriptionLabel.addCssClass("dim-label");

	auto successContentBox = new Box(Orientation.Vertical, Layout.textBoxSpacing);
	successContentBox.setHalign(Align.Center);
	successContentBox.append(successIcon);
	successContentBox.append(successTitleLabel);
	successContentBox.append(successDescriptionLabel);
	auto successContentRevealer = makeSlideDownRevealer(ANIM_DURATION_MS);
	successContentRevealer.setChild(successContentBox);

	auto completeButton = Button.newWithLabel(L("button.complete"));
	completeButton.setSizeRequest(ACTION_BTN_WIDTH, ACTION_BTN_HEIGHT);
	completeButton.setHalign(Align.Center);
	completeButton.setMarginTop(Layout.buttonMarginTop);
	completeButton.addCssClass("suggested-action");
	completeButton.addCssClass("pill");
	auto completeButtonRevealer = makeSlideDownRevealer(ANIM_DURATION_MS);
	completeButtonRevealer.setChild(completeButton);

	auto successPage = new Box(Orientation.Vertical, Layout.pageSpacing);
	successPage.setVexpand(true);
	successPage.setValign(Align.Center);
	successPage.setHalign(Align.Center);
	successPage.setMarginStart(Layout.pageMargin);
	successPage.setMarginEnd(Layout.pageMargin);
	successPage.append(successContentRevealer);
	successPage.append(completeButtonRevealer);

	navStack.addNamed(choosePage, "choose");
	navStack.addNamed(inputPage, "input");
	navStack.addNamed(testPage, "test");
	navStack.addNamed(errorPage, "error");
	navStack.addNamed(successPage, "success");
	navStack.addNamed(httpPage, "http-warning");
	navStack.setVisibleChildName("choose");

	MethodKind currentMethod = MethodKind.GitHubZsync;
	bool function(string) currentValidator = &isValidGitHub;
	string pendingRepoInput;

	void enterInputPage(MethodKind kind) {
		setupInputPage(kind, currentMethod, currentValidator,
			inputIcon, inputTitleLabel, inputDescriptionLabel, inputExampleLabel,
			inputEntry, nextButton, inputEntryRevealer, nextButtonRevealer);
		goForward("input");
		setBackAction(() { goBack("choose"); setBackAction(() { onComplete(); }); });
		animateInputPage(inputEntryRevealer, nextButtonRevealer);
	}

	choiceList.connectRowActivated((ListBoxRow listBoxRow, ListBox listBox) {
		immutable MethodKind[4] methods = [
			MethodKind.GitHubZsync, MethodKind.Zsync, MethodKind.Pling,
			MethodKind.DirectLink
		];
		int selectedIndex = listBoxRow.getIndex();
		if (selectedIndex >= 0 && selectedIndex < 4)
			enterInputPage(methods[selectedIndex]);
	});

	inputEntry.connectChanged(() {
		nextButton.setSensitive(currentValidator(inputEntry.getText()));
	});

	nextButton.connectClicked(() {
		string rawInput = inputEntry.getText();

		bool isHttpUrl = rawInput.strip().startsWith("http://");
		bool needsHttpCheck = isHttpUrl
			&& (currentMethod == MethodKind.Zsync
				|| currentMethod == MethodKind.DirectLink);

		if (needsHttpCheck && !httpConfirmed) {
			httpContentRevealer.setRevealChild(false);
			httpContinueButtonRevealer.setRevealChild(false);
			httpBackButtonRevealer.setRevealChild(false);
			goForward("http-warning");
			onDisableBack();
			revealAfterDelay(httpContentRevealer, 0);
			revealAfterDelay(httpContinueButtonRevealer, ACTION_REVEAL_DELAY_MS);
			revealAfterDelay(httpBackButtonRevealer, ACTION_REVEAL_DELAY_MS);
			setBackAction(() {
				httpContentRevealer.setRevealChild(false);
				httpContinueButtonRevealer.setRevealChild(false);
				httpBackButtonRevealer.setRevealChild(false);
				goBack("input");
				animateInputPage(inputEntryRevealer, nextButtonRevealer);
				setBackAction(() {
					goBack("choose");
					setBackAction(() { onComplete(); });
				});
				onEnableBack();
			});
			return;
		}
		httpConfirmed = false;

		testContentRevealer.setRevealChild(false);
		goForward("test");
		onDisableBack();
		revealAfterDelay(testContentRevealer, 0);

		void goToError(string message) {
			errorDescriptionLabel.setLabel(message);
			errorContentRevealer.setRevealChild(false);
			errorBackButtonRevealer.setRevealChild(false);
			goForward("error");
			revealAfterDelay(errorContentRevealer, 0);
			revealAfterDelay(errorBackButtonRevealer, ACTION_REVEAL_DELAY_MS);
		}

		void returnToInput(MethodKind kind, string repoInput) {
			setupInputPage(kind, currentMethod, currentValidator,
				inputIcon, inputTitleLabel, inputDescriptionLabel, inputExampleLabel,
				inputEntry, nextButton, inputEntryRevealer, nextButtonRevealer);
			if (repoInput.length)
				inputEntry.setText(repoInput);
			nextButton.setSensitive(currentValidator(inputEntry.getText()));
			goBack("input");
			animateInputPage(inputEntryRevealer, nextButtonRevealer);
			setBackAction(() {
				goBack("choose");
				setBackAction(() { onComplete(); });
			});
		}

		void saveAndFinish(string updateInfo) {
			bool succeeded = false;
			string saveError;
			doWork(
			{
				Thread.sleep(dur!"msecs"(TEST_MIN_MS));
				try {
					saveUpdateInfo(sanitizedName, updateInfo);
					succeeded = true;
				} catch (FileException error) {
					saveError = error.msg;
				} catch (JSONException error) {
					saveError = error.msg;
				}
			},
			{
				onEnableBack();
				if (succeeded) {
					goForward("success");
					onDisableBack();
					revealAfterDelay(successContentRevealer, 0);
					revealAfterDelay(completeButtonRevealer, ACTION_REVEAL_DELAY_MS);
				} else {
					setBackAction(() { returnToInput(currentMethod, ""); });
					goToError(L("addupdate.error.save", saveError));
				}
			});
		}

		if (currentMethod == MethodKind.GitHubZsync) {
			immutable string capturedRepo = normalizeGitHubInput(rawInput);
			pendingRepoInput = capturedRepo;
			immutable auto slashPos = capturedRepo.indexOf('/');
			immutable string ownerName = capturedRepo[0 .. slashPos];
			immutable string repositoryName = capturedRepo[slashPos + 1 .. $];
			string zsyncAsset;
			string resolveError;
			bool resolveOk = false;
			bool hasLinuxManifest = false;
			doWork(
			{
				Thread.sleep(dur!"msecs"(TEST_MIN_MS));
				resolveOk = findGitHubZsyncAsset(
				ownerName,
				repositoryName,
				zsyncAsset,
				resolveError);
				if (resolveOk && !zsyncAsset.length)
					resolveOk = findLinuxManifestAsset(
					ownerName,
					repositoryName,
					hasLinuxManifest,
					resolveError);
			},
			{
				onEnableBack();
				if (!resolveOk) {
					setBackAction(() {
						returnToInput(MethodKind.GitHubZsync, capturedRepo);
					});
					goToError(resolveError);
				} else if (zsyncAsset.length) {
					// .zsync asset found, use gh-releases-zsync directly
					immutable string updateInfo = buildUpdateInfo(
					MethodKind.GitHubZsync, capturedRepo);
					testContentRevealer.setRevealChild(false);
					goForward("test");
					onDisableBack();
					revealAfterDelay(testContentRevealer, 0);
					saveAndFinish(updateInfo);
				} else if (hasLinuxManifest) {
					// latest-linux.yml asset found, use gh-linux-yml directly
					immutable string updateInfo = buildUpdateInfo(
					MethodKind.GitHubLinuxManifest, capturedRepo);
					testContentRevealer.setRevealChild(false);
					goForward("test");
					onDisableBack();
					revealAfterDelay(testContentRevealer, 0);
					saveAndFinish(updateInfo);
				} else {
					// No .zsync or yml, ask user for the filename pattern
					setupInputPage(MethodKind.GitHubRelease, currentMethod,
					currentValidator,
					inputIcon, inputTitleLabel, inputDescriptionLabel,
					inputExampleLabel, inputEntry, nextButton,
					inputEntryRevealer, nextButtonRevealer);
					goBack("input");
					animateInputPage(inputEntryRevealer, nextButtonRevealer);
					setBackAction(() {
						returnToInput(MethodKind.GitHubZsync, capturedRepo);
					});
				}
			});
		} else if (currentMethod == MethodKind.GitHubRelease) {
			immutable string updateInfo = buildUpdateInfo(
				MethodKind.GitHubRelease, pendingRepoInput, rawInput);
			saveAndFinish(updateInfo);
		} else {
			saveAndFinish(buildUpdateInfo(currentMethod, rawInput));
		}
	});

	httpBackButton.connectClicked(() {
		httpContentRevealer.setRevealChild(false);
		httpContinueButtonRevealer.setRevealChild(false);
		httpBackButtonRevealer.setRevealChild(false);
		goBack("input");
		animateInputPage(inputEntryRevealer, nextButtonRevealer);
		setBackAction(() { goBack("choose"); setBackAction(() { onComplete(); }); });
		onEnableBack();
	});

	httpContinueButton.connectClicked(() {
		httpConfirmed = true;
		nextButton.activate();
	});

	errorBackButton.connectClicked(() {
		errorContentRevealer.setRevealChild(false);
		errorBackButtonRevealer.setRevealChild(false);
		goBack("input");
		animateInputPage(inputEntryRevealer, nextButtonRevealer);
		setBackAction(() { goBack("choose"); setBackAction(() { onComplete(); }); });
	});

	completeButton.connectClicked(() { onComplete(); });

	revealWithStagger([
		githubRowRevealer,
		zsyncRowRevealer,
		plingRowRevealer,
		directRowRevealer,
	], CONTENT_REVEAL_DELAY_MS, CARD_STAGGER_MS);

	auto root = new Box(Orientation.Vertical, 0);
	root.setHexpand(true);
	root.setVexpand(true);
	root.append(navStack);
	return root;
}
