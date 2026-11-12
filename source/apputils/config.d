// Config file I/O and language detection
//
module apputils.config;

import std.conv : to;
import std.path : buildPath;

import apputils.paths : configDir, xdgDataHome;

// Returns the base directory where AppImages are installed
// Uses the value from config.json if set, otherwise returns the XDG default
public string installBaseDir() {
	import constants : APPIMAGES_DIR_NAME;

	string configured = readConfigInstallDir();
	if (configured.length)
		return configured;
	return buildPath(xdgDataHome(), APPIMAGES_DIR_NAME);
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
