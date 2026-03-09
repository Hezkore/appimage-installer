// Path lookup and string utility functions
//
module apputils.paths;

import core.stdc.stdlib : getenv;
import std.conv : to;
import std.digest.crc : CRC32Digest, crcHexString;
import std.exception : ErrnoException;
import std.format : format;
import std.path : buildPath;
import std.regex : matchFirst, regex;
import std.stdio : File;

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

// Returns the path to the systemd user unit directory
public string systemdUserDir() {
	return buildPath(xdgConfigHome(), "systemd", "user");
}
