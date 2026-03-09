module constants;

import std.conv : octal;

// Version string written into each manifest at install time
enum string INSTALLER_VERSION = "0.1.0";

// Binary name used in User-Agent headers and to register the desktop installer action
enum string INSTALLER_NAME = "appimage-installer";

// Filesystem locations and identifiers used during install and uninstall
enum string APPIMAGES_DIR_NAME = "appimages";
enum string APPLICATIONS_SUBDIR = "com.hezkore.appimage";
enum string UPDATE_SUBDIR = "update";
enum string MANIFEST_FILE_NAME = "manifest.json";
enum string DESKTOP_PREFIX = "com.hezkore.appimage.";
enum string DESKTOP_SUFFIX = ".desktop";

// GTK style provider priorities used when applying CSS
enum int CSS_PRIORITY_APP = 600; // GTK_STYLE_PROVIDER_PRIORITY_APPLICATION
enum int CSS_PRIORITY_USER = 700; // GTK_STYLE_PROVIDER_PRIORITY_USER

// Unix permission mode set on every installed AppImage binary
enum uint APPIMAGE_EXEC_MODE = octal!755;

// System hicolor icon theme index used to seed a fresh user hicolor directory
enum string SYSTEM_ICON_THEME_PATH = "/usr/share/icons/hicolor/index.theme";

// FUSE mount prefix used by the AppImage runtime when running mounted
enum string APPIMAGE_FUSE_MOUNT_PREFIX = "/tmp/.mount_";

// Linux process file system, read to verify whether a PID belongs to a live process
enum string PROC_DIRECTORY = "/proc";

// Shared temporary directory and file prefixes used during updates and checks
enum string TEMP_DIRECTORY_PATH = "/tmp";
enum string INSTALLER_UPDATE_TEMP_DIRECTORY_PREFIX =
	"appimage-installer-update-";
enum string SIGNATURE_TEMP_FILE_PREFIX = "aisig_";

// Desktop file name that registers the installer as the AppImage handler
enum string INSTALLER_DESKTOP_FILE = "com.hezkore.appimage.installer.desktop";

// GitHub release tag sentinels used when selecting and comparing release channels
enum string TAG_LATEST = "latest";
enum string TAG_LATEST_PRE = "latest-pre";
enum string TAG_LATEST_ALL = "latest-all";

// GitHub identity for this installer used for self-update checks
enum string INSTALLER_GH_USER = "Hezkore";
enum string INSTALLER_GH_REPO = "appimage-installer";
enum string INSTALLER_RELEASES_URL =
	"https://github.com/Hezkore/appimage-installer/releases";

// Architecture string embedded at compile time for self-update tarball URL construction
version (X86_64)
	enum string INSTALLER_ARCH = "x86_64";
else version (AArch64)
	enum string INSTALLER_ARCH = "aarch64";
else
	enum string INSTALLER_ARCH = "unknown";

// File written by the background updater when an installer update is detected
enum string INSTALLER_FLAG_FILE_NAME = "installer-update.json";

// Application identifier used for D-Bus registration and config directory name
enum string APP_ID = "com.hezkore.appimage.installer";

// Separate identifier used by the background updater to avoid D-Bus conflicts
enum string BGUPDATE_APP_ID = "com.hezkore.appimage.installer.bgupdate";

// File inside the config directory that stores user preferences
enum string CONFIG_FILE_NAME = "config.json";

// State file inside the config directory written by the background updater
enum string BGUPDATE_STATE_FILE_NAME = "bgupdate.json";
