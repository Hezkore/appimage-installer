module windows.base;

import std.stdio : writeln;
import std.concurrency;
import core.atomic : atomicLoad, atomicStore;
import core.time : dur;
import core.thread : Thread;

import glib.global : idleAdd, timeoutAdd;
import glib.types : PRIORITY_DEFAULT;
import gtk.application_window : ApplicationWindow;
import gtk.box : Box;
import gtk.button : Button;
import gtk.center_box : CenterBox;
import gtk.css_provider : CssProvider;
import gtk.header_bar : HeaderBar;
import gtk.image : Image;
import gtk.label : Label;
import gtk.menu_button : MenuButton;
import gtk.popover : Popover;
import gtk.revealer : Revealer;
import gtk.spinner : Spinner;
import gtk.style_context : StyleContext;
import gtk.types : Align, Orientation, RevealerTransitionType;
import gtk.widget : Widget;

import types : DoneMessage;
import application : App;
import constants : CSS_PRIORITY_APP;
import lang : L, setLang, availableLangs, activeLangCode, langName;

package(windows) enum int ACTION_BTN_WIDTH = 192;
package(windows) enum int ACTION_BTN_HEIGHT = 48;
package(windows) enum int ANIM_DURATION_MS = 350;
package(windows) enum int REVEAL_MS = 200; // Short slide or crossfade for banners and revealers
package(windows) enum int CONTENT_REVEAL_DELAY_MS = 250;
package(windows) enum int ACTION_REVEAL_DELAY_MS = 500;
package(windows) enum int CARD_STAGGER_MS = 100;

// Creates a language selector in the header bar that rebuilds the window on change.
// Each run gets its own stack frame so each closure captures a unique language code.
private void connectLangButton(Button btn, string code, Popover popover, AppWindow win) {
	btn.connectClicked(() {
		import apputils : writeConfigLang;

		setLang(code);
		writeConfigLang(code);
		popover.popdown();
		// Defer the rebuild so GTK finishes the click event before teardown
		idleAdd(PRIORITY_DEFAULT, () { win.reloadWindow(); return false; });
	});
}

// Builds language selector buttons into a box, dismissing containerPopover on selection
package(windows) Box makeLangBox(AppWindow win, Popover containerPopover) {
	enum int LANG_BOX_SPACING = 2;
	enum int ROW_SPACING = 8;
	auto box = new Box(Orientation.Vertical, LANG_BOX_SPACING);
	foreach (code; availableLangs()) {
		auto row = new Box(Orientation.Horizontal, ROW_SPACING);
		auto nameLabel = new Label(langName(code));
		nameLabel.setHexpand(true);
		nameLabel.setHalign(Align.Start);
		auto checkIcon = Image.newFromIconName("object-select-symbolic");
		if (code != activeLangCode())
			checkIcon.setOpacity(0);
		row.append(nameLabel);
		row.append(checkIcon);
		auto languageButton = new Button;
		languageButton.addCssClass("flat");
		languageButton.setChild(row);
		connectLangButton(languageButton, code, containerPopover, win);
		box.append(languageButton);
	}
	return box;
}

package MenuButton makeLangButton(AppWindow win) {
	enum int POPOVER_MARGIN = 4;
	auto languageMenuButton = new MenuButton;
	languageMenuButton.setIconName("preferences-desktop-locale-symbolic");
	languageMenuButton.addCssClass("flat");
	languageMenuButton.setValign(Align.Center);
	languageMenuButton.setTooltipText(langName(activeLangCode()));

	auto popover = new Popover;
	auto popoverBox = makeLangBox(win, popover);
	popoverBox.setMarginTop(POPOVER_MARGIN);
	popoverBox.setMarginBottom(POPOVER_MARGIN);
	popoverBox.setMarginStart(POPOVER_MARGIN);
	popoverBox.setMarginEnd(POPOVER_MARGIN);
	popover.setChild(popoverBox);
	languageMenuButton.setPopover(popover);
	return languageMenuButton;
}

// Applies a CSS string to a single widget at application CSS priority
package void applyCssToWidget(T)(T widget, string css) {
	auto provider = new CssProvider;
	provider.loadFromData(css, css.length);
	widget.getStyleContext().addProvider(provider, CSS_PRIORITY_APP);
}

// Creates a hidden SlideDown revealer, centred horizontally
// All animated content uses this so every window slides the same way
package Revealer makeSlideDownRevealer(int durationMs) {
	auto revealer = new Revealer;
	revealer.setTransitionType(RevealerTransitionType.SlideDown);
	revealer.setTransitionDuration(durationMs);
	revealer.setRevealChild(false);
	revealer.setHalign(Align.Center);
	return revealer;
}

// Reveals one widget after a shared stage delay so pages follow the same cadence
package void revealAfterDelay(
	Revealer revealer,
	int delayMs,
	bool delegate() shouldStop = null) {
	if (revealer is null)
		return;
	timeoutAdd(PRIORITY_DEFAULT, delayMs, {
		if (shouldStop !is null && shouldStop())
			return false;
		revealer.setRevealChild(true);
		return false;
	});
}

// Reveals a vertical list one item at a time so cards fold out with a steady rhythm
package void revealWithStagger(
	Revealer[] revealers,
	int delayMs,
	int staggerMs = CARD_STAGGER_MS,
	bool delegate() shouldStop = null) {
	foreach (index, revealer; revealers) {
		revealAfterDelay(
			revealer,
			delayMs + cast(int) index * staggerMs,
			shouldStop);
	}
}

// Creates a flat left-arrow back button for a header bar
package Button makeBackButton(void delegate() onClicked) {
	auto button = new Button;
	button.setChild(Image.newFromIconName("go-previous-symbolic"));
	button.addCssClass("flat");
	button.setTooltipText(L("button.back"));
	button.setValign(Align.Center);
	button.connectClicked(() { onClicked(); });
	return button;
}

// Base class for all windows Subclasses load data in a background thread then build the UI on the GTK thread
abstract class AppWindow : ApplicationWindow {
	private enum int WINDOW_WIDTH = 700;
	private enum int WINDOW_HEIGHT = 564;
	private enum int SPINNER_SIZE = 32;
	private enum int WORK_POLL_MS = 100;

	App app;
	HeaderBar headerBar;
	CenterBox loadingBox;
	Spinner loadingSpinner;

	// Set to true on window close so background downloads abort via shouldCancel delegates
	package(windows) shared bool workCancelled;

	// Runs the work function on a background thread and reports the result back to GTK.
	void doThreadedWork(void delegate() workDelegate, void delegate() completionDelegate) {
		atomicStore(this.workCancelled, false);
		this.setCursorFromName("wait");

		auto worker = new Thread({
			scope (success)
				send(this.app.mainThreadId, DoneMessage(true));
			scope (failure)
				send(this.app.mainThreadId, DoneMessage(false));
			workDelegate();
		});
		worker.isDaemon = true;
		worker.start();

		timeoutAdd(PRIORITY_DEFAULT, WORK_POLL_MS, {
			if (atomicLoad(this.workCancelled)) {
				this.setCursor(null);
				return false;
			}

			bool messageReceived = false;
			DoneMessage message;

			receiveTimeout(dur!"msecs"(0),
				(DoneMessage m) { message = m; messageReceived = true; });

			if (messageReceived) {
				this.setCursor(null);
				if (message.success) {
					completionDelegate();
				} else {
					// Closing here avoids a stuck spinner when the worker never finished cleanly.
					writeln("Worker failed, closing window.");
					this.close();
				}
				return false;
			}
			return true;
		});
	}

	this(App app) {
		import gtk.application : Application;

		this.app = app;
		super(cast(Application) app);

		this.setTitle(L("window.title.installer"));
		this.setDefaultSize(WINDOW_WIDTH, WINDOW_HEIGHT);
		this.setSizeRequest(WINDOW_WIDTH, WINDOW_HEIGHT);
		this.setResizable(false);

		this.headerBar = new HeaderBar;
		this.setTitlebar(this.headerBar);

		this.loadingBox = new CenterBox;
		this.setChild(this.loadingBox);

		this.loadingSpinner = new Spinner;
		this.loadingSpinner.setSizeRequest(SPINNER_SIZE, SPINNER_SIZE);
		this.loadingSpinner.setHexpand(true);
		this.loadingSpinner.setVexpand(false);
		this.loadingSpinner.setHalign(Align.Center);
		this.loadingSpinner.setValign(Align.Center);

		this.loadingBox.setCenterWidget(this.loadingSpinner);
		this.loadingBox.setHexpand(true);
		this.loadingBox.setVexpand(false);
		this.loadingBox.setHalign(Align.Center);
		this.loadingBox.setValign(Align.Center);

		// Allow close at any time so active downloads stop
		this.connectCloseRequest(() {
			atomicStore(this.workCancelled, true);
			return false;
		});
	}

	// Resets the header bar and rebuilds all UI using the current language
	protected void reloadWindow() {
		this.headerBar = new HeaderBar;
		this.setTitlebar(this.headerBar);
		showWindow();
	}

	abstract void loadWindow();
	abstract void showWindow();
}
