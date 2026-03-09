// Single-app update availability check used by the manage window and background updater
//
module update.checker;

import std.json : JSONValue;
import std.stdio : writeln;

import update.common : parseUpdateMethodKind, UpdateMethodKind;
import update.githubcommon : fetchGitHubRelease;
import update.githubrelease : checkGitHubReleaseForUpdate;
import update.githubzsync : checkGitHubZsyncForUpdate;
import update.githublinuxmanifest : checkGitHubLinuxManifestForUpdate;
import update.pling : checkPlingForUpdate;
import update.zsync : extractZsyncUrl, checkZsyncForUpdate;
import windows.manage.scan : InstalledApp;
import constants : INSTALLER_GH_USER, INSTALLER_GH_REPO, INSTALLER_VERSION, TAG_LATEST;

// Returns true when a newer version is available for the given app
// Returns false for DirectLink (cannot be pre-checked), unknown methods, or on any error
public bool checkOneApp(InstalledApp entry, out string error) {
	if (!entry.updateInfo.length)
		return false;
	bool available;
	final switch (parseUpdateMethodKind(entry.updateInfo)) {
	case UpdateMethodKind.DirectLink:
		return false;
	case UpdateMethodKind.Zsync:
		checkZsyncForUpdate(entry.appDirectory, entry.sanitizedName,
			extractZsyncUrl(entry.updateInfo), available, error);
		break;
	case UpdateMethodKind.GitHubZsync:
		checkGitHubZsyncForUpdate(entry.appDirectory, entry.sanitizedName,
			entry.updateInfo, available, error);
		break;
	case UpdateMethodKind.GitHubRelease:
		checkGitHubReleaseForUpdate(
			entry.appDirectory,
			entry.updateInfo,
			available,
			error);
		break;
	case UpdateMethodKind.GitHubLinuxManifest:
		checkGitHubLinuxManifestForUpdate(
			entry.appDirectory,
			entry.updateInfo,
			available,
			error);
		break;
	case UpdateMethodKind.PlingV1Zsync:
		checkPlingForUpdate(entry.appDirectory, entry.sanitizedName,
			entry.updateInfo, available, error);
		break;
	case UpdateMethodKind.Unknown:
		writeln("checkOneApp: unknown update method: ", entry.updateInfo);
		break;
	}
	return available;
}

// Checks whether the installed version of this installer is behind the latest GitHub release
// Sets latestVersion to the version string from the release when an update is available
public bool checkInstallerUpdate(out string latestVersion, out string error) {
	JSONValue releaseJson;
	if (!fetchGitHubRelease(
			INSTALLER_GH_USER,
			INSTALLER_GH_REPO,
			TAG_LATEST,
			releaseJson,
			error))
		return false;
	auto tagPtr = "tag_name" in releaseJson;
	if (tagPtr is null) {
		error = "No tag_name in release response";
		return false;
	}
	string latest = tagPtr.str;
	if (latest.length > 1 && latest[0] == 'v')
		latest = latest[1 .. $];
	writeln("checker: installer current=", INSTALLER_VERSION, " latest=", latest);
	if (latest == INSTALLER_VERSION)
		return false;
	latestVersion = latest;
	return true;
}
