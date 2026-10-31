// Desktop file and systemd integration
//
module apputils.system;

import std.path : buildPath;

import apputils.paths : systemdUserDir, xdgDataHome;

// True when the default AppImage MIME handler is this installer's desktop file
// and that desktop file's Exec= points to the currently running binary
public bool isAppImageAssociated() {
	import std.file : thisExePath, exists;
	import std.process : execute, ProcessException;
	import std.string : strip, startsWith;
	import constants : INSTALLER_DESKTOP_FILE;

	try {
		auto result = execute([
			"xdg-mime", "query", "default", "application/vnd.appimage"
		]);
		if (result.status != 0
			|| result.output.strip() != INSTALLER_DESKTOP_FILE)
			return false;
	} catch (ProcessException) {
		return false;
	}

	string desktopPath = buildPath(
		xdgDataHome(), "applications", INSTALLER_DESKTOP_FILE);
	if (!exists(desktopPath))
		return false;
	// Empty locale falls back to the base Exec= value
	string execValue = readDesktopFieldLocalized(desktopPath, "Exec", "");
	string currentExe = thisExePath();
	return execValue.startsWith(currentExe);
}

// Writes the embedded installer icon into the user hicolor theme so launchers can find it
public bool installInstallerIcon(out string error) {
	import std.file : write, FileException, mkdirRecurse;
	import appimage.icon : updateIconCache;
	import constants : INSTALLER_ICON_NAME;

	string hicolorBase = buildPath(xdgDataHome(), "icons", "hicolor");
	string iconDirectory = buildPath(hicolorBase, "scalable", "apps");
	try {
		mkdirRecurse(iconDirectory);
		write(buildPath(iconDirectory, INSTALLER_ICON_NAME ~ ".svg"),
			import(INSTALLER_ICON_NAME ~ ".svg"));
	} catch (FileException fileException) {
		error = fileException.msg;
		return false;
	}
	updateIconCache(hicolorBase);
	return true;
}

// Builds a desktop file key line in English plus one line per other language
private string localizedDesktopField(string key, string translationKey) {
	import lang : availableLangs, translateIn;

	string lines = key ~ "=" ~ translateIn("en", translationKey) ~ "\n";
	foreach (code; availableLangs()) {
		if (code == "en")
			continue;
		lines ~= key ~ "[" ~ code ~ "]=" ~ translateIn(code, translationKey) ~ "\n";
	}
	return lines;
}

// Writes the installer .desktop file to destPath and its icon, always overwriting
// The hidden background updater entry is only kept while the update timer is installed
public bool writeInstallerDesktopFile(string destPath, out string error) {
	import std.file : write, FileException, mkdirRecurse, thisExePath;
	import std.path : dirName;
	import constants : INSTALLER_ICON_NAME;

	if (!installInstallerIcon(error))
		return false;

	try {
		mkdirRecurse(dirName(destPath));
		write(destPath,
			"[Desktop Entry]\n"
				~ "Type=Application\n"
				~ localizedDesktopField("Name", "app.name")
				~ localizedDesktopField("Comment", "app.description")
				~ "Icon=" ~ INSTALLER_ICON_NAME ~ "\n"
				~ "Exec=" ~ thisExePath() ~ " %f\n"
				~ "MimeType=application/vnd.appimage;"
				~ "application/x-iso9660-appimage;\n"
				~ "NoDisplay=false\n");
	} catch (FileException fileException) {
		error = fileException.msg;
		return false;
	}

	// Keep the hidden updater entry in sync with the systemd timer
	syncBgupdateDesktopFile(dirName(destPath));
	return true;
}

// Writes or removes the hidden background updater desktop entry based on
// whether the systemd update timer is installed
public void syncBgupdateDesktopFile(string desktopDir) {
	if (!isSystemdTimerInstalled()) {
		removeBgupdateDesktopFile(desktopDir);
		return;
	}

	string error;
	if (!writeBgupdateDesktopFile(desktopDir, error) && error.length) {
		import std.stdio : writeln;

		writeln("apputils: could not write background updater desktop entry: ", error);
	}
}

// Writes the hidden background updater desktop entry into desktopDir
// This entry is only needed while the systemd update timer is installed
private bool writeBgupdateDesktopFile(string desktopDir, out string error) {
	import std.file : write, FileException, mkdirRecurse, thisExePath;
	import constants : INSTALLER_ICON_NAME, BGUPDATE_DESKTOP_FILE;

	try {
		mkdirRecurse(desktopDir);
		write(buildPath(desktopDir, BGUPDATE_DESKTOP_FILE),
			"[Desktop Entry]\n"
				~ "Type=Application\n"
				~ localizedDesktopField("Name", "app.name")
				~ "Icon=" ~ INSTALLER_ICON_NAME ~ "\n"
				~ "Exec=" ~ thisExePath() ~ " --background-update\n"
				~ "NoDisplay=true\n");
	} catch (FileException fileException) {
		error = fileException.msg;
		return false;
	}
	return true;
}

// Removes the hidden background updater desktop entry from desktopDir if present
private void removeBgupdateDesktopFile(string desktopDir) {
	import std.file : exists, remove, FileException;
	import constants : BGUPDATE_DESKTOP_FILE;

	string path = buildPath(desktopDir, BGUPDATE_DESKTOP_FILE);
	try {
		if (exists(path))
			remove(path);
	} catch (FileException fileException) {
		import std.stdio : writeln;

		writeln("apputils: could not remove background updater desktop entry: ",
			fileException.msg);
	}
}

// Registers desktopFileName as the default handler for both AppImage MIME types
public bool registerAppImages(string desktopFileName, out string error) {
	import std.process : execute, ProcessException;

	try {
		foreach (mime; [
				"application/vnd.appimage",
				"application/x-iso9660-appimage"
			]) {
			auto result = execute([
					"xdg-mime", "default", desktopFileName, mime
				]);
			if (result.status != 0) {
				error = "xdg-mime failed for " ~ mime;
				return false;
			}
		}
	} catch (ProcessException processException) {
		error = "xdg-mime not available: " ~ processException.msg;
		return false;
	}
	return true;
}

// Reads a desktop file field with locale fallback from [Desktop Entry] only
// Tries key[locale]= first then falls back to key= and returns empty on any failure
public string readDesktopFieldLocalized(string path, string key, string locale) {
	import std.file : readText, FileException;
	import std.string : splitLines, strip;

	try {
		string localePrefix = key ~ "[" ~ locale ~ "]=";
		string basePrefix = key ~ "=";
		string baseValue;
		bool inDesktopEntry = false;
		foreach (line; readText(path).splitLines()) {
			string stripped = line.strip();
			if (stripped.length && stripped[0] == '[') {
				if (stripped == "[Desktop Entry]") {
					inDesktopEntry = true;
				} else if (inDesktopEntry) {
					break; // Left [Desktop Entry], nothing more to find
				}
				continue;
			}
			if (!inDesktopEntry)
				continue;
			if (line.length > localePrefix.length
				&& line[0 .. localePrefix.length] == localePrefix)
				return line[localePrefix.length .. $];
			if (!baseValue.length && line.length > basePrefix.length
				&& line[0 .. basePrefix.length] == basePrefix)
				baseValue = line[basePrefix.length .. $];
		}
		return baseValue;
	} catch (FileException) {
		return "";
	}
}

// Writes a systemd user service unit that runs the background update check
public bool writeSystemdServiceFile(
	string destPath, int checkIntervalHours, bool autoUpdate,
	out string error) {
	import std.file : write, FileException, mkdirRecurse, thisExePath;
	import std.path : dirName;
	import std.conv : to;

	try {
		mkdirRecurse(dirName(destPath));
		write(destPath,
			"[Unit]\n"
				~ "Description=AppImage Installer background update check\n"
				~ "\n"
				~ "[Service]\n"
				~ "Type=simple\n"
				~ "ExecStart=" ~ thisExePath()
				~ " --background-update --check-interval "
				~ to!string(
					checkIntervalHours)
				~ " --auto-update "
				~ (autoUpdate ? "true" : "false") ~ "\n");
	} catch (FileException fileException) {
		error = fileException.msg;
		return false;
	}
	return true;
}

// Writes a systemd user timer unit that triggers the update service
public bool writeSystemdTimerFile(
	string destPath, int timerIntervalHours, out string error) {
	import std.file : write, FileException, mkdirRecurse;
	import std.path : dirName;
	import std.conv : to;

	try {
		mkdirRecurse(dirName(destPath));
		write(destPath,
			"[Unit]\n"
				~ "Description=Run AppImage Installer background update check\n"
				~ "\n"
				~ "[Timer]\n"
				~ "OnBootSec=5min\n"
				~ "OnUnitActiveSec=" ~ to!string(
					timerIntervalHours) ~ "h\n"
				~ "Persistent=true\n"
				~ "\n"
				~ "[Install]\n"
				~ "WantedBy=timers.target\n");
	} catch (FileException fileException) {
		error = fileException.msg;
		return false;
	}
	return true;
}

// Writes the desktop file then registers it as the default AppImage handler
public bool associateAppImages(out string error) {
	import constants : INSTALLER_DESKTOP_FILE;

	string desktopPath = buildPath(xdgDataHome(), "applications", INSTALLER_DESKTOP_FILE);
	if (!writeInstallerDesktopFile(desktopPath, error))
		return false;
	return registerAppImages(INSTALLER_DESKTOP_FILE, error);
}

// True if the background update timer unit file is present in the systemd user dir
public bool isSystemdTimerInstalled() {
	import std.file : exists;

	return exists(
		buildPath(systemdUserDir(), "appimage-installer-update.timer"));
}
