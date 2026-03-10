module windows.manage.row;

import std.path : buildPath, dirName;
import std.file : FileException, exists, symlink, mkdirRecurse, remove,
	setAttributes, getAttributes;
import std.process : spawnProcess, ProcessException, wait, tryWait, Pid;
import std.stdio : writeln;

import glib.global : idleAdd, timeoutAdd;
import glib.types : PRIORITY_DEFAULT;
import gtk.box : Box;
import gtk.button : Button;
import gtk.css_provider : CssProvider;
import gtk.gesture_click : GestureClick;
import gtk.image : Image;
import gtk.label : Label;
import gtk.list_box_row : ListBoxRow;
import gtk.progress_bar : ProgressBar;
import gtk.revealer : Revealer;
import gtk.spinner : Spinner;
import gtk.stack : Stack;
import gtk.types : Align, Orientation, RevealerTransitionType, StackTransitionType;
import gtk.widget : Widget;
import pango.types : EllipsizeMode;

import core.atomic : atomicLoad;
import core.thread : Thread;
import core.time : dur;
import types : InstallMethod;
import windows.base : makeBackButton, REVEAL_MS;
import windows.manage : ManageWindow;
import windows.manage.scan : InstalledApp, tryReadDesktopFieldLocalized;
import windows.update : buildUpdateBox, buildCheckingBox,
	buildDirectLinkUpdateFlow, buildZsyncUpdateFlow, buildGitHubZsyncUpdateFlow,
	buildGitHubReleaseUpdateFlow, buildGitHubLinuxManifestUpdateFlow,
	buildPlingUpdateFlow;
import update.common : parseUpdateMethodKind, UpdateMethodKind, reapplyAppIntegration;
import update.directlink : extractDirectLinkUrl;
import update.zsync : extractZsyncUrl, checkZsyncForUpdate;
import update.githubzsync : checkGitHubZsyncForUpdate;
import update.githubrelease : checkGitHubReleaseForUpdate;
import update.githublinuxmanifest : checkGitHubLinuxManifestForUpdate;
import update.pling : checkPlingForUpdate;
import windows.uninstall : buildUninstallBox;
import windows.cleanup : buildCleanupBox;
import windows.addupdate : buildAddUpdateMethodBox;
import windows.optimize : buildOptimizeBox;
import windows.options : buildOptionsBox;
import appimage : AppImage;
import appimage.manifest : Manifest;
import appimage.install : portableHomeDir, portableConfigDir, writeDesktopFile, launchInstalledApp;
import appimage.icon : reinstallIconFromExtractedDir, reinstallIconFromAppImageFile;
import constants : CSS_PRIORITY_USER, APPLICATIONS_SUBDIR, DESKTOP_SUFFIX,
	APPIMAGE_EXEC_MODE;
import lang : L;

// Row layout constants, shared with manage/package.d and manage/watcher.d
package enum Layout {
	iconSize = 48,
	rowMargin = 12,
	rowSpacing = 12,
	buttonWidth = 96,
	buttonHeight = 30,
	iconStaggerMs = 100,
	infoIndent = rowMargin + iconSize + rowSpacing,
	infoSpacing = 2,
	infoStartPadding = 4,
	commentMaxChars = 56,
	cleanupButtonExtra = 16,
	issueRowSpacing = 6,
	issueMarginBottom = 8,
	warningIconSize = 16,
	fixButtonWidth = 64,
	fixButtonHeight = 26,
	actionsMarginTop = 8,
}

// Fallback icon name when an installed app has no icon
package enum string FALLBACK_ICON = "application-x-executable";

// Duration for slide stack page transitions, mirrored from ManageWindow
private enum int SLIDE_MS = 300;

// How long before a launched or browsed button becomes clickable again
private enum int BUTTON_COOLDOWN_MS = 5000;

// Seconds to wait after launch before checking if the app exited with an error
private enum int LAUNCH_CRASH_CHECK_DELAY_SECONDS = 5;

// Row widgets returned so showWindow() can schedule icon loads and wire click handlers
package struct AppRowResult {
	ListBoxRow row;
	Box outer;
	Box mainRow;
	Box infoColumn;
	Box iconSlot;
	Spinner spinner;
	Revealer revealer; // Null for orphan rows
	CssProvider highlight; // Null for orphan rows
	// Null for orphan rows, wired in showWindow after all rows are built
	GestureClick click;
	Image chevron; // Null for orphan rows, shown as pan-end or pan-down icon
	Label updateLabel; // Null for orphan rows, visible when an update is available
	ProgressBar updateProgressBar; // Null for orphan rows, visible during Update All
	Label updateStatusLabel; // Null for orphan rows, shows status during Update All
	InstalledApp entry; // Copy of the app data used to build this row
	void delegate() reloadRow; // Refreshes all displayed data from manifest
}

// Returns a bool callback wrapping a reload for use with timeoutAdd
// Static to allocate a fresh heap frame per run and avoid closure capture inside a loop
package bool delegate() makeReloadCallback(void delegate() reloadRow) {
	return () { reloadRow(); return false; };
}

// Returns a callback that exclusively opens one revealer and closes all others
// Static for the same closure capture reason as makeIconCallback
package void delegate() makeToggleCallback(
	size_t rowIndex, Revealer[] revealers,
	CssProvider[] highlights, ListBoxRow[] rows,
	Image[] chevrons) {
	return () {
		bool nowOpen = !revealers[rowIndex].getRevealChild();
		foreach (revealerIndex; 0 .. revealers.length) {
			bool active = (revealerIndex == rowIndex) && nowOpen;
			revealers[revealerIndex].setRevealChild(active);
			if (active)
				rows[revealerIndex].addCssClass("open-row");
			else
				rows[revealerIndex].removeCssClass("open-row");
			if (chevrons[revealerIndex]!is null)
				chevrons[revealerIndex].setFromIconName(active ? "pan-down-symbolic"
						: "pan-end-symbolic");
		}
	};
}

// Binds the row toggle click, blocking it for anything below the header
// Margins are included in the threshold so all four edges stay clickable
package void bindToggleClick(
	GestureClick click, size_t rowIndex, Revealer[] revealers,
	CssProvider[] highlights,
	ListBoxRow[] rows, Image[] chevrons, Box mainRow) {
	auto toggleCallback = makeToggleCallback(
		rowIndex, revealers, highlights, rows, chevrons);
	click.connectPressed(
		(int pressCount, double xCoordinate,
			double yCoordinate, GestureClick gesture) {
		immutable headerHeight = Layout.rowMargin * 2
			+ mainRow.getAllocatedHeight();
		if (yCoordinate > headerHeight)
			return;
		toggleCallback();
	});
}

// Builds one row widget for the given entry
// win is the ManageWindow that owns the row, needed to wire navigation actions
package AppRowResult buildAppRow(ManageWindow win, ref InstalledApp entry) {
	auto row = new ListBoxRow;
	row.setActivatable(false);

	auto outer = new Box(Orientation.Vertical, 0);
	row.setChild(outer);

	auto mainRow = new Box(Orientation.Horizontal, Layout.rowSpacing);
	mainRow.setMarginTop(Layout.rowMargin);
	mainRow.setMarginBottom(Layout.rowMargin);
	mainRow.setMarginStart(Layout.rowMargin);
	mainRow.setMarginEnd(Layout.rowMargin);

	auto iconSlot = new Box(Orientation.Vertical, 0);
	iconSlot.setSizeRequest(Layout.iconSize, Layout.iconSize);
	iconSlot.setValign(Align.Center);

	auto spinner = new Spinner;
	spinner.setSizeRequest(Layout.iconSize, Layout.iconSize);
	spinner.setValign(Align.Center);
	spinner.setSpinning(true);
	iconSlot.append(spinner);
	mainRow.append(iconSlot);

	auto infoColumn = new Box(Orientation.Vertical, Layout.infoSpacing);
	infoColumn.setHexpand(true);
	infoColumn.setValign(Align.Center);
	infoColumn.setMarginStart(Layout.infoStartPadding);

	auto capturedNameLabel = new Label(entry.appName);
	capturedNameLabel.addCssClass("heading");
	capturedNameLabel.setHalign(Align.Start);
	capturedNameLabel.setEllipsize(EllipsizeMode.End);
	infoColumn.append(capturedNameLabel);

	if (entry.isOrphan) {
		auto statusLabel = new Label(L("manage.app.status.orphan"));
		statusLabel.setHalign(Align.Start);
		statusLabel.addCssClass("caption");
		statusLabel.addCssClass("dim-label");
		infoColumn.append(statusLabel);

		mainRow.append(infoColumn);

		string capturedOrphanName = entry.appName;
		string capturedOrphanIconName = entry.installedIconName;
		string capturedOrphanDesktop = entry.desktopSymlink;
		auto capturedOrphanRow = row;

		auto cleanupButton = Button.newWithLabel(L("button.cleanup"));
		cleanupButton.setSizeRequest(
			Layout.buttonWidth + Layout.cleanupButtonExtra, Layout.buttonHeight);
		cleanupButton.setValign(Align.Center);
		cleanupButton.addCssClass("destructive-action");
		cleanupButton.addCssClass("pill");
		cleanupButton.connectClicked(() {
			string manageTitle = win.getTitle();
			win.setTitle(capturedOrphanName);

			Button backButton;
			void delegate() restoreFromCleanup = () {
				win.headerBar.remove(backButton);
				win.setTitle(manageTitle);
				win.slideBackToManage();
			};
			backButton = makeBackButton(restoreFromCleanup);
			win.headerBar.packStart(backButton);

			win.slideToSub(buildCleanupBox(
				capturedOrphanName,
				capturedOrphanIconName,
				capturedOrphanDesktop,
				(void delegate() workDelegate, void delegate() doneDelegate) {
					win.doThreadedWork(workDelegate, doneDelegate);
				},
				() { backButton.setSensitive(false); },
				() { backButton.setSensitive(true); },
				() {
					capturedOrphanRow.setVisible(false);
					win.hideOrphanSectionIfEmpty();
				}));
		});
		mainRow.append(cleanupButton);

		outer.append(mainRow);
		void delegate() reloadRow = () {
			string iconToLoad = capturedOrphanIconName.length
				? capturedOrphanIconName : FALLBACK_ICON;
			Widget iconChild = iconSlot.getFirstChild();
			while (iconChild !is null) {
				Widget next = iconChild.getNextSibling();
				iconSlot.remove(iconChild);
				iconChild = next;
			}
			auto newIcon = Image.newFromIconName(iconToLoad);
			newIcon.setSizeRequest(Layout.iconSize, Layout.iconSize);
			newIcon.pixelSize = Layout.iconSize;
			newIcon.setValign(Align.Center);
			iconSlot.append(newIcon);
		};
		return AppRowResult(
			row, outer, null, infoColumn, iconSlot, spinner, null, null, null, null, null,
			null, null, entry, reloadRow);
	}

	Label capturedVersionLabel = null;

	auto updateLabel = new Label(L("manage.app.update_available"));
	updateLabel.addCssClass("caption");
	updateLabel.addCssClass("warning");
	updateLabel.setHalign(Align.Start);
	updateLabel.setVisible(entry.updateAvailable);
	infoColumn.append(updateLabel);

	auto rowProgressBar = new ProgressBar;
	rowProgressBar.setHexpand(true);
	rowProgressBar.setShowText(false);
	rowProgressBar.hide();
	infoColumn.append(rowProgressBar);

	auto rowStatusLabel = new Label("");
	rowStatusLabel.addCssClass("caption");
	rowStatusLabel.setHalign(Align.Start);
	rowStatusLabel.setWrap(true);
	rowStatusLabel.hide();
	infoColumn.append(rowStatusLabel);

	capturedVersionLabel = new Label(
		entry.releaseVersion.length
			? L("app.version.format", entry.releaseVersion) : "");
	capturedVersionLabel.addCssClass("caption");
	capturedVersionLabel.addCssClass("dim-label");
	capturedVersionLabel.setHalign(Align.Start);
	capturedVersionLabel.setVisible(entry.releaseVersion.length > 0);
	infoColumn.append(capturedVersionLabel);

	auto capturedCommentLabel = new Label(entry.appComment);
	capturedCommentLabel.addCssClass("caption");
	capturedCommentLabel.addCssClass("dim-label");
	capturedCommentLabel.setHalign(Align.Start);
	capturedCommentLabel.setEllipsize(EllipsizeMode.End);
	capturedCommentLabel.setMaxWidthChars(Layout.commentMaxChars);
	capturedCommentLabel.setVisible(entry.appComment.length > 0);
	infoColumn.append(capturedCommentLabel);

	mainRow.append(infoColumn);

	auto chevron = Image.newFromIconName("pan-end-symbolic");
	chevron.addCssClass("row-chevron");
	chevron.setValign(Align.Center);
	mainRow.append(chevron);

	outer.append(mainRow);

	foreach (issue; entry.issues) {
		auto issueRow = new Box(Orientation.Horizontal, Layout.issueRowSpacing);
		issueRow.setMarginStart(Layout.infoIndent);
		issueRow.setMarginEnd(Layout.rowMargin);
		issueRow.setMarginBottom(Layout.issueMarginBottom);

		auto warningIcon = Image.newFromIconName("dialog-warning-symbolic");
		warningIcon.pixelSize = Layout.warningIconSize;
		warningIcon.setValign(Align.Center);
		issueRow.append(warningIcon);

		auto issueLabel = new Label(issue);
		issueLabel.addCssClass("caption");
		issueLabel.setHalign(Align.Start);
		issueLabel.setHexpand(true);
		issueRow.append(issueLabel);

		if (issue == L("manage.issue.desktop_broken")) {
			auto fixButton = Button.newWithLabel(L("button.fix"));
			fixButton.setSizeRequest(
				Layout.fixButtonWidth, Layout.fixButtonHeight);
			fixButton.addCssClass("pill");
			Box capturedIssueRow = issueRow;
			string capturedFixDir = entry.appDirectory;
			string capturedFixSanitized = entry.sanitizedName;
			string capturedFixSymlink = entry.desktopSymlink;
			InstallMethod capturedFixMethod = entry.installMethod;
			fixButton.connectClicked(() {
				// AppImage sits alongside the app dir; for
				// Extracted it was moved into the metadata dir
				string appImagePath = (capturedFixMethod
					== InstallMethod.Extracted)
					? buildPath(capturedFixDir,
						APPLICATIONS_SUBDIR,
						capturedFixSanitized ~ ".AppImage") : buildPath(capturedFixDir,
						capturedFixSanitized ~ ".AppImage");
				string desktopInAppDir = buildPath(
					capturedFixDir, APPLICATIONS_SUBDIR,
					capturedFixSanitized ~ DESKTOP_SUFFIX);
				if (exists(appImagePath)) {
					reapplyAppIntegration(
						appImagePath,
						capturedFixDir,
						capturedFixSanitized);
				} else if (capturedFixMethod == InstallMethod.Extracted) {
					// AppImage is gone but the extracted dir may still be here
					// Generate a minimal desktop file from what the manifest knows
					string appRunPath = buildPath(capturedFixDir, "AppRun");
					if (!exists(appRunPath)) {
						writeln("fix: AppRun not found: ", appRunPath);
						return;
					}
					auto loadedManifest = Manifest.loadFromAppDir(
						capturedFixDir);
					auto syntheticApp = new AppImage("");
					syntheticApp.sanitizedName = capturedFixSanitized;
					syntheticApp.installMethod = InstallMethod.Extracted;
					if (loadedManifest !is null) {
						syntheticApp.appName =
							loadedManifest.appName.length
							? loadedManifest.appName : capturedFixSanitized;
						syntheticApp.installedIconName =
							loadedManifest.installedIconName;
						syntheticApp.portableHome =
							loadedManifest.portableHome;
						syntheticApp.portableConfig =
							loadedManifest.portableConfig;
					} else {
						syntheticApp.appName = capturedFixSanitized;
					}
					syntheticApp.desktopFileLines = [
						"[Desktop Entry]",
						"Type=Application",
						"Name=" ~ syntheticApp.appName,
						"Exec=" ~ appRunPath,
						"Icon=" ~ syntheticApp.installedIconName,
						"Terminal=false",
						"Categories=Utility;",
					];
					try {
						mkdirRecurse(buildPath(
							capturedFixDir, APPLICATIONS_SUBDIR));
					} catch (FileException) {
					}
					writeDesktopFile(
						syntheticApp, desktopInAppDir,
						capturedFixDir, appRunPath);
				} else {
					writeln("fix: AppImage not found: ", appImagePath);
					return;
				}
				if (!exists(desktopInAppDir)) {
					writeln("fix: desktop still missing after reapply: ",
						desktopInAppDir);
					return;
				}
				try {
					string symlinkDir = dirName(
						capturedFixSymlink);
					mkdirRecurse(symlinkDir);
					try {
						remove(capturedFixSymlink);
					} catch (FileException) {
					}
					symlink(desktopInAppDir,
						capturedFixSymlink);
					writeln("fix: symlink recreated: ",
						capturedFixSymlink);
					try {
						spawnProcess([
								"update-desktop-database",
								symlinkDir
							]);
					} catch (ProcessException) {
					}
					capturedIssueRow.setVisible(false);
				} catch (FileException error) {
					writeln(
						"fix: failed to recreate symlink: ",
						error.msg);
				}
			});
			issueRow.append(fixButton);
		}

		if (issue == L("manage.issue.apprun_not_executable")) {
			auto fixButton = Button.newWithLabel(L("button.fix"));
			fixButton.setSizeRequest(Layout.fixButtonWidth, Layout.fixButtonHeight);
			fixButton.addCssClass("pill");
			Box capturedIssueRow = issueRow;
			string capturedAppRunPath = buildPath(entry.appDirectory, "AppRun");
			fixButton.connectClicked(() {
				try {
					setAttributes(capturedAppRunPath, APPIMAGE_EXEC_MODE);
					capturedIssueRow.setVisible(false);
				} catch (FileException error) {
					writeln("fix: chmod AppRun failed: ", error.msg);
				}
			});
			issueRow.append(fixButton);
		}

		if (issue == L("manage.issue.icon_broken")) {
			auto fixButton = Button.newWithLabel(L("button.fix"));
			fixButton.setSizeRequest(Layout.fixButtonWidth, Layout.fixButtonHeight);
			fixButton.addCssClass("pill");
			Box capturedIssueRow = issueRow;
			Box capturedIconSlot = iconSlot;
			string capturedDir = entry.appDirectory;
			string capturedSanitized = entry.sanitizedName;
			InstallMethod capturedMethod = entry.installMethod;
			fixButton.connectClicked(() {
				string iconName, iconFilePath;
				bool ok;
				if (capturedMethod == InstallMethod.AppImage) {
					string appImagePath = buildPath(
						capturedDir, capturedSanitized ~ ".AppImage");
					ok = reinstallIconFromAppImageFile(
						appImagePath, capturedSanitized, iconName, iconFilePath);
				} else {
					ok = reinstallIconFromExtractedDir(
						capturedDir, capturedSanitized, iconName, iconFilePath);
				}
				if (ok) {
					auto installedAppManifest =
						Manifest.loadFromAppDir(capturedDir);
					if (installedAppManifest !is null) {
						installedAppManifest.installedIconName = iconName;
						installedAppManifest.save();
					}
					Widget child = capturedIconSlot.getFirstChild();
					while (child !is null) {
						Widget next = child.getNextSibling();
						capturedIconSlot.remove(child);
						child = next;
					}
					auto newIcon = Image.newFromFile(iconFilePath);
					newIcon.setSizeRequest(Layout.iconSize, Layout.iconSize);
					newIcon.pixelSize = Layout.iconSize;
					newIcon.setValign(Align.Center);
					capturedIconSlot.append(newIcon);
					capturedIssueRow.setVisible(false);
				} else {
					writeln("fix: icon reinstall failed for ", capturedSanitized);
				}
			});
			issueRow.append(fixButton);
		}

		outer.append(issueRow);
	}

	auto highlightProvider = new CssProvider;
	row.getStyleContext().addProvider(highlightProvider, CSS_PRIORITY_USER);

	auto revealer = new Revealer;
	revealer.setTransitionType(RevealerTransitionType.SlideDown);
	revealer.setTransitionDuration(REVEAL_MS);
	revealer.setRevealChild(false);
	revealer.setHexpand(true);

	auto actionsBox = new Box(Orientation.Horizontal, 0);
	actionsBox.addCssClass("linked");
	actionsBox.setHalign(Align.Center);
	actionsBox.setMarginTop(Layout.actionsMarginTop);
	actionsBox.setMarginBottom(Layout.rowMargin);

	string capturedName = entry.appName;
	string capturedDir = entry.appDirectory;
	string capturedSanitizedName = entry.sanitizedName;
	string capturedUpdateInfo = entry.updateInfo;
	string capturedIconName = entry.installedIconName;
	string capturedDesktopSymlink = entry.desktopSymlink;
	string capturedVersion = entry.releaseVersion;
	InstallMethod capturedInstallMethod = entry.installMethod;
	ubyte capturedAppImageType = entry.appImageType;
	auto capturedRow = row;

	void delegate() reloadRow = () {
		auto installedAppManifest = Manifest.loadFromAppDir(capturedDir);
		if (installedAppManifest is null)
			return;
		capturedVersion = installedAppManifest.releaseVersion;
		capturedUpdateInfo = installedAppManifest.updateInfo;
		capturedIconName = installedAppManifest.installedIconName;
		string desktopPath = buildPath(
			capturedDir, APPLICATIONS_SUBDIR, capturedSanitizedName ~ DESKTOP_SUFFIX);
		string freshName = tryReadDesktopFieldLocalized(desktopPath, "Name");
		if (!freshName.length)
			freshName = installedAppManifest.appName;
		string freshComment = tryReadDesktopFieldLocalized(desktopPath, "Comment");
		if (freshName.length)
			capturedName = freshName;
		capturedNameLabel.setLabel(capturedName);
		capturedCommentLabel.setLabel(freshComment);
		capturedCommentLabel.setVisible(freshComment.length > 0);
		updateLabel.setVisible(installedAppManifest.updateAvailable);
		if (capturedVersion.length) {
			capturedVersionLabel.setLabel(L("app.version.format", capturedVersion));
			capturedVersionLabel.setVisible(true);
		} else {
			capturedVersionLabel.setVisible(false);
		}
		string iconToLoad = capturedIconName.length ? capturedIconName : FALLBACK_ICON;
		Widget iconChild = iconSlot.getFirstChild();
		while (iconChild !is null) {
			Widget next = iconChild.getNextSibling();
			iconSlot.remove(iconChild);
			iconChild = next;
		}
		auto newIconImage = Image.newFromIconName(iconToLoad);
		newIconImage.setSizeRequest(Layout.iconSize, Layout.iconSize);
		newIconImage.pixelSize = Layout.iconSize;
		newIconImage.setValign(Align.Center);
		iconSlot.append(newIconImage);
	};

	auto launchButton = Button.newWithLabel(L("button.launch"));
	launchButton.setSizeRequest(Layout.buttonWidth, Layout.buttonHeight);
	launchButton.connectClicked(() {
		rowStatusLabel.hide();
		rowStatusLabel.removeCssClass("warning");
		string launchPath = (capturedInstallMethod == InstallMethod.AppImage)
			? buildPath(capturedDir, capturedSanitizedName ~ ".AppImage") : buildPath(capturedDir, "AppRun");
		launchButton.setSensitive(false);
		try {
			auto installedAppManifest = Manifest.loadFromAppDir(capturedDir);
			bool hasPHome = installedAppManifest !is null
				&& installedAppManifest.portableHome;
			bool hasPConfig = installedAppManifest !is null
				&& installedAppManifest.portableConfig;
			Pid pid = launchInstalledApp(launchPath, capturedDir,
				capturedInstallMethod, hasPHome, hasPConfig);
			Label capturedStatusLabel = rowStatusLabel;
			string capturedAppName = capturedName;
			auto watchThread = new Thread({
				Thread.sleep(dur!"seconds"(LAUNCH_CRASH_CHECK_DELAY_SECONDS));

				auto result = tryWait(pid);
				if (!result.terminated || result.status == 0)
					return;
				string errText = L("manage.app.launch.failed", capturedAppName);
				if (capturedInstallMethod == InstallMethod.AppImage)
					errText ~= "\n" ~ L("manage.app.launch.failed.hint");
				idleAdd(PRIORITY_DEFAULT, () {
					capturedStatusLabel.setText(errText);
					capturedStatusLabel.addCssClass("warning");
					capturedStatusLabel.show();
					return false;
				});
			});
			watchThread.isDaemon = true;
			watchThread.start();
		} catch (ProcessException error) {
			writeln("ManageWindow: failed to launch '", capturedName, "': ", error.msg);
		}
		timeoutAdd(PRIORITY_DEFAULT, BUTTON_COOLDOWN_MS, {
			launchButton.setSensitive(true);
			return false;
		});
	});
	actionsBox.append(launchButton);

	auto browseButton = Button.newWithLabel(L("button.browse"));
	browseButton.setSizeRequest(Layout.buttonWidth, Layout.buttonHeight);
	browseButton.connectClicked(() {
		rowStatusLabel.hide();
		rowStatusLabel.removeCssClass("warning");
		try {
			spawnProcess(["xdg-open", capturedDir]);
		} catch (ProcessException error) {
			writeln("ManageWindow: failed to browse '", capturedDir, "': ", error.msg);
		}
		browseButton.setSensitive(false);
		timeoutAdd(PRIORITY_DEFAULT, BUTTON_COOLDOWN_MS, {
			browseButton.setSensitive(true);
			return false;
		});
	});
	actionsBox.append(browseButton);

	auto optimizeButton = Button.newWithLabel(L("button.optimize"));
	optimizeButton.setSizeRequest(Layout.buttonWidth, Layout.buttonHeight);
	optimizeButton.connectClicked(() {
		rowStatusLabel.hide();
		rowStatusLabel.removeCssClass("warning");
		string manageTitle = win.getTitle();
		win.setTitle(capturedName);

		Button backButton;
		void delegate() restoreFromOptimize = () {
			win.headerBar.remove(backButton);
			win.setTitle(manageTitle);
			win.slideBackToManage();
		};
		backButton = makeBackButton(restoreFromOptimize);
		win.headerBar.packStart(backButton);

		win.slideToSub(buildOptimizeBox(
			capturedName,
			capturedDir,
			capturedSanitizedName,
			capturedInstallMethod,
			capturedAppImageType,
			win,
			(void delegate() workDelegate, void delegate() doneDelegate) {
				win.doThreadedWork(workDelegate, doneDelegate);
			},
			() { backButton.setSensitive(false); },
			() { backButton.setSensitive(true); },
			(InstallMethod newMethod) {
				capturedInstallMethod = newMethod;
				foreach (ref installedApp; win.installedApps)
					if (installedApp.sanitizedName == capturedSanitizedName) {
						installedApp.installMethod = newMethod;
						break;
					}
			},
			() { restoreFromOptimize(); }));
	});
	actionsBox.append(optimizeButton);

	auto optionsButton = Button.newWithLabel(L("button.options"));
	optionsButton.setSizeRequest(Layout.buttonWidth, Layout.buttonHeight);
	optionsButton.connectClicked(() {
		rowStatusLabel.hide();
		rowStatusLabel.removeCssClass("warning");
		string manageTitle = win.getTitle();
		win.setTitle(capturedName);

		void delegate() currentBackAction;
		Button backButton;
		void delegate() restoreFromOptions = () {
			win.headerBar.remove(backButton);
			win.setTitle(manageTitle);
			win.slideBackToManage();
			reloadRow();
		};
		currentBackAction = restoreFromOptions;
		backButton = makeBackButton(() { currentBackAction(); });
		win.headerBar.packStart(backButton);

		win.slideToSub(buildOptionsBox(
			capturedName,
			capturedSanitizedName,
			capturedDir,
			(void delegate() workDelegate, void delegate() doneDelegate) {
				win.doThreadedWork(workDelegate, doneDelegate);
			},
			() { backButton.setSensitive(false); },
			() { backButton.setSensitive(true); },
			(void delegate() backActionDelegate) {
				currentBackAction = backActionDelegate;
			},
			() { restoreFromOptions(); }
		));
	});
	actionsBox.append(optionsButton);

	auto updateButton = Button.newWithLabel(L("button.update"));
	updateButton.setSizeRequest(Layout.buttonWidth, Layout.buttonHeight);
	updateButton.connectClicked(() {
		rowStatusLabel.hide();
		rowStatusLabel.removeCssClass("warning");
		string manageTitle = win.getTitle();
		win.setTitle(capturedName);

		void delegate() currentBackAction;

		Button backButton;
		void delegate() restoreManageView = () {
			win.headerBar.remove(backButton);
			win.setTitle(manageTitle);
			win.slideBackToManage();
			reloadRow();
		};

		currentBackAction = restoreManageView;
		backButton = makeBackButton(() { currentBackAction(); });
		win.headerBar.packStart(backButton);

		auto addUpdateSlot = new Box(Orientation.Vertical, 0);
		addUpdateSlot.setHexpand(true);
		addUpdateSlot.setVexpand(true);

		auto updateNavStack = new Stack;
		updateNavStack.setHexpand(true);
		updateNavStack.setVexpand(true);
		updateNavStack.setTransitionDuration(SLIDE_MS);

		auto contentSlot = new Box(Orientation.Vertical, 0);
		contentSlot.setHexpand(true);
		contentSlot.setVexpand(true);

		void delegate(bool, string, bool) showUpdateBox;

		void slideToAddUpdate() {
			currentBackAction = () {
				updateNavStack.setTransitionType(StackTransitionType.SlideRight);
				updateNavStack.setVisibleChildName("content");
				currentBackAction = restoreManageView;
			};
			auto previousChild = addUpdateSlot.getFirstChild();
			if (previousChild !is null)
				addUpdateSlot.remove(previousChild);
			addUpdateSlot.append(buildAddUpdateMethodBox(
				capturedName,
				capturedSanitizedName,
				(void delegate() workDelegate, void delegate() doneDelegate) {
					win.doThreadedWork(workDelegate, doneDelegate);
				},
				() { backButton.setSensitive(false); },
				() { backButton.setSensitive(true); },
				(void delegate() backActionDelegate) {
					currentBackAction = backActionDelegate;
				},
				() {
					backButton.setSensitive(true);
					// Read updateInfo the wizard saved and refresh the content slot
					auto installedAppManifest =
					Manifest.loadFromAppDir(capturedDir);
					if (installedAppManifest !is null)
						capturedUpdateInfo = installedAppManifest.updateInfo;
					updateNavStack.setTransitionType(StackTransitionType.SlideRight);
					updateNavStack.setVisibleChildName("content");
					currentBackAction = restoreManageView;
					showUpdateBox(true, "", false);
				}));
			updateNavStack.setTransitionType(StackTransitionType.SlideLeft);
			updateNavStack.setVisibleChildName("addupdate");
		}

		updateNavStack.addNamed(contentSlot, "content");
		updateNavStack.addNamed(addUpdateSlot, "addupdate");
		updateNavStack.setVisibleChildName("content");

		showUpdateBox = (bool available, string error, bool force = false) {
			auto previousChild = contentSlot.getFirstChild();
			if (previousChild !is null)
				contentSlot.remove(previousChild);
			final switch (parseUpdateMethodKind(capturedUpdateInfo)) {
			case UpdateMethodKind.DirectLink:
				buildDirectLinkUpdateFlow(contentSlot,
					capturedName, capturedSanitizedName, capturedDir,
					extractDirectLinkUrl(capturedUpdateInfo), capturedVersion,
					(void delegate() workDelegate, void delegate() doneDelegate) {
					win.doThreadedWork(workDelegate, doneDelegate);
				},
					() { backButton.setSensitive(false); },
					() { backButton.setSensitive(true); },
					() => cast(bool) atomicLoad(win.workCancelled), force, force);
				break;
			case UpdateMethodKind.Zsync:
				if (available || error.length) {
					buildZsyncUpdateFlow(contentSlot,
						capturedName, capturedSanitizedName, capturedDir,
						extractZsyncUrl(capturedUpdateInfo), capturedVersion,
						(void delegate() workDelegate, void delegate() doneDelegate) {
						win.doThreadedWork(workDelegate, doneDelegate);
					},
						() { backButton.setSensitive(false); },
						() { backButton.setSensitive(true); },
						() => cast(bool) atomicLoad(win.workCancelled), force, force);
				} else {
					contentSlot.append(buildUpdateBox(
						capturedName, false, "",
						capturedUpdateInfo, capturedVersion, &slideToAddUpdate,
						() { showUpdateBox(true, "", true); }));
				}
				break;
			case UpdateMethodKind.GitHubZsync:
				if (available || error.length) {
					buildGitHubZsyncUpdateFlow(contentSlot,
						capturedName, capturedSanitizedName, capturedDir,
						capturedUpdateInfo, capturedVersion,
						(void delegate() workDelegate, void delegate() doneDelegate) {
						win.doThreadedWork(workDelegate, doneDelegate);
					},
						() { backButton.setSensitive(false); },
						() { backButton.setSensitive(true); },
						() => cast(bool) atomicLoad(win.workCancelled), force, force);
				} else {
					contentSlot.append(buildUpdateBox(
						capturedName, false, "",
						capturedUpdateInfo, capturedVersion, &slideToAddUpdate,
						() { showUpdateBox(true, "", true); }));
				}
				break;
			case UpdateMethodKind.GitHubRelease:
				if (available || error.length) {
					buildGitHubReleaseUpdateFlow(contentSlot,
						capturedName, capturedSanitizedName, capturedDir,
						capturedUpdateInfo, capturedVersion,
						(void delegate() workDelegate, void delegate() doneDelegate) {
						win.doThreadedWork(workDelegate, doneDelegate);
					},
						() { backButton.setSensitive(false); },
						() { backButton.setSensitive(true); },
						() => cast(bool) atomicLoad(win.workCancelled), force);
				} else {
					contentSlot.append(buildUpdateBox(
						capturedName, false, "",
						capturedUpdateInfo, capturedVersion, &slideToAddUpdate,
						() { showUpdateBox(true, "", true); }));
				}
				break;
			case UpdateMethodKind.GitHubLinuxManifest:
				if (available || error.length) {
					buildGitHubLinuxManifestUpdateFlow(contentSlot,
						capturedName, capturedSanitizedName, capturedDir,
						capturedUpdateInfo, capturedVersion,
						(void delegate() workDelegate, void delegate() doneDelegate) {
						win.doThreadedWork(workDelegate, doneDelegate);
					},
						() { backButton.setSensitive(false); },
						() { backButton.setSensitive(true); },
						() => cast(bool) atomicLoad(win.workCancelled), force);
				} else {
					contentSlot.append(buildUpdateBox(
						capturedName, false, "",
						capturedUpdateInfo, capturedVersion, &slideToAddUpdate,
						() { showUpdateBox(true, "", true); }));
				}
				break;
			case UpdateMethodKind.PlingV1Zsync:
				if (available || error.length) {
					buildPlingUpdateFlow(contentSlot,
						capturedName, capturedSanitizedName, capturedDir,
						capturedUpdateInfo, capturedVersion,
						(void delegate() workDelegate, void delegate() doneDelegate) {
						win.doThreadedWork(workDelegate, doneDelegate);
					},
						() { backButton.setSensitive(false); },
						() { backButton.setSensitive(true); },
						() {
						auto installedAppManifest =
						Manifest.loadFromAppDir(capturedDir);
						if (installedAppManifest !is null)
							capturedUpdateInfo =
							installedAppManifest.updateInfo;
					},
						() => cast(bool) atomicLoad(win.workCancelled), force, force);
				} else {
					contentSlot.append(buildUpdateBox(
						capturedName, false, "",
						capturedUpdateInfo, capturedVersion, &slideToAddUpdate,
						() { showUpdateBox(true, "", true); }));
				}
				break;
			case UpdateMethodKind.Unknown:
				contentSlot.append(buildUpdateBox(
					capturedName, available, error,
					capturedUpdateInfo, "", &slideToAddUpdate));
				break;
			}
		};

		switch (parseUpdateMethodKind(capturedUpdateInfo)) {
		case UpdateMethodKind.Unknown:
			showUpdateBox(false, "", false);
			win.slideToSub(updateNavStack);
			break;
		case UpdateMethodKind.DirectLink:
			showUpdateBox(true, "", false);
			win.slideToSub(updateNavStack);
			break;
		case UpdateMethodKind.Zsync: {
				contentSlot.append(buildCheckingBox());
				win.slideToSub(updateNavStack);
				bool available;
				string error;
				win.doThreadedWork(
				{
					checkZsyncForUpdate(capturedDir, capturedSanitizedName,
					extractZsyncUrl(capturedUpdateInfo), available, error,
					() => cast(bool) atomicLoad(win.workCancelled));
				},
				{ showUpdateBox(available, error, false); });
				break;
			}
		case UpdateMethodKind.GitHubZsync: {
				contentSlot.append(buildCheckingBox());
				win.slideToSub(updateNavStack);
				bool available;
				string error;
				win.doThreadedWork(
				{
					checkGitHubZsyncForUpdate(capturedDir, capturedSanitizedName,
					capturedUpdateInfo, available, error,
					() => cast(bool) atomicLoad(win.workCancelled));
				},
				{ showUpdateBox(available, error, false); });
				break;
			}
		case UpdateMethodKind.GitHubRelease: {
				contentSlot.append(buildCheckingBox());
				win.slideToSub(updateNavStack);
				bool available;
				string error;
				win.doThreadedWork(
				{
					checkGitHubReleaseForUpdate(capturedDir,
					capturedUpdateInfo, available, error,
					() => cast(bool) atomicLoad(win.workCancelled));
				},
				{ showUpdateBox(available, error, false); });
				break;
			}
		case UpdateMethodKind.GitHubLinuxManifest: {
				contentSlot.append(buildCheckingBox());
				win.slideToSub(updateNavStack);
				bool available;
				string error;
				win.doThreadedWork(
				{
					checkGitHubLinuxManifestForUpdate(capturedDir,
					capturedUpdateInfo, available, error,
					() => cast(bool) atomicLoad(win.workCancelled));
				},
				{ showUpdateBox(available, error, false); });
				break;
			}
		case UpdateMethodKind.PlingV1Zsync: {
				contentSlot.append(buildCheckingBox());
				win.slideToSub(updateNavStack);
				bool available;
				string error;
				win.doThreadedWork(
				{
					checkPlingForUpdate(capturedDir, capturedSanitizedName,
					capturedUpdateInfo, available, error,
					() => cast(bool) atomicLoad(win.workCancelled));
				},
				{ showUpdateBox(available, error, false); });
				break;
			}
		default:
			win.slideToSub(updateNavStack);
			showUpdateBox(false, "", false);
			break;
		}
	});
	actionsBox.append(updateButton);

	auto uninstallButton = Button.newWithLabel(L("button.uninstall"));
	uninstallButton.setSizeRequest(Layout.buttonWidth, Layout.buttonHeight);
	uninstallButton.addCssClass("destructive-action");
	uninstallButton.connectClicked(() {
		rowStatusLabel.hide();
		rowStatusLabel.removeCssClass("warning");
		string manageTitle = win.getTitle();
		win.setTitle(capturedName);

		Button backButton;
		void delegate() restoreFromUninstall = () {
			win.headerBar.remove(backButton);
			win.setTitle(manageTitle);
			win.slideBackToManage();
		};
		backButton = makeBackButton(restoreFromUninstall);
		win.headerBar.packStart(backButton);

		win.slideToSub(buildUninstallBox(
			capturedName,
			capturedDir,
			capturedIconName,
			capturedDesktopSymlink,
			(void delegate() workDelegate, void delegate() doneDelegate) {
				win.doThreadedWork(workDelegate, doneDelegate);
			},
			() { backButton.setSensitive(false); },
			() { backButton.setSensitive(true); },
			() { capturedRow.setVisible(false); },
			() { restoreFromUninstall(); }
		));
	});
	actionsBox.append(uninstallButton);

	revealer.setChild(actionsBox);
	outer.append(revealer);

	auto click = new GestureClick;
	row.addController(click);
	return AppRowResult(
		row, outer, mainRow, infoColumn, iconSlot, spinner,
		revealer, highlightProvider, click, chevron, updateLabel,
		rowProgressBar, rowStatusLabel, entry, reloadRow);
}
