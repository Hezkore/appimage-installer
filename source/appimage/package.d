// Metadata loading and installation logic for a single .AppImage file
//
module appimage;

import std.stdio : writeln, File;
import std.algorithm : canFind, endsWith;
import std.array : array;
import std.exception : collectException, ErrnoException;
import std.file;
import std.format : format;
import std.path;
import std.regex : regex, replaceAll;
import std.string : strip, startsWith, toLower, replace, split, indexOf;
import std.conv : to;
import std.digest.crc;
import std.datetime : SysTime;

import gdk.texture : Texture;
import gtk.image : Image;
import gio.file : GioFile = File;
import gio.types : FileQueryInfoFlags;
import glib.error : ErrorWrap;

import apputils : readableFileSize;
static import appimage.install;
static import appimage.icon;

import types : InstallMethod;
import constants : APPIMAGES_DIR_NAME, APPLICATIONS_SUBDIR, MANIFEST_FILE_NAME,
	DESKTOP_SUFFIX, APPIMAGE_FUSE_MOUNT_PREFIX;
import constants : APPIMAGE_EXEC_MODE;
import appimage.elf : readElfInfo;
import appimage.signature : SignatureStatus, SignatureResult, checkSignature;
import lang : L;

// Like std.file.isSymlink but never throws
// Returns false for missing or inaccessible paths
public bool pathIsSymlink(string path) {
	bool result;
	return collectException(isSymlink(path), result) is null && result;
}

// Metadata and loading logic for a single .AppImage file
class AppImage {
	private enum uint MOUNT_RETRY_MAX = 100;
	private enum int MOUNT_RETRY_MS = 100;
	private enum int HASH_BUFFER_SIZE = 4096; // Bytes

	string filePath;
	string fileName; // Basename without extension
	string fileSize;
	string fileModified;
	string fileHash;
	string mimeType;
	string defaultIconName; // Fallback system icon name
	string appName;
	string appGenericName;
	string appComment;
	string releaseVersion;
	Image appIconWidget;
	string[] desktopFileLines;
	string sanitizedName; // Filesystem-safe lowercase, used for install dirs
	bool isFullyLoaded;
	// Theme icon name registered in hicolor after install
	string installedIconName;
	string installedAppDirectory; // ~/.local/share/appimages/<sanitizedName>/
	// Symlink path in ~/.local/share/applications/
	string installedDesktopSymlinkPath;
	// Path to the .AppImage inside installedAppDirectory in AppImage mode
	string appImageDestPath;
	InstallMethod installMethod = InstallMethod.AppImage;
	// Set before install() when an existing portable.home or portable.config should be preserved
	bool portableHome;
	bool portableConfig;
	// Written by the worker thread so the main thread can poll the progress bar
	shared double installProgress;

	// Icon bytes and extension captured inside loadFullInfo() while the AppImage is still mounted
	// Used by the AppImage-mode installer so a second mount is not needed
	public ubyte[] cachedIconBytes;
	public string cachedIconExtension;

	ubyte appImageType; // 1 = ISO 9660 + ELF (legacy), 2 = ELF + squashfs (common)
	// Target CPU architecture, e.g. "x86_64" from ELF e_machine
	string architecture;
	// Update transport string from .upd_info ELF section, if present
	string updateInfo;
	// When set before installation, overrides the ELF updateInfo in the manifest
	public string pendingUpdateInfo;
	// Signature verification result, checked during loadBasicInfo()
	SignatureStatus signatureStatus;
	// PGP issuer key ID extracted from the .sha256_sig section, e.g. "ABCDEF1234567890"
	string signatureKeyId;

	private string computeHash() {
		try {
			auto hashDigest = new CRC32Digest();
			ubyte[HASH_BUFFER_SIZE] buffer;
			auto file = File(this.filePath, "rb");
			scope (exit)
				file.close();
			while (true) {
				auto bytesRead = file.rawRead(buffer[]);
				if (bytesRead.length == 0)
					break;
				hashDigest.put(bytesRead);
			}
			return crcHexString(hashDigest.finish());
		} catch (ErrnoException error) {
			return L("common.unknown");
		}
	}

	private static string buildSanitizedName(string displayName) {
		import std.uni : toLower;

		string result = displayName.strip();
		result = result.replace(" ", "_");
		result = result.replaceAll(regex(r"[^a-zA-Z0-9_-]"), "_");
		return result.toLower();
	}

	this(string filePath) {
		this.filePath = filePath;
		this.fileName = filePath.baseName.stripExtension;

		this.fileSize = L("common.unknown");
		this.fileModified = L("common.unknown");
		this.fileHash = L("common.unknown");
		this.mimeType = "application-x-executable";
		this.defaultIconName = "application-x-executable";

		this.appName = this.fileName;
		this.appGenericName = "";
		this.appComment = "";
		this.releaseVersion = "";
		this.sanitizedName = this.fileName;
	}

	void loadBasicInfo() {
		this.fileSize = readableFileSize(std.file.getSize(this.filePath));
		writeln("File size: ", this.fileSize);

		try {
			SysTime accessTime, modificationTime;
			std.file.getTimes(this.filePath, accessTime, modificationTime);
			auto utcModTime = modificationTime.toUTC();
			this.fileModified = "%04d-%02d-%02d %02d:%02d:%02d".format(utcModTime.year, utcModTime.month, utcModTime
					.day,
					utcModTime.hour, utcModTime.minute, utcModTime.second);
		} catch (FileException error) {
			this.fileModified = L("common.unknown");
		}
		writeln("Modified: ", this.fileModified);

		this.fileHash = this.computeHash();
		writeln("CRC32: ", this.fileHash);

		auto elfInfo = readElfInfo(this.filePath);
		this.appImageType = elfInfo.appImageType;
		this.architecture = elfInfo.architecture;
		this.updateInfo = elfInfo.updateInfo;
		writeln("AppImage type: ", this.appImageType);
		writeln("Architecture: ", this.architecture);
		if (this.updateInfo.length)
			writeln("Update info: ", this.updateInfo);
		auto sigResult = checkSignature(
			this.filePath, elfInfo.sigSectionOffset, elfInfo.sigSectionSize);
		this.signatureStatus = sigResult.status;
		this.signatureKeyId = sigResult.keyId;
		writeln("Signature status: ", this.signatureStatus);

		try {
			auto gioFile = GioFile.newForPath(this.filePath);
			auto info = gioFile.queryInfo(
				"standard::content-type,standard::icon",
				FileQueryInfoFlags.None, null);

			this.mimeType = info.getAttributeString("standard::content-type");

			auto icon = info.getIcon();
			if (icon !is null) {
				foreach (part; icon.toString_().split(' ')) {
					if (part.length == 0 || part == "." ||
						(part.startsWith("G") && part.endsWith("Icon")))
						continue;
					this.defaultIconName = part;
					break;
				}
			}
		} catch (ErrorWrap error) {
			writeln("appimage: MIME type detection failed: ", error.msg);
			this.mimeType = "application/octet-stream";
			this.defaultIconName = "application-x-executable";
		}
		writeln("MIME type: ", this.mimeType);
		writeln("Default icon: ", this.defaultIconName);
	}

	private bool validateAppImageFile() {
		if (!exists(this.filePath) || !isFile(this.filePath)) {
			writeln("Path is not a regular file: ", this.filePath);
			return false;
		}

		// First 11 bytes cover ELF magic at 0-3, AppImage "AI" marker at 8-9, type at 10
		ubyte[11] header;
		try {
			auto file = File(this.filePath, "rb");
			size_t bytesRead = file.rawRead(header[]).length;
			file.close();
			if (bytesRead < header.length) {
				writeln("File too small to be an AppImage: ", this.filePath);
				return false;
			}
		} catch (ErrnoException error) {
			writeln("Cannot read file: ", error.msg);
			return false;
		}

		if (header[0 .. 4] != [
				0x7F, cast(ubyte) 'E', cast(ubyte) 'L', cast(ubyte) 'F'
			]) {
			writeln("Not an ELF file: ", this.filePath);
			return false;
		}

		// Bytes 8–9 hold the "AI" magic present in all AppImages
		if (header[8] != 0x41 || header[9] != 0x49 || header[10] == 0) {
			writeln("APPIMAGE magic not found in: ", this.filePath);
			return false;
		}

		return true;
	}

	private void parseDesktopEntry(string mountPoint) {
		import lang : activeLangCode;

		string locale = activeLangCode();
		string nameLPrefix = "Name[" ~ locale ~ "]=";
		string genericNameLPrefix = "GenericName[" ~ locale ~ "]=";
		string commentLPrefix = "Comment[" ~ locale ~ "]=";
		string localeName, localeGenericName, localeComment;

		bool inDesktopSection = false;
		foreach (line; this.desktopFileLines) {
			string stripped = line.strip();

			if (stripped == "[Desktop Entry]") {
				inDesktopSection = true;
				continue;
			}
			if (inDesktopSection &&
				stripped.length && stripped[0] == '[' && stripped[$ - 1] == ']')
				break;

			if (!inDesktopSection)
				continue;

			if (stripped.startsWith("Name="))
				this.appName = stripped["Name=".length .. $];
			else if (stripped.startsWith("GenericName="))
				this.appGenericName = stripped["GenericName=".length .. $];
			else if (stripped.startsWith("Comment="))
				this.appComment = stripped["Comment=".length .. $];
			else if (stripped.startsWith("X-AppImage-Version="))
				this.releaseVersion = stripped["X-AppImage-Version=".length .. $];
			else if (stripped.startsWith("Icon="))
				resolveEmbeddedIcon(stripped["Icon=".length .. $], mountPoint);

			if (stripped.startsWith(nameLPrefix))
				localeName = stripped[nameLPrefix.length .. $];
			else if (stripped.startsWith(genericNameLPrefix))
				localeGenericName = stripped[genericNameLPrefix.length .. $];
			else if (stripped.startsWith(commentLPrefix))
				localeComment = stripped[commentLPrefix.length .. $];
		}

		if (localeName.length)
			this.appName = localeName;
		if (localeGenericName.length)
			this.appGenericName = localeGenericName;
		if (localeComment.length)
			this.appComment = localeComment;
	}

	private void resolveEmbeddedIcon(string iconField, string mountPoint) {
		string iconBaseName = iconField.strip().baseName.stripExtension;
		immutable string[] supportedExtensions = [".svg", ".png", ".xpm"];

		string[] candidates;
		candidates ~= buildPath(mountPoint, iconField.strip());

		foreach (entry; dirEntries(mountPoint, SpanMode.shallow)) {
			string name = entry.name.baseName;
			if (name.stripExtension != iconBaseName)
				continue;
			if (supportedExtensions.canFind(name.extension.toLower))
				candidates ~= entry.name;
		}

		foreach (candidate; candidates) {
			if (!exists(candidate))
				continue;
			writeln("Loading icon from: ", candidate);
			try {
				auto texture = Texture.newFromFile(GioFile.newForPath(candidate));
				this.defaultIconName = candidate;
				this.appIconWidget = Image.newFromPaintable(texture);
				// Cache raw bytes so the installer can write the icon without remounting
				this.cachedIconBytes = cast(ubyte[]) std.file.read(candidate);
				this.cachedIconExtension = candidate.extension.toLower;
				return;
			} catch (ErrorWrap error) {
				writeln("Failed to load icon ", candidate, ": ", error.msg);
			} catch (FileException error) {
				writeln("Failed to load icon ", candidate, ": ", error.msg);
			}
		}
	}

	void loadFullInfo() {
		import core.thread : Thread;
		import core.time : dur;
		import std.process : pipeProcess, kill, wait;

		this.isFullyLoaded = false;

		if (!this.validateAppImageFile())
			return;

		// Temporarily make executable so the AppImage runtime can mount it
		auto savedAttributes = getAttributes(this.filePath);
		setAttributes(this.filePath, APPIMAGE_EXEC_MODE);

		auto mountProcess = pipeProcess([this.filePath, "--appimage-mount"]);
		scope (exit) {
			kill(mountProcess.pid);
			wait(mountProcess.pid);
			writeln("AppImage unmounted");
		}

		setAttributes(this.filePath, savedAttributes);

		string mountPoint;
		foreach (line; mountProcess.stdout.byLine()) {
			string trimmed = (cast(string) line).strip();
			writeln("Mount output: ", trimmed);
			if (trimmed.startsWith(APPIMAGE_FUSE_MOUNT_PREFIX)) {
				mountPoint = trimmed;
				break;
			}
		}
		writeln("Mount point: ", mountPoint);

		uint retries = MOUNT_RETRY_MAX;
		while (!exists(mountPoint)) {
			writeln("Waiting for mount point: ", mountPoint);
			if (retries-- == 0) {
				writeln("Mount point never appeared: ", mountPoint);
				return;
			}
			Thread.sleep(dur!"msecs"(MOUNT_RETRY_MS));
		}

		string rootDir = mountPoint ~ "/squashfs-root";
		if (!exists(rootDir))
			rootDir = mountPoint;

		string desktopFilePath = "";
		foreach (entry; dirEntries(rootDir, SpanMode.depth)) {
			if (entry.name.endsWith(DESKTOP_SUFFIX)) {
				desktopFilePath = entry.name;
				break;
			}
		}

		if (desktopFilePath.length) {
			writeln("Found .desktop file: ", desktopFilePath);
			this.desktopFileLines = File(desktopFilePath, "r").byLineCopy().array;
			this.parseDesktopEntry(mountPoint);
		} else {
			writeln("No .desktop file found, generating synthetic one");
		}

		if (this.desktopFileLines.length == 0) {
			this.desktopFileLines = [
				"[Desktop Entry]",
				"Type=Application",
				"Name=" ~ this.appName,
				"GenericName=" ~ this.appGenericName,
				"Comment=" ~ this.appComment,
				"Exec=" ~ this.filePath,
				"Icon=" ~ this.defaultIconName,
				"Terminal=false",
				"Categories=Utility;",
			];
			if (this.releaseVersion.length)
				this.desktopFileLines ~= "X-AppImage-Version=" ~ this.releaseVersion;
		}

		if (this.appName.length == 0)
			this.appName = this.fileName;

		if (this.appComment.length && this.appComment == this.appName)
			this.appComment = "";

		if (this.appComment.length == 0 &&
			this.appGenericName.length &&
			this.appGenericName != this.appName)
			this.appComment = this.appGenericName;

		if (this.appIconWidget is null) {
			writeln("Using .DirIcon fallback");
			string dirIconPath = mountPoint ~ "/.DirIcon";
			// Resolve to the real file to get the correct extension for caching
			string resolvedDirIcon = dirIconPath;
			while (pathIsSymlink(resolvedDirIcon)) {
				string target = readLink(resolvedDirIcon);
				if (!isAbsolute(target))
					target = buildPath(resolvedDirIcon.dirName, target);
				resolvedDirIcon = buildNormalizedPath(target);
			}
			if (!exists(resolvedDirIcon))
				resolvedDirIcon = dirIconPath;
			if (exists(resolvedDirIcon)) {
				this.cachedIconExtension = resolvedDirIcon.extension.toLower;
				try {
					this.cachedIconBytes = cast(ubyte[]) std.file.read(resolvedDirIcon);
				} catch (FileException error) {
					writeln("Failed to cache .DirIcon bytes: ", error.msg);
				}
			}
			this.appIconWidget = Image.newFromFile(dirIconPath);
		}

		this.sanitizedName = buildSanitizedName(this.appName);

		this.isFullyLoaded = true;
	}

	// Returns the releaseVersion from an existing install manifest, or "" if not installed
	string readInstalledVersion() {
		return appimage.install.readInstalledVersion(this);
	}

	// Installs the AppImage using the current installMethod
	bool install() {
		return appimage.install.install(this);
	}
}
