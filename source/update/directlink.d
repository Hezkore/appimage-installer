// Helpers and update logic for the Direct Link update method
//
module update.directlink;

import std.exception : collectException;
import std.file : exists, remove, mkdirRecurse, rmdir;
import std.file : FileException;
import std.path : buildPath, dirName;
import std.stdio : writeln;
import std.string : startsWith;

import update.common : readManifestFields, finishInstall, downloadFile,
	parseUpdateMethodKind, UpdateMethodKind;
import types : InstallMethod;
import constants : APPLICATIONS_SUBDIR, UPDATE_SUBDIR;
import apputils : hashFile;

// Progress fractions marking each phase of the direct link update
private enum Progress {
	start = 0.0,
	afterManifest = 0.1,
	afterDownload = 0.6,
	complete = 1.0,
}

// True when updateInfo encodes a Direct Link update method
public bool isDirectLink(string updateInfo) {
	return parseUpdateMethodKind(updateInfo) == UpdateMethodKind.DirectLink;
}

// Extracts the raw URL from a Direct Link updateInfo string
public string extractDirectLinkUrl(string updateInfo) {
	return updateInfo["direct-link|".length .. $];
}

// Downloads url and replaces the installed app with the new version
// Updates progress 0.0 to 1.0, wasUpdated is false if the downloaded file matches the existing one
public bool performDirectLinkUpdate(
	string appDirectory,
	string sanitizedName,
	string url,
	ref double progress,
	ref string progressText,
	out bool wasUpdated,
	out string errorMessage,
	bool delegate() shouldCancel = null,
	bool force = false) {
	progress = Progress.start;
	progressText = "update.direct.status.start";
	wasUpdated = true;

	InstallMethod installMethod;
	if (readManifestFields(appDirectory, installMethod, errorMessage) == false)
		return false;

	string tempPath;
	if (installMethod == InstallMethod.AppImage) {
		string updateDir = buildPath(appDirectory, APPLICATIONS_SUBDIR, UPDATE_SUBDIR);
		try {
			mkdirRecurse(updateDir);
		} catch (FileException error) {
			errorMessage = "Could not create update directory: " ~ error.msg;
			return false;
		}
		tempPath = buildPath(updateDir, sanitizedName ~ ".AppImage");
	} else {
		// Temp outside appDirectory so doInstallExtracted can wipe the dir freely
		tempPath = buildPath(
			dirName(appDirectory), "." ~ sanitizedName ~ ".update.AppImage");
	}

	scope (failure) {
		if (exists(tempPath))
			try {
				remove(tempPath);
			} catch (FileException) {
			}
	}

	progress = Progress.afterManifest;
	progressText = "update.direct.status.downloading";
	if (!downloadFile(url, tempPath, progress,
			Progress.afterManifest, Progress.afterDownload, errorMessage, shouldCancel))
		return false;

	// Compare hashes to detect no-op updates and skip reinstalling if identical
	string existingPath;
	if (installMethod == InstallMethod.AppImage) {
		existingPath = buildPath(appDirectory, sanitizedName ~ ".AppImage");
	} else {
		existingPath = buildPath(
			appDirectory, APPLICATIONS_SUBDIR, sanitizedName ~ ".AppImage");
	}
	string newHash = hashFile(tempPath);
	string existingHash = hashFile(existingPath);
	if (!force && newHash.length && existingHash.length && newHash == existingHash) {
		wasUpdated = false;
		collectException(remove(tempPath));
		if (installMethod == InstallMethod.AppImage)
			collectException(rmdir(dirName(tempPath)));
		writeln("directlink: no update, downloaded matches existing");
		return true;
	}

	return finishInstall(
		tempPath, appDirectory, sanitizedName,
		installMethod,
		progress, Progress.afterDownload, Progress.complete,
		progressText,
		"update.direct.status.installing",
		"update.direct.status.extracting",
		errorMessage, false, shouldCancel);
}
