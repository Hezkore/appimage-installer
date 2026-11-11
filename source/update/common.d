// Shared post-download install steps used by all update methods
//
module update.common;

import std.conv : to;
import std.exception : collectException, ErrnoException;
import std.file : FileException, exists, rename, rmdir, setAttributes;
static import std.file;
import std.process : ProcessException;
import std.net.curl : HTTP, CurlException;
import std.path : buildPath, dirName;
import std.regex : replaceAll, regex;
import std.stdio : File, writeln;

import appimage : AppImage;
import appimage.elf : readElfInfo;
import appimage.icon : installIconFromCachedData;
import appimage.install : writeDesktopFile, applyUserSettings;
import appimage.manifest : Manifest, fileStamp;
import appimage.signature : SignatureStatus, SignatureResult, checkSignature;
import types : InstallMethod;
import constants : APPIMAGE_EXEC_MODE, APPLICATIONS_SUBDIR, DESKTOP_SUFFIX,
	HTTP_SUCCESS_MIN, HTTP_SUCCESS_MAX;

// The part of a file name that changes with each release: a version such as 2.25.5,
// a build number of four or more digits, or a commit hash
private enum string VERSION_TOKEN =
	r"\d+(?:\.\d+)+|(?<![A-Za-z0-9])(?:\d{4,}|(?=[0-9a-f]*\d)[0-9a-f]{7,40})(?![A-Za-z0-9])";

// Removes version numbers from a file name, so two releases of one build compare equal
public string withoutVersion(string fileName) {
	return replaceAll(fileName, regex(VERSION_TOKEN), "");
}

// Replaces exact version tokens in gh-releases asset patterns with * so the
// pattern keeps matching after the app is updated to a new version
public string normalizeUpdateInfoPattern(string updateInfo) {
	import std.array : join, replace, split;
	import std.string : indexOf, startsWith;

	bool isGhRelease = updateInfo.startsWith("gh-releases|");
	bool isGhZsync = updateInfo.startsWith("gh-releases-zsync|");
	if (!isGhRelease && !isGhZsync)
		return updateInfo;
	auto fields = updateInfo.split("|");
	if (fields.length < 5)
		return updateInfo;
	// GitHub stores spaces in uploaded asset names as dots
	string pattern = fields[$ - 1].replace(" ", ".");
	if (pattern.indexOf('*') < 0)
		pattern = replaceAll(pattern, regex(VERSION_TOKEN), "*");
	fields[$ - 1] = pattern;
	return fields.join("|");
}

// Identifies which update method a raw updateInfo string encodes
public enum UpdateMethodKind {
	DirectLink,
	Zsync,
	GitHubZsync,
	GitHubRelease,
	GitHubLinuxManifest,
	PlingV1Zsync,
	Unknown,
}

// Returns the update method kind from a raw updateInfo string
public UpdateMethodKind parseUpdateMethodKind(string updateInfo) {
	import std.string : startsWith;

	if (updateInfo.startsWith("direct-link|"))
		return UpdateMethodKind.DirectLink;
	if (updateInfo.startsWith("zsync|"))
		return UpdateMethodKind.Zsync;
	if (updateInfo.startsWith("gh-releases-zsync|"))
		return UpdateMethodKind.GitHubZsync;
	if (updateInfo.startsWith("gh-releases|"))
		return UpdateMethodKind.GitHubRelease;
	if (updateInfo.startsWith("gh-linux-yml|"))
		return UpdateMethodKind.GitHubLinuxManifest;
	if (updateInfo.startsWith("pling-v1-zsync|"))
		return UpdateMethodKind.PlingV1Zsync;
	return UpdateMethodKind.Unknown;
}

// Maximum number of HTTP redirects to follow per request
public enum int MAX_HTTP_REDIRECTS = 10;

// Fraction of the [progressStart, progressEnd] range where each extracted-mode
// phase completes, matching the spacing used in the original directlink enums
private enum double LOAD_FRAC = 0.375;

private bool isCancelled(bool delegate() shouldCancel) {
	return shouldCancel !is null && shouldCancel();
}

// Downloads url to destinationPath using libcurl, reporting progress in real time
// Return true from shouldCancel on any tick to stop the transfer early
public bool downloadFile(
	string url,
	string destinationPath,
	ref double progress,
	double progressStart,
	double progressEnd,
	out string errorMessage,
	bool delegate() shouldCancel = null) {
	writeln("download: ", url);
	File outFile;
	try {
		outFile = File(destinationPath, "wb");
	} catch (ErrnoException error) {
		errorMessage = "Could not open temp file: " ~ error.msg;
		return false;
	}
	auto http = HTTP(url);
	http.maxRedirects(MAX_HTTP_REDIRECTS);
	http.onProgress = (size_t dlTotal, size_t dlNow, size_t ulTotal, size_t ulNow) {
		if (shouldCancel !is null && shouldCancel())
			return 1;
		if (dlTotal > 0) {
			double frac = cast(double) dlNow / dlTotal;
			progress = progressStart + frac * (progressEnd - progressStart);
		}
		return 0;
	};
	http.onReceive = (ubyte[] data) { outFile.rawWrite(data); return data.length; };
	try {
		http.perform();
		outFile.close();
	} catch (CurlException error) {
		errorMessage = error.msg;
		if (outFile.isOpen)
			outFile.close();
		return false;
	}
	immutable uint statusCode = http.statusLine.code;
	if (statusCode < HTTP_SUCCESS_MIN || statusCode >= HTTP_SUCCESS_MAX) {
		errorMessage = "HTTP " ~ statusCode.to!string;
		return false;
	}
	return true;
}

// Sets permissions to 755 so the AppImage can be executed
public void makeExecutable(string path) {
	setAttributes(path, APPIMAGE_EXEC_MODE);
}

// Remounts the AppImage to refresh its icon and version, and rewrites the desktop file
// with the Update and Uninstall actions
// installMethod says how the app runs: from that AppImage, or from the files extracted into appDirectory
public void reapplyAppIntegration(
	string appImagePath,
	string appDirectory,
	string sanitizedName,
	InstallMethod installMethod) {
	import glib.error : ErrorWrap;

	string metaDir = buildPath(appDirectory, APPLICATIONS_SUBDIR);
	string desktopPath = buildPath(metaDir, sanitizedName ~ DESKTOP_SUFFIX);
	// Taken before the read, so a file replaced while we read counts as changed next time
	string stampBeforeRead = fileStamp(appImagePath);

	auto updatedApp = new AppImage(appImagePath);
	updatedApp.installAs(sanitizedName);
	updatedApp.installMethod = installMethod;
	auto manifestBeforeRead = Manifest.loadFromAppDir(appDirectory);
	if (manifestBeforeRead !is null)
		updatedApp.installedIconName = manifestBeforeRead.installedIconName;

	try {
		updatedApp.loadBasicInfo();
		updatedApp.loadFullInfo();
	} catch (ErrnoException error) {
		writeln("update: could not load new AppImage info: ", error.msg);
	} catch (ErrorWrap error) {
		writeln("update: could not load new AppImage info: ", error.msg);
	} catch (ProcessException error) {
		writeln("update: could not load new AppImage info: ", error.msg);
	} catch (FileException error) {
		writeln("update: could not load new AppImage info: ", error.msg);
	}

	// An AppImage we could not read keeps the desktop file and icon it has
	if (updatedApp.isFullyLoaded && updatedApp.cachedIconBytes.length)
		installIconFromCachedData(updatedApp);

	// Loaded only now, so nothing saved while the AppImage was mounted is lost or written back stale
	auto installedAppManifest = Manifest.loadFromAppDir(appDirectory);
	if (updatedApp.isFullyLoaded) {
		if (installedAppManifest !is null)
			applyUserSettings(updatedApp, installedAppManifest);
		if (installMethod == InstallMethod.Extracted)
			writeDesktopFile(updatedApp, desktopPath, appDirectory, buildPath(appDirectory, "AppRun"));
		else
			writeDesktopFile(updatedApp, desktopPath, "", appImagePath);
	}
	if (installedAppManifest is null)
		return;
	// Saved for an unreadable file too, so that file is not read again until it changes
	installedAppManifest.installedFileStamp = stampBeforeRead;
	if (updatedApp.isFullyLoaded) {
		if (updatedApp.installedIconName.length)
			installedAppManifest.installedIconName = updatedApp.installedIconName;
		if (updatedApp.releaseVersion.length)
			installedAppManifest.releaseVersion = updatedApp.releaseVersion;
		installedAppManifest.architecture = updatedApp.architecture;
		// After applyUserSettings these hold what the user set, or else what the new version says
		// An AppImage without a desktop entry has only its file name to offer, so the saved name stays
		if (updatedApp.hasDesktopEntry) {
			installedAppManifest.appName = updatedApp.appName;
			installedAppManifest.appComment = updatedApp.appComment;
		}
	}
	installedAppManifest.save();
}

// Reads an app's details again when its AppImage was replaced from outside, such as by the app's own updater
// Returns true when the details were read again
public bool reapplyIfFileChanged(string appDirectory, string sanitizedName) {
	auto installedAppManifest = Manifest.loadFromAppDir(appDirectory);
	if (installedAppManifest is null || installedAppManifest.installMethod != InstallMethod.AppImage)
		return false;
	string appImagePath = buildPath(appDirectory, sanitizedName ~ ".AppImage");
	if (!exists(appImagePath))
		return false;
	string currentStamp = fileStamp(appImagePath);
	if (installedAppManifest.installedFileStamp == currentStamp)
		return false;
	// An install from before stamps existed has nothing to compare with, so it starts from the file as it is
	if (!installedAppManifest.installedFileStamp.length) {
		installedAppManifest.installedFileStamp = currentStamp;
		installedAppManifest.save();
		return false;
	}
	writeln("update: ", appImagePath, " changed since it was last read");
	reapplyAppIntegration(appImagePath, appDirectory, sanitizedName, InstallMethod.AppImage);
	return true;
}

// Reads installMethod from the manifest at appDirectory
public bool readManifestFields(
	string appDirectory,
	out InstallMethod method,
	out string errorMessage) {
	method = InstallMethod.AppImage;
	auto installedAppManifest = Manifest.loadFromAppDir(appDirectory);
	if (installedAppManifest is null) {
		errorMessage = "Manifest not found in: " ~ appDirectory;
		return false;
	}
	method = installedAppManifest.installMethod;
	return true;
}

private enum string NOT_AN_APPIMAGE_ERROR = "The file is not an AppImage.";

// Final install step shared by all update methods, handles AppImage and Extracted modes
// Pass skipSigCheck when the user has already been warned about a bad or missing signature
public bool finishInstall(
	string tempPath,
	string appDirectory,
	string sanitizedName,
	InstallMethod installMethod,
	ref double progress,
	double progressStart,
	double progressEnd,
	ref string progressText,
	string textInstalling,
	string textExtracting,
	out string errorMessage,
	bool skipSigCheck = false,
	bool delegate() shouldCancel = null) {
	if (isCancelled(shouldCancel))
		return false;

	// A download can be anything, such as a web page from a link that moved
	if (!(new AppImage(tempPath)).isAppImageFile()) {
		collectException(std.file.remove(tempPath));
		errorMessage = NOT_AN_APPIMAGE_ERROR;
		return false;
	}

	// Verify GPG signature before touching anything on disk
	if (!skipSigCheck) {
		auto elfInfo = readElfInfo(tempPath);
		if (elfInfo.sigSectionOffset != 0) {
			auto sigResult = checkSignature(tempPath, elfInfo.sigSectionOffset, elfInfo
					.sigSectionSize);
			// Only block on a confirmed bad signature, unverifiable keys pass through
			if (sigResult.status == SignatureStatus.Invalid) {
				errorMessage = "sig:invalid:" ~ tempPath;
				return false;
			}
		}
	}

	double span = progressEnd - progressStart;
	progress = progressStart;
	progressText = textInstalling;
	if (isCancelled(shouldCancel))
		return false;

	if (installMethod == InstallMethod.AppImage) {
		string dest = buildPath(appDirectory, sanitizedName ~ ".AppImage");
		try {
			rename(tempPath, dest);
		} catch (FileException error) {
			errorMessage = error.msg;
			return false;
		}
		try {
			makeExecutable(dest);
		} catch (FileException error) {
			errorMessage = "Could not make AppImage executable: " ~ error.msg;
			return false;
		}
		collectException(rmdir(dirName(tempPath)));
		progress = progressEnd;
		writeln("update: replaced AppImage at ", dest);
		reapplyAppIntegration(dest, appDirectory, sanitizedName, InstallMethod.AppImage);
		// The new file is the latest release, so the stored flag is now stale
		auto updatedManifest = Manifest.loadFromAppDir(appDirectory);
		if (updatedManifest !is null && updatedManifest.updateAvailable) {
			updatedManifest.updateAvailable = false;
			updatedManifest.save();
		}
		return true;
	}

	// For Extracted mode, re-run the full install from the new AppImage
	try {
		makeExecutable(tempPath);
	} catch (FileException error) {
		errorMessage = "Could not make AppImage executable: " ~ error.msg;
		return false;
	}
	if (isCancelled(shouldCancel))
		return false;

	auto newApp = new AppImage(tempPath);
	newApp.installAs(sanitizedName);
	newApp.installMethod = InstallMethod.Extracted;

	import glib.error : ErrorWrap;

	try {
		newApp.loadBasicInfo();
		newApp.loadFullInfo();
	} catch (ErrnoException error) {
		errorMessage = "Failed to read new AppImage: " ~ error.msg;
		return false;
	} catch (ErrorWrap error) {
		errorMessage = "Failed to read new AppImage: " ~ error.msg;
		return false;
	} catch (ProcessException error) {
		errorMessage = "Failed to read new AppImage: " ~ error.msg;
		return false;
	} catch (FileException error) {
		errorMessage = "Failed to read new AppImage: " ~ error.msg;
		return false;
	}
	// Nothing installed is touched for a download that cannot be read
	if (!newApp.isFullyLoaded) {
		errorMessage = "Failed to read new AppImage.";
		return false;
	}
	if (isCancelled(shouldCancel))
		return false;

	progress = progressStart + LOAD_FRAC * span;
	progressText = textExtracting;

	// install() keeps what the user set and the portable data, since the app is installed already
	auto oldManifest = Manifest.loadFromAppDir(appDirectory);
	if (!newApp.install()) {
		errorMessage = "Extraction failed.";
		return false;
	}

	// The download had only a temporary name, so the app still counts as coming from its first file
	if (oldManifest !is null) {
		auto installedAppManifest =
			Manifest.loadFromAppDir(newApp.installedAppDirectory);
		if (installedAppManifest !is null) {
			installedAppManifest.keepSourceFrom(oldManifest);
			installedAppManifest.save();
		}
	}

	progress = progressEnd;
	writeln("update: re-extracted and installed ", sanitizedName);
	return true;
}

// Calls finishInstall with the signature check bypassed after the user has accepted the risk
public bool retryInstallAfterSig(
	string tempPath,
	string appDirectory,
	string sanitizedName,
	InstallMethod installMethod,
	ref double progress,
	double progressStart,
	double progressEnd,
	ref string progressText,
	string textInstalling,
	string textExtracting,
	out string errorMessage,
	bool delegate() shouldCancel = null) {
	return finishInstall(
		tempPath, appDirectory, sanitizedName, installMethod,
		progress, progressStart, progressEnd,
		progressText, textInstalling, textExtracting,
		errorMessage, true, shouldCancel);
}
