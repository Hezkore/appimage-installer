// Shared utility functions
//
module apputils;

import core.stdc.stdlib : getenv;
import std.conv : octal, to;
import std.digest.crc : CRC32Digest, crcHexString;
import std.exception : ErrnoException;
import std.format : format;
import std.path : buildPath;
import std.regex : regex, matchFirst;
import std.stdio : File, writeln;

// Extracts the first version-like token (e.g. 4.5.3) from a filename string
public string parseVersionFromFilename(string filename) {
	auto versionMatch = matchFirst(
		filename,
		regex(`(\d+\.\d+(?:\.\d+)*)`, "g"));
	return versionMatch.empty ? "" : versionMatch[1];
}

// Formats a byte count as a human-readable string with appropriate unit
public string readableFileSize(ulong bytes) {

	immutable string[] units = ["bytes", "KB", "MB", "GB", "TB"];
	enum double BYTES_PER_KB = 1024.0;
	double size = cast(double) bytes;
	int unitIndex = 0;
	while (size >= BYTES_PER_KB && unitIndex < cast(int) units.length - 1) {
		size /= BYTES_PER_KB;
		unitIndex++;
	}
	return unitIndex == 0
		? "%d %s".format(cast(int) size, units[unitIndex]) : "%.2f %s".format(size, units[unitIndex]);
}

// Returns the current user's home directory from the HOME environment variable
public string homeDir() {
	return to!string(getenv("HOME"));
}

// Returns the XDG data home directory, respecting XDG_DATA_HOME
public string xdgDataHome() {
	string xdg = to!string(getenv("XDG_DATA_HOME"));
	if (xdg.length)
		return xdg;
	return buildPath(homeDir(), ".local", "share");
}

// Returns the XDG config home directory, respecting XDG_CONFIG_HOME
public string xdgConfigHome() {
	string xdg = to!string(getenv("XDG_CONFIG_HOME"));
	if (xdg.length)
		return xdg;
	return buildPath(homeDir(), ".config");
}

// Returns the app-specific config directory under XDG config home
public string configDir() {
	import constants : APP_ID;

	return buildPath(xdgConfigHome(), APP_ID);
}

// Returns the CRC32 hex string of the file at path, or "" on read failure
public string hashFile(string path) {
	auto digest = new CRC32Digest();
	try {
		auto f = File(path, "rb");
		ubyte[65_536] readBuffer;
		while (!f.eof) {
			auto chunk = f.rawRead(readBuffer[]);
			if (chunk.length == 0)
				break;
			digest.put(chunk);
		}
		f.close();
	} catch (ErrnoException) {
		return "";
	}
	return crcHexString(digest.finish());
}

// True when the default AppImage MIME handler is this installer's desktop file
// and that desktop file's Exec= points to the currently running binary
public bool isAppImageAssociated() {
	import std.file : thisExePath, exists;
	import std.process : execute, ProcessException;
	import std.string : strip, startsWith;
	import constants : INSTALLER_DESKTOP_FILE;

	try {
		auto result = execute([
			"xdg-mime", "query", "default", "application/vnd.appimage"
		]);
		if (result.status != 0
			|| result.output.strip() != INSTALLER_DESKTOP_FILE)
			return false;
	} catch (ProcessException) {
		return false;
	}

	string desktopPath = buildPath(
		xdgDataHome(), "applications", INSTALLER_DESKTOP_FILE);
	if (!exists(desktopPath))
		return false;
	// Empty locale falls back to the base Exec= value
	string execValue = readDesktopFieldLocalized(desktopPath, "Exec", "");
	string currentExe = thisExePath();
	import std.stdio : writeln;

	writeln("association check: Exec=", execValue, " current=", currentExe);
	return execValue.startsWith(currentExe);
}

// Writes the installer .desktop file to destPath, always overwriting
public bool writeInstallerDesktopFile(string destPath, out string error) {
	import std.file : write, FileException, mkdirRecurse, thisExePath;
	import std.path : dirName;
	import lang : availableLangs, translateIn;
	import constants : INSTALLER_DESKTOP_FILE;

	string baseName = translateIn("en", "app.name");
	string baseDesc = translateIn("en", "app.description");

	string localeNames = "Name=" ~ baseName ~ "\n";
	string localeDescs = "Comment=" ~ baseDesc ~ "\n";
	foreach (code; availableLangs()) {
		if (code == "en")
			continue;
		localeNames ~= "Name[" ~ code ~ "]=" ~ translateIn(code, "app.name") ~ "\n";
		localeDescs ~= "Comment[" ~ code ~ "]=" ~ translateIn(code, "app.description") ~ "\n";
	}

	try {
		mkdirRecurse(dirName(destPath));
		write(destPath,
			"[Desktop Entry]\n"
				~ "Type=Application\n"
				~ localeNames
				~ localeDescs
				~ "Icon=com.hezkore.appimage.installer\n"
				~ "Exec=" ~ thisExePath() ~ " %f\n"
				~ "MimeType=application/vnd.appimage;"
				~ "application/x-iso9660-appimage;\n"
				~ "NoDisplay=false\n");
	} catch (FileException fileException) {
		error = fileException.msg;
		return false;
	}
	return true;
}

// Registers desktopFileName as the default handler for both AppImage MIME types
public bool registerAppImages(string desktopFileName, out string error) {
	import std.process : execute, ProcessException;
	import constants : INSTALLER_DESKTOP_FILE;

	try {
		foreach (mime; [
				"application/vnd.appimage",
				"application/x-iso9660-appimage"
			]) {
			auto result = execute([
					"xdg-mime", "default", desktopFileName, mime
				]);
			if (result.status != 0) {
				error = "xdg-mime failed for " ~ mime;
				return false;
			}
		}
	} catch (ProcessException processException) {
		error = "xdg-mime not available: " ~ processException.msg;
		return false;
	}
	return true;
}

// Reads a desktop file field with locale fallback from [Desktop Entry] only.
// Tries key[locale]= first then falls back to key= and returns empty on any failure.
public string readDesktopFieldLocalized(string path, string key, string locale) {
	import std.file : readText, FileException;
	import std.string : splitLines, strip;

	try {
		string localePrefix = key ~ "[" ~ locale ~ "]=";
		string basePrefix = key ~ "=";
		string baseValue;
		bool inDesktopEntry = false;
		foreach (line; readText(path).splitLines()) {
			string stripped = line.strip();
			if (stripped.length && stripped[0] == '[') {
				if (stripped == "[Desktop Entry]") {
					inDesktopEntry = true;
				} else if (inDesktopEntry) {
					break; // Left [Desktop Entry], nothing more to find
				}
				continue;
			}
			if (!inDesktopEntry)
				continue;
			if (line.length > localePrefix.length
				&& line[0 .. localePrefix.length] == localePrefix)
				return line[localePrefix.length .. $];
			if (!baseValue.length && line.length > basePrefix.length
				&& line[0 .. basePrefix.length] == basePrefix)
				baseValue = line[basePrefix.length .. $];
		}
		return baseValue;
	} catch (FileException) {
		return "";
	}
}

// Writes a systemd user service unit that runs the background update check
public bool writeSystemdServiceFile(string destPath, int checkIntervalHours, out string error) {
	import std.file : write, FileException, mkdirRecurse, thisExePath;
	import std.path : dirName;
	import std.conv : to;

	try {
		mkdirRecurse(dirName(destPath));
		write(destPath,
			"[Unit]\n"
				~ "Description=AppImage Installer background update check\n"
				~ "\n"
				~ "[Service]\n"
				~ "Type=simple\n"
				~ "ExecStart=" ~ thisExePath()
				~ " --background-update --check-interval "
				~ to!string(
					checkIntervalHours) ~ "\n");
	} catch (FileException fileException) {
		error = fileException.msg;
		return false;
	}
	return true;
}

// Writes a systemd user timer unit that triggers the update service every 4 hours
public bool writeSystemdTimerFile(string destPath, out string error) {
	import std.file : write, FileException, mkdirRecurse;
	import std.path : dirName;

	try {
		mkdirRecurse(dirName(destPath));
		write(destPath,
			"[Unit]\n"
				~ "Description=Run AppImage Installer background update check\n"
				~ "\n"
				~ "[Timer]\n"
				~ "OnBootSec=5min\n"
				~ "OnUnitActiveSec=4h\n"
				~ "Persistent=true\n"
				~ "\n"
				~ "[Install]\n"
				~ "WantedBy=timers.target\n");
	} catch (FileException fileException) {
		error = fileException.msg;
		return false;
	}
	return true;
}

// Writes the desktop file then registers it as the default AppImage handler
public bool associateAppImages(out string error) {
	import constants : INSTALLER_DESKTOP_FILE;

	string desktopPath = buildPath(xdgDataHome(), "applications", INSTALLER_DESKTOP_FILE);
	if (!writeInstallerDesktopFile(desktopPath, error))
		return false;
	return registerAppImages(INSTALLER_DESKTOP_FILE, error);
}

// Writes the installer update flag file with the detected available version
public void writeInstallerUpdateFlag(string newVersion) {
	import std.json : JSONValue;
	import std.file : write, FileException, mkdirRecurse;
	import std.path : dirName;
	import constants : INSTALLER_FLAG_FILE_NAME;

	string path = buildPath(configDir(), INSTALLER_FLAG_FILE_NAME);
	try {
		mkdirRecurse(dirName(path));
		auto json = JSONValue(["version": JSONValue(newVersion)]);
		write(path, json.toPrettyString() ~ "\n");
	} catch (FileException) {
	}
}

// Returns the version from the installer update flag file, or empty if not found
public string readInstallerUpdateVersion() {
	import std.json : parseJSON, JSONType, JSONException;
	import std.file : exists, readText, FileException;
	import constants : INSTALLER_FLAG_FILE_NAME;

	string path = buildPath(configDir(), INSTALLER_FLAG_FILE_NAME);
	if (!exists(path))
		return "";
	try {
		auto json = parseJSON(readText(path));
		if (auto v = "version" in json)
			if (v.type == JSONType.string)
				return v.str;
	} catch (JSONException) {
	} catch (FileException) {
	}
	return "";
}

// Deletes the installer update flag file
public void clearInstallerUpdateFlag() {
	import std.file : exists, remove, FileException;
	import constants : INSTALLER_FLAG_FILE_NAME;

	string path = buildPath(configDir(), INSTALLER_FLAG_FILE_NAME);
	try {
		if (exists(path))
			remove(path);
	} catch (FileException) {
	}
}

// Reads the language code stored in config.json, or returns empty if not set
public string readConfigLang() {
	import std.json : parseJSON, JSONType, JSONException;
	import std.file : exists, readText, FileException;
	import constants : CONFIG_FILE_NAME;

	string path = buildPath(configDir(), CONFIG_FILE_NAME);
	if (!exists(path))
		return "";
	try {
		auto json = parseJSON(readText(path));
		if (auto v = "language" in json)
			if (v.type == JSONType.string)
				return v.str;
	} catch (JSONException) {
	} catch (FileException) {
	}
	return "";
}

// Writes the language code to config.json, preserving any other keys
public void writeConfigLang(string locale) {
	import std.json : parseJSON, JSONValue, JSONException;
	import std.file : exists, readText, write, mkdirRecurse, FileException;
	import std.path : dirName;
	import constants : CONFIG_FILE_NAME;

	string path = buildPath(configDir(), CONFIG_FILE_NAME);
	JSONValue json;
	if (exists(path)) {
		try {
			json = parseJSON(readText(path));
		} catch (JSONException) {
			json = JSONValue.emptyObject;
		} catch (FileException) {
			json = JSONValue.emptyObject;
		}
	} else {
		json = JSONValue.emptyObject;
	}
	json["language"] = locale;
	try {
		mkdirRecurse(dirName(path));
		write(path, json.toPrettyString() ~ "\n");
	} catch (FileException) {
	}
}

// Returns the best matching available language code from the OS locale, or empty
public string detectSystemLang() {
	import lang : availableLangs;
	import std.string : indexOf;

	string[] candidates = [
		to!string(getenv("LANGUAGE")),
		to!string(getenv("LANG")),
		to!string(getenv("LC_ALL")),
	];
	string[] available = availableLangs();
	foreach (raw; candidates) {
		if (!raw.length || raw == "(null)")
			continue;
		// LANGUAGE may be colon-separated so only the first entry is used
		auto colon = raw.indexOf(':');
		string first = colon >= 0 ? raw[0 .. colon] : raw;
		// Strip territory and encoding to get the base language code
		auto under = first.indexOf('_');
		auto dot = first.indexOf('.');
		long end = first.length;
		if (under >= 0 && under < end)
			end = under;
		if (dot >= 0 && dot < end)
			end = dot;
		string code = first[0 .. end];
		foreach (avail; available)
			if (avail == code)
				return code;
	}
	return "";
}

// Downloads and installs a specific version of the installer, replacing the running binary
// Calls onStatus with a human-readable status string during each phase
public bool downloadAndInstallSelf(
	string newVersion,
	void delegate(string) onStatus,
	out string error) {
	import std.file : thisExePath, copy, rename, setAttributes, FileException,
		mkdirRecurse;
	import std.net.curl : HTTP, CurlException;
	import std.process : execute, ProcessException;
	import lang : L;
	import constants : INSTALLER_ARCH, INSTALLER_GH_USER, INSTALLER_GH_REPO;
	import constants : INSTALLER_UPDATE_TEMP_DIRECTORY_PREFIX;
	import constants : TEMP_DIRECTORY_PATH;
	import update.common : MAX_HTTP_REDIRECTS;

	string tarName = "AppImage_Installer-" ~ newVersion ~ "-" ~ INSTALLER_ARCH ~ ".tar.gz";
	string url = "https://github.com/" ~ INSTALLER_GH_USER ~ "/"
		~ INSTALLER_GH_REPO ~ "/releases/download/" ~ newVersion ~ "/" ~ tarName;
	string updateDownloadTempDirectory =
		buildPath(TEMP_DIRECTORY_PATH,
			INSTALLER_UPDATE_TEMP_DIRECTORY_PREFIX ~ newVersion);
	string tarPath = buildPath(updateDownloadTempDirectory, tarName);

	try {
		mkdirRecurse(updateDownloadTempDirectory);
	} catch (FileException fileException) {
		error = "Cannot create temp dir: " ~ fileException.msg;
		return false;
	}

	onStatus(L("manage.installer.update.downloading"));
	try {
		File tarFile = File(tarPath, "wb");
		auto http = HTTP(url);
		http.maxRedirects(MAX_HTTP_REDIRECTS);
		http.onReceive = (ubyte[] chunk) {
			tarFile.rawWrite(chunk);
			return chunk.length;
		};
		http.perform();
		tarFile.close();
		immutable uint statusCode = http.statusLine.code;
		if (statusCode < 200 || statusCode >= 300) {
			error = "HTTP " ~ statusCode.to!string;
			return false;
		}
	} catch (CurlException curlException) {
		error = curlException.msg;
		return false;
	}

	onStatus(L("manage.installer.update.extracting"));
	try {
		auto result = execute([
			"tar",
			"xzf",
			tarPath,
			"-C",
			updateDownloadTempDirectory,
		]);
		if (result.status != 0) {
			error = result.output.length ? result.output : "tar failed";
			return false;
		}
	} catch (ProcessException processException) {
		error = processException.msg;
		return false;
	}

	onStatus(L("manage.installer.update.installing"));
	try {
		// Rename over running binary to avoid ETXTBSY from in-place overwrite
		string selfPath = thisExePath();
		string tmpSelf = selfPath ~ ".new";
		copy(
			buildPath(updateDownloadTempDirectory, "appimage-installer"),
			tmpSelf);
		setAttributes(tmpSelf, octal!755);
		rename(tmpSelf, selfPath);
	} catch (FileException fileException) {
		error = fileException.msg;
		return false;
	}

	string assocError;
	if (!associateAppImages(assocError) && assocError.length)
		writeln("apputils: could not refresh file association: ", assocError);
	return true;
}

// Returns the base directory where AppImages are installed
// Uses the value from config.json if set, otherwise returns the XDG default
public string installBaseDir() {
	import constants : APPIMAGES_DIR_NAME;

	string configured = readConfigInstallDir();
	if (configured.length)
		return configured;
	return buildPath(xdgDataHome(), APPIMAGES_DIR_NAME);
}

// Reads the GitHub personal access token from config.json, or returns ""
public string readConfigGithubToken() {
	import std.json : parseJSON, JSONType, JSONException;
	import std.file : exists, readText, FileException;
	import constants : CONFIG_FILE_NAME;

	string path = buildPath(configDir(), CONFIG_FILE_NAME);
	if (!exists(path))
		return "";
	try {
		auto json = parseJSON(readText(path));
		if (auto v = "githubToken" in json)
			if (v.type == JSONType.string)
				return v.str;
	} catch (JSONException) {
	} catch (FileException) {
	}
	return "";
}

// Writes the GitHub token to config.json, preserving any other keys
// Passing an empty string removes the key
public void writeConfigGithubToken(string token) {
	import std.json : parseJSON, JSONValue, JSONException;
	import std.file : exists, readText, write, mkdirRecurse, FileException;
	import std.path : dirName;
	import constants : CONFIG_FILE_NAME;

	string path = buildPath(configDir(), CONFIG_FILE_NAME);
	JSONValue json;
	if (exists(path)) {
		try {
			json = parseJSON(readText(path));
		} catch (JSONException) {
			json = JSONValue.emptyObject;
		} catch (FileException) {
			json = JSONValue.emptyObject;
		}
	} else {
		json = JSONValue.emptyObject;
	}
	if (token.length)
		json["githubToken"] = token;
	else if ("githubToken" in json)
		json.object.remove("githubToken");
	try {
		mkdirRecurse(dirName(path));
		write(path, json.toPrettyString() ~ "\n");
	} catch (FileException) {
	}
}

// Reads the custom AppImage install directory from config.json, or returns ""
public string readConfigInstallDir() {
	import std.json : parseJSON, JSONType, JSONException;
	import std.file : exists, readText, FileException;
	import constants : CONFIG_FILE_NAME;

	string path = buildPath(configDir(), CONFIG_FILE_NAME);
	if (!exists(path))
		return "";
	try {
		auto json = parseJSON(readText(path));
		if (auto v = "installDir" in json)
			if (v.type == JSONType.string)
				return v.str;
	} catch (JSONException) {
	} catch (FileException) {
	}
	return "";
}

// Writes the custom install directory to config.json, preserving any other keys
// Passing an empty string removes the key and reverts to the XDG default
public void writeConfigInstallDir(string dir) {
	import std.json : parseJSON, JSONValue, JSONException;
	import std.file : exists, readText, write, mkdirRecurse, FileException;
	import std.path : dirName;
	import constants : CONFIG_FILE_NAME;

	string path = buildPath(configDir(), CONFIG_FILE_NAME);
	JSONValue json;
	if (exists(path)) {
		try {
			json = parseJSON(readText(path));
		} catch (JSONException) {
			json = JSONValue.emptyObject;
		} catch (FileException) {
			json = JSONValue.emptyObject;
		}
	} else {
		json = JSONValue.emptyObject;
	}
	if (dir.length)
		json["installDir"] = dir;
	else if ("installDir" in json)
		json.object.remove("installDir");
	try {
		mkdirRecurse(dirName(path));
		write(path, json.toPrettyString() ~ "\n");
	} catch (FileException) {
	}
}
