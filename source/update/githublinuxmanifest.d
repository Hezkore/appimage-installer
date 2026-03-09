// GitHub electron-builder latest-linux.yml update method
// Finds the AppImage download URL from the latest-linux.yml release asset
module update.githublinuxmanifest;

import std.ascii : isWhite;
import std.conv : to;
import std.exception : collectException;
import std.file : exists, FileException, mkdirRecurse, remove;
import std.json : JSONValue;
import std.net.curl : CurlException, HTTP;
import std.path : buildPath, dirName;
import std.stdio : writeln;
import std.string : indexOf, split, splitLines, startsWith, strip;

import appimage.manifest : Manifest;
import constants : APPLICATIONS_SUBDIR, INSTALLER_NAME, TAG_LATEST, UPDATE_SUBDIR;
import types : InstallMethod;
import update.common : downloadFile, finishInstall, MAX_HTTP_REDIRECTS,
	readManifestFields;
import update.githubcommon : fetchGitHubRelease;

private enum string PREFIX = "gh-linux-yml|";
private enum string LINUX_MANIFEST_ASSET_NAME = "latest-linux.yml";
private enum string GITHUB_RELEASES_BASE_URL = "https://github.com/";

// Progress fractions for each phase of the GitHub Linux manifest update
private enum Progress {
	start = 0.0,
	afterManifest = 0.05,
	afterLinuxManifest = 0.1,
	afterDownload = 0.6,
	complete = 1.0,
}

// True when updateInfo encodes the GitHub Linux manifest update method
public bool isGitHubLinuxManifest(string updateInfo) {
	import update.common : parseUpdateMethodKind, UpdateMethodKind;

	return parseUpdateMethodKind(updateInfo)
		== UpdateMethodKind.GitHubLinuxManifest;
}

// Parses the owner and repository from a GitHub Linux manifest updateInfo string
private void parseGitHubLinuxManifestInfo(
	string updateInfo, out string ownerName, out string repositoryName) {
	auto fields = updateInfo[PREFIX.length .. $].split("|");
	ownerName = fields[0].strip();
	repositoryName = fields[1].strip();
}

// Strips surrounding single or double quotes from a YAML scalar value
private string stripYamlQuotes(string value) {
	if (value.length >= 2
		&& ((value[0] == '\'' && value[$ - 1] == '\'')
			|| (value[0] == '"' && value[$ - 1] == '"')))
		return value[1 .. $ - 1];
	return value;
}

// Parses version and path from the text of a latest-linux.yml file
// Returns true only when both fields are found
private bool parseLatestLinuxManifest(
	string bodyText,
	out string releaseVersion,
	out string assetName) {
	foreach (line; bodyText.splitLines()) {
		if (!line.length || isWhite(line[0]))
			continue;
		auto colonPos = line.indexOf(':');
		if (colonPos < 0)
			continue;
		string key = line[0 .. colonPos].strip();
		string value = stripYamlQuotes(line[colonPos + 1 .. $].strip());
		if (key == "version")
			releaseVersion = value;
		else if (key == "path")
			assetName = value;
	}
	return releaseVersion.length > 0 && assetName.length > 0;
}

// Fetches the latest-linux.yml body for ownerName/repositoryName as a string
// Returns false and sets error on network or HTTP failure
private bool fetchLatestLinuxManifestBody(
	string ownerName,
	string repositoryName,
	out string bodyText, out string error,
	bool delegate() shouldCancel = null) {
	string url = GITHUB_RELEASES_BASE_URL ~ ownerName ~ "/" ~ repositoryName
		~ "/releases/latest/download/" ~ LINUX_MANIFEST_ASSET_NAME;
	writeln("ghlinuxyml: fetching ", url);
	auto http = HTTP(url);
	http.addRequestHeader("User-Agent", INSTALLER_NAME);
	http.maxRedirects(MAX_HTTP_REDIRECTS);
	int statusCode;
	http.onReceive = (ubyte[] data) {
		bodyText ~= cast(string) data;
		return data.length;
	};
	http.onReceiveStatusLine = (HTTP.StatusLine sl) { statusCode = sl.code; };
	if (shouldCancel !is null)
		http.onProgress = (ulong dlTotal, ulong dlNow, ulong ulTotal, ulong ulNow) {
		return shouldCancel() ? 1 : 0;
	};
	try {
		http.perform();
	} catch (CurlException curlException) {
		error = "Failed to fetch " ~ LINUX_MANIFEST_ASSET_NAME
			~ ": " ~ curlException.msg;
		return false;
	}
	if (statusCode < 200 || statusCode >= 300) {
		error = "HTTP " ~ statusCode.to!string ~ " fetching "
			~ LINUX_MANIFEST_ASSET_NAME;
		return false;
	}
	return true;
}

// Queries the latest GitHub release of ownerName/repositoryName for a latest-linux.yml asset
// Sets hasLinuxManifest to true when found; returns false and sets error on network failure
public bool findLinuxManifestAsset(
	string ownerName,
	string repositoryName,
	out bool hasLinuxManifest,
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
			if (asset["name"].str == LINUX_MANIFEST_ASSET_NAME) {
				hasLinuxManifest = true;
				writeln("ghlinuxyml: found ", LINUX_MANIFEST_ASSET_NAME);
				return true;
			}
		}
	}
	writeln("ghlinuxyml: no ", LINUX_MANIFEST_ASSET_NAME, " asset found");
	return true;
}

// Checks whether a newer version is available by comparing the YML version to the manifest
// Returns false and sets error on network or parse failure
public bool checkGitHubLinuxManifestForUpdate(
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

	string ownerName;
	string repositoryName;
	parseGitHubLinuxManifestInfo(updateInfo, ownerName, repositoryName);

	string bodyText;
	if (!fetchLatestLinuxManifestBody(
			ownerName, repositoryName, bodyText, error, shouldCancel))
		return false;

	string releaseVersion;
	string assetName;
	if (!parseLatestLinuxManifest(bodyText, releaseVersion, assetName)) {
		error = "Could not parse version/path from "
			~ LINUX_MANIFEST_ASSET_NAME;
		return false;
	}

	if (!manifest.releaseVersion.length) {
		writeln("ghlinuxyml: no installed version on record, assuming update available");
		return true;
	}

	if (releaseVersion == manifest.releaseVersion) {
		available = false;
		writeln("ghlinuxyml: already at ", releaseVersion);
	} else {
		writeln(
			"ghlinuxyml: installed=",
			manifest.releaseVersion,
			" latest=",
			releaseVersion);
	}
	return true;
}

// Downloads the AppImage named in the YML and installs it over the existing version
// progress goes 0.0 to 1.0, progressText and wasUpdated report state to caller
public bool performGitHubLinuxManifestUpdate(
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

	string ownerName;
	string repositoryName;
	parseGitHubLinuxManifestInfo(updateInfo, ownerName, repositoryName);

	string bodyText;
	if (!fetchLatestLinuxManifestBody(
			ownerName,
			repositoryName,
			bodyText,
			errorMessage,
			shouldCancel))
		return false;

	string releaseVersion;
	string assetName;
	if (!parseLatestLinuxManifest(bodyText, releaseVersion, assetName)) {
		errorMessage = "Could not parse version/path from "
			~ LINUX_MANIFEST_ASSET_NAME;
		return false;
	}

	progress = Progress.afterLinuxManifest;

	if (shouldCancel !is null && shouldCancel())
		return false;

	string downloadUrl = GITHUB_RELEASES_BASE_URL
		~ ownerName ~ "/" ~ repositoryName
		~ "/releases/latest/download/" ~ assetName;

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

	scope (failure) {
		if (exists(tempPath))
			collectException(remove(tempPath));
	}

	progressText = "update.gh.status.downloading";
	if (!downloadFile(downloadUrl, tempPath, progress,
			Progress.afterLinuxManifest, Progress.afterDownload, errorMessage, shouldCancel))
		return false;

	if (!finishInstall(
			tempPath, appDirectory, sanitizedName,
			installMethod,
			progress, Progress.afterDownload, Progress.complete,
			progressText,
			"update.gh.status.installing",
			"update.gh.status.extracting",
			errorMessage, false, shouldCancel))
		return false;

	// Persist the YML version so the next update check compares correctly
	auto manifest = Manifest.loadFromAppDir(appDirectory);
	if (manifest !is null) {
		manifest.releaseVersion = releaseVersion;
		manifest.save();
	}

	return true;
}
