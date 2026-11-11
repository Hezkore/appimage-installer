// GitHub Releases zsync update method
// Resolves the .zsync asset URL from the GitHub API then passes to the zsync engine
module update.githubzsync;

import std.exception : collectException;
import std.file : exists, remove, mkdirRecurse, FileException;
import std.json : JSONValue;
import std.path : buildPath, dirName, stripExtension;
import std.string : endsWith, split, startsWith, strip;
import std.stdio : writeln;

import appimage.manifest : Manifest;
import constants : TAG_LATEST, APPLICATIONS_SUBDIR, UPDATE_SUBDIR;
import types : InstallMethod;
import update.common : normalizeUpdateInfoPattern, withoutVersion, downloadFile, finishInstall,
	readManifestFields;
import update.githubcommon : assetMatchesHost, fetchGitHubRelease;
import update.zsync : checkZsyncForUpdate, performZsyncUpdate;

private enum string PREFIX = "gh-releases-zsync|";
private enum string ZSYNC_EXTENSION = ".zsync";
private enum string ZSYNC_ASSET_PATTERN = "*" ~ ZSYNC_EXTENSION;

// True when updateInfo encodes a GitHub Releases zsync update method
public bool isGitHubZsync(string updateInfo) {
	import update.common : parseUpdateMethodKind, UpdateMethodKind;

	return parseUpdateMethodKind(updateInfo) == UpdateMethodKind.GitHubZsync;
}

// Which file of a release to find: the .zsync asset, or the AppImage it describes
private enum AssetKind {
	zsync,
	appImage,
}

// Resolves the download URL of one asset in the release that the gh-releases-zsync info string names
// With several builds in the release, the build the app was installed from is taken
// Returns false and sets error on failure
private bool resolveReleaseAsset(
	string updateInfo,
	string appDirectory,
	AssetKind kind,
	out string assetUrl,
	out string error,
	bool delegate() shouldCancel = null) {
	auto fields = normalizeUpdateInfoPattern(updateInfo)[PREFIX.length .. $].split("|");
	if (fields.length != 4) {
		error = "Invalid gh-releases-zsync format";
		return false;
	}
	string ownerName = fields[0].strip();
	string repositoryName = fields[1].strip();
	string tag = fields[2].strip();
	string assetPattern = fields[3].strip();
	if (kind == AssetKind.appImage && assetPattern.endsWith(ZSYNC_EXTENSION))
		assetPattern = assetPattern[0 .. $ - ZSYNC_EXTENSION.length];

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

	string[] assetNames;
	string[string] urlOfAsset;
	if (auto assetsPointer = "assets" in releaseJson) {
		foreach (asset; assetsPointer.array) {
			string name = asset["name"].str;
			if (!assetMatchesHost(name, assetPattern))
				continue;
			assetNames ~= name;
			urlOfAsset[name] = asset["browser_download_url"].str;
		}
	}
	if (!assetNames.length) {
		error = "No asset matching '" ~ assetPattern ~ "' in release "
			~ tag ~ " of " ~ ownerName ~ "/" ~ repositoryName;
		return false;
	}

	auto installedAppManifest = Manifest.loadFromAppDir(appDirectory);
	string picked = pickAssetForInstalledFile(
		assetNames, installedAppManifest is null ? "" : installedAppManifest.sourceFileName);
	// With no name to tell several builds apart only the pattern decides, so the first listed is taken
	if (!picked.length)
		picked = assetNames[0];
	assetUrl = urlOfAsset[picked];
	writeln("ghzsync: resolved to ", assetUrl);
	return true;
}

// Picks the asset that belongs to the installed AppImage file, by its name without the version
// A release can hold several builds of one app, so only a lone asset or a name match is certain
private string pickAssetForInstalledFile(const string[] assetNames, string installedFileName) {
	if (assetNames.length == 1)
		return assetNames[0];
	if (!installedFileName.length)
		return "";
	foreach (name; assetNames) {
		string appImageFile = name.endsWith(ZSYNC_EXTENSION)
			? name[0 .. $ - ZSYNC_EXTENSION.length] : name;
		if (withoutVersion(appImageFile.stripExtension) == withoutVersion(installedFileName))
			return name;
	}
	return "";
}

// Queries the latest release of user/repo for the .zsync asset of the installed AppImage file
// Returns true on success with assetName left empty when no asset is a sure match
public bool findGitHubZsyncAsset(
	string ownerName,
	string repositoryName,
	string installedFileName,
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
	string[] assetNames;
	if (auto assetsPointer = "assets" in releaseJson) {
		foreach (asset; assetsPointer.array) {
			string name = asset["name"].str;
			if (assetMatchesHost(name, ZSYNC_ASSET_PATTERN))
				assetNames ~= name;
		}
	}
	assetName = pickAssetForInstalledFile(assetNames, installedFileName);
	writeln("ghzsync: ", assetNames.length, " zsync asset(s) for this machine, picked '", assetName, "'");
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
	if (!resolveReleaseAsset(
			updateInfo,
			appDirectory,
			AssetKind.zsync,
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
	if (!resolveReleaseAsset(
			updateInfo, appDirectory, AssetKind.appImage, assetUrl, errorMessage, shouldCancel))
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
	if (!resolveReleaseAsset(
			updateInfo,
			appDirectory,
			AssetKind.zsync,
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

// An asset name saved as the pattern keeps matching the same asset in later releases
unittest {
	string saved = PREFIX ~ "WowUp|WowUp.CF|latest|WowUp-CF-2.25.5.AppImage.zsync";
	string pattern = normalizeUpdateInfoPattern(saved).split("|")[$ - 1];
	assert(pattern == "WowUp-CF-*.AppImage.zsync");
	assert(assetMatchesHost("WowUp-CF-2.26.0.AppImage.zsync", pattern));
	assert(!assetMatchesHost("WowUp-CF-2.26.0.AppImage", pattern));
}

// With several builds in one release, only the build that was installed is picked
unittest {
	string[] builds = ["App-1.1-x86_64.AppImage.zsync", "App-legacy-1.1-x86_64.AppImage.zsync"];
	assert(pickAssetForInstalledFile(builds, "App-legacy-1.0-x86_64") == builds[1]);
	assert(pickAssetForInstalledFile(builds, "App-1.0-x86_64") == builds[0]);
	assert(pickAssetForInstalledFile(builds, "renamed") == "");
	assert(pickAssetForInstalledFile(builds[0 .. 1], "renamed") == builds[0]);
	assert(pickAssetForInstalledFile([], "App-1.0-x86_64") == "");
	string[] appImages = ["App-1.1-x86_64.AppImage", "App-legacy-1.1-x86_64.AppImage"];
	assert(pickAssetForInstalledFile(appImages, "App-legacy-1.0-x86_64") == appImages[1]);
}

// Build numbers and commit hashes in a name change with each release, like versions do
unittest {
	string patternOf(string assetName) {
		return normalizeUpdateInfoPattern(PREFIX ~ "owner|repository|latest|" ~ assetName).split("|")[$ - 1];
	}

	assert(patternOf("App-38314-x86_64.AppImage.zsync") == "App-*-x86_64.AppImage.zsync");
	assert(patternOf("App_0.9_b5f46e3.AppImage.zsync") == "App_*_*.AppImage.zsync");
	assert(patternOf("App-qt6-i686.AppImage.zsync") == "App-qt6-i686.AppImage.zsync");
	assert(patternOf("App-aarch64.AppImage.zsync") == "App-aarch64.AppImage.zsync");
}
