module appimage.install;

import core.atomic : atomicStore;
import std.algorithm : canFind;
import std.array : join;
import std.exception : collectException;
import std.file;
import std.path : buildPath, baseName, dirName;
import std.process : execute, spawnProcess, Config, ProcessException, Pid, environment;
import std.stdio : writeln;
import std.string : startsWith, strip, split, indexOf, splitLines;

import appimage : AppImage, pathIsSymlink;
import appimage.icon : installIconFromDir, installIconFromCachedData;
import appimage.manifest : Manifest;
import types : InstallMethod;
import apputils : xdgDataHome, installBaseDir;
import constants : APPLICATIONS_SUBDIR;
import constants : MANIFEST_FILE_NAME, DESKTOP_SUFFIX, APPIMAGE_EXEC_MODE;
import lang : translateIn, availableLangs;
import update.common : normalizeUpdateInfoPattern;

// Progress bar values used during installation
private enum Progress {
	afterInit = 0.1,
	afterCopy = 0.4,
	afterExtract = 0.5,
	afterMove = 0.6,
	afterIcon = 0.7,
	afterDesktop = 0.9,
	complete = 1.0
}

// Update and Uninstall actions are excluded since those always use the installer binary
// All other Exec= lines are rebuilt so no stale launcher path can be left behind
public void reapplyPortableExec(
	string desktopPath,
	string appDirectory,
	string sanitizedName,
	InstallMethod method,
	bool portableHome,
	bool portableConfig) {
	if (!exists(desktopPath))
		return;
	string launcherPath = (method == InstallMethod.Extracted)
		? buildPath(appDirectory, "AppRun") : buildPath(appDirectory, sanitizedName ~ ".AppImage");
	string raw;
	try {
		raw = readText(desktopPath);
	} catch (FileException) {
		return;
	}
	bool inExecSection = false;
	string[] result;
	foreach (line; raw.splitLines()) {
		string stripped = line.strip();
		if (stripped == "[Desktop Entry]") {
			inExecSection = true;
		} else if (stripped.length && stripped[0] == '[') {
			inExecSection = stripped.startsWith("[Desktop Action ")
				&& stripped != "[Desktop Action Update]"
				&& stripped != "[Desktop Action Uninstall]";
		}
		if (inExecSection && stripped.startsWith("Exec=")) {
			string newLine;
			if (portableHome || portableConfig) {
				newLine = "Exec=" ~ buildPortableEnvPrefix(
					appDirectory, portableHome, portableConfig)
					~ " " ~ launcherPath;
			} else if (method == InstallMethod.Extracted) {
				newLine = "Exec=env APPDIR=" ~ appDirectory ~ " " ~ launcherPath;
			} else {
				newLine = "Exec=" ~ launcherPath;
			}
			result ~= newLine;
			continue;
		}
		result ~= line;
	}
	try {
		write(desktopPath, result.join("\n") ~ "\n");
	} catch (FileException error) {
		writeln("reapplyPortableExec: failed: ", error.msg);
	}
}

// The launcher path changes when the install mode does so all exec references need updating
// Only lines containing the old path are touched to avoid corrupting other Exec= entries
public void rewriteDesktopForModeSwitch(
	string desktopPath,
	string appDirectory,
	string sanitizedName,
	InstallMethod oldMethod,
	InstallMethod newMethod,
	bool portableHome,
	bool portableConfig) {
	if (!exists(desktopPath))
		return;
	string oldLauncher = (oldMethod == InstallMethod.Extracted)
		? buildPath(appDirectory, "AppRun") : buildPath(appDirectory, sanitizedName ~ ".AppImage");
	string newLauncher = (newMethod == InstallMethod.Extracted)
		? buildPath(appDirectory, "AppRun") : buildPath(appDirectory, sanitizedName ~ ".AppImage");
	string raw;
	try {
		raw = readText(desktopPath);
	} catch (FileException) {
		return;
	}
	bool changed = false;
	bool inDesktopEntry = false;
	string[] result;
	foreach (line; raw.splitLines()) {
		string stripped = line.strip();
		if (stripped == "[Desktop Entry]")
			inDesktopEntry = true;
		else if (stripped.length > 0 && stripped[0] == '[')
			inDesktopEntry = false;
		if (inDesktopEntry && stripped.startsWith("TryExec=")) {
			result ~= "TryExec=" ~ newLauncher;
			changed = true;
			continue;
		}
		if (!stripped.startsWith("Exec=") || line.indexOf(oldLauncher) < 0) {
			result ~= line;
			continue;
		}
		auto launcherPos = line.indexOf(oldLauncher);
		auto launcherEnd = launcherPos + oldLauncher.length;
		string trailingArgs = launcherEnd < line.length ? line[launcherEnd .. $] : "";
		string newLine;
		if (portableHome || portableConfig) {
			newLine = "Exec=" ~ buildPortableEnvPrefix(
				appDirectory, portableHome, portableConfig)
				~ " " ~ newLauncher ~ trailingArgs;
		} else if (newMethod == InstallMethod.Extracted) {
			newLine = "Exec=env APPDIR=" ~ appDirectory ~ " " ~ newLauncher ~ trailingArgs;
		} else {
			newLine = "Exec=" ~ newLauncher ~ trailingArgs;
		}
		result ~= newLine;
		changed = true;
	}
	if (!changed) {
		writeln("rewriteDesktopForModeSwitch: no match in ", desktopPath);
		return;
	}
	try {
		write(desktopPath, result.join("\n") ~ "\n");
	} catch (FileException error) {
		writeln("rewriteDesktopForModeSwitch: write failed: ", error.msg);
	}
}

// Returns the releaseVersion from an existing install manifest, or "" if not installed
public string readInstalledVersion(AppImage appImage) {
	string path = Manifest.pathFor(
		buildPath(installBaseDir(), appImage.sanitizedName));
	auto loadedManifest = Manifest.load(path);
	return loadedManifest !is null ? loadedManifest.releaseVersion : "";
}

// Build a manifest from an AppImage and save it to manifestPath
public void writeManifest(AppImage appImage, string manifestPath) {
	auto installedAppManifest = new Manifest;
	installedAppManifest.appName = appImage.appName;
	installedAppManifest.appGenericName = appImage.appGenericName;
	installedAppManifest.appComment = appImage.appComment;
	installedAppManifest.releaseVersion = appImage.releaseVersion;
	installedAppManifest.sanitizedName = appImage.sanitizedName;
	installedAppManifest.originalSourceFile = appImage.filePath;
	installedAppManifest.sourceFileName = appImage.fileName;
	installedAppManifest.sourceFileSize = appImage.fileSize;
	installedAppManifest.sourceFileModified = appImage.fileModified;
	installedAppManifest.sourceFileHash = appImage.fileHash;
	installedAppManifest.appImageType = appImage.appImageType;
	installedAppManifest.architecture = appImage.architecture;
	installedAppManifest.updateInfo = normalizeUpdateInfoPattern(
		appImage.pendingUpdateInfo.length > 0
			? appImage.pendingUpdateInfo : appImage.updateInfo);
	installedAppManifest.installedIconName = appImage.installedIconName;
	installedAppManifest.appDirectory = appImage.installedAppDirectory;
	installedAppManifest.desktopSymlink =
		appImage.installedDesktopSymlinkPath;
	installedAppManifest.installMethod = appImage.installMethod;
	installedAppManifest.portableHome = appImage.portableHome;
	installedAppManifest.portableConfig = appImage.portableConfig;
	installedAppManifest.saveTo(manifestPath);
}

// Ensures Update and Uninstall entries are present in the desktop Action value
private string buildActionsValue(string existing, bool hasUpdate, bool hasUninstall) {
	if (hasUpdate && hasUninstall)
		return existing;
	string result = existing;
	if (result.length && result[$ - 1] != ';')
		result ~= ";";
	if (!hasUpdate)
		result ~= "Update;";
	if (!hasUninstall)
		result ~= "Uninstall;";
	return result;
}

// Both install modes keep portable dirs in the same location inside the metadata directory
public string portableHomeDir(string appDirectory) {
	return buildPath(appDirectory, APPLICATIONS_SUBDIR, "portable.home");
}

public string portableConfigDir(string appDirectory) {
	return buildPath(appDirectory, APPLICATIONS_SUBDIR, "portable.config");
}

// Spawns an installed app with the environment the install method requires
public Pid launchInstalledApp(string launchPath, string appDirectory,
	InstallMethod method, bool portableHome, bool portableConfig) {
	bool needsEnv = portableHome || portableConfig
		|| method == InstallMethod.Extracted;
	if (!needsEnv)
		return spawnProcess([launchPath]);
	string[string] env = environment.toAA();
	if (method == InstallMethod.Extracted)
		env["APPDIR"] = appDirectory;
	if (portableHome) {
		string homeDir = portableHomeDir(appDirectory);
		try {
			mkdirRecurse(homeDir);
		} catch (FileException) {
		}
		env["HOME"] = homeDir;
		env["XDG_DATA_HOME"] = homeDir ~ "/.local/share";
		env["XDG_CACHE_HOME"] = homeDir ~ "/.cache";
		env["XDG_STATE_HOME"] = homeDir ~ "/.local/state";
	}
	if (portableConfig) {
		string cfgDir = portableConfigDir(appDirectory);
		try {
			mkdirRecurse(cfgDir);
		} catch (FileException) {
		}
		env["XDG_CONFIG_HOME"] = cfgDir;
	}
	return spawnProcess([launchPath], env);
}

// Covers HOME and all XDG dirs that session env may already have set
private string buildPortableEnvPrefix(
	string appDirectory, bool portableHome, bool portableConfig) {
	string prefix = "env";
	if (portableHome) {
		string portableHomePath = portableHomeDir(appDirectory);
		prefix ~= " HOME=" ~ portableHomePath;
		prefix ~= " XDG_DATA_HOME=" ~ portableHomePath ~ "/.local/share";
		prefix ~= " XDG_CACHE_HOME=" ~ portableHomePath ~ "/.cache";
		prefix ~= " XDG_STATE_HOME=" ~ portableHomePath ~ "/.local/state";
	}
	if (portableConfig)
		prefix ~= " XDG_CONFIG_HOME=" ~ portableConfigDir(appDirectory);
	return prefix;
}

// Removes everything under appDir except the metadata subdirectory
// Called when switching modes so the manifest and portable directories are not touched
public void clearAppDirExceptMeta(string appDir) {
	foreach (entry; dirEntries(appDir, SpanMode.shallow)) {
		if (baseName(entry.name) == APPLICATIONS_SUBDIR)
			continue;
		try {
			if (isSymlink(entry.name))
				std.file.remove(entry.name);
			else if (entry.isDir)
				rmdirRecurse(entry.name);
			else
				std.file.remove(entry.name);
		} catch (FileException error) {
			writeln("clearAppDirExceptMeta: skipped ", entry.name, ": ", error.msg);
		}
	}
}

public void writeDesktopFile(
	AppImage appImage, string desktopFilePath, string appExtractDir,
	string appRunPath) {
	// Both modes store portable dirs inside the metadata directory
	string baseDir = appExtractDir.length ? appExtractDir : dirName(appRunPath);
	string portableHomePath = appImage.portableHome ? portableHomeDir(baseDir) : "";
	string portableConfigPath = appImage.portableConfig ? portableConfigDir(baseDir) : "";
	string[] outputLines;
	// True while parsing [Desktop Entry], needed for Icon= and TryExec= rewrites
	bool inDesktopEntry = false;
	// True inside any section that needs Exec= rewritten to use AppRun
	bool inExecSection = false;
	// Tracks whether we already rewrote the Actions= key
	bool actionsRewritten = false;

	foreach (line; appImage.desktopFileLines) {
		string stripped = line.strip();

		if (stripped == "[Desktop Entry]") {
			inDesktopEntry = true;
			inExecSection = true;
		} else if (stripped.length && stripped[0] == '[' && stripped[$ - 1] == ']') {
			// Once [Desktop Entry] ends, inject Actions= if it was absent
			if (inDesktopEntry && !actionsRewritten) {
				outputLines ~= "Actions=Update;Uninstall;";
				actionsRewritten = true;
			}
			inDesktopEntry = false;
			// Rewrite Exec= for all app Desktop Actions but not for
			// [Desktop Action Update] and [Desktop Action Uninstall] which we append ourselves
			inExecSection = stripped.startsWith("[Desktop Action ") && stripped != "[Desktop Action Update]" &&
				stripped != "[Desktop Action Uninstall]";
		}

		if (inExecSection && stripped.startsWith("Exec=")) {
			// Replace the executable token with the correct launcher, keeping trailing args
			string afterEquals = stripped[5 .. $];
			auto spaceIndex = afterEquals.indexOf(' ');
			string trailingArgs = (spaceIndex != -1) ? afterEquals[spaceIndex .. $] : "";
			if (portableHomePath.length || portableConfigPath.length) {
				outputLines ~= "Exec=" ~ buildPortableEnvPrefix(
					baseDir, appImage.portableHome, appImage.portableConfig)
					~ " " ~ appRunPath ~ trailingArgs;
			} else if (appImage.installMethod == InstallMethod.Extracted) {
				// Explicitly set APPDIR so custom AppRun scripts that detect it via $1 don't break
				outputLines ~= "Exec=env APPDIR=" ~ appExtractDir ~ " " ~ appRunPath ~ trailingArgs;
			} else {
				outputLines ~= "Exec=" ~ appRunPath ~ trailingArgs;
			}
			continue;
		}

		if (inDesktopEntry) {
			if (stripped.startsWith("TryExec=")) {
				outputLines ~= "TryExec=" ~ appRunPath;
				continue;
			}
			if (stripped.startsWith("Icon=") && appImage.installedIconName.length) {
				outputLines ~= "Icon=" ~ appImage.installedIconName;
				continue;
			}
			if (stripped.startsWith("Actions=")) {
				// Ensure both Update and Uninstall are listed, avoid duplicates on reinstall
				string existing = stripped[8 .. $].strip();
				auto tokens = existing.split(";");
				bool hasUpdate = tokens.canFind("Update");
				bool hasUninstall = tokens.canFind("Uninstall");
				outputLines ~= "Actions="
					~ buildActionsValue(existing, hasUpdate, hasUninstall);
				actionsRewritten = true;
				continue;
			}
		}

		outputLines ~= line;
	}

	// If [Desktop Entry] was the last (or only) section and Actions= never appeared
	if (inDesktopEntry && !actionsRewritten)
		outputLines ~= "Actions=Update;Uninstall;";

	// Append update and uninstall desktop actions
	// Reference the desktop file path inside the app directory so the manager can find it
	outputLines ~= "";
	outputLines ~= "[Desktop Action Update]";
	outputLines ~= "Name="
		~ translateIn("en", "desktop.action.update", appImage.appName);
	foreach (locale; availableLangs())
		if (locale != "en")
			outputLines ~= "Name[" ~ locale ~ "]="
				~ translateIn(
					locale, "desktop.action.update", appImage.appName);
	outputLines ~= "Exec=" ~ thisExePath() ~ " --update " ~ desktopFilePath;
	outputLines ~= "";
	outputLines ~= "[Desktop Action Uninstall]";
	outputLines ~= "Name="
		~ translateIn("en", "desktop.action.uninstall", appImage.appName);
	foreach (locale; availableLangs())
		if (locale != "en")
			outputLines ~= "Name[" ~ locale ~ "]="
				~ translateIn(
					locale, "desktop.action.uninstall", appImage.appName);
	outputLines ~= "Exec=" ~ thisExePath() ~ " --uninstall " ~ desktopFilePath;

	try {
		write(desktopFilePath, outputLines.join("\n") ~ "\n");
		writeln("Desktop file written: ", desktopFilePath);
	} catch (FileException error) {
		writeln("Failed to write desktop file: ", error.msg);
	}
}

// Copies the AppImage into the app directory and wires up desktop and icon integration
// The .AppImage file is the sole launch entry point No extraction needed and zsync updates still work
private bool doInstallAppImage(AppImage appImage) {
	string shareDir = xdgDataHome();
	string appimagesBaseDir = installBaseDir();
	string appDir = buildPath(appimagesBaseDir, appImage.sanitizedName);
	string metadataDir = buildPath(appDir, APPLICATIONS_SUBDIR);
	string appImageDest = buildPath(appDir, appImage.sanitizedName ~ ".AppImage");
	string desktopFileInsideAppDir = buildPath(
		metadataDir, appImage.sanitizedName ~ DESKTOP_SUFFIX);
	string desktopSymlinkDir = buildPath(shareDir, "applications");
	string desktopSymlinkPath = buildPath(desktopSymlinkDir,
		APPLICATIONS_SUBDIR ~ "." ~ appImage.sanitizedName ~ DESKTOP_SUFFIX);

	writeln("Installing AppImage to: ", appDir);

	if (pathIsSymlink(appDir)) {
		writeln("Removing symlink at install path: ", appDir);
		std.file.remove(appDir);
	} else if (exists(appDir)) {
		writeln("Removing existing installation: ", appDir);
		rmdirRecurse(appDir);
	}

	try {
		mkdirRecurse(appDir);
	} catch (FileException error) {
		writeln("Failed to create app directory: ", error.msg);
		return false;
	}

	atomicStore(appImage.installProgress, cast(double) Progress.afterInit);

	try {
		try {
			rename(appImage.filePath, appImageDest);
		} catch (FileException) {
			// Cross-device move, copy then remove original
			copy(appImage.filePath, appImageDest);
			std.file.remove(appImage.filePath);
		}
		setAttributes(appImageDest, APPIMAGE_EXEC_MODE);
		writeln("AppImage moved to: ", appImageDest);
	} catch (FileException error) {
		writeln("Failed to move AppImage: ", error.msg);
		return false;
	}
	appImage.appImageDestPath = appImageDest;

	atomicStore(appImage.installProgress, cast(double) Progress.afterCopy);

	installIconFromCachedData(appImage);

	atomicStore(appImage.installProgress, cast(double) Progress.afterIcon);

	try {
		mkdirRecurse(metadataDir);
	} catch (FileException error) {
		writeln("Failed to create metadata directory: ", error.msg);
		return false;
	}

	// Exec= points directly at the AppImage so appExtractDir is unused in this mode
	writeDesktopFile(appImage, desktopFileInsideAppDir, "", appImageDest);

	atomicStore(appImage.installProgress, cast(double) Progress.afterDesktop);

	try {
		mkdirRecurse(desktopSymlinkDir);
		if (exists(desktopSymlinkPath))
			std.file.remove(desktopSymlinkPath);
		symlink(desktopFileInsideAppDir, desktopSymlinkPath);
		writeln("Desktop symlink created: ", desktopSymlinkPath,
			" -> ", desktopFileInsideAppDir);
	} catch (FileException error) {
		writeln("Failed to create desktop symlink: ", error.msg);
		return false;
	}

	appImage.installedAppDirectory = appDir;
	appImage.installedDesktopSymlinkPath = desktopSymlinkPath;

	try {
		spawnProcess(["update-desktop-database", desktopSymlinkDir]);
		writeln("Desktop database update started: ", desktopSymlinkDir);
	} catch (ProcessException error) {
		writeln("update-desktop-database not available: ", error.msg);
	}

	writeManifest(appImage, buildPath(metadataDir, MANIFEST_FILE_NAME));
	atomicStore(appImage.installProgress, cast(double) Progress.complete);

	writeln("Installation complete");
	writeln("  App directory : ", appDir);
	writeln("  AppImage      : ", appImageDest);
	writeln("  Desktop file  : ", desktopFileInsideAppDir);
	writeln("  Desktop link  : ", desktopSymlinkPath);
	return true;
}

// Extracts the AppImage, wires AppRun as the launch entry point for faster startup
// Breaks zsync updates, only use when the user explicitly picks Extracted via Optimize
private bool doInstallExtracted(AppImage appImage) {
	string shareDir = xdgDataHome();
	string appimagesBaseDir = installBaseDir();
	string appExtractDir = buildPath(appimagesBaseDir, appImage.sanitizedName);
	// Our files go in a named subdir, deleting appExtractDir automatically removes all symlinks
	string metadataDir = buildPath(appExtractDir, APPLICATIONS_SUBDIR);
	string desktopFileInsideAppDir = buildPath(
		metadataDir, appImage.sanitizedName ~ DESKTOP_SUFFIX);
	string desktopSymlinkDir = buildPath(shareDir, "applications");
	string desktopSymlinkPath = buildPath(desktopSymlinkDir,
		APPLICATIONS_SUBDIR ~ "." ~ appImage.sanitizedName ~ DESKTOP_SUFFIX);

	writeln("Extracting AppImage to: ", appExtractDir);

	// pathIsSymlink() avoids throws on missing paths and catches dangling symlinks
	if (pathIsSymlink(appExtractDir)) {
		writeln("Removing symlink at install path: ", appExtractDir);
		std.file.remove(appExtractDir);
	} else if (exists(appExtractDir)) {
		writeln("Removing existing installation: ", appExtractDir);
		rmdirRecurse(appExtractDir);
	}

	try {
		mkdirRecurse(appimagesBaseDir);
	} catch (FileException error) {
		writeln("Failed to create directories: ", error.msg);
		return false;
	}

	atomicStore(appImage.installProgress, cast(double) Progress.afterInit);

	// AppImages extract to inconsistent root names (squashfs-root, AppDir, etc)
	// Staging inside appimagesBaseDir keeps it contained and ensures an atomic rename
	string stagingDir = buildPath(
		appimagesBaseDir, "." ~ appImage.sanitizedName ~ ".staging");
	if (exists(stagingDir) || pathIsSymlink(stagingDir))
		rmdirRecurse(stagingDir);
	try {
		mkdirRecurse(stagingDir);
	} catch (FileException error) {
		writeln("Failed to create staging directory: ", error.msg);
		return false;
	}
	scope (exit) {
		// Always clean up the staging dir, even on failure
		if (exists(stagingDir) || pathIsSymlink(stagingDir))
			collectException(rmdirRecurse(stagingDir));
	}

	setAttributes(appImage.filePath, APPIMAGE_EXEC_MODE);

	writeln("Running --appimage-extract in staging dir: ", stagingDir);
	auto extractResult = execute(
		[appImage.filePath, "--appimage-extract"],
		null, Config.none, size_t.max, stagingDir);

	if (extractResult.status != 0) {
		writeln(
			"Extraction failed (exit ", extractResult.status,
			"): ", extractResult.output);
		return false;
	}

	string realExtractRoot;
	foreach (entry; dirEntries(stagingDir, SpanMode.shallow)) {
		if (!isSymlink(entry.name) && entry.isDir) {
			realExtractRoot = entry.name;
			break;
		}
	}
	if (!realExtractRoot.length) {
		writeln("No extracted directory found inside staging dir: ", stagingDir);
		return false;
	}
	writeln("Extracted root: ", realExtractRoot);

	atomicStore(appImage.installProgress, cast(double) Progress.afterExtract);

	// Move extracted root to its final app directory
	try {
		rename(realExtractRoot, appExtractDir);
		writeln("Installed to: ", appExtractDir);
	} catch (FileException error) {
		writeln("Failed to rename extracted directory: ", error.msg);
		return false;
	}

	// Some AppImages ship a non-executable AppRun inside the squashfs
	string appRunPath = buildPath(appExtractDir, "AppRun");
	if (exists(appRunPath))
		setAttributes(appRunPath, APPIMAGE_EXEC_MODE);

	atomicStore(appImage.installProgress, cast(double) Progress.afterMove);

	installIconFromDir(appImage, appExtractDir);

	atomicStore(appImage.installProgress, cast(double) Progress.afterIcon);

	try {
		mkdirRecurse(metadataDir);
	} catch (FileException error) {
		writeln("Failed to create metadata directory: ", error.msg);
		return false;
	}

	// Stored inside the app dir so deleting it automatically removes the symlink in applications/
	writeDesktopFile(appImage, desktopFileInsideAppDir, appExtractDir, buildPath(
			appExtractDir, "AppRun"));

	atomicStore(appImage.installProgress, cast(double) Progress.afterDesktop);

	// Symlink .desktop into ~/.local/share/applications/
	try {
		mkdirRecurse(desktopSymlinkDir);
		if (exists(desktopSymlinkPath))
			std.file.remove(desktopSymlinkPath);
		symlink(desktopFileInsideAppDir, desktopSymlinkPath);
		writeln("Desktop symlink created: ", desktopSymlinkPath,
			" -> ", desktopFileInsideAppDir);
	} catch (FileException error) {
		writeln("Failed to create desktop symlink: ", error.msg);
		return false;
	}

	appImage.installedAppDirectory = appExtractDir;
	appImage.installedDesktopSymlinkPath = desktopSymlinkPath;

	// Rebuild MIME/app database so the DE sees the new desktop file immediately
	try {
		spawnProcess(["update-desktop-database", desktopSymlinkDir]);
		writeln("Desktop database update started: ", desktopSymlinkDir);
	} catch (ProcessException error) {
		writeln("update-desktop-database not available: ", error.msg);
	}

	writeManifest(appImage, buildPath(metadataDir, MANIFEST_FILE_NAME));

	// Move the original AppImage into the metadata dir so we always know where it lives
	string appImageInMeta = buildPath(
		metadataDir, appImage.sanitizedName ~ ".AppImage");
	try {
		try {
			rename(appImage.filePath, appImageInMeta);
		} catch (FileException) {
			// Cross-device move, copy then delete original
			copy(appImage.filePath, appImageInMeta);
			std.file.remove(appImage.filePath);
		}
		setAttributes(appImageInMeta, APPIMAGE_EXEC_MODE);
		writeln("AppImage moved to metadata dir: ", appImageInMeta);
	} catch (FileException error) {
		writeln("Warning: could not move AppImage to metadata dir: ", error.msg);
	}

	atomicStore(appImage.installProgress, cast(double) Progress.complete);

	writeln("Installation complete");
	writeln("  App directory : ", appExtractDir);
	writeln("  Desktop file  : ", desktopFileInsideAppDir);
	writeln("  Desktop link  : ", desktopSymlinkPath);
	return true;
}

// Installs the AppImage using the method specified in appImage.installMethod
public bool install(AppImage appImage) {
	if (appImage.installMethod == InstallMethod.Extracted)
		return doInstallExtracted(appImage);
	return doInstallAppImage(appImage);
}
