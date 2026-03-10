module windows.optimize.helpers;

import gtk.box : Box;
import gtk.image : Image;
import gtk.label : Label;
import gtk.progress_bar : ProgressBar;
import gtk.revealer : Revealer;
import gtk.stack : Stack;
import gtk.types : Align, Justification, Orientation, RevealerTransitionType, StackTransitionType;

import windows.base : applyCssToWidget, makeSlideDownRevealer, makeIcon, ACTION_BTN_WIDTH, REVEAL_MS;
import constants : APPLICATIONS_SUBDIR, MANIFEST_FILE_NAME;
import lang : L;

public enum int SLIDE_MS = 300;
public enum int CONTENT_WIDTH = 480; // Width of the centred content columns
public enum int OPTION_DELAY_MS = 80;
public enum int CARD_STAGGER_MS = 130;
public enum int ACTION_DELAY_MS = 250;
public enum int PROGRESS_POLL_MS = 80;

// Pixel measurements for the option row and result page widgets
private enum Layout {
	pageMargin = 32,
	iconSize = 32,
	iconMarginEnd = 14,
	checkIconSize = 16,
	checkIconMarginEnd = 8,
	titleRowSpacing = 6,
	textColumnSpacing = 2,
	cardDescMaxChars = 44,
	rowPadding = 10,
	rowSideMargin = 16,
	statusMaxChars = 40,
	statusMarginTop = 8,
	barDescExtraWidth = 64,
	barDescHeight = 60,
	barDescMarginTop = 16,
	resultDescMaxChars = 52,
}

// Widgets built by buildResultPage, returned so the caller can reference them
public struct ResultPageWidgets {
	Box resultPage;
	Image statusIcon;
	Label statusLabel;
	Stack barDescStack;
	ProgressBar progressBar;
	Label resultDescriptionLabel;
	Revealer resultBarRevealer;
}

// Centred vertical column used for the confirm, locate, and result pages
public Box makeCentredPage() {
	auto page = new Box(Orientation.Vertical, 0);
	page.setVexpand(true);
	page.setValign(Align.Center);
	page.setHalign(Align.Center);
	page.setMarginBottom(Layout.pageMargin);
	page.setMarginStart(Layout.pageMargin);
	page.setMarginEnd(Layout.pageMargin);
	return page;
}

// Builds one row in the install-mode choice list or keep-copy list
public Box makeOptionRowContent(
	string iconName, string title, bool isCurrent, string description,
	out Image checkMark) {

	checkMark = Image.newFromIconName("object-select-symbolic");
	checkMark.setPixelSize(Layout.checkIconSize);
	checkMark.setValign(Align.Center);
	checkMark.setMarginEnd(Layout.checkIconMarginEnd);
	checkMark.setVisible(isCurrent);

	auto icon = Image.newFromIconName(iconName);
	icon.pixelSize = Layout.iconSize;
	icon.setValign(Align.Center);
	icon.setMarginEnd(Layout.iconMarginEnd);

	// Title row with name and "(current)" side by side to save vertical space
	auto titleRow = new Box(Orientation.Horizontal, Layout.titleRowSpacing);
	titleRow.setHalign(Align.Start);

	auto titleLabel = new Label(title);
	titleLabel.addCssClass("heading");
	titleRow.append(titleLabel);

	auto currentLabel = new Label(L("optimize.current.label"));
	currentLabel.addCssClass("caption");
	currentLabel.addCssClass("dim-label");
	currentLabel.setValign(Align.Center);
	currentLabel.setOpacity(isCurrent ? 1.0 : 0.0);
	titleRow.append(currentLabel);

	auto textColumn = new Box(Orientation.Vertical, Layout.textColumnSpacing);
	textColumn.setHexpand(true);
	textColumn.setValign(Align.Center);
	textColumn.append(titleRow);

	auto descriptionLabel = new Label(description);
	descriptionLabel.addCssClass("caption");
	descriptionLabel.addCssClass("dim-label");
	descriptionLabel.setHalign(Align.Start);
	descriptionLabel.setWrap(true);
	descriptionLabel.setMaxWidthChars(Layout.cardDescMaxChars);
	textColumn.append(descriptionLabel);

	auto rowBox = new Box(Orientation.Horizontal, 0);
	rowBox.setMarginTop(Layout.rowPadding);
	rowBox.setMarginBottom(Layout.rowPadding);
	rowBox.setMarginStart(Layout.rowSideMargin);
	rowBox.setMarginEnd(Layout.rowSideMargin);
	rowBox.append(checkMark);
	rowBox.append(icon);
	rowBox.append(textColumn);
	return rowBox;
}

// Builds the result page shown while and after installation runs
// Returns widget references that the caller needs to wire up progress and completion
public ResultPageWidgets buildResultPage() {
	auto resultPage = new Box(Orientation.Vertical, 0);
	resultPage.setVexpand(true);
	resultPage.setValign(Align.Fill);
	resultPage.setHalign(Align.Center);
	resultPage.setMarginBottom(Layout.pageMargin);
	resultPage.setMarginStart(Layout.pageMargin);
	resultPage.setMarginEnd(Layout.pageMargin);
	resultPage.setSizeRequest(CONTENT_WIDTH, -1);

	auto resultTopSpacer = new Box(Orientation.Vertical, 0);
	resultTopSpacer.setVexpand(true);
	resultPage.append(resultTopSpacer);

	// Icon and label are immediately visible with only the progress bar sliding in
	auto statusIcon = makeIcon([
		"emblem-synchronizing-symbolic", "system-run-symbolic"
	]);
	statusIcon.addCssClass("icon-large");
	statusIcon.setHalign(Align.Center);
	resultPage.append(statusIcon);

	auto statusLabel = new Label(L("optimize.status.running"));
	statusLabel.addCssClass("title-3");
	statusLabel.setHalign(Align.Center);
	statusLabel.setMaxWidthChars(Layout.statusMaxChars);
	statusLabel.setWrap(true);
	statusLabel.setMarginTop(Layout.statusMarginTop);
	resultPage.append(statusLabel);

	// Progress bar and completion description share a fixed-height slot
	auto barDescStack = new Stack;
	barDescStack.setTransitionType(StackTransitionType.SlideDown);
	barDescStack.setTransitionDuration(SLIDE_MS);
	barDescStack.setHalign(Align.Center);
	barDescStack.setSizeRequest(ACTION_BTN_WIDTH + Layout.barDescExtraWidth, Layout.barDescHeight);
	barDescStack.setMarginTop(Layout.barDescMarginTop);
	applyCssToWidget(barDescStack, "stack { overflow: hidden; }");

	auto progressBar = new ProgressBar;
	progressBar.setHexpand(true);
	progressBar.setValign(Align.Center);
	barDescStack.addNamed(progressBar, "bar");

	auto resultDescriptionLabel = new Label("");
	resultDescriptionLabel.addCssClass("dim-label");
	resultDescriptionLabel.setHalign(Align.Center);
	resultDescriptionLabel.setWrap(true);
	resultDescriptionLabel.setMaxWidthChars(Layout.resultDescMaxChars);
	resultDescriptionLabel.setJustify(Justification.Center);
	barDescStack.addNamed(resultDescriptionLabel, "desc");
	barDescStack.setVisibleChildName("bar");

	auto resultBarRevealer = makeSlideDownRevealer(REVEAL_MS);
	resultBarRevealer.setChild(barDescStack);
	resultPage.append(resultBarRevealer);

	auto resultBottomSpacer = new Box(Orientation.Vertical, 0);
	resultBottomSpacer.setVexpand(true);
	resultPage.append(resultBottomSpacer);

	return ResultPageWidgets(resultPage, statusIcon, statusLabel, barDescStack,
		progressBar, resultDescriptionLabel, resultBarRevealer);
}
