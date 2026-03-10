module windows.install.helpers;

import std.path : buildPath;
import std.process : ProcessException;
import std.stdio : writeln;

import glib.global : timeoutAdd;
import glib.types : PRIORITY_DEFAULT;
import gtk.box : Box;
import gtk.button : Button;
import gtk.center_box : CenterBox;
import gtk.image : Image;
import gtk.label : Label;
import gtk.list_box : ListBox;
import gtk.list_box_row : ListBoxRow;
import gtk.revealer : Revealer;
import gtk.stack : Stack;
import gtk.types : Align, Orientation, RevealerTransitionType, SelectionMode, StackTransitionType;
import pango.types : EllipsizeMode;

import windows.install : InstallWindow;
import windows.base : ACTION_BTN_WIDTH, ACTION_BTN_HEIGHT, makeIcon;
import appimage.install : launchInstalledApp;
import types : InstallMethod;
import lang : L;

package(windows) enum int INFO_MARGIN = 48;
package(windows) enum int ACTION_TRANSITION_MS = 350;
package(windows) enum int SLIDE_TRANSITION_MS = 500;

// Pixel measurements for info rows and the details page layout
private enum Layout {
	rowSpacing = 8,
	iconSize = 24,
	columnSpacing = 2,
	cellPadding = 8,
	cellEndMargin = 16,
	valueMaxChars = 48,
	detailsTopMargin = 8,
	detailsBottomMargin = 16,
	closeButtonMarginTop = 32,
}

package(windows) Box buildInfoRow(string iconName, string heading,
	string value, string tooltipText = "") {
	return buildInfoRow([iconName], heading, value, tooltipText);
}

// Falls back through names so the row still gets an icon on themes without every icon
package(windows) Box buildInfoRow(string[] iconNames, string heading,
	string value, string tooltipText = "") {
	auto row = new Box(Orientation.Horizontal, Layout.rowSpacing);

	auto icon = makeIcon(iconNames);
	icon.pixelSize = Layout.iconSize;
	icon.setMarginStart(Layout.cellEndMargin);
	icon.setValign(Align.Center);
	row.append(icon);

	auto textColumn = new Box(Orientation.Vertical, Layout.columnSpacing);
	textColumn.setValign(Align.Center);
	textColumn.setHexpand(true);

	auto headingLabel = new Label(heading);
	headingLabel.addCssClass("caption-heading");
	headingLabel.setHexpand(true);
	headingLabel.setHalign(Align.Start);
	headingLabel.setMarginTop(Layout.cellPadding);
	headingLabel.setMarginStart(Layout.cellPadding);
	headingLabel.setMarginEnd(Layout.cellEndMargin);

	auto valueLabel = new Label(value);
	valueLabel.addCssClass("caption");
	valueLabel.addCssClass("dim-label");
	valueLabel.setHexpand(true);
	valueLabel.setHalign(Align.Start);
	valueLabel.setEllipsize(EllipsizeMode.Middle);
	valueLabel.setMaxWidthChars(Layout.valueMaxChars);
	valueLabel.setMarginBottom(Layout.cellPadding);
	valueLabel.setMarginStart(Layout.cellPadding);
	valueLabel.setMarginEnd(Layout.cellEndMargin);

	textColumn.append(headingLabel);
	textColumn.append(valueLabel);
	row.append(textColumn);

	if (tooltipText.length)
		row.setTooltipText(tooltipText);

	return row;
}

package(windows) void doInstallationComplete(InstallWindow installWindow) {
	writeln("Installation complete, showing success screen");

	auto appDirRow = buildInfoRow(
		["folder-symbolic", "folder"],
		L("install.info.installed_to"),
		installWindow.appImage.installedAppDirectory);
	auto desktopRow = buildInfoRow(
		[
		"application-x-executable-symbolic", "application-x-desktop",
		"text-x-generic-symbolic"
	],
	L("install.info.desktop_entry"),
	installWindow.appImage.installedDesktopSymlinkPath);

	auto detailsList = new ListBox;
	detailsList.setSelectionMode(SelectionMode.None);
	detailsList.addCssClass("boxed-list");

	foreach (row; [appDirRow, desktopRow]) {
		auto listRow = new ListBoxRow;
		listRow.setChild(row);
		listRow.setActivatable(false);
		detailsList.append(listRow);
	}

	auto detailsPage = new Box(Orientation.Vertical, 0);
	detailsPage.setVexpand(true);
	detailsPage.setValign(Align.Center);
	detailsPage.setMarginTop(Layout.detailsTopMargin);
	detailsPage.setMarginBottom(Layout.detailsBottomMargin);
	detailsPage.setMarginStart(INFO_MARGIN);
	detailsPage.setMarginEnd(INFO_MARGIN);
	detailsPage.append(detailsList);

	auto launchButton = Button.newWithLabel(L("button.launch"));
	launchButton.setSizeRequest(ACTION_BTN_WIDTH, ACTION_BTN_HEIGHT);
	launchButton.addCssClass("pill");
	launchButton.addCssClass("suggested-action");

	launchButton.connectClicked({
		installWindow.actionRevealer.setRevealChild(false);
		installWindow.bannerRevealer.setRevealChild(false);
		timeoutAdd(PRIORITY_DEFAULT, ACTION_TRANSITION_MS, {
			string launchPath = buildPath(
			installWindow.appImage.installedAppDirectory,
			installWindow.appImage.sanitizedName ~ ".AppImage");
			if (installWindow.appImage.installMethod == InstallMethod.Extracted)
				launchPath = buildPath(
				installWindow.appImage.installedAppDirectory,
				"AppRun");
			try {
				launchInstalledApp(launchPath,
				installWindow.appImage.installedAppDirectory,
				installWindow.appImage.installMethod,
				installWindow.appImage.portableHome,
				installWindow.appImage.portableConfig);
			} catch (ProcessException error) {
				writeln("launch: failed: ", error.msg);
			}
			if (installWindow.onCloseCallback !is null)
				installWindow.onCloseCallback();
			else
				installWindow.app.quit();
			return false;
		});
	});

	launchButton.setHalign(Align.Center);
	launchButton.setMarginTop(Layout.closeButtonMarginTop);
	installWindow.actionStack.addTitled(launchButton, "done", "Done");

	installWindow.installProgressBar.setFraction(1.0);

	enum int POST_INSTALL_PAUSE_MS = 250;
	timeoutAdd(PRIORITY_DEFAULT, POST_INSTALL_PAUSE_MS, {
		installWindow.actionRevealer.setTransitionType(RevealerTransitionType.SlideDown);
		installWindow.actionRevealer.setRevealChild(false);
		timeoutAdd(PRIORITY_DEFAULT, ACTION_TRANSITION_MS + POST_INSTALL_PAUSE_MS, {
			installWindow.actionStack.setVisibleChildName("done");
			installWindow.actionRevealer.setTransitionType(RevealerTransitionType.SlideDown);
			installWindow.actionRevealer.setRevealChild(true);

			installWindow.contentStack.addNamed(detailsPage, "details");
			installWindow.contentStack.setTransitionDuration(SLIDE_TRANSITION_MS);

			auto successBannerBox = new CenterBox;
			successBannerBox.setHexpand(true);
			successBannerBox.addCssClass("success-banner");

			auto successBannerLabel = new Label(L("install.success.banner"));
			successBannerLabel.addCssClass("heading");
			successBannerLabel.setValign(Align.Center);
			successBannerBox.setCenterWidget(successBannerLabel);

			auto detailsButton = Button.newWithLabel(L("install.button.details"));
			detailsButton.addCssClass("pill");
			detailsButton.setHexpand(false);
			detailsButton.setVexpand(false);
			detailsButton.setValign(Align.Center);
			detailsButton.setMarginStart(Layout.cellPadding);
			detailsButton.setMarginEnd(Layout.cellEndMargin);
			detailsButton.connectClicked({
				bool showingDetails = installWindow.contentStack.getVisibleChildName() == "details";
				if (showingDetails) {
					installWindow.contentStack.setTransitionType(StackTransitionType.SlideRight);
					installWindow.contentStack.setVisibleChildName("summary");
					detailsButton.setLabel(L("install.button.details"));
				} else {
					installWindow.contentStack.setTransitionType(StackTransitionType.SlideLeft);
					installWindow.contentStack.setVisibleChildName("details");
					detailsButton.setLabel(L("button.back"));
				}
			});
			successBannerBox.setEndWidget(detailsButton);

			installWindow.bannerStack.addTitled(successBannerBox, "success", "Success");
			installWindow.bannerStack.setVisibleChildName("success");
			installWindow.bannerRevealer.setRevealChild(true);
			return false;
		});
		return false;
	});
}
