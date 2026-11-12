// Single-app update availability check used by the manage window and background updater
//
module update.checker;

import update.common : parseUpdateMethodKind, UpdateMethodKind, reapplyIfFileChanged;
import update.githubrelease : checkGitHubReleaseForUpdate;
import update.githubzsync : checkGitHubZsyncForUpdate;
import update.githublinuxmanifest : checkGitHubLinuxManifestForUpdate;
import update.pling : checkPlingForUpdate;
import update.zsync : extractZsyncUrl, checkZsyncForUpdate;
import windows.manage.scan : InstalledApp;

// Checks one app for a newer version with its update method
// DirectLink cannot be checked ahead and an unknown method not at all, so both leave available and error unset
public void checkForUpdate(
	string appDirectory,
	string sanitizedName,
	string updateInfo,
	out bool available,
	out string error,
	bool delegate() shouldCancel = null) {
	// An app that updated its own file must not be compared by the version we saved before
	reapplyIfFileChanged(appDirectory, sanitizedName);
	final switch (parseUpdateMethodKind(updateInfo)) {
	case UpdateMethodKind.DirectLink:
	case UpdateMethodKind.Unknown:
		break;
	case UpdateMethodKind.Zsync:
		checkZsyncForUpdate(appDirectory, sanitizedName,
			extractZsyncUrl(updateInfo), available, error, shouldCancel);
		break;
	case UpdateMethodKind.GitHubZsync:
		checkGitHubZsyncForUpdate(appDirectory, sanitizedName,
			updateInfo, available, error, shouldCancel);
		break;
	case UpdateMethodKind.GitHubRelease:
		checkGitHubReleaseForUpdate(appDirectory, updateInfo, available, error, shouldCancel);
		break;
	case UpdateMethodKind.GitHubLinuxManifest:
		checkGitHubLinuxManifestForUpdate(appDirectory, updateInfo, available, error, shouldCancel);
		break;
	case UpdateMethodKind.PlingV1Zsync:
		checkPlingForUpdate(appDirectory, sanitizedName,
			updateInfo, available, error, shouldCancel);
		break;
	}
}

// Returns true when a newer version is available for the given app
// Returns false for DirectLink (cannot be pre-checked), unknown methods, or on any error
public bool checkOneApp(InstalledApp entry, out string error) {
	if (!entry.updateInfo.length)
		return false;
	bool available;
	checkForUpdate(entry.appDirectory, entry.sanitizedName, entry.updateInfo, available, error);
	return available;
}
