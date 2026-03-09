module windows.cleanup;

import core.atomic : atomicLoad, atomicStore;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.file : exists, isDir, isSymlink, remove, rmdirRecurse, FileException;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : join;
import appimage.icon : findInstalledIconPaths;
import apputils : xdgDataHome, installBaseDir;
import core.thread : Thread;

import glib.global : idleAdd, timeoutAdd;
import glib.types : PRIORITY_DEFAULT;
import gtk.box : Box;
import gtk.button : Button;
import gtk.image : Image;
import gtk.label : Label;
import gtk.revealer : Revealer;
import gtk.spinner : Spinner;
import gtk.types : Align, Justification, Orientation, RevealerTransitionType, StackTransitionType;
import gtk.stack : Stack;

import windows.base : makeSlideDownRevealer, revealAfterDelay, revealWithStagger;
import windows.base : ACTION_BTN_WIDTH, ACTION_BTN_HEIGHT, CONTENT_REVEAL_DELAY_MS;
import windows.base : ACTION_REVEAL_DELAY_MS, CARD_STAGGER_MS;
import constants : DESKTOP_PREFIX;
import lang : L;

// Revealer and stack transition duration
private enum int ANIM_DURATION_MS = 300;
private enum int SPINNER_MIN_MS = 250; // Spinner shown for at least this long
private enum int DISCOVER_POLL_MS = 40;

// Pixel measurements and spacing for the cleanup page layout
private enum Layout {
	iconSize = 18,
	iconStackSize = 20,
	labelWidthChars = 10,
	rowSpacing = 10,
	rowPadding = 3,
	descMaxChars = 48,
	sectionSpacing = 6,
	itemSpacing = 16,
	buttonMarginTop = 16,
	errorMarginTop = 6,
	sideMargin = 48,
}

// What the file system scan found for this orphan entry
private struct CleanupTargets {
	string desktopPath;
	bool desktopFound;
	string appDirPath;
	bool appDirFound;
	string[] iconPaths;
}

// Widgets and callbacks for one removable item in the cleanup list
private struct ItemRow {
	Revealer revealer;
	void delegate(bool found) resolve;
	void delegate() respin;
}

// Scans the file system to figure out what this orphan left behind
private CleanupTargets discover(
	string installedIconName, string desktopSymlink) {
	CleanupTargets t;
	t.desktopPath = desktopSymlink;

	try {
		t.desktopFound = isSymlink(desktopSymlink) || exists(desktopSymlink);
	} catch (FileException error) {
		writeln("cleanup: desktop check: ", error.msg);
	}

	if (installedIconName.length > DESKTOP_PREFIX.length
		&& installedIconName[0 .. DESKTOP_PREFIX.length] == DESKTOP_PREFIX) {
		string sanitized = installedIconName[DESKTOP_PREFIX.length .. $];
		if (sanitized.length) {
			t.appDirPath = buildPath(installBaseDir(), sanitized);
			try {
				t.appDirFound = exists(t.appDirPath) && isDir(t.appDirPath);
			} catch (FileException error) {
				writeln("cleanup: dir check: ", error.msg);
			}
		}
	}

	t.iconPaths = findInstalledIconPaths(installedIconName);

	return t;
}

// Deletes all discovered leftovers
// Throws on failure so the caller can handle the error
private void performCleanup(ref CleanupTargets t) {
	foreach (path; t.iconPaths)
		remove(path);
	if (t.appDirFound)
		rmdirRecurse(t.appDirPath);
	if (t.desktopFound)
		remove(t.desktopPath);
}

private ItemRow makeItemRow(string labelText) {
	auto spinner = new Spinner;
	spinner.setSizeRequest(Layout.iconSize, Layout.iconSize);
	spinner.setValign(Align.Center);
	spinner.setHalign(Align.Center);
	spinner.setSpinning(true);

	// Placeholder image that resolve() will fill with the correct icon and CSS
	auto iconImage = new Image;
	iconImage.setSizeRequest(Layout.iconSize, Layout.iconSize);
	iconImage.setValign(Align.Center);
	iconImage.setHalign(Align.Center);

	// SlideLeft stack where the spinner exits left and the icon enters from the right
	auto iconStack = new Stack;
	iconStack.setTransitionType(StackTransitionType.SlideLeft);
	iconStack.setTransitionDuration(ANIM_DURATION_MS);
	iconStack.setSizeRequest(Layout.iconStackSize, Layout.iconStackSize);
	iconStack.setValign(Align.Center);
	iconStack.setHalign(Align.Center);
	iconStack.addNamed(spinner, "spin");
	iconStack.addNamed(iconImage, "icon");
	iconStack.setVisibleChildName("spin");

	auto label = new Label(labelText);
	label.addCssClass("caption-heading");
	label.setValign(Align.Center);
	label.setHalign(Align.End);
	label.setWidthChars(Layout.labelWidthChars);

	auto row = new Box(Orientation.Horizontal, Layout.rowSpacing);
	row.setHalign(Align.Center);
	row.setMarginTop(Layout.rowPadding);
	row.setMarginBottom(Layout.rowPadding);
	row.append(label);
	row.append(iconStack);

	auto revealer = makeSlideDownRevealer(ANIM_DURATION_MS);
	revealer.setHalign(Align.Center);
	revealer.setChild(row);

	void resolve(bool found) {
		iconImage.setFromIconName(
			found ? "emblem-ok-symbolic" : "window-close-symbolic");
		iconImage.pixelSize = Layout.iconSize;
		if (found)
			iconImage.addCssClass("success");
		else
			iconImage.addCssClass("dimmed");
		iconStack.setVisibleChildName("icon");
	}

	// Slides icon out to the left and spinner in from the right
	void respin() {
		iconStack.setVisibleChildName("spin");
	}

	return ItemRow(revealer, &resolve, &respin);
}

// Builds the cleanup section for an orphan desktop entry onCleanupSucceeded runs right away when files are deleted
package Box buildCleanupBox(
	string appName,
	string installedIconName,
	string desktopSymlink,
	void delegate(void delegate(), void delegate()) doWork,
	void delegate() onDisableBack,
	void delegate() onEnableBack,
	void delegate() onCleanupSucceeded) {

	// The broom slides up and out when switching to the done state

	auto broomImage = Image.newFromIconName("edit-clear-all-symbolic");
	broomImage.addCssClass("icon-large");

	auto doneImage = Image.newFromIconName("emblem-default-symbolic");
	doneImage.addCssClass("icon-large");
	doneImage.addCssClass("success");

	auto iconStack = new Stack;
	iconStack.setTransitionType(StackTransitionType.SlideUp);
	iconStack.setTransitionDuration(ANIM_DURATION_MS);
	iconStack.setHalign(Align.Center);
	iconStack.addNamed(broomImage, "broom");
	iconStack.addNamed(doneImage, "done");
	iconStack.setVisibleChildName("broom");

	// Icon and text will be combined into one revealer after textStack is built below

	auto titleLabel = new Label(L("cleanup.confirm.title", appName));
	titleLabel.addCssClass("title-3");
	titleLabel.setHalign(Align.Center);

	auto descriptionLabel = new Label(L("cleanup.confirm.description", appName));
	descriptionLabel.setHalign(Align.Center);
	descriptionLabel.setJustify(Justification.Center);
	descriptionLabel.setWrap(true);
	descriptionLabel.setMaxWidthChars(Layout.descMaxChars);
	descriptionLabel.addCssClass("dim-label");

	auto headerBox = new Box(Orientation.Vertical, Layout.sectionSpacing);
	headerBox.setHalign(Align.Center);
	headerBox.append(titleLabel);
	headerBox.append(descriptionLabel);

	auto doneTitleLabel = new Label(L("cleanup.done.title"));
	doneTitleLabel.addCssClass("title-3");
	doneTitleLabel.setHalign(Align.Center);

	auto doneSummaryLabel = new Label("");
	doneSummaryLabel.addCssClass("caption");
	doneSummaryLabel.addCssClass("dim-label");
	doneSummaryLabel.setHalign(Align.Center);

	auto doneTxtBox = new Box(Orientation.Vertical, Layout.sectionSpacing);
	doneTxtBox.setHalign(Align.Center);
	doneTxtBox.append(doneTitleLabel);
	doneTxtBox.append(doneSummaryLabel);

	// Both text blocks share the same space SlideLeft swaps them on success
	auto textStack = new Stack;
	textStack.setTransitionType(StackTransitionType.SlideLeft);
	textStack.setTransitionDuration(ANIM_DURATION_MS);
	textStack.setHalign(Align.Center);
	textStack.addNamed(headerBox, "header");
	textStack.addNamed(doneTxtBox, "done");
	textStack.setVisibleChildName("header");

	// textStack is combined with iconStack here so the title is never pushed by the icon sliding in
	auto iconTextBox = new Box(Orientation.Vertical, Layout.itemSpacing);
	iconTextBox.setHalign(Align.Center);
	iconTextBox.append(iconStack);
	iconTextBox.append(textStack);
	auto contentRevealer = makeSlideDownRevealer(ANIM_DURATION_MS);
	contentRevealer.setHalign(Align.Center);
	contentRevealer.setChild(iconTextBox);

	auto shortcutItem = makeItemRow(L("cleanup.item.shortcut"));
	auto iconItem = makeItemRow(L("cleanup.item.icon"));
	auto dirItem = makeItemRow(L("cleanup.item.directory"));

	// Items box that also slides in with the header
	auto itemsBox = new Box(Orientation.Vertical, 0);
	itemsBox.setHalign(Align.Center);
	itemsBox.append(shortcutItem.revealer);
	itemsBox.append(iconItem.revealer);
	itemsBox.append(dirItem.revealer);

	auto cleanupButton = Button.newWithLabel(L("button.cleanup"));
	cleanupButton.setSizeRequest(ACTION_BTN_WIDTH, ACTION_BTN_HEIGHT);
	cleanupButton.setHalign(Align.Center);
	cleanupButton.setMarginTop(Layout.buttonMarginTop);
	cleanupButton.addCssClass("destructive-action");
	cleanupButton.addCssClass("pill");
	auto buttonRevealer = makeSlideDownRevealer(ANIM_DURATION_MS);
	buttonRevealer.setHalign(Align.Center);
	buttonRevealer.setChild(cleanupButton);

	auto errorLabel = new Label(L("cleanup.error.failed"));
	errorLabel.addCssClass("error-label");
	errorLabel.setHalign(Align.Center);
	errorLabel.setMarginTop(Layout.errorMarginTop);
	auto errorRevealer = makeSlideDownRevealer(ANIM_DURATION_MS);
	errorRevealer.setHalign(Align.Center);
	errorRevealer.setChild(errorLabel);

	auto section = new Box(Orientation.Vertical, Layout.itemSpacing);
	section.setVexpand(true);
	section.setValign(Align.Center);
	section.setHalign(Align.Center);
	section.setMarginStart(Layout.sideMargin);
	section.setMarginEnd(Layout.sideMargin);
	section.append(contentRevealer);
	section.append(itemsBox);
	section.append(buttonRevealer);
	section.append(errorRevealer);

	// Header reveals right away, cards follow after a short pause, and the button waits
	// until the scan has resolved so the last action appears last.

	CleanupTargets* results = new CleanupTargets;
	shared bool* discoverDone = new shared bool(false);

	auto discoverer = new Thread({
		*results = discover(installedIconName, desktopSymlink);
		atomicStore(*discoverDone, true);
	});
	discoverer.isDaemon = true;
	discoverer.start();

	timeoutAdd(PRIORITY_DEFAULT, ANIM_DURATION_MS, {
		auto elapsedTimer = StopWatch(AutoStart.yes);
		timeoutAdd(PRIORITY_DEFAULT, DISCOVER_POLL_MS, {
			if (!atomicLoad(*discoverDone))
				return true;
			if (elapsedTimer.peek.total!"msecs" < SPINNER_MIN_MS)
				return true;
			shortcutItem.resolve(results.desktopFound);
			iconItem.resolve(results.iconPaths.length > 0);
			dirItem.resolve(results.appDirFound);
			revealAfterDelay(buttonRevealer, ACTION_REVEAL_DELAY_MS);
			return false;
		});
		return false;
	});

	bool* succeeded = new bool(false);
	cleanupButton.connectClicked(() {
		// Respin found items and slide the button away Start work after the button exit animation
		if (results.desktopFound)
			shortcutItem.respin();
		if (results.iconPaths.length > 0)
			iconItem.respin();
		if (results.appDirFound)
			dirItem.respin();
		buttonRevealer.setRevealChild(false);
		onDisableBack();
		timeoutAdd(PRIORITY_DEFAULT, ANIM_DURATION_MS, {
			doWork(
			{
				try {
					performCleanup(*results);
					*succeeded = true;
				} catch (FileException error) {
					writeln("cleanup: error: ", error.msg);
				}
			},
			{
				onEnableBack();
				if (*succeeded) {
					string[] cleaned;
					if (results.desktopFound)
						cleaned ~= L("cleanup.item.shortcut");
					if (results.iconPaths.length > 0)
						cleaned ~= L("cleanup.item.icon");
					if (results.appDirFound)
						cleaned ~= L("cleanup.item.directory");

					string summaryText;
					if (cleaned.length) {
						immutable string items = cleaned.join(", ");
						summaryText = L("cleanup.done.removed", items);
					} else {
						summaryText = L("cleanup.done.nothing");
					}
					doneSummaryLabel.setLabel(summaryText);

					onCleanupSucceeded();

					// Short pause so the user can see the spinners settle, then slide items away
					timeoutAdd(PRIORITY_DEFAULT, ACTION_REVEAL_DELAY_MS, {
						// Slide items away first
						shortcutItem.revealer.setRevealChild(false);
						iconItem.revealer.setRevealChild(false);
						dirItem.revealer.setRevealChild(false);

						// Then swap icon and text simultaneously via their stacks
						timeoutAdd(PRIORITY_DEFAULT, ANIM_DURATION_MS, {
							iconStack.setVisibleChildName("done");
							textStack.setVisibleChildName("done");
							return false;
						});
						return false;
					});
				} else {
					errorRevealer.setRevealChild(true);
				}
			});
			return false;
		});
	});

	revealAfterDelay(contentRevealer, 0);
	revealWithStagger([
		shortcutItem.revealer,
		iconItem.revealer,
		dirItem.revealer,
	], CONTENT_REVEAL_DELAY_MS, CARD_STAGGER_MS);

	auto root = new Box(Orientation.Vertical, 0);
	root.setHexpand(true);
	root.setVexpand(true);
	root.append(section);
	return root;
}
