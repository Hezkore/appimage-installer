// Settings sub-page for GitHub token and AppImage install directory
module windows.settings;

import core.thread : Thread;
import std.conv : to, ConvException;
import std.file : exists, isDir, mkdirRecurse, isSymlink, remove,
	rename, copy, rmdirRecurse, dirEntries, SpanMode, FileException;
import std.path : buildPath, baseName;
import std.process : execute, ProcessException;
import std.stdio : writeln;
import std.string : replace, toStringz;
import std.typecons : Yes;

import gtk.switch_ : Switch;
import glib.global : idleAdd, timeoutAdd;
import glib.types : PRIORITY_DEFAULT;
import gobject.object : ObjectWrap;
import gio.async_result : AsyncResult;
import gtk.box : Box;
import gtk.button : Button;
import gtk.alert_dialog : AlertDialog;
import gtk.c.functions : gtk_alert_dialog_new;
import gtk.entry : Entry;
import gtk.file_dialog : FileDialog;
import gtk.image : Image;
import gtk.label : Label;
import gtk.list_box : ListBox;
import gtk.list_box_row : ListBoxRow;
import gtk.progress_bar : ProgressBar;
import gtk.revealer : Revealer;
import gtk.scrolled_window : ScrolledWindow;
import gtk.types : Align, Justification, Orientation, PolicyType,
	RevealerTransitionType, SelectionMode;

import glib.error : ErrorWrap;
import appimage.manifest : Manifest;
import apputils : installBaseDir, readConfigGithubToken, writeConfigGithubToken,
	readConfigInstallDir, writeConfigInstallDir, xdgDataHome,
	isSystemdTimerInstalled, systemdUserDir, writeSystemdServiceFile,
	writeSystemdTimerFile, readConfigTimerIntervalHours, writeConfigTimerIntervalHours,
	readConfigCheckIntervalHours, writeConfigCheckIntervalHours,
	readConfigAutoUpdate, writeConfigAutoUpdate, writeInstallerUpdateFlag;
import constants : APPLICATIONS_SUBDIR, DESKTOP_SUFFIX, DESKTOP_PREFIX, INSTALLER_VERSION;
import update.checker : checkInstallerUpdate;
import lang : L;
import windows.base : makeBackButton, ANIM_DURATION_MS;
import windows.manage : ManageWindow;

// Pixel measurements for the settings page layout
private enum Layout {
	iconSize = 48,
	iconMarginBottom = 6,
	pageMarginHorizontal = 20,
	pageMarginVertical = 16,
	groupSpacing = 18,
	rowPadding = 12,
	rowSideMargin = 14,
	rowSpacing = 8,
	noteMarginStart = 14,
	noteMarginBottom = 6,
	labelWidth = 160,
	saveButtonWidth = 120,
	saveButtonHeight = 32,
	saveButtonMarginTop = 24,
	progressPollMs = 100,
}

// Copies a directory tree src into dst recursively
private void copyDirRecurse(string src, string dst) {
	mkdirRecurse(dst);
	foreach (entry; dirEntries(src, SpanMode.shallow)) {
		string target = buildPath(dst, baseName(entry.name));
		if (entry.isDir)
			copyDirRecurse(entry.name, target);
		else
			copy(entry.name, target);
	}
}

// Updates manifests, desktop Exec= paths, and symlinks to refer to the new location
// Returns empty string on success, or the first error message encountered
private string migrateAppsTo(string oldBase, string newBase) {
	if (!exists(oldBase) || !isDir(oldBase))
		return "";
	try {
		mkdirRecurse(newBase);
	} catch (FileException fileException) {
		return fileException.msg;
	}
	foreach (dirEntry; dirEntries(oldBase, SpanMode.shallow)) {
		if (!dirEntry.isDir)
			continue;
		string sanitized = baseName(dirEntry.name);
		string oldDir = dirEntry.name;
		string newDir = buildPath(newBase, sanitized);
		try {
			rename(oldDir, newDir);
		} catch (FileException) {
			// Cross-device move so fall back to copy then delete
			try {
				copyDirRecurse(oldDir, newDir);
				rmdirRecurse(oldDir);
			} catch (FileException fileException) {
				return fileException.msg;
			}
		}

		// Update manifest appDirectory to point at new location
		auto installedAppManifest = Manifest.loadFromAppDir(newDir);
		if (installedAppManifest !is null) {
			installedAppManifest.appDirectory = newDir;
			installedAppManifest.save();
		}

		// Patch all paths in the desktop file inside the app directory
		string desktopPath = buildPath(
			newDir, APPLICATIONS_SUBDIR, sanitized ~ DESKTOP_SUFFIX);
		if (exists(desktopPath)) {
			try {
				import std.file : readText, write;

				string content = readText(desktopPath);
				string patched = replace(content, oldDir, newDir);
				if (patched != content)
					write(desktopPath, patched);
			} catch (FileException) {
			}
		}

		// Re-create the desktop symlink pointing at the new desktop file location
		if (installedAppManifest !is null
			&& installedAppManifest.desktopSymlink.length) {
			try {
				if (isSymlink(installedAppManifest.desktopSymlink)
					|| exists(installedAppManifest.desktopSymlink))
					remove(installedAppManifest.desktopSymlink);
			} catch (FileException) {
			}
			try {
				import std.file : symlink;

				symlink(desktopPath, installedAppManifest.desktopSymlink);
			} catch (FileException fileException) {
				writeln("settings: could not re-create symlink: ", fileException.msg);
			}
		}
	}
	return "";
}

// Builds the settings sub-page and wires the back button into win.headerBar
// onSaved triggers a full reload, onBack fires when leaving with no pending changes
public Box buildSettingsBox(
	ManageWindow win,
	void delegate() onSaved,
	void delegate() onBack) {
	auto scroll = new ScrolledWindow;
	scroll.setHexpand(true);
	scroll.setVexpand(true);
	scroll.setPolicy(PolicyType.Never, PolicyType.Automatic);

	auto settingsBox = new Box(Orientation.Vertical, Layout.groupSpacing);
	settingsBox.setMarginStart(Layout.pageMarginHorizontal);
	settingsBox.setMarginEnd(Layout.pageMarginHorizontal);
	settingsBox.setMarginTop(Layout.pageMarginVertical);
	settingsBox.setMarginBottom(Layout.pageMarginVertical);
	settingsBox.setHexpand(true);
	scroll.setChild(settingsBox);

	auto headerIcon = Image.newFromIconName("preferences-system-symbolic");
	headerIcon.addCssClass("icon-dropshadow");
	headerIcon.setSizeRequest(Layout.iconSize, Layout.iconSize);
	headerIcon.setPixelSize(Layout.iconSize);
	headerIcon.setHalign(Align.Center);
	headerIcon.setMarginBottom(Layout.iconMarginBottom);
	settingsBox.append(headerIcon);

	auto titleLabel = new Label(L("settings.title"));
	titleLabel.addCssClass("title-3");
	titleLabel.setHalign(Align.Center);
	settingsBox.append(titleLabel);

	// Section heading
	Label makeHeading(string text) {
		auto label = new Label(text);
		label.addCssClass("section-heading");
		label.setHalign(Align.Start);
		return label;
	}

	// Boxed-list row with a left label and a right entry, not activatable
	ListBoxRow makeEntryRow(string title, string placeholder, out Entry entry) {
		auto rowBox = new Box(Orientation.Horizontal, Layout.rowSpacing);
		rowBox.setMarginTop(Layout.rowPadding);
		rowBox.setMarginBottom(Layout.rowPadding);
		rowBox.setMarginStart(Layout.rowSideMargin);
		rowBox.setMarginEnd(Layout.rowSideMargin);
		auto label = new Label(title);
		label.setHalign(Align.Start);
		label.setXalign(0.0f);
		label.setValign(Align.Center);
		label.setSizeRequest(Layout.labelWidth, -1);
		rowBox.append(label);
		entry = new Entry;
		entry.setPlaceholderText(placeholder);
		entry.setHexpand(true);
		entry.setValign(Align.Center);
		rowBox.append(entry);
		auto row = new ListBoxRow;
		row.setActivatable(false);
		row.setChild(rowBox);
		return row;
	}

	// About section
	settingsBox.append(makeHeading(L("settings.group.about")));
	auto aboutList = new ListBox;
	aboutList.setHexpand(true);
	aboutList.addCssClass("boxed-list");
	aboutList.setSelectionMode(SelectionMode.None);
	settingsBox.append(aboutList);

	auto checkRowBox = new Box(Orientation.Horizontal, Layout.rowSpacing);
	checkRowBox.setMarginTop(Layout.rowPadding);
	checkRowBox.setMarginBottom(Layout.rowPadding);
	checkRowBox.setMarginStart(Layout.rowSideMargin);
	checkRowBox.setMarginEnd(Layout.rowSideMargin);
	auto checkVersionLabel = new Label(
		L("settings.installer.version", INSTALLER_VERSION));
	checkVersionLabel.setHalign(Align.Start);
	checkVersionLabel.setXalign(0.0f);
	checkVersionLabel.setValign(Align.Center);
	checkVersionLabel.setSizeRequest(Layout.labelWidth, -1);
	auto checkStatusLabel = new Label("");
	checkStatusLabel.setHalign(Align.Start);
	checkStatusLabel.setHexpand(true);
	checkStatusLabel.setValign(Align.Center);
	auto checkButton = Button.newWithLabel(L("button.check_updates"));
	checkButton.setValign(Align.Center);
	checkRowBox.append(checkVersionLabel);
	checkRowBox.append(checkStatusLabel);
	checkRowBox.append(checkButton);
	auto checkRow = new ListBoxRow;
	checkRow.setActivatable(false);
	checkRow.setChild(checkRowBox);
	aboutList.append(checkRow);

	bool updateReady;
	string pendingVersion;
	checkButton.connectClicked(() {
		if (updateReady) {
			win.revealInstallerUpdate(pendingVersion);
			onBack();
			return;
		}
		checkButton.setSensitive(false);
		checkStatusLabel.setText(L("update.checking.label"));
		auto checkThread = new Thread({
			string available, checkError;
			bool hasUpdate = checkInstallerUpdate(available, checkError);
			idleAdd(PRIORITY_DEFAULT, () {
				if (checkError.length)
					checkStatusLabel.setText(
					L("manage.installer.update.failed", checkError));
				else if (hasUpdate) {
					checkStatusLabel.setText(
					L("manage.installer.update.version", available));
					writeInstallerUpdateFlag(available);
					win.setInstallerUpdateAvailable(available);
					pendingVersion = available;
					updateReady = true;
					checkButton.setLabel(L("update.button.now"));
				} else {
					checkStatusLabel.setText(L("settings.installer.up_to_date"));
				}
				checkButton.setSensitive(true);
				return false;
			});
		});
		checkThread.isDaemon = true;
		checkThread.start();
	});

	// GitHub section
	settingsBox.append(makeHeading(L("settings.group.github")));
	auto githubList = new ListBox;
	githubList.setHexpand(true);
	githubList.addCssClass("boxed-list");
	githubList.setSelectionMode(SelectionMode.None);
	settingsBox.append(githubList);

	Entry tokenEntry;
	githubList.append(makeEntryRow(
			L("settings.token.title"), L("settings.token.placeholder"), tokenEntry));
	tokenEntry.setText(readConfigGithubToken());

	auto tokenNote = new Label(L("settings.token.note"));
	tokenNote.addCssClass("caption");
	tokenNote.addCssClass("dim-label");
	tokenNote.setHalign(Align.Start);
	tokenNote.setWrap(true);
	tokenNote.setMarginStart(Layout.noteMarginStart);
	tokenNote.setMarginBottom(Layout.noteMarginBottom);
	settingsBox.append(tokenNote);

	// Storage section
	settingsBox.append(makeHeading(L("settings.group.storage")));
	auto storageList = new ListBox;
	storageList.setHexpand(true);
	storageList.addCssClass("boxed-list");
	storageList.setSelectionMode(SelectionMode.None);
	settingsBox.append(storageList);

	auto dirRowBox = new Box(Orientation.Horizontal, Layout.rowSpacing);
	dirRowBox.setMarginTop(Layout.rowPadding);
	dirRowBox.setMarginBottom(Layout.rowPadding);
	dirRowBox.setMarginStart(Layout.rowSideMargin);
	dirRowBox.setMarginEnd(Layout.rowSideMargin);
	auto dirLabel = new Label(L("settings.dir.title"));
	dirLabel.setHalign(Align.Start);
	dirLabel.setXalign(0.0f);
	dirLabel.setValign(Align.Center);
	dirLabel.setSizeRequest(Layout.labelWidth, -1);
	dirRowBox.append(dirLabel);
	auto dirEntry = new Entry;
	dirEntry.setText(installBaseDir());
	dirEntry.setHexpand(true);
	dirEntry.setValign(Align.Center);
	dirRowBox.append(dirEntry);
	auto browseButton = new Button;
	browseButton.setLabel(L("settings.dir.browse"));
	browseButton.setValign(Align.Center);
	dirRowBox.append(browseButton);
	auto dirRow = new ListBoxRow;
	dirRow.setActivatable(false);
	dirRow.setChild(dirRowBox);
	storageList.append(dirRow);

	// Background updates section
	settingsBox.append(makeHeading(L("settings.group.bgupdate")));
	auto bgupdateList = new ListBox;
	bgupdateList.setHexpand(true);
	bgupdateList.addCssClass("boxed-list");
	bgupdateList.setSelectionMode(SelectionMode.None);
	settingsBox.append(bgupdateList);

	auto enableRowBox = new Box(Orientation.Horizontal, Layout.rowSpacing);
	enableRowBox.setMarginTop(Layout.rowPadding);
	enableRowBox.setMarginBottom(Layout.rowPadding);
	enableRowBox.setMarginStart(Layout.rowSideMargin);
	enableRowBox.setMarginEnd(Layout.rowSideMargin);
	auto enableBgupdateLabel = new Label(L("settings.bgupdate.enable"));
	enableBgupdateLabel.setHalign(Align.Start);
	enableBgupdateLabel.setXalign(0.0f);
	enableBgupdateLabel.setValign(Align.Center);
	enableBgupdateLabel.setHexpand(true);
	enableRowBox.append(enableBgupdateLabel);
	auto enableSwitch = new Switch;
	enableSwitch.setValign(Align.Center);
	enableRowBox.append(enableSwitch);
	auto enableRow = new ListBoxRow;
	enableRow.setActivatable(false);
	enableRow.setChild(enableRowBox);
	bgupdateList.append(enableRow);

	auto intervalRowBox = new Box(Orientation.Horizontal, Layout.rowSpacing);
	intervalRowBox.setMarginTop(Layout.rowPadding);
	intervalRowBox.setMarginBottom(Layout.rowPadding);
	intervalRowBox.setMarginStart(Layout.rowSideMargin);
	intervalRowBox.setMarginEnd(Layout.rowSideMargin);
	auto intervalLabel = new Label(L("settings.bgupdate.interval"));
	intervalLabel.setHalign(Align.Start);
	intervalLabel.setXalign(0.0f);
	intervalLabel.setValign(Align.Center);
	intervalLabel.setSizeRequest(Layout.labelWidth, -1);
	intervalRowBox.append(intervalLabel);
	auto intervalEntry = new Entry;
	intervalEntry.setHexpand(true);
	intervalEntry.setValign(Align.Center);
	intervalRowBox.append(intervalEntry);
	auto intervalUnitLabel = new Label(L("settings.bgupdate.interval.unit"));
	intervalUnitLabel.setValign(Align.Center);
	intervalRowBox.append(intervalUnitLabel);
	auto intervalRow = new ListBoxRow;
	intervalRow.setActivatable(false);
	intervalRow.setChild(intervalRowBox);
	bgupdateList.append(intervalRow);

	auto fetchRowBox = new Box(Orientation.Horizontal, Layout.rowSpacing);
	fetchRowBox.setMarginTop(Layout.rowPadding);
	fetchRowBox.setMarginBottom(Layout.rowPadding);
	fetchRowBox.setMarginStart(Layout.rowSideMargin);
	fetchRowBox.setMarginEnd(Layout.rowSideMargin);
	auto fetchLabel = new Label(L("settings.bgupdate.fetch_interval"));
	fetchLabel.setHalign(Align.Start);
	fetchLabel.setXalign(0.0f);
	fetchLabel.setValign(Align.Center);
	fetchLabel.setSizeRequest(Layout.labelWidth, -1);
	fetchRowBox.append(fetchLabel);
	auto fetchEntry = new Entry;
	fetchEntry.setHexpand(true);
	fetchEntry.setValign(Align.Center);
	fetchRowBox.append(fetchEntry);
	auto fetchUnitLabel = new Label(L("settings.bgupdate.interval.unit"));
	fetchUnitLabel.setValign(Align.Center);
	fetchRowBox.append(fetchUnitLabel);
	auto fetchRow = new ListBoxRow;
	fetchRow.setActivatable(false);
	fetchRow.setChild(fetchRowBox);
	bgupdateList.append(fetchRow);

	auto autoUpdateRowBox = new Box(Orientation.Horizontal, Layout.rowSpacing);
	autoUpdateRowBox.setMarginTop(Layout.rowPadding);
	autoUpdateRowBox.setMarginBottom(Layout.rowPadding);
	autoUpdateRowBox.setMarginStart(Layout.rowSideMargin);
	autoUpdateRowBox.setMarginEnd(Layout.rowSideMargin);
	auto autoUpdateLabel = new Label(L("settings.bgupdate.autoupdate"));
	autoUpdateLabel.setHalign(Align.Start);
	autoUpdateLabel.setXalign(0.0f);
	autoUpdateLabel.setValign(Align.Center);
	autoUpdateLabel.setHexpand(true);
	autoUpdateRowBox.append(autoUpdateLabel);
	auto autoUpdateSwitch = new Switch;
	autoUpdateSwitch.setValign(Align.Center);
	autoUpdateRowBox.append(autoUpdateSwitch);
	auto autoUpdateRow = new ListBoxRow;
	autoUpdateRow.setActivatable(false);
	autoUpdateRow.setChild(autoUpdateRowBox);
	bgupdateList.append(autoUpdateRow);

	auto progressBar = new ProgressBar;
	progressBar.setHexpand(true);
	progressBar.setShowText(true);
	progressBar.setText(L("settings.move.progress"));
	auto progressRevealer = new Revealer;
	progressRevealer.setTransitionType(RevealerTransitionType.SlideDown);
	progressRevealer.setTransitionDuration(ANIM_DURATION_MS);
	progressRevealer.setChild(progressBar);
	progressRevealer.setRevealChild(false);
	settingsBox.append(progressRevealer);

	Button backButton;
	auto saveButton = Button.newWithLabel(L("button.save"));
	saveButton.addCssClass("pill");
	saveButton.setHalign(Align.End);
	saveButton.setSizeRequest(Layout.saveButtonWidth, Layout.saveButtonHeight);
	saveButton.setMarginTop(Layout.saveButtonMarginTop);
	saveButton.setSensitive(false);
	settingsBox.append(saveButton);

	string initialToken = tokenEntry.getText();
	string initialDir = dirEntry.getText();
	bool initialBgupdateEnabled = isSystemdTimerInstalled();
	int initialTimerHours = readConfigTimerIntervalHours();
	int initialFetchHours = readConfigCheckIntervalHours();
	bool initialAutoUpdate = readConfigAutoUpdate();
	enableSwitch.setActive(initialBgupdateEnabled);
	intervalEntry.setText(to!string(initialTimerHours));
	fetchEntry.setText(to!string(initialFetchHours));
	autoUpdateSwitch.setActive(initialAutoUpdate);
	intervalRow.setVisible(initialBgupdateEnabled);
	fetchRow.setVisible(initialBgupdateEnabled);
	autoUpdateRow.setVisible(initialBgupdateEnabled);

	void updateSaveSensitive() {
		bool bgupdateChanged =
			enableSwitch.getActive() != initialBgupdateEnabled
			|| (enableSwitch.getActive() && (
					intervalEntry.getText() != to!string(initialTimerHours)
					|| fetchEntry.getText() != to!string(initialFetchHours)
					|| autoUpdateSwitch.getActive() != initialAutoUpdate));
		saveButton.setSensitive(
			tokenEntry.getText() != initialToken
				|| dirEntry.getText() != initialDir
				|| bgupdateChanged);
	}

	tokenEntry.connectChanged(() { updateSaveSensitive(); });
	dirEntry.connectChanged(() { updateSaveSensitive(); });
	enableSwitch.connectStateSet((bool state) {
		intervalRow.setVisible(state);
		fetchRow.setVisible(state);
		autoUpdateRow.setVisible(state);
		updateSaveSensitive();
		return false;
	});
	intervalEntry.connectChanged(() { updateSaveSensitive(); });
	fetchEntry.connectChanged(() { updateSaveSensitive(); });
	autoUpdateSwitch.connectStateSet((bool state) {
		updateSaveSensitive();
		return false;
	});

	auto outerBox = new Box(Orientation.Vertical, 0);
	outerBox.setHexpand(true);
	outerBox.setVexpand(true);
	outerBox.append(scroll);

	backButton = makeBackButton(() {
		if (!saveButton.getSensitive()) {
			win.headerBar.remove(backButton);
			onBack();
			return;
		}
		auto dlg = new AlertDialog(cast(void*) gtk_alert_dialog_new(
			"%s".ptr, L("dialog.unsaved.title").toStringz()), Yes.Take);
		dlg.setDetail(L("dialog.unsaved.body"));
		dlg.setButtons([L("button.discard"), L("button.cancel")]);
		dlg.setDefaultButton(1);
		dlg.setCancelButton(1);
		dlg.setModal(true);
		dlg.choose(win, null, (ObjectWrap src, AsyncResult res) {
			try {
				if (dlg.chooseFinish(res) == 0) {
					win.headerBar.remove(backButton);
					onBack();
				}
			} catch (ErrorWrap) {
			}
		});
	});
	win.headerBar.packStart(backButton);

	browseButton.connectClicked(() {
		auto fileDialog = new FileDialog;
		fileDialog.setTitle(L("settings.dir.title"));
		fileDialog.selectFolder(win, null,
			(ObjectWrap source, AsyncResult asyncResult) {
			try {
				auto gioFile = fileDialog.selectFolderFinish(asyncResult);
				string path = gioFile.getPath();
				if (path.length)
					dirEntry.setText(path);
			} catch (ErrorWrap) {
			}
		});
	});

	saveButton.connectClicked(() {
		string newToken = tokenEntry.getText();
		string newDir = dirEntry.getText();
		string oldDir = installBaseDir();

		bool dirChanged = (newDir != oldDir);

		writeConfigGithubToken(newToken);

		// Handle background update settings
		bool newEnabled = enableSwitch.getActive();
		int newTimerHours = 4;
		try {
			newTimerHours = to!int(intervalEntry.getText());
		} catch (ConvException) {
		}
		if (newTimerHours < 1)
			newTimerHours = 1;
		int newFetchHours = 24;
		try {
			newFetchHours = to!int(fetchEntry.getText());
		} catch (ConvException) {
		}
		if (newFetchHours < 1)
			newFetchHours = 1;
		bool newAutoUpdateValue = autoUpdateSwitch.getActive();
		string svcDir = systemdUserDir();
		string svcPath = buildPath(
			svcDir, "appimage-installer-update.service");
		string timerPath = buildPath(
			svcDir, "appimage-installer-update.timer");
		if (newEnabled) {
			string svcError;
			writeSystemdServiceFile(
				svcPath, newFetchHours, newAutoUpdateValue, svcError);
			if (svcError.length)
				writeln("settings: ", svcError);
			string timerError;
			writeSystemdTimerFile(timerPath, newTimerHours, timerError);
			if (timerError.length)
				writeln("settings: ", timerError);
			try {
				execute(["systemctl", "--user", "daemon-reload"]);
				if (!initialBgupdateEnabled)
					execute([
						"systemctl", "--user", "enable",
						"--now", "appimage-installer-update.timer"
					]);
			} catch (ProcessException) {
			}
		} else if (initialBgupdateEnabled) {
			try {
				execute([
					"systemctl", "--user", "disable",
					"--now", "appimage-installer-update.timer"
				]);
			} catch (ProcessException) {
			}
			try {
				if (exists(svcPath))
					remove(svcPath);
			} catch (FileException) {
			}
			try {
				if (exists(timerPath))
					remove(timerPath);
			} catch (FileException) {
			}
		}
		writeConfigTimerIntervalHours(newTimerHours);
		writeConfigCheckIntervalHours(newFetchHours);
		writeConfigAutoUpdate(newAutoUpdateValue);
		initialBgupdateEnabled = newEnabled;
		initialTimerHours = newTimerHours;
		initialFetchHours = newFetchHours;
		initialAutoUpdate = newAutoUpdateValue;

		if (!dirChanged) {
			win.headerBar.remove(backButton);
			onSaved();
			return;
		}

		// Directory changed so migrate all app directories to the new location
		saveButton.setSensitive(false);
		backButton.setSensitive(false);
		browseButton.setSensitive(false);
		tokenEntry.setSensitive(false);
		dirEntry.setSensitive(false);

		progressBar.pulse();
		progressRevealer.setRevealChild(true);

		// Pulse the bar while the migration thread runs
		bool migrationDone = false;
		string migrationError;
		timeoutAdd(PRIORITY_DEFAULT, Layout.progressPollMs, () {
			if (migrationDone)
				return false;
			progressBar.pulse();
			return true;
		});

		auto thread = new Thread({
			string err = migrateAppsTo(oldDir, newDir);
			migrationDone = true;
			migrationError = err;
			idleAdd(PRIORITY_DEFAULT, () {
				if (migrationError.length) {
					progressBar.setFraction(0.0);
					auto errorLabel = new Label(
					L("settings.move.error", migrationError));
					errorLabel.addCssClass("warning");
					errorLabel.setWrap(true);
					errorLabel.setJustify(Justification.Center);
					errorLabel.setHalign(Align.Center);
					settingsBox.append(errorLabel);
					progressRevealer.setRevealChild(false);
					saveButton.setSensitive(true);
					backButton.setSensitive(true);
					browseButton.setSensitive(true);
					tokenEntry.setSensitive(true);
					dirEntry.setSensitive(true);
					return false;
				}
				writeConfigInstallDir(newDir);
				win.headerBar.remove(backButton);
				onSaved();
				return false;
			});
		});
		thread.isDaemon = true;
		thread.start();
	});

	return outerBox;
}
