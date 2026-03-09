// GitHub Releases zsync update method
// Resolves the .zsync asset URL from the GitHub API then passes to the zsync engine
module update.githubzsync;

import std.exception : collectException;
import std.file : exists, remove, mkdirRecurse, FileException;
import std.json : JSONValue;
import std.path : buildPath, dirName, globMatch;
import std.string : endsWith, split, startsWith, strip;
import std.stdio : writeln;

import appimage.manifest : Manifest;
import constants : TAG_LATEST, APPLICATIONS_SUBDIR, UPDATE_SUBDIR;
import types : InstallMethod;
import update.common : downloadFile, finishInstall, readManifestFields;
import update.githubcommon : fetchGitHubRelease;
import update.zsync : checkZsyncForUpdate, performZsyncUpdate;

private enum string PREFIX = "gh-releases-zsync|";

// True when updateInfo encodes a GitHub Releases zsync update method
public bool isGitHubZsync(string updateInfo) {
	import update.common : parseUpdateMethodKind, UpdateMethodKind;

	return parseUpdateMethodKind(updateInfo) == UpdateMethodKind.GitHubZsync;
}

// Resolves the .zsync asset URL via the GitHub API using the gh-releases-zsync info string
// Returns false and sets error on failure
private bool resolveGitHubZsyncUrl(
	string updateInfo,
	out string metadataUrl,
	out string error,
	bool delegate() shouldCancel = null) {
	auto fields = updateInfo[PREFIX.length .. $].split("|");
	if (fields.length != 4) {
		error = "Invalid gh-releases-zsync format";
		return false;
	}
	string ownerName = fields[0].strip();
	string repositoryName = fields[1].strip();
	string tag = fields[2].strip();
	string assetPattern = fields[3].strip();

	writeln(
		"ghzsync: resolving for ", ownerName, "/", repositoryName, "@", tag);
	JSONValue releaseJson;
	if (!fetchGitHubRelease(
			ownerName,
			repositoryName,
			tag,
			releaseJson,
			error,
			shouldCancel))
		return false;

	if (auto assetsPointer = "assets" in releaseJson) {
		foreach (asset; assetsPointer.array) {
			string name = asset["name"].str;
			if (globMatch(name, assetPattern)) {
				metadataUrl = asset["browser_download_url"].str;
				writeln("ghzsync: resolved to ", metadataUrl);
				return true;
			}
		}
	}

	error = "No asset matching '" ~ assetPattern ~ "' in release "
		~ tag ~ " of " ~ ownerName ~ "/" ~ repositoryName;
	return false;
}

// Queries the latest release of user/repo for any .zsync asset
// Returns true and sets assetName on success, false and sets error on failure
public bool findGitHubZsyncAsset(
	string ownerName,
	string repositoryName,
	out string assetName,
	out string error) {
	JSONValue releaseJson;
	if (!fetchGitHubRelease(
			ownerName,
			repositoryName,
			TAG_LATEST,
			releaseJson,
			error))
		return false;
	if (auto assetsPointer = "assets" in releaseJson) {
		foreach (asset; assetsPointer.array) {
			string name = asset["name"].str;
			if (name.endsWith(".zsync")) {
				assetName = name;
				writeln("ghzsync: found zsync asset: ", name);
				return true;
			}
		}
	}
	writeln("ghzsync: no zsync asset found");
	return true;
}

// Checks whether a GitHub Releases zsync update is available
// Resolves the asset URL then passes to checkZsyncForUpdate
public bool checkGitHubZsyncForUpdate(
	string appDirectory,
	string sanitizedName,
	string updateInfo,
	out bool available,
	out string error,
	bool delegate() shouldCancel = null) {
	string metadataUrl;
	if (!resolveGitHubZsyncUrl(
			updateInfo,
			metadataUrl,
			error,
			shouldCancel))
		return false;
	return checkZsyncForUpdate(
		appDirectory,
		sanitizedName,
		metadataUrl,
		available,
		error,
		shouldCancel);
}

// Progress fractions for the full-file fallback download
private enum FallbackProgress {
	afterManifest = 0.05,
	afterResolve = 0.1,
	afterDownload = 0.85,
	complete = 1.0,
}

// Finds the AppImage asset URL in the same release, used as a fallback when zsync fails
// The pattern is derived by stripping ".zsync" from the zsync asset pattern
private bool resolveFallbackAsset(
	string updateInfo,
	out string assetUrl,
	out string error,
	bool delegate() shouldCancel = null) {
	auto fields = updateInfo[PREFIX.length .. $].split("|");
	if (fields.length != 4)
		return false;
	string ownerName = fields[0].strip();
	string repositoryName = fields[1].strip();
	string tag = fields[2].strip();
	string zsyncPattern = fields[3].strip();
	string appimagePattern = zsyncPattern.endsWith(".zsync")
		? zsyncPattern[0 .. $ - ".zsync".length] : zsyncPattern;

	JSONValue releaseJson;
	if (!fetchGitHubRelease(
			ownerName, repositoryName, tag, releaseJson, error, shouldCancel))
		return false;

	if (auto assetsPointer = "assets" in releaseJson) {
		foreach (asset; assetsPointer.array) {
			string name = asset["name"].str;
			if (globMatch(name, appimagePattern)) {
				assetUrl = asset["browser_download_url"].str;
				writeln("ghzsync: fallback asset resolved to ", assetUrl);
				return true;
			}
		}
	}
	error = "No fallback asset matching '" ~ appimagePattern
		~ "' in release " ~ tag ~ " of " ~ ownerName ~ "/" ~ repositoryName;
	return false;
}

// Downloads the full AppImage directly as a fallback when zsync fails
private bool performFallbackDownload(
	string appDirectory,
	string sanitizedName,
	string updateInfo,
	ref double progress,
	ref string progressText,
	out bool wasUpdated,
	out string errorMessage,
	bool delegate() shouldCancel = null) {
	wasUpdated = true;

	InstallMethod installMethod;
	if (!readManifestFields(appDirectory, installMethod, errorMessage))
		return false;

	progress = FallbackProgress.afterManifest;

	string assetUrl;
	if (!resolveFallbackAsset(updateInfo, assetUrl, errorMessage, shouldCancel))
		return false;

	progress = FallbackProgress.afterResolve;
	if (shouldCancel !is null && shouldCancel())
		return false;

	string tempPath;
	if (installMethod == InstallMethod.AppImage) {
		string updateDir = buildPath(appDirectory, APPLICATIONS_SUBDIR, UPDATE_SUBDIR);
		try {
			mkdirRecurse(updateDir);
		} catch (FileException fileError) {
			errorMessage = "Could not create update directory: " ~ fileError.msg;
			return false;
		}
		tempPath = buildPath(updateDir, sanitizedName ~ ".AppImage");
	} else {
		tempPath = buildPath(
			dirName(appDirectory), "." ~ sanitizedName ~ ".update.AppImage");
	}

	scope (failure)
		collectException(remove(tempPath));

	progressText = "update.gh.status.downloading";
	if (!downloadFile(
			assetUrl, tempPath, progress,
			FallbackProgress.afterResolve, FallbackProgress.afterDownload,
			errorMessage, shouldCancel))
		return false;

	return finishInstall(
		tempPath, appDirectory, sanitizedName, installMethod,
		progress, FallbackProgress.afterDownload, FallbackProgress.complete,
		progressText,
		"update.direct.status.installing",
		"update.direct.status.extracting",
		errorMessage, false, shouldCancel);
}

// Resolves the asset URL and runs the zsync delta update
// Falls back to a full download if zsync fails for any reason
// progress goes 0.0 to 1.0, progressText and wasUpdated report state to caller
public bool performGitHubZsyncUpdate(
	string appDirectory,
	string sanitizedName,
	string updateInfo,
	ref double progress,
	ref string progressText,
	out bool wasUpdated,
	out string errorMessage,
	bool delegate() shouldCancel = null,
	bool force = false) {
	string metadataUrl;
	if (!resolveGitHubZsyncUrl(
			updateInfo,
			metadataUrl,
			errorMessage,
			shouldCancel))
		return false;
	if (shouldCancel !is null && shouldCancel())
		return false;
	bool ok = performZsyncUpdate(
		appDirectory, sanitizedName, metadataUrl,
		progress, progressText, wasUpdated, errorMessage, shouldCancel, force);
	if (ok || (shouldCancel !is null && shouldCancel()))
		return ok;
	writeln("ghzsync: zsync failed (", errorMessage, "), trying full download");
	string fallbackError;
	bool fallbackOk = performFallbackDownload(
		appDirectory, sanitizedName, updateInfo,
		progress, progressText, wasUpdated, fallbackError, shouldCancel);
	if (fallbackOk) {
		errorMessage = "";
		return true;
	}
	return false;
}
