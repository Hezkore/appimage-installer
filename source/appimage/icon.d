module appimage.icon;

import std.file : exists, copy, dirEntries, isDir, mkdirRecurse, readLink,
	FileException, SpanMode, getAttributes, setAttributes;
import std.path : buildPath, baseName, buildNormalizedPath, dirName;
import std.path : extension, isAbsolute, stripExtension;
import std.process : spawnProcess, ProcessException;
import std.stdio : writeln;
import std.string : startsWith, strip, toLower;

import appimage : AppImage, pathIsSymlink;
import constants : APPLICATIONS_SUBDIR, SYSTEM_ICON_THEME_PATH,
	APPIMAGE_EXEC_MODE, APPIMAGE_FUSE_MOUNT_PREFIX;
import apputils : xdgDataHome;

// Hicolor theme subdirectory for rasterized icons (PNG, XPM)
private enum string ICON_DIR_PNG = "256x256";
// Hicolor theme subdirectory for vector icons
private enum string ICON_DIR_SVG = "scalable";
// Icon formats to search for, in priority order
private immutable string[] ICON_EXTENSIONS = [".svg", ".png", ".xpm"];

// Copies the best available icon from the extracted app directory into the hicolor theme
public void installIconFromDir(AppImage appImage, string extractDirectory) {
	import appimage : pathIsSymlink;

	string iconBaseName = appImage.defaultIconName.baseName.stripExtension;
	string hicolorBase = buildPath(xdgDataHome(), "icons", "hicolor");

	// .DirIcon is always present so resolve through symlinks to get the real extension
	string[] candidates;
	string dirIconPath = buildPath(extractDirectory, ".DirIcon");
	if (exists(dirIconPath)) {
		string resolved = dirIconPath;
		// Follow the symlink chain to reach the real file
		while (pathIsSymlink(resolved)) {
			string target = readLink(resolved);
			if (!isAbsolute(target))
				target = buildPath(resolved.dirName, target);
			resolved = buildNormalizedPath(target);
		}
		if (exists(resolved))
			candidates ~= resolved;
	}

	// Falls back to a named icon at app root then standard XDG locations
	foreach (extension; ICON_EXTENSIONS) {
		candidates ~= buildPath(extractDirectory, iconBaseName ~ extension);
		candidates ~= buildPath(extractDirectory, "usr", "share", "pixmaps", iconBaseName ~ extension);
	}

	foreach (candidate; candidates) {
		if (!exists(candidate))
			continue;

		string fileExtension = candidate.extension.toLower;
		if (fileExtension != ".svg"
			&& fileExtension != ".png" && fileExtension != ".xpm")
			continue;

		string sizeSubdirectory = (fileExtension == ".svg") ? ICON_DIR_SVG : ICON_DIR_PNG;
		string iconDestDir = buildPath(hicolorBase, sizeSubdirectory, "apps");

		try {
			mkdirRecurse(iconDestDir);
			string destPath = buildPath(iconDestDir, APPLICATIONS_SUBDIR ~ "." ~ appImage.sanitizedName ~ fileExtension);
			copy(candidate, destPath);
			appImage.installedIconName = APPLICATIONS_SUBDIR ~ "." ~ appImage.sanitizedName;
			writeln("Icon installed: ", destPath);
			updateIconCache(hicolorBase);
			return;
		} catch (FileException error) {
			writeln("Failed to install icon from ", candidate, ": ", error.msg);
		}
	}
	writeln("Could not install icon for: ", appImage.sanitizedName);
}

// Writes the icon cached during loadFullInfo() to hicolor without a second mount
public void installIconFromCachedData(AppImage appImage) {
	if (!appImage.cachedIconBytes.length || !appImage.cachedIconExtension.length) {
		writeln("No cached icon data, skipping icon install");
		return;
	}

	string hicolorBase = buildPath(xdgDataHome(), "icons", "hicolor");
	string sizeSubdirectory = (appImage.cachedIconExtension == ".svg") ? ICON_DIR_SVG : ICON_DIR_PNG;
	string iconDestDir = buildPath(hicolorBase, sizeSubdirectory, "apps");

	try {
		import std.file : write;

		mkdirRecurse(iconDestDir);
		string destPath = buildPath(iconDestDir,
			APPLICATIONS_SUBDIR ~ "." ~ appImage.sanitizedName ~ appImage.cachedIconExtension);
		write(destPath, appImage.cachedIconBytes);
		appImage.installedIconName = APPLICATIONS_SUBDIR ~ "." ~ appImage.sanitizedName;
		writeln("Icon installed from cache: ", destPath);
		updateIconCache(hicolorBase);
	} catch (FileException error) {
		writeln("Failed to install icon from cache: ", error.msg);
	}
}

// Rebuilds the icon lookup cache in the background so it never blocks install time
public void updateIconCache(string hicolorBase) {
	immutable string systemIndexTheme = SYSTEM_ICON_THEME_PATH;
	string userIndexTheme = buildPath(hicolorBase, "index.theme");

	if (!exists(userIndexTheme) && exists(systemIndexTheme)) {
		try {
			copy(systemIndexTheme, userIndexTheme);
			writeln("Copied index.theme to: ", userIndexTheme);
		} catch (FileException error) {
			writeln("Could not copy index.theme: ", error.msg);
		}
	}

	try {
		spawnProcess([
			"gtk-update-icon-cache", "--force", "--quiet",
			"--ignore-theme-index", hicolorBase
		]);
		writeln("Icon cache update started: ", hicolorBase);
	} catch (ProcessException error) {
		writeln("gtk-update-icon-cache not available: ", error.msg);
	}
}

public string[] findInstalledIconPaths(string installedIconName) {
	if (!installedIconName.length)
		return [];
	string iconsBase = buildPath(xdgDataHome(), "icons", "hicolor");
	if (!exists(iconsBase) || !isDir(iconsBase))
		return [];
	string[] paths;
	try {
		foreach (entry; dirEntries(iconsBase, SpanMode.depth, false)) {
			string fileName = baseName(entry.name);
			if (fileName.length >= installedIconName.length
				&& fileName[0 .. installedIconName.length] == installedIconName)
				paths ~= entry.name;
		}
	} catch (FileException error) {
		writeln("findInstalledIconPaths: ", error.msg);
	}
	return paths;
}

// Reads up to 16 bytes from path and returns ".png" or ".svg" based on magic bytes
// Returns "" when the format cannot be determined
private string inferIconExtension(string path) {
	try {
		import std.file : read;

		ubyte[] header = cast(ubyte[]) read(path, 16);
		if (header.length >= 4
			&& header[0] == 0x89 && header[1] == 'P'
			&& header[2] == 'N' && header[3] == 'G')
			return ".png";
		// SVG is XML text starting with '<' or a UTF-8 BOM followed by '<'
		if (header.length >= 1 && header[0] == '<')
			return ".svg";
		if (header.length >= 4
			&& header[0] == 0xEF && header[1] == 0xBB
			&& header[2] == 0xBF && header[3] == '<')
			return ".svg";
	} catch (FileException) {
	}
	return "";
}

// Reinstalls the icon for a previously extracted app from its app directory
// Used when the theme icon is missing but the extracted AppDir is still on disk
public bool reinstallIconFromExtractedDir(
	string appDirectory, string sanitizedName,
	out string iconName, out string iconFilePath
) {
	string hicolorBase = buildPath(xdgDataHome(), "icons", "hicolor");

	string[] candidates;
	string dirIconPath = buildPath(appDirectory, ".DirIcon");
	if (exists(dirIconPath)) {
		string resolved = dirIconPath;
		while (pathIsSymlink(resolved)) {
			string target = readLink(resolved);
			if (!isAbsolute(target))
				target = buildPath(resolved.dirName, target);
			resolved = buildNormalizedPath(target);
		}
		if (exists(resolved))
			candidates ~= resolved;
	}
	foreach (ext; ICON_EXTENSIONS) {
		candidates ~= buildPath(appDirectory, sanitizedName ~ ext);
		candidates ~= buildPath(
			appDirectory, "usr", "share", "pixmaps", sanitizedName ~ ext);
	}

	foreach (candidate; candidates) {
		if (!exists(candidate))
			continue;
		string fileExt = candidate.extension.toLower;
		if (fileExt != ".svg" && fileExt != ".png" && fileExt != ".xpm")
			fileExt = inferIconExtension(candidate);
		if (fileExt != ".svg" && fileExt != ".png" && fileExt != ".xpm")
			continue;
		string sizeSubdir = (fileExt == ".svg") ? ICON_DIR_SVG : ICON_DIR_PNG;
		string destDir = buildPath(hicolorBase, sizeSubdir, "apps");
		try {
			mkdirRecurse(destDir);
			string destPath = buildPath(
				destDir, APPLICATIONS_SUBDIR ~ "." ~ sanitizedName ~ fileExt);
			copy(candidate, destPath);
			iconName = APPLICATIONS_SUBDIR ~ "." ~ sanitizedName;
			iconFilePath = destPath;
			writeln("icon: reinstalled from dir: ", destPath);
			updateIconCache(hicolorBase);
			return true;
		} catch (FileException error) {
			writeln("icon: reinstall from dir failed for ", candidate, ": ", error.msg);
		}
	}
	writeln("icon: could not reinstall icon for ", sanitizedName, " from dir");
	return false;
}

// Mounts the AppImage, reads .DirIcon, and writes it into the hicolor theme
// Blocks the caller while the AppImage is mounted (typically under one second)
public bool reinstallIconFromAppImageFile(
	string appImagePath, string sanitizedName,
	out string iconName, out string iconFilePath
) {
	import std.process : pipeProcess, kill, wait;
	import core.thread : Thread;
	import core.time : dur;

	enum int MOUNT_RETRY_MAX = 100;
	enum int MOUNT_RETRY_MS = 100;

	if (!exists(appImagePath)) {
		writeln("icon: AppImage not found: ", appImagePath);
		return false;
	}

	auto savedAttrs = getAttributes(appImagePath);
	setAttributes(appImagePath, APPIMAGE_EXEC_MODE);

	auto mountProcess = pipeProcess([appImagePath, "--appimage-mount"]);
	scope (exit) {
		kill(mountProcess.pid);
		wait(mountProcess.pid);
		writeln("icon: AppImage unmounted");
	}

	setAttributes(appImagePath, savedAttrs);

	string mountPoint;
	foreach (line; mountProcess.stdout.byLine()) {
		string trimmed = (cast(string) line).strip();
		if (trimmed.startsWith(APPIMAGE_FUSE_MOUNT_PREFIX)) {
			mountPoint = trimmed;
			break;
		}
	}

	if (!mountPoint.length) {
		writeln("icon: no mount point from ", appImagePath);
		return false;
	}

	uint retries = MOUNT_RETRY_MAX;
	while (!exists(mountPoint)) {
		if (retries-- == 0) {
			writeln("icon: mount point never appeared: ", mountPoint);
			return false;
		}
		Thread.sleep(dur!"msecs"(MOUNT_RETRY_MS));
	}

	string rootDir = buildPath(mountPoint, "squashfs-root");
	if (!exists(rootDir))
		rootDir = mountPoint;

	string dirIconPath = buildPath(rootDir, ".DirIcon");
	string resolved = dirIconPath;
	while (pathIsSymlink(resolved)) {
		string target = readLink(resolved);
		if (!isAbsolute(target))
			target = buildPath(resolved.dirName, target);
		resolved = buildNormalizedPath(target);
	}

	if (!exists(resolved)) {
		writeln("icon: .DirIcon not found in ", rootDir);
		return false;
	}

	string fileExt = resolved.extension.toLower;
	if (fileExt != ".svg" && fileExt != ".png" && fileExt != ".xpm")
		fileExt = inferIconExtension(resolved);
	if (fileExt != ".svg" && fileExt != ".png" && fileExt != ".xpm") {
		writeln("icon: unsupported icon format ", fileExt, " in ", resolved);
		return false;
	}

	ubyte[] bytes;
	try {
		import std.file : read;

		bytes = cast(ubyte[]) read(resolved);
	} catch (FileException error) {
		writeln("icon: failed to read .DirIcon: ", error.msg);
		return false;
	}

	string hicolorBase = buildPath(xdgDataHome(), "icons", "hicolor");
	string sizeSubdir = (fileExt == ".svg") ? ICON_DIR_SVG : ICON_DIR_PNG;
	string destDir = buildPath(hicolorBase, sizeSubdir, "apps");
	try {
		import std.file : write;

		mkdirRecurse(destDir);
		string destPath = buildPath(
			destDir, APPLICATIONS_SUBDIR ~ "." ~ sanitizedName ~ fileExt);
		write(destPath, bytes);
		iconName = APPLICATIONS_SUBDIR ~ "." ~ sanitizedName;
		iconFilePath = destPath;
		writeln("icon: reinstalled from AppImage: ", destPath);
		updateIconCache(hicolorBase);
		return true;
	} catch (FileException error) {
		writeln("icon: failed to write icon: ", error.msg);
		return false;
	}
}
