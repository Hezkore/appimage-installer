// Dispatches an update for an installed app to the correct update method
module update.dispatch;

import update.common : parseUpdateMethodKind, UpdateMethodKind;
import update.directlink : extractDirectLinkUrl, performDirectLinkUpdate;
import update.zsync : extractZsyncUrl, performZsyncUpdate;
import update.githubzsync : performGitHubZsyncUpdate;
import update.githubrelease : performGitHubReleaseUpdate;
import update.githublinuxmanifest : performGitHubLinuxManifestUpdate;
import update.pling : performPlingUpdate;
import windows.manage.scan : InstalledApp;

// Runs the appropriate update for entry, reporting progress
// Returns true on success; wasUpdated is false when already up to date
public bool applyUpdateWithProgress(
	ref InstalledApp entry,
	ref double progress,
	ref string progressText,
	out bool wasUpdated,
	out string errorMessage,
	bool delegate() shouldCancel = null) {
	final switch (parseUpdateMethodKind(entry.updateInfo)) {
	case UpdateMethodKind.DirectLink:
		return performDirectLinkUpdate(
			entry.appDirectory, entry.sanitizedName,
			extractDirectLinkUrl(entry.updateInfo),
			progress, progressText, wasUpdated, errorMessage, shouldCancel);
	case UpdateMethodKind.Zsync:
		return performZsyncUpdate(
			entry.appDirectory, entry.sanitizedName,
			extractZsyncUrl(entry.updateInfo),
			progress, progressText, wasUpdated, errorMessage, shouldCancel);
	case UpdateMethodKind.GitHubZsync:
		return performGitHubZsyncUpdate(
			entry.appDirectory, entry.sanitizedName,
			entry.updateInfo,
			progress, progressText, wasUpdated, errorMessage, shouldCancel);
	case UpdateMethodKind.GitHubRelease:
		return performGitHubReleaseUpdate(
			entry.appDirectory, entry.sanitizedName,
			entry.updateInfo,
			progress, progressText, wasUpdated, errorMessage, shouldCancel);
	case UpdateMethodKind.GitHubLinuxManifest:
		return performGitHubLinuxManifestUpdate(
			entry.appDirectory, entry.sanitizedName,
			entry.updateInfo,
			progress, progressText, wasUpdated, errorMessage, shouldCancel);
	case UpdateMethodKind.PlingV1Zsync:
		return performPlingUpdate(
			entry.appDirectory, entry.sanitizedName,
			entry.updateInfo,
			progress, progressText, wasUpdated, errorMessage, shouldCancel);
	case UpdateMethodKind.Unknown:
		errorMessage = "No known update method";
		return false;
	}
}
