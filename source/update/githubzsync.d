// GitHub Releases zsync update method
// Resolves the .zsync asset URL from the GitHub API then passes to the zsync engine
module update.githubzsync;

import std.json : JSONValue;
import std.path : globMatch;
import std.string : endsWith, split, startsWith, strip;
import std.stdio : writeln;

import constants : TAG_LATEST;
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

// Resolves the asset URL and runs the zsync delta update
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
	return performZsyncUpdate(
		appDirectory, sanitizedName, metadataUrl,
		progress, progressText, wasUpdated, errorMessage, shouldCancel, force);
}
