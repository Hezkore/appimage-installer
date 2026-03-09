// Install manifest backed by a JSON file inside the app metadata directory
//
module appimage.manifest;

import std.conv : to, ConvException;
import std.datetime : Clock;
import std.file : exists, readText, write, FileException;
import std.json : JSONException, JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.stdio : writeln;

import types : InstallMethod;
import constants : APPLICATIONS_SUBDIR, INSTALLER_VERSION, MANIFEST_FILE_NAME;

// One installed app's metadata stored on disk as JSON inside the app directory
class Manifest {
	string installerVersion = INSTALLER_VERSION;
	string installedAt;
	string appName;
	string appGenericName;
	string appComment;
	string releaseVersion;
	string sanitizedName;
	string originalSourceFile;
	string sourceFileName;
	string sourceFileSize;
	string sourceFileModified;
	string sourceFileHash;
	ubyte appImageType;
	string architecture;
	string updateInfo;
	string installedIconName;
	string appDirectory;
	string desktopSymlink;
	InstallMethod installMethod = InstallMethod.AppImage;
	bool updateAvailable;
	string lastCheckedAt;
	bool portableHome;
	bool portableConfig;

	private string loadedPath;

	// Canonical path to the manifest inside an app directory
	static string pathFor(string appDirectory) {
		return buildPath(appDirectory, APPLICATIONS_SUBDIR, MANIFEST_FILE_NAME);
	}

	// Load from an explicit file path
	// Returns null on any failure
	static Manifest load(string path) {
		if (!exists(path))
			return null;
		try {
			auto json = parseJSON(readText(path));
			auto manifest = new Manifest;
			manifest.loadedPath = path;

			string field(string key, string fallback = "") {
				auto jsonEntry = key in json;
				return (jsonEntry && jsonEntry.type == JSONType.string) ? jsonEntry.str : fallback;
			}

			manifest.installerVersion =
				field("installerVersion", INSTALLER_VERSION);
			manifest.installedAt = field("installedAt");
			manifest.appName = field("appName");
			manifest.appGenericName = field("appGenericName");
			manifest.appComment = field("appComment");
			manifest.releaseVersion = field("releaseVersion");
			manifest.sanitizedName = field("sanitizedName");
			// Read new key first, fall back to old key for manifests written before the rename
			string origSrc = field("originalSourceFile");
			manifest.originalSourceFile =
				origSrc.length ? origSrc : field("sourceFile");
			manifest.sourceFileName = field("sourceFileName");
			manifest.sourceFileSize = field("sourceFileSize");
			manifest.sourceFileModified = field("sourceFileModified");
			manifest.sourceFileHash = field("sourceFileHash");
			manifest.installedIconName = field("installedIconName");
			manifest.appDirectory = field("appDirectory");
			manifest.desktopSymlink = field("desktopSymlink");
			manifest.updateInfo = field("updateInfo");
			if (auto ua = "updateAvailable" in json)
				if (ua.type == JSONType.true_ || ua.type == JSONType.false_)
					manifest.updateAvailable = ua.type == JSONType.true_;
			manifest.lastCheckedAt = field("lastCheckedAt");
			if (auto ph = "portableHome" in json)
				if (ph.type == JSONType.true_ || ph.type == JSONType.false_)
					manifest.portableHome = ph.type == JSONType.true_;
			if (auto pc = "portableConfig" in json)
				if (pc.type == JSONType.true_ || pc.type == JSONType.false_)
					manifest.portableConfig = pc.type == JSONType.true_;

			if (auto typeEntry = "appImageType" in json)
				manifest.appImageType = cast(ubyte) typeEntry.integer;

			string rawMethod = field("installMethod", "appimage");
			try {
				manifest.installMethod = rawMethod.to!InstallMethod;
			} catch (ConvException) {
				manifest.installMethod = InstallMethod.AppImage;
			}

			return manifest;
		} catch (JSONException error) {
			writeln("Manifest.load: JSON error in ", path, ": ", error.msg);
			return null;
		} catch (FileException error) {
			writeln("Manifest.load: could not read ", path, ": ", error.msg);
			return null;
		}
	}

	// Load from the standard path inside an app directory
	// Returns null on any failure
	static Manifest loadFromAppDir(string appDirectory) {
		return load(pathFor(appDirectory));
	}

	// Save all fields to the path this was loaded from
	// Returns false on failure
	bool save() {
		return this.saveTo(this.loadedPath);
	}

	// Save all fields to an explicit path
	// Returns false on failure
	bool saveTo(string path) {
		if (!path.length) {
			writeln("Manifest.saveTo: no path given");
			return false;
		}
		try {
			auto json = this.buildJSON();
			write(path, json.toPrettyString() ~ "\n");
			writeln("Manifest written: ", path);
			return true;
		} catch (FileException error) {
			writeln("Manifest.saveTo: write failed: ", error.msg);
			return false;
		}
	}

	private JSONValue buildJSON() {
		auto json = JSONValue.emptyObject;
		json["installerVersion"] = this.installerVersion;
		json["installedAt"] = this.installedAt.length
			? this.installedAt
			: Clock.currTime.toISOExtString();
		json["appName"] = this.appName;
		json["appGenericName"] = this.appGenericName;
		json["appComment"] = this.appComment;
		json["releaseVersion"] = this.releaseVersion;
		json["sanitizedName"] = this.sanitizedName;
		json["originalSourceFile"] = this.originalSourceFile;
		json["sourceFileName"] = this.sourceFileName;
		json["sourceFileSize"] = this.sourceFileSize;
		json["sourceFileModified"] = this.sourceFileModified;
		json["sourceFileHash"] = this.sourceFileHash;
		json["appImageType"] = this.appImageType;
		json["architecture"] = this.architecture;
		json["updateInfo"] = this.updateInfo;
		json["installedIconName"] = this.installedIconName;
		json["appDirectory"] = this.appDirectory;
		json["desktopSymlink"] = this.desktopSymlink;
		json["installMethod"] = this.installMethod.to!string;
		json["updateAvailable"] = this.updateAvailable;
		json["lastCheckedAt"] = this.lastCheckedAt;
		json["portableHome"] = this.portableHome;
		json["portableConfig"] = this.portableConfig;
		return json;
	}
}
