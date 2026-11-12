// The installer's own update: the check, the saved notice and the update itself
//
module update.installer;

import std.conv : to;
import std.exception : collectException;
import std.file : FileException, exists, mkdirRecurse, readText, remove, rename, rmdirRecurse;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : baseName, buildPath, dirName;
import std.process : ProcessException, execute, spawnProcess, thisProcessID, wait;
import std.stdio : File, writeln;
import std.string : startsWith, strip;

import apputils.paths : configDir, executablePathOfProcess, installerPath, writeFileAtomically;
import apputils.system : installerLauncherPath;
import constants : INSTALLER_ARCH, INSTALLER_FLAG_FILE_NAME,
	INSTALLER_GH_REPO, INSTALLER_GH_USER, INSTALLER_NAME, INSTALLER_VERSION,
	INSTALLER_VERSION_LINE_PREFIX, TAG_LATEST;
import lang : L;
import update.common : downloadFile;
import update.githubcommon : fetchGitHubRelease;

// Release file names, as the release workflow writes them
private enum string ARCHIVE_NAME_PREFIX = "AppImage_Installer-";
private enum string ARCHIVE_NAME_SUFFIX = ".tar.gz";
private enum string CHECKSUM_NAME_SUFFIX = ".sha256";

// Folder beside the installer that holds one update while it is checked, followed by the process number
// Beside the installer, so the new file is on the same disk and programs may run there
private enum string WORK_DIRECTORY_PREFIX = "." ~ INSTALLER_NAME ~ ".update.";

// Seconds the new installer gets to print its version or write its launcher
private enum int NEW_INSTALLER_TIME_LIMIT_SECONDS = 20;

private enum size_t CHECKSUM_READ_BUFFER_SIZE = 65_536;

// Reasons an update stops, shown after "Failed:" on the update card
private enum string ERROR_WORK_DIRECTORY = "Cannot write to ";
private enum string ERROR_CHECKSUM_DOWNLOAD = "Cannot get the checksum: ";
private enum string ERROR_CHECKSUM_MISMATCH = "The download fails the checksum.";
private enum string ERROR_UNPACK = "Cannot unpack the download: ";
private enum string ERROR_DOES_NOT_START = "The new version does not start on this computer: ";
private enum string ERROR_REPLACE = "Cannot replace the installer: ";

debug {
	// Set by --installer-release-url, so a test can serve a release from this computer
	public __gshared string releaseFilesUrlOverride;
}

// Address of the folder that holds the files of one release
private string releaseFilesUrl(string releaseVersion) {
	debug {
		if (releaseFilesUrlOverride.length)
			return releaseFilesUrlOverride;
	}
	return "https://github.com/" ~ INSTALLER_GH_USER ~ "/" ~ INSTALLER_GH_REPO
		~ "/releases/download/" ~ releaseVersion ~ "/";
}

private string updateFlagPath() {
	return buildPath(configDir(), INSTALLER_FLAG_FILE_NAME);
}

// Saves the version of a found installer update, so the next start shows it without a check
private void saveFoundVersion(string foundVersion) {
	try {
		mkdirRecurse(configDir());
		auto json = JSONValue(["version": JSONValue(foundVersion)]);
		writeFileAtomically(updateFlagPath(), json.toPrettyString() ~ "\n");
	} catch (FileException fileException) {
		writeln("installer update: could not save the found version: ", fileException.msg);
	}
}

// Deletes the saved version of an installer update
private void forgetFoundVersion() {
	try {
		if (exists(updateFlagPath()))
			remove(updateFlagPath());
	} catch (FileException fileException) {
		writeln("installer update: could not remove the saved version: ", fileException.msg);
	}
}

// Returns the saved version of an installer update, or empty when there is none
// A saved version that is this version, such as after a manual install, is dropped
public string readInstallerUpdateVersion() {
	string savedVersion;
	try {
		if (!exists(updateFlagPath()))
			return "";
		auto json = parseJSON(readText(updateFlagPath()));
		if (auto versionField = "version" in json)
			if (versionField.type == JSONType.string)
				savedVersion = versionField.str;
	} catch (Exception exception) {
		// The file only repeats what the next check finds again, so one that cannot be read is dropped
		writeln("installer update: could not read the saved version: ", exception.msg);
	}
	if (savedVersion.length && savedVersion != INSTALLER_VERSION)
		return savedVersion;
	forgetFoundVersion();
	return "";
}

// Checks whether the latest GitHub release of this installer is another version than this one
// An older release counts too, since that is how a release that was taken back reaches its users
// Sets latestVersion to that release, and saves or drops the notice for the next start
public bool checkInstallerUpdate(out string latestVersion, out string error) {
	JSONValue releaseJson;
	if (!fetchGitHubRelease(
			INSTALLER_GH_USER,
			INSTALLER_GH_REPO,
			TAG_LATEST,
			releaseJson,
			error))
		return false;
	auto tagField = "tag_name" in releaseJson;
	if (tagField is null || tagField.type != JSONType.string) {
		error = "No tag_name in release response";
		return false;
	}
	string latest = tagField.str;
	if (latest.startsWith("v"))
		latest = latest[1 .. $];
	writeln("installer update: current=", INSTALLER_VERSION, " latest=", latest);
	if (latest == INSTALLER_VERSION) {
		forgetFoundVersion();
		return false;
	}
	saveFoundVersion(latest);
	latestVersion = latest;
	return true;
}

// Removes work folders left by updates that were cut off
// A folder whose process still runs this installer belongs to an update in another window
private void removeAbandonedWorkDirectories(string installDirectory) {
	import std.file : SpanMode, dirEntries;

	try {
		foreach (entry; dirEntries(installDirectory, WORK_DIRECTORY_PREFIX ~ "*", SpanMode.shallow)) {
			string processNumber = baseName(entry.name)[WORK_DIRECTORY_PREFIX.length .. $];
			int processId;
			if (collectException(processNumber.to!int, processId) is null
				&& processId != thisProcessID
				&& executablePathOfProcess(processId) == installerPath())
				continue;
			collectException(rmdirRecurse(entry.name));
		}
	} catch (FileException fileException) {
		writeln("installer update: could not clean up old downloads: ", fileException.msg);
	}
}

private string sha256OfFile(string path) {
	import std.digest : LetterCase, toHexString;
	import std.digest.sha : SHA256;

	SHA256 digest;
	digest.start();
	auto file = File(path, "rb");
	scope (exit)
		file.close();
	ubyte[CHECKSUM_READ_BUFFER_SIZE] buffer;
	while (true) {
		auto chunk = file.rawRead(buffer[]);
		if (chunk.length == 0)
			break;
		digest.put(chunk);
	}
	return toHexString!(LetterCase.lower)(digest.finish()).idup;
}

// Downloads the checksum the release publishes for the archive and compares it with the download
// A release without a checksum fails, since nothing else tells a complete download from a damaged one
private bool archiveMatchesChecksum(string archivePath, string archiveUrl, out string error) {
	import std.string : split;

	string checksumPath = archivePath ~ CHECKSUM_NAME_SUFFIX;
	double unusedProgress;
	string downloadError;
	if (!downloadFile(archiveUrl ~ CHECKSUM_NAME_SUFFIX, checksumPath,
			unusedProgress, 0.0, 1.0, downloadError)) {
		error = ERROR_CHECKSUM_DOWNLOAD ~ downloadError;
		return false;
	}
	try {
		// The file holds the checksum, then the archive name
		auto checksumFields = readText(checksumPath).split();
		if (checksumFields.length && checksumFields[0] == sha256OfFile(archivePath)) {
			writeln("installer update: checksum verified for ", baseName(archivePath));
			return true;
		}
		error = ERROR_CHECKSUM_MISMATCH;
	} catch (Exception exception) {
		// A checksum file that cannot be read or is not text proves nothing about the download
		error = ERROR_CHECKSUM_DOWNLOAD ~ exception.msg;
	}
	return false;
}

// Unpacks only the installer from the archive, so nothing else in the archive reaches the disk
private bool unpackInstaller(string archivePath, string workDirectory, out string error) {
	try {
		auto result = execute([
			"tar", "xzf", archivePath, "-C", workDirectory, "--", INSTALLER_NAME
		]);
		if (result.status == 0)
			return true;
		error = ERROR_UNPACK ~ result.output.strip();
	} catch (ProcessException processException) {
		error = ERROR_UNPACK ~ processException.msg;
	}
	return false;
}

// Command that runs the new installer under a time limit, so a program that hangs cannot hold the update
private string[] newInstallerCommand(string newInstallerPath) {
	return ["timeout", NEW_INSTALLER_TIME_LIMIT_SECONDS.to!string, newInstallerPath];
}

// True when the new installer runs on this computer and names the expected version
// A build for other system libraries fails here, while the working installer is still in place
private bool newInstallerStarts(string newInstallerPath, string newVersion, out string error) {
	import std.algorithm : canFind;
	import std.string : splitLines;

	try {
		auto result = execute(newInstallerCommand(newInstallerPath) ~ ["--version"]);
		// Other lines can come from libraries the system loads into every program
		if (result.status == 0
			&& result.output.splitLines().canFind(INSTALLER_VERSION_LINE_PREFIX ~ newVersion))
			return true;
		error = ERROR_DOES_NOT_START ~ result.output.strip();
	} catch (ProcessException processException) {
		error = ERROR_DOES_NOT_START ~ processException.msg;
	}
	return false;
}

// Lets the new installer write its own launcher, with the names and icon of its version
// Only a launcher that exists is written again, and the file association stays as the user set it
private void refreshInstallerLauncher() {
	if (!exists(installerLauncherPath()))
		return;
	try {
		// Its output goes to our log, since a pipe would stay open until the icon cache tool it starts ends
		int status = wait(spawnProcess(newInstallerCommand(installerPath())
				~ ["--desktop", dirName(installerLauncherPath())]));
		if (status != 0)
			writeln("installer update: the launcher refresh ended with code ", status);
	} catch (ProcessException processException) {
		writeln("installer update: could not refresh the launcher: ", processException.msg);
	}
}

private bool downloadCheckAndReplace(
	string newVersion,
	void delegate(string) onStatus,
	out string error) {
	string installDirectory = dirName(installerPath());
	string workDirectory = buildPath(
		installDirectory, WORK_DIRECTORY_PREFIX ~ thisProcessID.to!string);
	string archiveName = ARCHIVE_NAME_PREFIX ~ newVersion ~ "-" ~ INSTALLER_ARCH
		~ ARCHIVE_NAME_SUFFIX;
	string archiveUrl = releaseFilesUrl(newVersion) ~ archiveName;
	string archivePath = buildPath(workDirectory, archiveName);
	string newInstallerPath = buildPath(workDirectory, INSTALLER_NAME);

	removeAbandonedWorkDirectories(installDirectory);
	try {
		mkdirRecurse(workDirectory);
	} catch (FileException fileException) {
		error = ERROR_WORK_DIRECTORY ~ installDirectory ~ ": " ~ fileException.msg;
		return false;
	}
	scope (exit)
		collectException(rmdirRecurse(workDirectory));

	onStatus(L("manage.installer.update.downloading"));
	double unusedProgress;
	if (!downloadFile(archiveUrl, archivePath, unusedProgress, 0.0, 1.0, error))
		return false;

	onStatus(L("manage.installer.update.verifying"));
	if (!archiveMatchesChecksum(archivePath, archiveUrl, error))
		return false;

	onStatus(L("manage.installer.update.extracting"));
	if (!unpackInstaller(archivePath, workDirectory, error)
		|| !newInstallerStarts(newInstallerPath, newVersion, error))
		return false;

	onStatus(L("manage.installer.update.installing"));
	try {
		// A rename swaps the file in one step, and this running installer keeps its old file open
		rename(newInstallerPath, installerPath());
	} catch (FileException fileException) {
		error = ERROR_REPLACE ~ fileException.msg;
		return false;
	}
	refreshInstallerLauncher();
	forgetFoundVersion();
	return true;
}

// Downloads a release of the installer, checks it and puts it in place of this installer
// The installer in place stays untouched until the new one proved that it starts
// Calls onStatus with a status text at each step
public bool updateInstaller(
	string newVersion,
	void delegate(string) onStatus,
	out string error) {
	writeln("installer update: updating ", INSTALLER_VERSION, " to ", newVersion);
	bool wasUpdated;
	try {
		wasUpdated = downloadCheckAndReplace(newVersion, onStatus, error);
	} catch (Exception exception) {
		// This runs on its own thread, where an error nobody catches would leave the update card waiting
		error = exception.msg;
	}
	if (wasUpdated)
		writeln("installer update: finished, ", installerPath(), " is now ", newVersion);
	else
		writeln("installer update: failed: ", error);
	return wasUpdated;
}
