// Config file I/O, language detection, installer flags, and self-update
//
module apputils.config;

import std.conv : octal, to;
import std.path : buildPath;
import std.stdio : File, writeln;

import apputils.paths : configDir, xdgDataHome;
import apputils.system : associateAppImages;
import constants : HTTP_SUCCESS_MIN, HTTP_SUCCESS_MAX;

// Returns the base directory where AppImages are installed
// Uses the value from config.json if set, otherwise returns the XDG default
public string installBaseDir() {
	import constants : APPIMAGES_DIR_NAME;

	string configured = readConfigInstallDir();
	if (configured.length)
		return configured;
	return buildPath(xdgDataHome(), APPIMAGES_DIR_NAME);
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
	import core.stdc.stdlib : getenv;
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
	import std.digest.sha : SHA256;
	import std.digest : toHexString, LetterCase;
	import std.exception : collectException;
	import std.file : thisExePath, copy, rename, setAttributes, FileException,
		mkdirRecurse, rmdirRecurse;
	import std.net.curl : HTTP, CurlException;
	import std.process : execute, ProcessException;
	import std.string : strip, indexOf;
	import lang : L;
	import constants : INSTALLER_ARCH, INSTALLER_GH_USER, INSTALLER_GH_REPO;
	import constants : INSTALLER_UPDATE_TEMP_DIRECTORY_PREFIX;
	import constants : TEMP_DIRECTORY_PATH;
	import update.common : MAX_HTTP_REDIRECTS;

	string tarName = "AppImage_Installer-" ~ newVersion ~ "-" ~ INSTALLER_ARCH ~ ".tar.gz";
	string releaseBase = "https://github.com/" ~ INSTALLER_GH_USER ~ "/"
		~ INSTALLER_GH_REPO ~ "/releases/download/" ~ newVersion ~ "/";
	string url = releaseBase ~ tarName;
	string checksumUrl = releaseBase ~ tarName ~ ".sha256";
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

	scope (exit)
		collectException(rmdirRecurse(updateDownloadTempDirectory));

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
		if (statusCode < HTTP_SUCCESS_MIN || statusCode >= HTTP_SUCCESS_MAX) {
			error = "HTTP " ~ statusCode.to!string;
			return false;
		}
	} catch (CurlException curlException) {
		error = curlException.msg;
		return false;
	}

	onStatus(L("manage.installer.update.verifying"));
	try {
		string checksumBody;
		int checksumStatus;
		auto checksumHttp = HTTP(checksumUrl);
		checksumHttp.maxRedirects(MAX_HTTP_REDIRECTS);
		checksumHttp.onReceive = (ubyte[] data) {
			checksumBody ~= cast(string) data;
			return data.length;
		};
		checksumHttp.onReceiveStatusLine = (HTTP.StatusLine sl) {
			checksumStatus = sl.code;
		};
		checksumHttp.perform();
		if (checksumStatus >= HTTP_SUCCESS_MIN && checksumStatus < HTTP_SUCCESS_MAX) {
			string line = checksumBody.strip();
			auto spacePos = line.indexOf(' ');
			string expectedHex = spacePos > 0 ? line[0 .. spacePos] : line;
			SHA256 sha;
			sha.start();
			auto tarFile = File(tarPath, "rb");
			scope (exit)
				tarFile.close();
			ubyte[65_536] buf;
			while (!tarFile.eof) {
				auto chunk = tarFile.rawRead(buf[]);
				if (chunk.length == 0)
					break;
				sha.put(chunk);
			}
			string actualHex = toHexString!(LetterCase.lower)(sha.finish()).idup;
			if (actualHex != expectedHex) {
				error = "Checksum mismatch: download may be corrupt or tampered";
				return false;
			}
			writeln("apputils: checksum verified for ", tarName);
		} else {
			writeln("apputils: no checksum available for ", tarName,
				", skipping verification");
		}
	} catch (CurlException curlException) {
		writeln("apputils: could not fetch checksum: ", curlException.msg);
	} catch (FileException fileException) {
		writeln("apputils: could not verify checksum: ", fileException.msg);
	}

	onStatus(L("manage.installer.update.extracting"));
	try {
		// Only extract the single binary we need so no other archive contents touch disk
		auto result = execute([
			"tar", "xzf", tarPath,
			"-C", updateDownloadTempDirectory,
			"--", "appimage-installer",
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

// Reads the background update check interval from config.json, defaults to 24
public int readConfigCheckIntervalHours() {
	import std.json : parseJSON, JSONType, JSONException;
	import std.file : exists, readText, FileException;
	import constants : CONFIG_FILE_NAME;

	string path = buildPath(configDir(), CONFIG_FILE_NAME);
	if (!exists(path))
		return 24;
	try {
		auto json = parseJSON(readText(path));
		if (auto v = "checkIntervalHours" in json)
			if (v.type == JSONType.integer)
				return cast(int) v.integer;
	} catch (JSONException) {
	} catch (FileException) {
	}
	return 24;
}

// Writes the background update check interval to config.json
public void writeConfigCheckIntervalHours(int hours) {
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
	json["checkIntervalHours"] = hours;
	try {
		mkdirRecurse(dirName(path));
		write(path, json.toPrettyString() ~ "\n");
	} catch (FileException) {
	}
}

// Reads the auto-update flag from config.json, defaults to false
public bool readConfigAutoUpdate() {
	import std.json : parseJSON, JSONType, JSONException;
	import std.file : exists, readText, FileException;
	import constants : CONFIG_FILE_NAME;

	string path = buildPath(configDir(), CONFIG_FILE_NAME);
	if (!exists(path))
		return false;
	try {
		auto json = parseJSON(readText(path));
		if (auto v = "autoUpdate" in json)
			if (v.type == JSONType.true_ || v.type == JSONType.false_)
				return v.type == JSONType.true_;
	} catch (JSONException) {
	} catch (FileException) {
	}
	return false;
}

// Writes the auto-update flag to config.json
public void writeConfigAutoUpdate(bool value) {
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
	json["autoUpdate"] = value;
	try {
		mkdirRecurse(dirName(path));
		write(path, json.toPrettyString() ~ "\n");
	} catch (FileException) {
	}
}

// Reads the systemd timer fire interval from config.json, defaults to 4
public int readConfigTimerIntervalHours() {
	import std.json : parseJSON, JSONType, JSONException;
	import std.file : exists, readText, FileException;
	import constants : CONFIG_FILE_NAME;

	string path = buildPath(configDir(), CONFIG_FILE_NAME);
	if (!exists(path))
		return 4;
	try {
		auto json = parseJSON(readText(path));
		if (auto v = "timerIntervalHours" in json)
			if (v.type == JSONType.integer)
				return cast(int) v.integer;
	} catch (JSONException) {
	} catch (FileException) {
	}
	return 4;
}

// Writes the systemd timer fire interval to config.json
public void writeConfigTimerIntervalHours(int hours) {
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
	json["timerIntervalHours"] = hours;
	try {
		mkdirRecurse(dirName(path));
		write(path, json.toPrettyString() ~ "\n");
	} catch (FileException) {
	}
}
