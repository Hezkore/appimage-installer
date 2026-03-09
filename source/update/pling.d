// Pling Store (pling-v1-zsync) update method
// Compares the best available AppImage filename against the installed one to detect updates
module update.pling;

import std.algorithm : sort;
import std.conv : to;
import std.exception : collectException;
import std.file : exists, remove, FileException;
import std.json : JSONException, JSONType, JSONValue, parseJSON;
import std.net.curl : CurlException, HTTP;
import std.path : buildPath, dirName;
import std.stdio : writeln;
import std.string : endsWith, startsWith, split, strip;

import update.common : downloadFile, finishInstall, readManifestFields;
import appimage.manifest : Manifest;
import types : InstallMethod;
import apputils : parseVersionFromFilename;
import constants : APPLICATIONS_SUBDIR, INSTALLER_NAME, UPDATE_SUBDIR;

private enum string PREFIX = "pling-v1-zsync|";
private enum string OCS_API_BASE =
	"https://api.opendesktop.org/ocs/v1/content/data/";

// Maximum numbered download slot to check per OCS product entry
private enum int OCS_MAX_DOWNLOADS = 1000;

// Progress fractions marking each phase of the Pling update
private enum Progress {
	start = 0.05,
	afterResolve = 0.1,
	afterDownload = 0.7,
	complete = 1.0,
}

// True when updateInfo encodes a Pling Store update method
public bool isPling(string updateInfo) {
	import update.common : parseUpdateMethodKind, UpdateMethodKind;

	return parseUpdateMethodKind(updateInfo) == UpdateMethodKind.PlingV1Zsync;
}

// Extracts the numeric product ID from a Pling updateInfo string
// Handles legacy entries that stored a full URL instead of a bare numeric ID
public string parsePlingId(string updateInfo) {
	auto fields = updateInfo[PREFIX.length .. $].split("|");
	string id = fields[0].strip();
	if (id.startsWith("http://") || id.startsWith("https://")) {
		import std.string : lastIndexOf;

		auto lastSlash = id.lastIndexOf('/');
		if (lastSlash >= 0 && lastSlash < cast(ptrdiff_t) id.length - 1)
			id = id[lastSlash + 1 .. $];
	}
	return id;
}

// Extracts the filename pattern from a Pling updateInfo string
public string parsePlingPattern(string updateInfo) {
	auto fields = updateInfo[PREFIX.length .. $].split("|");
	return fields.length >= 2 ? fields[1].strip() : "";
}

// Fetches product data from the OCS API and returns the content object
// Sets error and returns false on any network or parse failure
private bool fetchPlingContent(
	string productId,
	out JSONValue content,
	out string error,
	bool delegate() shouldCancel = null) {
	string apiUrl = OCS_API_BASE ~ productId ~ "?format=json";
	writeln("pling: fetching product data from ", apiUrl);
	string body;
	try {
		auto http = HTTP(apiUrl);
		http.addRequestHeader("User-Agent", INSTALLER_NAME);
		http.addRequestHeader("Accept", "application/json");
		http.onReceive = (ubyte[] data) {
			body ~= cast(string) data;
			return data.length;
		};
		if (shouldCancel !is null)
			http.onProgress = (ulong dlTotal, ulong dlNow, ulong ulTotal, ulong ulNow) {
			return shouldCancel() ? 1 : 0;
		};
		http.perform();
	} catch (CurlException curlException) {
		error = "Pling API request failed: " ~ curlException.msg;
		return false;
	}
	JSONValue json;
	try {
		json = parseJSON(body);
	} catch (JSONException jsonException) {
		error = "Pling API response parse failed: " ~ jsonException.msg;
		return false;
	}
	auto dataPtr = "data" in json;
	if (dataPtr is null || dataPtr.type != JSONType.array
		|| dataPtr.array.length == 0) {
		error = "Unexpected Pling API response format";
		return false;
	}
	content = dataPtr.array[0];
	return true;
}

// Queries the Pling OCS API for product files matching pattern
// Sorts by filename descending and returns the direct URL of the best match
private bool resolvePlingBestMatch(
	string productId,
	string pattern,
	out string downloadUrl,
	out string bestName,
	out string error,
	bool delegate() shouldCancel = null) {
	JSONValue content;
	if (!fetchPlingContent(productId, content, error, shouldCancel))
		return false;
	import std.path : globMatch;

	string[] matchingNames;
	string[string] linkForName;
	foreach (i; 1 .. OCS_MAX_DOWNLOADS) {
		auto namePtr = ("downloadname" ~ i.to!string) in content;
		auto linkPtr = ("downloadlink" ~ i.to!string) in content;
		if (namePtr is null || linkPtr is null)
			break;
		string name = namePtr.str.strip();
		string link = linkPtr.str.strip();
		if (name.length == 0 || link.length == 0)
			continue;
		if (globMatch(name, pattern) || name.endsWith(".AppImage")
			|| name.endsWith(".appimage")) {
			matchingNames ~= name;
			linkForName[name] = link;
		}
	}
	if (matchingNames.length == 0) {
		error = "No AppImage file found for product " ~ productId;
		return false;
	}
	matchingNames.sort!((a, b) => a > b)();
	bestName = matchingNames[0];
	downloadUrl = linkForName[bestName];
	writeln("pling: best match ", bestName, " -> ", downloadUrl);
	return true;
}

// Queries the OCS API for productId and finds the best matching AppImage download
// Sets downloadUrl and pattern on success, error on failure
public bool resolvePlingAppImageUrl(
	string productId,
	out string downloadUrl,
	out string pattern,
	out string appName,
	out string iconUrl,
	out string error) {
	JSONValue content;
	if (!fetchPlingContent(productId, content, error))
		return false;
	auto productNamePtr = "name" in content;
	if (productNamePtr !is null && productNamePtr.type == JSONType.string)
		appName = productNamePtr.str.strip();
	auto productIconPtr = "smallpreviewpic1" in content;
	if (productIconPtr is null)
		productIconPtr = "previewpic1" in content;
	if (productIconPtr !is null && productIconPtr.type == JSONType.string)
		iconUrl = productIconPtr.str.strip();
	string[] matchingNames;
	string[string] linkForName;
	foreach (i; 1 .. OCS_MAX_DOWNLOADS) {
		auto namePtr = ("downloadname" ~ i.to!string) in content;
		auto linkPtr = ("downloadlink" ~ i.to!string) in content;
		if (namePtr is null || linkPtr is null)
			break;
		string name = namePtr.str.strip();
		string link = linkPtr.str.strip();
		if (name.length == 0 || link.length == 0)
			continue;
		if (name.endsWith(".AppImage") || name.endsWith(".appimage")) {
			matchingNames ~= name;
			linkForName[name] = link;
		}
	}
	if (matchingNames.length == 0) {
		error = "No .AppImage found for product " ~ productId;
		return false;
	}
	matchingNames.sort!((a, b) => a > b)();
	pattern = matchingNames[0];
	downloadUrl = linkForName[pattern];
	writeln("pling: resolved AppImage ", pattern, " -> ", downloadUrl);
	return true;
}

// Checks whether a Pling update is available by comparing the best available
// AppImage filename against the installed filename stored in updateInfo
public bool checkPlingForUpdate(
	string appDirectory,
	string sanitizedName,
	string updateInfo,
	out bool available,
	out string error,
	bool delegate() shouldCancel = null) {
	string bestUrl, bestName;
	if (!resolvePlingBestMatch(
			parsePlingId(updateInfo), parsePlingPattern(updateInfo),
			bestUrl, bestName, error, shouldCancel))
		return false;
	string storedPattern = parsePlingPattern(updateInfo);
	if (storedPattern.length == 0) {
		// No baseline yet - compare against the file that was actually installed
		// so we don't falsely mark a newer version as already installed
		auto installedAppManifest = Manifest.loadFromAppDir(appDirectory);
		string installedName =
			installedAppManifest !is null
			? installedAppManifest.sourceFileName ~ ".AppImage" : "";
		if (installedName.length > ".AppImage".length
			&& bestName == installedName) {
			installedAppManifest.updateInfo =
				PREFIX ~ parsePlingId(updateInfo) ~ "|" ~ bestName;
			installedAppManifest.save();
			available = false;
			writeln("pling: baseline confirmed from install, ",
				bestName, " is current");
		} else {
			available = true;
			writeln("pling: no baseline match, update available: ", bestName);
		}
		return true;
	}
	available = bestName != storedPattern;
	writeln("pling: installed=", storedPattern,
		" latest=", bestName,
		" available=", available);
	return true;
}

// Downloads the best available AppImage from Pling and replaces the installed version
public bool performPlingUpdate(
	string appDirectory,
	string sanitizedName,
	string updateInfo,
	ref double progress,
	ref string progressText,
	out bool wasUpdated,
	out string errorMessage,
	bool delegate() shouldCancel = null,
	bool force = false) {
	progress = Progress.start;
	progressText = "update.pling.status.start";
	wasUpdated = true;

	string bestUrl, bestName;
	if (!resolvePlingBestMatch(
			parsePlingId(updateInfo), parsePlingPattern(updateInfo),
			bestUrl, bestName, errorMessage, shouldCancel)) {
		wasUpdated = false;
		return false;
	}

	if (shouldCancel !is null && shouldCancel()) {
		wasUpdated = false;
		return false;
	}

	if (!force && bestName == parsePlingPattern(updateInfo)) {
		wasUpdated = false;
		return true;
	}

	InstallMethod installMethod;
	if (!readManifestFields(appDirectory, installMethod, errorMessage))
		return false;

	string tempPath;
	if (installMethod == InstallMethod.AppImage) {
		import std.file : mkdirRecurse;

		string updateDir = buildPath(
			appDirectory, APPLICATIONS_SUBDIR, UPDATE_SUBDIR);
		try {
			mkdirRecurse(updateDir);
		} catch (FileException error) {
			errorMessage = "Could not create update directory: " ~ error.msg;
			return false;
		}
		tempPath = buildPath(updateDir, sanitizedName ~ ".AppImage");
	} else {
		tempPath = buildPath(
			dirName(appDirectory),
			"." ~ sanitizedName ~ ".update.AppImage");
	}

	scope (failure) {
		if (exists(tempPath))
			collectException(remove(tempPath));
	}

	progress = Progress.afterResolve;
	progressText = "update.pling.status.downloading";
	if (!downloadFile(bestUrl, tempPath, progress,
			Progress.afterResolve, Progress.afterDownload,
			errorMessage, shouldCancel)) {
		wasUpdated = false;
		return false;
	}

	if (!finishInstall(tempPath, appDirectory, sanitizedName,
			installMethod, progress,
			Progress.afterDownload, Progress.complete,
			progressText,
			"update.pling.status.installing",
			"update.pling.status.extracting", errorMessage,
			false, shouldCancel))
		return false;

	// Record the new filename and version so the next check shows up to date.
	// Pling filename is the canonical version source for apps without X-AppImage-Version=
	auto installedAppManifest = Manifest.loadFromAppDir(appDirectory);
	if (installedAppManifest !is null) {
		installedAppManifest.updateInfo =
			PREFIX ~ parsePlingId(updateInfo) ~ "|" ~ bestName;
		string parsedVersion = parseVersionFromFilename(bestName);
		if (parsedVersion.length)
			installedAppManifest.releaseVersion = parsedVersion;
		installedAppManifest.save();
	}
	writeln("pling: updated to ", bestName);
	return true;
}
