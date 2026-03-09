// GitHub Releases direct update method (no zsync)
// Finds the matching AppImage asset via the GitHub API and compares release tags to detect updates
module update.githubrelease;

import std.exception : collectException;
import std.file : exists, remove, mkdirRecurse, FileException;
import std.json : JSONValue;
import std.path : buildPath, dirName, globMatch;
import std.stdio : writeln;
import std.string : split, startsWith, strip;

import appimage.manifest : Manifest;
import update.common : readManifestFields, finishInstall, downloadFile;
import update.githubcommon : fetchGitHubRelease;
import types : InstallMethod;
import constants : APPLICATIONS_SUBDIR, UPDATE_SUBDIR;

private enum string PREFIX = "gh-releases|";

// Progress fractions for each phase of the GitHub Releases direct update
private enum Progress {
	start = 0.0,
	afterManifest = 0.05,
	afterResolve = 0.1,
	afterDownload = 0.6,
	complete = 1.0,
}

// Release info resolved from the GitHub Releases API
private struct GitHubReleaseInfo {
	string tag;
	string assetUrl;
}

// True when updateInfo encodes a GitHub Releases direct download update method
public bool isGitHubRelease(string updateInfo) {
	import update.common : parseUpdateMethodKind, UpdateMethodKind;

	return parseUpdateMethodKind(updateInfo) == UpdateMethodKind.GitHubRelease;
}

// Resolves the release download URL via the GitHub API using the gh-releases info string
// Returns false and sets error on failure
private bool resolveGitHubRelease(
	string updateInfo,
	out GitHubReleaseInfo releaseInfo,
	out string error,
	bool delegate() shouldCancel = null) {
	auto fields = updateInfo[PREFIX.length .. $].split("|");
	if (fields.length != 4) {
		error = "Invalid gh-releases format";
		return false;
	}
	string ownerName = fields[0].strip();
	string repositoryName = fields[1].strip();
	string tag = fields[2].strip();
	string assetPattern = fields[3].strip();

	writeln(
		"ghrelease: resolving for ", ownerName, "/", repositoryName, "@", tag);
	JSONValue releaseJson;
	if (!fetchGitHubRelease(
			ownerName,
			repositoryName,
			tag,
			releaseJson,
			error,
			shouldCancel))
		return false;

	if (auto tagPointer = "tag_name" in releaseJson)
		releaseInfo.tag = tagPointer.str;

	if (auto assetsPointer = "assets" in releaseJson) {
		foreach (asset; assetsPointer.array) {
			string name = asset["name"].str;
			if (globMatch(name, assetPattern)) {
				releaseInfo.assetUrl = asset["browser_download_url"].str;
				writeln(
					"ghrelease: resolved ",
					releaseInfo.tag,
					" -> ",
					releaseInfo.assetUrl);
				return true;
			}
		}
	}

	error = "No asset matching '" ~ assetPattern ~ "' in release "
		~ tag ~ " of " ~ ownerName ~ "/" ~ repositoryName;
	return false;
}

// Strips a leading "v" so "v1.2.3" and "1.2.3" compare equal
private string normalizeTag(string tag) {
	return tag.length > 1 && tag[0] == 'v' ? tag[1 .. $] : tag;
}

// Compares the installed manifest version to the latest GitHub release to detect updates
// Returns false and sets error on failure
public bool checkGitHubReleaseForUpdate(
	string appDirectory,
	string updateInfo,
	out bool available,
	out string error,
	bool delegate() shouldCancel = null) {
	available = true;

	auto manifest = Manifest.loadFromAppDir(appDirectory);
	if (manifest is null) {
		error = "Manifest not found in: " ~ appDirectory;
		return false;
	}

	GitHubReleaseInfo releaseInfo;
	if (!resolveGitHubRelease(updateInfo, releaseInfo, error, shouldCancel))
		return false;

	if (!manifest.releaseVersion.length) {
		writeln("ghrelease: no installed version on record, assuming update available");
		return true;
	}

	if (normalizeTag(releaseInfo.tag) == normalizeTag(manifest.releaseVersion)) {
		available = false;
		writeln("ghrelease: already at ", releaseInfo.tag);
	} else {
		writeln(
			"ghrelease: installed=",
			manifest.releaseVersion,
			" latest=",
			releaseInfo.tag);
	}
	return true;
}

// Resolves the asset URL then downloads and installs it, replacing the existing version
// progress goes 0.0 to 1.0, progressText and wasUpdated report state to caller
public bool performGitHubReleaseUpdate(
	string appDirectory,
	string sanitizedName,
	string updateInfo,
	ref double progress,
	ref string progressText,
	out bool wasUpdated,
	out string errorMessage,
	bool delegate() shouldCancel = null) {
	progress = Progress.start;
	progressText = "update.gh.status.start";
	wasUpdated = true;

	InstallMethod installMethod;
	if (!readManifestFields(appDirectory, installMethod, errorMessage))
		return false;

	progress = Progress.afterManifest;

	GitHubReleaseInfo releaseInfo;
	if (!resolveGitHubRelease(updateInfo, releaseInfo, errorMessage, shouldCancel))
		return false;

	progress = Progress.afterResolve;

	if (shouldCancel !is null && shouldCancel())
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
		tempPath = buildPath(
			dirName(appDirectory), "." ~ sanitizedName ~ ".update.AppImage");
	}

	scope (failure) {
		if (exists(tempPath))
			collectException(remove(tempPath));
	}

	progressText = "update.gh.status.downloading";
	if (!downloadFile(releaseInfo.assetUrl, tempPath, progress,
			Progress.afterResolve, Progress.afterDownload, errorMessage, shouldCancel))
		return false;

	return finishInstall(
		tempPath, appDirectory, sanitizedName,
		installMethod,
		progress, Progress.afterDownload, Progress.complete,
		progressText,
		"update.direct.status.installing",
		"update.direct.status.extracting",
		errorMessage, false, shouldCancel);
}
