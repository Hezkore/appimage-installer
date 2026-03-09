module windows.manage.scan;

import std.ascii : toUpper;
import std.file : exists, isDir, isSymlink, dirEntries, SpanMode, FileException,
	rmdirRecurse, getAttributes;
import std.conv : octal;
import std.path : buildPath, baseName;
import std.stdio : writeln;
import std.string : replace;

import gtk.box : Box;
import gtk.image : Image;
import gtk.label : Label;
import gtk.list_box : ListBox;
import gtk.list_box_row : ListBoxRow;
import gtk.types : Align, Orientation, SelectionMode;

import types : InstallMethod;
import constants : APPLICATIONS_SUBDIR, MANIFEST_FILE_NAME, UPDATE_SUBDIR;
import constants : DESKTOP_PREFIX, DESKTOP_SUFFIX, INSTALLER_DESKTOP_FILE;
import constants : APPIMAGE_EXEC_MODE;
import appimage.manifest : Manifest;
import apputils : xdgDataHome, installBaseDir, readDesktopFieldLocalized;
import lang : L, activeLangCode;

// Pixel measurements for the empty state box shown when no apps are installed
private enum Layout {
	emptyIconSize = 64,
	titleTopMargin = 12,
	hintTopMargin = 4,
	addListTopMargin = 16,
	addCardPadding = 10,
	addCardIconSize = 16,
	addCardIconMargin = 10,
}

private enum double EMPTY_ICON_OPACITY = 0.35;

// Manifest metadata for one installed AppImage
public struct InstalledApp {
	string appName;
	string appComment;
	string releaseVersion;
	string sanitizedName;
	string appDirectory;
	string installedIconName;
	string desktopSymlink;
	string updateInfo;
	InstallMethod installMethod = InstallMethod.AppImage;
	ubyte appImageType; // 1 = ISO 9660 + ELF (legacy), 2 = ELF + SquashFS
	string[] issues; // Problems found by checkSanity(), shown as warning rows
	bool isOrphan; // No manifest, found only via a stale desktop file
	bool updateAvailable;
}

// Metadata for one installed app loaded from its manifest, or scraped from a stale desktop file
// Underscores become spaces then each word is title-cased
package string cleanOrphanName(string raw) {
	string result = raw
		.replace("_-_", " - ")
		.replace("_", " ");
	bool capitalizeNext = true;
	char[] chars = result.dup;
	foreach (ref character; chars) {
		if (character == ' ') {
			capitalizeNext = true;
		} else if (capitalizeNext) {
			character = cast(char) toUpper(character);
			capitalizeNext = false;
		}
	}
	return cast(string) chars;
}

// Reads one key= line from a .desktop file with locale fallback
// Delegates to readDesktopFieldLocalized passing the active language code
package string tryReadDesktopFieldLocalized(string path, string key) {
	return readDesktopFieldLocalized(path, key, activeLangCode());
}

// Returns true when the manifest file still exists in the app directory
package bool isStillInstalled(InstalledApp entry) {
	string manifestPath = buildPath(entry.appDirectory, APPLICATIONS_SUBDIR, MANIFEST_FILE_NAME);
	return exists(manifestPath);
}

// Checks an installed app entry and returns any problems found as readable strings
package string[] checkSanity(InstalledApp entry) {
	string[] issues;
	if (!exists(entry.appDirectory) || !isDir(entry.appDirectory)) {
		issues ~= L("manage.issue.dir_missing");
		return issues;
	}
	if (entry.installMethod == InstallMethod.AppImage) {
		string appImagePath = buildPath(entry.appDirectory, entry.sanitizedName ~ ".AppImage");
		if (!exists(appImagePath))
			issues ~= L("manage.issue.appimage_missing");
	} else {
		string appRunPath = buildPath(entry.appDirectory, "AppRun");
		if (!exists(appRunPath)) {
			issues ~= L("manage.issue.apprun_missing");
		} else {
			uint attrs;
			try {
				attrs = getAttributes(appRunPath);
			} catch (FileException) {
			}
			if ((attrs & octal!111) == 0)
				issues ~= L("manage.issue.apprun_not_executable");
		}
	}
	try {
		if (!isSymlink(entry.desktopSymlink) || !exists(entry.desktopSymlink))
			issues ~= L("manage.issue.desktop_broken");
	} catch (FileException error) {
		issues ~= L("manage.issue.desktop_broken");
	}
	if (entry.installedIconName.length > 0) {
		string hicolorBase = buildPath(xdgDataHome(), "icons", "hicolor");
		bool iconExists =
			exists(buildPath(hicolorBase, "scalable", "apps",
					entry.installedIconName ~ ".svg"))
			|| exists(buildPath(hicolorBase, "256x256", "apps",
					entry.installedIconName ~ ".png"))
			|| exists(buildPath(hicolorBase, "256x256", "apps",
					entry.installedIconName ~ ".xpm"));
		if (!iconExists) {
			bool sourceAvailable = (entry.installMethod == InstallMethod.AppImage)
				? exists(buildPath(entry.appDirectory, entry.sanitizedName ~ ".AppImage")) : exists(
					entry.appDirectory);
			if (sourceAvailable)
				issues ~= L("manage.issue.icon_broken");
		}
	}
	return issues;
}

// Scans the appimages directory and applications directory, builds the full app list
public InstalledApp[] scanInstalledApps() {
	InstalledApp[] installedApps;

	string appimagesDir = installBaseDir();

	if (exists(appimagesDir) && isDir(appimagesDir)) {
		foreach (dirEntry; dirEntries(appimagesDir, SpanMode.shallow)) {
			try {
				if (!dirEntry.isDir)
					continue;
				string manifestPath = buildPath(dirEntry.name, APPLICATIONS_SUBDIR, MANIFEST_FILE_NAME);
				if (!exists(manifestPath))
					continue;

				auto installedAppManifest = Manifest.load(manifestPath);
				if (installedAppManifest is null)
					continue;

				InstalledApp entry;
				entry.appName = installedAppManifest.appName.length
					? installedAppManifest.appName : dirEntry.name.baseName;
				entry.appComment = installedAppManifest.appComment;
				entry.releaseVersion = installedAppManifest.releaseVersion;
				entry.sanitizedName = installedAppManifest.sanitizedName;
				entry.appDirectory = installedAppManifest.appDirectory.length
					? installedAppManifest.appDirectory : dirEntry.name;
				entry.installedIconName = installedAppManifest.installedIconName;
				entry.desktopSymlink = installedAppManifest.desktopSymlink;
				entry.updateInfo = installedAppManifest.updateInfo;
				entry.installMethod = installedAppManifest.installMethod;
				entry.appImageType = installedAppManifest.appImageType;
				entry.updateAvailable = installedAppManifest.updateAvailable;

				// Override name/comment with localized values from the installed desktop file
				if (entry.desktopSymlink.length) {
					string localName = tryReadDesktopFieldLocalized(
						entry.desktopSymlink, "Name");
					if (localName.length)
						entry.appName = localName;
					string localComment = tryReadDesktopFieldLocalized(
						entry.desktopSymlink, "Comment");
					if (localComment.length)
						entry.appComment = localComment;
				}
				entry.issues = checkSanity(entry);

				// Remove leftover download files from interrupted or completed updates
				string updateStagingDir = buildPath(
					dirEntry.name, APPLICATIONS_SUBDIR, UPDATE_SUBDIR);
				if (exists(updateStagingDir) && isDir(updateStagingDir))
					rmdirRecurse(updateStagingDir);

				installedApps ~= entry;
				writeln("Loaded: ", entry.appName, " v", entry.releaseVersion);
			} catch (FileException error) {
				writeln("Skipping ", dirEntry.name.baseName, ": ", error.msg);
			}
		}
	}

	// Scan applications/ for com.hezkore.appimage.*.desktop files with no matching manifest
	// These are stale leftovers from a manual app directory deletion
	bool[string] knownSymlinks;
	foreach (ref installedApp; installedApps)
		if (installedApp.desktopSymlink.length)
			knownSymlinks[installedApp.desktopSymlink] = true;

	string applicationsDir = buildPath(xdgDataHome(), "applications");
	if (!exists(applicationsDir) || !isDir(applicationsDir))
		return installedApps;

	// followSymlink=false so broken symlinks show up as entries instead of throwing
	foreach (dirEntry; dirEntries(applicationsDir, SpanMode.shallow, false)) {
		try {
			string name = dirEntry.name.baseName;
			if (name.length <= DESKTOP_PREFIX.length + DESKTOP_SUFFIX.length)
				continue;
			if (name[0 .. DESKTOP_PREFIX.length] != DESKTOP_PREFIX)
				continue;
			if (name[$ - DESKTOP_SUFFIX.length .. $] != DESKTOP_SUFFIX)
				continue;
			if (name == INSTALLER_DESKTOP_FILE)
				continue;
			if (dirEntry.name in knownSymlinks)
				continue;

			string iconName = name[0 .. $ - DESKTOP_SUFFIX.length];
			bool readable = exists(dirEntry.name);
			string displayName = readable ? tryReadDesktopFieldLocalized(dirEntry.name, "Name") : "";
			if (!displayName.length) {
				string raw = name[DESKTOP_PREFIX.length .. $ - DESKTOP_SUFFIX.length];
				displayName = cleanOrphanName(raw);
			}

			InstalledApp orphan;
			orphan.appName = displayName;
			orphan.appComment = readable
				? tryReadDesktopFieldLocalized(dirEntry.name, "Comment") : "";
			orphan.installedIconName = iconName;
			orphan.desktopSymlink = dirEntry.name;
			orphan.isOrphan = true;

			installedApps ~= orphan;
			writeln("Orphan: ", orphan.appName, " (", name, ")");
		} catch (FileException error) {
			writeln("Skipping orphan ", dirEntry.name.baseName, ": ", error.msg);
		}
	}

	return installedApps;
}

// Builds the "No AppImages installed" empty state box shown when the list is empty
package Box buildEmptyBox(void delegate() onInstall) {
	auto emptyIcon = Image.newFromIconName("application-x-executable");
	emptyIcon.pixelSize = Layout.emptyIconSize;
	emptyIcon.setHalign(Align.Center);
	emptyIcon.setOpacity(EMPTY_ICON_OPACITY);

	auto emptyTitle = new Label(L("manage.empty.title"));
	emptyTitle.addCssClass("title-3");
	emptyTitle.setHalign(Align.Center);
	emptyTitle.setMarginTop(Layout.titleTopMargin);

	auto emptyHint = new Label(L("manage.empty.hint"));
	emptyHint.addCssClass("dim-label");
	emptyHint.setHalign(Align.Center);
	emptyHint.setMarginTop(Layout.hintTopMargin);

	auto addRow = new ListBoxRow;
	auto addRowInner = new Box(Orientation.Horizontal, 0);
	addRowInner.setMarginTop(Layout.addCardPadding);
	addRowInner.setMarginBottom(Layout.addCardPadding);
	addRowInner.setMarginStart(Layout.addCardPadding);
	addRowInner.setMarginEnd(Layout.addCardPadding);
	auto addIcon = Image.newFromIconName("list-add-symbolic");
	addIcon.setPixelSize(Layout.addCardIconSize);
	addIcon.setMarginEnd(Layout.addCardIconMargin);
	auto addLabel = new Label(L("manage.add.row"));
	addLabel.addCssClass("dim-label");
	addLabel.setHalign(Align.Start);
	addRowInner.append(addIcon);
	addRowInner.append(addLabel);
	addRow.setChild(addRowInner);
	auto addList = new ListBox;
	addList.setHexpand(true);
	addList.addCssClass("boxed-list");
	addList.setSelectionMode(SelectionMode.None);
	addList.setMarginTop(Layout.addListTopMargin);
	addList.append(addRow);
	addList.connectRowActivated(
		(ListBoxRow activatedRow, ListBox listBox) { onInstall(); });

	auto box = new Box(Orientation.Vertical, 0);
	box.setHexpand(true);
	box.setVexpand(true);
	box.setHalign(Align.Center);
	box.setValign(Align.Center);
	box.append(emptyIcon);
	box.append(emptyTitle);
	box.append(emptyHint);
	box.append(addList);
	return box;
}
