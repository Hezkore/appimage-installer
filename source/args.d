// Parses command line arguments and returns everything needed to start the app
//
module args;

import std.stdio : writeln;
import std.file : exists, getAttributes, FileException;
import std.conv : octal, to, ConvException;
import std.string : startsWith, endsWith;
import std.path : buildPath, baseName, stripExtension;

import types : AppMode;
import constants : INSTALLER_VERSION, DESKTOP_PREFIX, DESKTOP_SUFFIX;
import constants : APPLICATIONS_SUBDIR, MANIFEST_FILE_NAME;
import apputils : xdgDataHome, homeDir, installBaseDir, writeInstallerDesktopFile, associateAppImages,
	writeSystemdServiceFile, writeSystemdTimerFile, isAppImageAssociated;
import constants : INSTALLER_DESKTOP_FILE;
import appimage : AppImage;
import appimage.manifest : Manifest;

private enum uint FILE_WRITE_BIT = octal!200;
private enum string SYSTEMD_SERVICE_FILE = "appimage-installer-update.service";
private enum string SYSTEMD_TIMER_FILE = "appimage-installer-update.timer";

// Holds everything figured out from the command line
struct AppArgs {
	AppMode mode;
	AppImage appImage;
	string targetAppName;
	string targetSanitizedName;
	string targetAppDir;
	string targetUpdateInfo;
	string targetIconName;
	string targetDesktopSymlink;
	int checkIntervalHours;
	bool autoUpdate;
	bool shouldQuit;
}

// Turns a .desktop filename, full directory path, or bare sanitized name into just the sanitized name
private string resolveSanitizedName(string target) {
	import std.path : isAbsolute;

	if (isAbsolute(target))
		return baseName(target);
	if (!target.endsWith(DESKTOP_SUFFIX))
		return target;
	string base = baseName(stripExtension(target));
	return base.startsWith(DESKTOP_PREFIX) ? base[DESKTOP_PREFIX.length .. $] : base;
}

// Returns true when the AppImage path exists and can be run
private bool checkAppImagePath(AppImage appImage) {
	if (appImage is null || appImage.filePath.length == 0) {
		writeln("Error: no file path specified.");
		return false;
	}
	if (!exists(appImage.filePath)) {
		writeln("Error: file not found: ", appImage.filePath);
		return false;
	}
	auto attributes = getAttributes(appImage.filePath);
	if ((attributes & FILE_WRITE_BIT) == 0) {
		writeln("Error: no write permission on file: ", appImage.filePath);
		return false;
	}
	return true;
}

// Reads a manifest to fill the target app name, dir, update info, and icon name
private void fillTargetFromArg(ref AppArgs result, string target) {
	if (!target.length) {
		writeln("Error: a path or app name is required.");
		return;
	}

	string sanitized = resolveSanitizedName(target);
	result.targetSanitizedName = sanitized;

	string manifestPath = Manifest.pathFor(
		buildPath(installBaseDir(), sanitized));

	auto loadedManifest = Manifest.load(manifestPath);
	if (loadedManifest is null) {
		writeln("No manifest found for '", sanitized, "'.");
		result.targetAppName = sanitized;
		return;
	}
	result.targetAppName =
		loadedManifest.appName.length ? loadedManifest.appName : sanitized;
	result.targetAppDir = loadedManifest.appDirectory;
	result.targetUpdateInfo = loadedManifest.updateInfo;
	result.targetIconName = loadedManifest.installedIconName;
	result.targetDesktopSymlink = loadedManifest.desktopSymlink;
}

// Prints install health info useful for debugging without indicating failure
private void printHealth() {
	import std.file : thisExePath;
	import std.path : dirName;
	import std.process : environment, execute, ProcessException;
	import std.algorithm : canFind;
	import std.string : split, strip;

	string binPath = thisExePath();
	string binDir = dirName(binPath);
	bool inPath = environment.get("PATH", "").split(":").canFind(binDir);

	string desktopPath = buildPath(
		xdgDataHome(), "applications", INSTALLER_DESKTOP_FILE);
	string systemdDir = buildPath(homeDir(), ".config", "systemd", "user");
	string servicePath = buildPath(systemdDir, SYSTEMD_SERVICE_FILE);
	string timerPath = buildPath(systemdDir, SYSTEMD_TIMER_FILE);

	bool associated = isAppImageAssociated();

	bool timerActive;
	try {
		auto timerCheckResult = execute([
			"systemctl", "--user", "is-active",
			SYSTEMD_TIMER_FILE
		]);
		timerActive = timerCheckResult.output.strip() == "active";
	} catch (ProcessException) {
		timerActive = false;
	}

	writeln("AppImage Installer v", INSTALLER_VERSION);
	writeln();
	writeln("binary     ", binPath);
	writeln("in PATH    ", inPath ? "yes" : "no");
	writeln("desktop    ", desktopPath,
		" [", exists(desktopPath) ? "exists" : "missing", "]");
	writeln("associated ", associated ? "yes" : "no");
	writeln("service    ", servicePath,
		" [", exists(servicePath) ? "exists" : "missing", "]");
	writeln("timer      ", timerPath,
		" [", exists(timerPath) ? "exists" : "missing", "]");
	writeln("timer on   ", timerActive ? "yes" : "no");
}

// Figure out what mode and target the user asked for
AppArgs parseArgs(string[] rawArgs) {
	AppArgs result;

	for (int i = 1; i < rawArgs.length; i++) {
		string argument = rawArgs[i];

		string takeNext() {
			if (i + 1 < rawArgs.length && rawArgs[i + 1][0] != '-')
				return rawArgs[++i];
			return null;
		}

		switch (argument) {
		case "--version", "-v":
			writeln("AppImage Installer v", INSTALLER_VERSION);
			result.shouldQuit = true;
			return result;

		case "--help", "-h":
			writeln(
				"Usage: appimage-installer [--install|--uninstall|--desktop|--associate|--background-update] [arg]");
			writeln("  --background-update [--check-interval <hours>] [--auto-update <true|false>]");
			writeln("  --systemd-service <dir>  write the background update service unit to <dir>");
			writeln("  --systemd-timer <dir>    write the background update timer unit to <dir>");
			writeln("  --health                 print install health info for debugging");
			result.shouldQuit = true;
			return result;

		case "--health":
			printHealth();
			result.shouldQuit = true;
			return result;

		case "--desktop":
			result.shouldQuit = true;
			string destDir = takeNext();
			if (!destDir.length) {
				import std.stdio : stderr;

				stderr.writeln("Error: --desktop requires a directory path.");
				return result;
			}
			string destPath = buildPath(destDir, INSTALLER_DESKTOP_FILE);
			string desktopError;
			if (!writeInstallerDesktopFile(destPath, desktopError)) {
				import std.stdio : stderr;

				stderr.writeln("Error: ", desktopError);
			} else
				writeln(destPath);
			return result;

		case "--systemd-service":
			result.shouldQuit = true;
			string serviceDir = takeNext();
			if (!serviceDir.length) {
				import std.stdio : stderr;

				stderr.writeln("Error: --systemd-service requires a directory path.");
				return result;
			}
			if (result.checkIntervalHours < 1) {
				import std.stdio : stderr;

				stderr.writeln(
					"Error: --systemd-service requires --check-interval <hours>.");
				return result;
			}
			string servicePath = buildPath(serviceDir, "appimage-installer-update.service");
			string serviceError;
			if (!writeSystemdServiceFile(servicePath, result.checkIntervalHours, serviceError)) {
				import std.stdio : stderr;

				stderr.writeln("Error: ", serviceError);
			} else
				writeln(servicePath);
			return result;

		case "--systemd-timer":
			result.shouldQuit = true;
			string timerDir = takeNext();
			if (!timerDir.length) {
				import std.stdio : stderr;

				stderr.writeln("Error: --systemd-timer requires a directory path.");
				return result;
			}
			string timerPath = buildPath(timerDir, "appimage-installer-update.timer");
			string timerError;
			if (!writeSystemdTimerFile(timerPath, timerError)) {
				import std.stdio : stderr;

				stderr.writeln("Error: ", timerError);
			} else
				writeln(timerPath);
			return result;

		case "--associate":
			result.shouldQuit = true;
			string assocError;
			if (!associateAppImages(assocError)) {
				import std.stdio : stderr;

				stderr.writeln("Error: ", assocError);
			}
			return result;

		case "--background-update":
			result.mode = AppMode.BackgroundUpdate;
			break;

		case "--check-interval":
			string intervalStr = takeNext();
			if (!intervalStr.length) {
				writeln("Error: --check-interval requires a number of hours.");
				result.shouldQuit = true;
				return result;
			}
			try {
				result.checkIntervalHours = to!int(intervalStr);
			} catch (ConvException) {
				writeln("Error: --check-interval value must be a whole number.");
				result.shouldQuit = true;
				return result;
			}
			if (result.checkIntervalHours < 1) {
				writeln("Error: --check-interval must be at least 1.");
				result.shouldQuit = true;
				return result;
			}
			break;

		case "--auto-update":
			string autoVal = takeNext();
			if (!autoVal.length) {
				writeln("Error: --auto-update requires true or false.");
				result.shouldQuit = true;
				return result;
			}
			result.autoUpdate = autoVal == "true" || autoVal == "1" || autoVal == "yes";
			break;

		case "--install", "-i":
			result.mode = AppMode.Install;
			result.appImage = new AppImage(takeNext());
			if (!checkAppImagePath(result.appImage)) {
				result.shouldQuit = true;
				return result;
			}
			break;

		case "--uninstall", "-u":
			result.mode = AppMode.Uninstall;
			fillTargetFromArg(result, takeNext());
			break;

		case "--update":
			result.mode = AppMode.Update;
			fillTargetFromArg(result, takeNext());
			break;

		default:
			if (argument.startsWith("-")) {
				writeln("Unknown option: ", argument);
				result.shouldQuit = true;
				return result;
			}
			// No mode was given so we check the file to figure out what to do
			result.appImage = new AppImage(argument);
			if (!checkAppImagePath(result.appImage)) {
				writeln("Switching to Manage mode");
				result.mode = AppMode.Manage;
				break;
			}
			writeln("File looks valid, switching to Install mode");
			result.mode = AppMode.Install;
			break;
		}
	}

	if (result.mode == AppMode.BackgroundUpdate && result.checkIntervalHours < 1) {
		writeln("Error: --background-update requires --check-interval <hours>.");
		result.shouldQuit = true;
	}

	return result;
}
