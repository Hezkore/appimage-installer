// Background update checker with no UI window
// Run via systemd timer or cron to check for updates and notify the user
module bgupdate;

import std.conv : ConvException, to;
import std.datetime : Clock, SysTime;
import std.file : exists, readLink, readText, write, remove, mkdirRecurse, FileException, thisExePath;
import std.json : JSONException, JSONType, JSONValue, parseJSON;
import std.path : buildPath, dirName;
import std.process : spawnProcess, Config;
import std.stdio : writeln;
import std.string : strip;
import core.thread : Thread;

import glib.global : idleAdd, timeoutAddSeconds;
import glib.types : PRIORITY_DEFAULT;
import glib.variant : Variant;
import gio.notification : GioNotification = Notification;
import gio.simple_action : SimpleAction;
import gio.themed_icon : ThemedIcon;
import gio.file : GioFile = File;
import gio.file_icon : FileIcon;
import gtk.application : GtkApplication = Application;

import appimage.manifest : Manifest;
import apputils : xdgDataHome, configDir, writeInstallerUpdateFlag;
import constants : BGUPDATE_STATE_FILE_NAME, PROC_DIRECTORY;
import lang : L;

import update.common : parseUpdateMethodKind, UpdateMethodKind;
import update.checker : checkOneApp, checkInstallerUpdate;
import update.dispatch : applyUpdateWithProgress;
import appimage.signature : SignatureStatus;
import windows.manage.scan : InstalledApp, scanInstalledApps;

// Seconds to keep the application alive after sending a notification, waiting for user action
private enum int NOTIFY_TIMEOUT_SECONDS = 1800;

// PID file name written while a background check is running to prevent duplicate invocations
private enum string BGUPDATE_PID_FILE_NAME = "bgupdate.pid";

private string buildStateFilePath() {
	return buildPath(configDir(), BGUPDATE_STATE_FILE_NAME);
}

private string buildPidFilePath() {
	return buildPath(configDir(), BGUPDATE_PID_FILE_NAME);
}

// Uses O_CREAT|O_EXCL so at most one instance can proceed past this check.
// Stale PID files are removed and retried so one bad run cannot block future runs.
private bool tryClaimPidFile(out int existingPid) {
	import core.stdc.errno : errno, EEXIST;
	import core.sys.posix.fcntl : open, O_CREAT, O_EXCL, O_WRONLY;
	import core.sys.posix.unistd : posixWrite = write, close, getpid;
	import std.conv : octal;
	import std.string : toStringz;

	string path = buildPidFilePath();
	try {
		mkdirRecurse(dirName(path));
	} catch (FileException) {
	}

	foreach (_; 0 .. 2) {
		int fd = open(path.toStringz(), O_CREAT | O_EXCL | O_WRONLY, octal!644);
		if (fd >= 0) {
			string pidLine = to!string(getpid()) ~ "\n";
			posixWrite(fd, cast(const void*) pidLine.ptr, pidLine.length);
			close(fd);
			return true;
		}
		if (errno != EEXIST) {
			writeln("bgupdate: could not create PID file, proceeding without lock");
			return true;
		}

		// File exists — check if it belongs to a live instance of this binary
		try {
			existingPid = to!int(readText(path).strip());
			try {
				if (readLink(PROC_DIRECTORY ~ "/" ~ to!string(existingPid) ~ "/exe") == thisExePath())
					return false; // genuine bgupdate instance holds the file
				// PID belongs to a different binary — recycled, treat as stale
			} catch (FileException) {
				// Process exited between readText and readLink — treat as stale
			}
		} catch (ConvException) {
			// Corrupted file — fall through to stale cleanup
		} catch (FileException) {
			continue; // file vanished between open and readText, retry
		}

		// Stale file — remove and let the loop retry O_CREAT|O_EXCL
		try {
			remove(path);
		} catch (FileException) {
		}
	}

	writeln("bgupdate: could not claim PID file, proceeding without lock");
	return true;
}

private SysTime readLastChecked() {
	string path = buildStateFilePath();
	if (!exists(path))
		return SysTime.init;
	try {
		auto json = parseJSON(readText(path));
		if (auto entry = "lastCheckedAt" in json)
			if (entry.type == JSONType.string)
				return SysTime.fromISOExtString(entry.str);
	} catch (JSONException) {
	} catch (ConvException) {
	} catch (FileException) {
	}
	return SysTime.init;
}

private void writeLastChecked() {
	string path = buildStateFilePath();
	try {
		mkdirRecurse(dirName(path));
		auto json = JSONValue([
			"lastCheckedAt": Clock.currTime().toISOExtString()
		]);
		write(path, json.toPrettyString() ~ "\n");
	} catch (FileException error) {
		writeln("bgupdate: could not write state: ", error.msg);
	}
}

private bool applyUpdateForApp(InstalledApp entry, out string error) {
	double progress;
	string statusText;
	bool wasUpdated;
	return applyUpdateWithProgress(entry, progress, statusText, wasUpdated, error);
}

// Marks the given app manifest with updateAvailable = true
private void markUpdateAvailable(InstalledApp entry) {
	auto installedAppManifest = Manifest.loadFromAppDir(entry.appDirectory);
	if (installedAppManifest is null || installedAppManifest.updateAvailable)
		return;
	installedAppManifest.updateAvailable = true;
	installedAppManifest.save();
}

// Spawns command in a transient systemd scope so the bgupdate cgroup cleanup does
// not kill the child. Falls back to plain spawn if systemd-run is unavailable.
private void spawnInNewScope(string[] command) {
	import std.process : ProcessException;

	try {
		spawnProcess(["systemd-run", "--user", "--scope"] ~ command,
			(string[string]).init, Config.detached);
	} catch (ProcessException) {
		spawnProcess(command, (string[string]).init, Config.detached);
	}
}

// Returns the path to the installed icon file for iconName, or empty string if not found
private string findInstalledIconPath(string iconName) {
	if (!iconName.length)
		return "";
	string hicolorBase = buildPath(xdgDataHome(), "icons", "hicolor");
	immutable string[2][] candidates = [
		["scalable/apps", ".svg"],
		["256x256/apps", ".png"],
		["48x48/apps", ".png"],
	];
	foreach (candidate; candidates) {
		string path = buildPath(hicolorBase, candidate[0], iconName ~ candidate[1]);
		if (exists(path))
			return path;
	}
	return "";
}

// Sends a GIO notification for one app update with a direct Update Now action
private void sendSingleUpdateNotify(
	GtkApplication app, string appName, string sanitizedName, string iconName) {
	auto notif = new GioNotification(L("bgupdate.notify.title"));
	notif.setBody(L("bgupdate.notify.body", appName));
	string iconPath = findInstalledIconPath(iconName);
	if (iconPath.length)
		notif.setIcon(new FileIcon(GioFile.newForPath(iconPath)));
	else
		notif.setIcon(new ThemedIcon("software-update-available"));
	notif.addButton(L("bgupdate.notify.button.update"), "app.bgupdate-update-now");
	notif.addButton(L("bgupdate.notify.button.manage"), "app.bgupdate-manage");
	app.sendNotification("bgupdate-single", notif);
}

// Sends a GIO notification for multiple app updates
private void sendMultiUpdateNotify(GtkApplication app, int count) {
	auto notif = new GioNotification(L("bgupdate.notify.title.multi"));
	notif.setBody(L("bgupdate.notify.body.multi", count.to!string));
	notif.setIcon(new ThemedIcon("software-update-available"));
	notif.addButton(L("bgupdate.notify.button.manage"), "app.bgupdate-manage");
	app.sendNotification("bgupdate-multi", notif);
}

// Sends a GIO notification that the installer itself has a newer release
private void sendInstallerUpdateNotify(GtkApplication app) {
	auto notif = new GioNotification(L("bgupdate.notify.installer.title"));
	notif.setBody(L("bgupdate.notify.installer.body"));
	notif.setIcon(new ThemedIcon("software-update-available"));
	notif.addButton(L("bgupdate.notify.button.manage"), "app.bgupdate-manage");
	app.sendNotification("bgupdate-installer", notif);
}

// Sends a combined notification when both the installer and app updates are available
private void sendCombinedUpdateNotify(GtkApplication app, int appCount) {
	auto notif = new GioNotification(L("bgupdate.notify.title.multi"));
	string bodyKey = appCount == 1
		? "bgupdate.notify.installer.body.with.app" : "bgupdate.notify.installer.body.with.apps";
	notif.setBody(L(bodyKey, appCount.to!string));
	notif.setIcon(new ThemedIcon("software-update-available"));
	notif.addButton(L("bgupdate.notify.button.manage"), "app.bgupdate-manage");
	app.sendNotification("bgupdate-installer", notif);
}

// Sends a GIO notification for apps whose signature check failed during auto-update
private void sendSigFailureNotify(GtkApplication app, InstalledApp[] failedApps) {
	auto notif = new GioNotification(L("bgupdate.notify.sig.title"));
	if (failedApps.length == 1) {
		notif.setBody(L("bgupdate.notify.sig.body", failedApps[0].appName));
		string iconPath = findInstalledIconPath(failedApps[0].installedIconName);
		if (iconPath.length)
			notif.setIcon(new FileIcon(GioFile.newForPath(iconPath)));
		else
			notif.setIcon(new ThemedIcon("dialog-warning"));
	} else {
		notif.setBody(L("bgupdate.notify.sig.body.multi", failedApps.length.to!string));
		notif.setIcon(new ThemedIcon("dialog-warning"));
	}
	notif.addButton(L("bgupdate.notify.button.manage"), "app.bgupdate-manage");
	app.sendNotification("bgupdate-sig", notif);
}

// Runs a full update check and sends a notification for any app that has an update
// Exits immediately if another instance is running or the check interval has not elapsed
public void runBackgroundUpdate(
	int checkIntervalHours,
	bool autoUpdate,
	GtkApplication app) {
	long intervalSeconds = checkIntervalHours * 3600L;

	auto lastChecked = readLastChecked();
	if (lastChecked != SysTime.init) {
		long elapsed = (Clock.currTime() - lastChecked).total!"seconds";
		if (elapsed < intervalSeconds) {
			writeln("bgupdate: checked ", elapsed, "s ago, interval is ",
				intervalSeconds, "s, exiting");
			app.release();
			return;
		}
	}

	int existingPid;
	if (!tryClaimPidFile(existingPid)) {
		writeln("bgupdate: already running at PID: ", existingPid);
		app.release();
		return;
	}

	writeln("bgupdate: starting check");
	bool capturedAutoUpdate = autoUpdate;
	GtkApplication capturedApp = app;

	auto thread = new Thread({
		// Always check installer version so the flag file stays current
		string installerLatestVersion;
		string installerCheckError;
		bool installerUpdate = checkInstallerUpdate(installerLatestVersion, installerCheckError);
		if (installerCheckError.length)
			writeln("bgupdate: installer check failed: ", installerCheckError);
		writeln("bgupdate: installer update=", installerUpdate);
		if (installerUpdate)
			writeInstallerUpdateFlag(installerLatestVersion);

		InstalledApp[] pendingNotify;
		InstalledApp[] pendingSigFail;
		writeln("bgupdate: starting per-app scan");
		auto apps = scanInstalledApps();
		writeln("bgupdate: found ", apps.length, " installed apps");
		foreach (ref entry; apps) {
			if (entry.isOrphan)
				continue;
			if (!entry.updateInfo.length) {
				if (entry.updateAvailable) {
					auto installedAppManifest =
						Manifest.loadFromAppDir(entry.appDirectory);
					if (installedAppManifest !is null
					&& installedAppManifest.updateAvailable) {
						installedAppManifest.updateAvailable = false;
						installedAppManifest.save();
					}
				}
				continue;
			}
			if (parseUpdateMethodKind(entry.updateInfo) == UpdateMethodKind.DirectLink) {
				if (entry.updateAvailable) {
					auto installedAppManifest =
						Manifest.loadFromAppDir(entry.appDirectory);
					if (installedAppManifest !is null
					&& installedAppManifest.updateAvailable) {
						installedAppManifest.updateAvailable = false;
						installedAppManifest.save();
					}
				}
				continue;
			}
			writeln("bgupdate: checking ", entry.appName);
			string error;
			bool available = checkOneApp(entry, error);
			if (error.length) {
				writeln("bgupdate: check failed for ", entry.appName, ": ", error);
				continue;
			}
			writeln("bgupdate: ", entry.appName, " update=", available);
			if (!available) {
				if (entry.updateAvailable) {
					auto installedAppManifest =
						Manifest.loadFromAppDir(entry.appDirectory);
					if (installedAppManifest !is null
					&& installedAppManifest.updateAvailable) {
						installedAppManifest.updateAvailable = false;
						installedAppManifest.save();
					}
				}
				continue;
			}
			if (capturedAutoUpdate) {
				string applyError;
				if (!applyUpdateForApp(entry, applyError)) {
					import std.string : startsWith;

					if (applyError.startsWith("sig:")) {
						// Sig check failed so clean up the temp file and queue a sig notification
						import std.string : indexOf;

						auto prefixEnd = applyError.indexOf(":", 4);
						if (prefixEnd >= 0) {
							string sigTempPath = applyError[prefixEnd + 1 .. $];
							import std.file : FileException;

							try {
								remove(sigTempPath);
							} catch (FileException) {
							}
						}
						markUpdateAvailable(entry);
						pendingSigFail ~= entry;
					} else {
						writeln("bgupdate: auto-update failed for ",
							entry.appName, ": ", applyError);
					}
				}
			} else {
				pendingNotify ~= entry;
			}
		}

		writeLastChecked();
		InstalledApp[] captured = pendingNotify;
		InstalledApp[] capturedSigFail = pendingSigFail;
		bool capturedInstallerUpdate = installerUpdate;
		idleAdd(PRIORITY_DEFAULT, () {
			foreach (ref notifyApp; captured)
				markUpdateAvailable(notifyApp);

			bool* released = new bool(false);
			void releaseOnce() {
				if (*released)
					return;
				*released = true;
				try {
					remove(buildPidFilePath());
				} catch (FileException) {
				}
				capturedApp.release();
			}

			auto manageAction = new SimpleAction("bgupdate-manage", null);
			manageAction.connectActivate((Variant param, SimpleAction a) {
				writeln("bgupdate: launching manager");
				spawnInNewScope([thisExePath()]);
				writeln("bgupdate: manager launched");
				releaseOnce();
			});
			capturedApp.addAction(manageAction);

			// Send sig-failure notifications (always, independent of update notifications)
			if (capturedSigFail.length > 0)
				sendSigFailureNotify(capturedApp, capturedSigFail);

			if (capturedInstallerUpdate && captured.length > 0) {
				sendCombinedUpdateNotify(capturedApp, cast(int) captured.length);
			} else if (capturedInstallerUpdate) {
				sendInstallerUpdateNotify(capturedApp);
			} else if (captured.length == 1) {
				auto updateAction = new SimpleAction("bgupdate-update-now", null);
				updateAction.connectActivate((Variant param, SimpleAction a) {
					writeln("bgupdate: launching update window for ", captured[0].appName);
					spawnInNewScope([
						thisExePath(), "--update", captured[0].sanitizedName
					]);
					releaseOnce();
				});
				capturedApp.addAction(updateAction);
				sendSingleUpdateNotify(
				capturedApp,
				captured[0].appName,
				captured[0].sanitizedName,
				captured[0].installedIconName);
			} else if (captured.length > 1) {
				sendMultiUpdateNotify(capturedApp, cast(int) captured.length);
			} else {
				writeln("bgupdate: no updates found, releasing");
				releaseOnce();
				return false;
			}

			timeoutAddSeconds(PRIORITY_DEFAULT, NOTIFY_TIMEOUT_SECONDS, () {
				writeln("bgupdate: notify timeout reached, withdrawing notifications");
				capturedApp.withdrawNotification("bgupdate-single");
				capturedApp.withdrawNotification("bgupdate-multi");
				capturedApp.withdrawNotification("bgupdate-installer");
				capturedApp.withdrawNotification("bgupdate-sig");
				releaseOnce();
				return false;
			});

			writeln("bgupdate: notifications sent, waiting for user action");
			return false;
		});
	});
	thread.isDaemon = true;
	thread.start();
}
