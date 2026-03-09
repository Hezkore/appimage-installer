module windows.manage.watcher;

import std.file : isSymlink, FileException;
import std.path : buildPath;
import std.stdio : writeln;

import glib.global : timeoutAdd;
import glib.types : PRIORITY_DEFAULT;
import gio.file : GioFile = File;
import gio.file_monitor : FileMonitor;
import gio.types : FileMonitorEvent, FileMonitorFlags;
import glib.error : ErrorWrap;

import apputils : installBaseDir;
import windows.manage : ManageWindow;
import windows.manage.scan : InstalledApp, isStillInstalled;
import windows.manage.row : AppRowResult, makeReloadCallback, buildAppRow;
import lang : L;

// Duration to wait for the revealer fade before hiding a row
private enum int REVEALER_FADE_MS = 250;
// Delay before loading the icon for a newly transitioned orphan row
private enum uint ORPHAN_ICON_DELAY_MS = 50;

// Returns true when the desktop symlink itself exists on disk
// Broken symlinks still count as present
package bool hasStaleDesktopSymlink(ref InstalledApp entry) {
	if (!entry.desktopSymlink.length)
		return false;
	try {
		return isSymlink(entry.desktopSymlink);
	} catch (FileException) {
		return false;
	}
}

// Returns true when at least one real app entry is still installed on disk
package bool hasAnyActiveApps(ManageWindow win) {
	foreach (ref installedApp; win.installedApps)
		if (!installedApp.isOrphan && isStillInstalled(installedApp))
			return true;
	return false;
}

// Hides the orphan section box if every row in it is now invisible
package void hideOrphanSectionIfEmpty(ManageWindow win) {
	auto child = win.orphanListBox.getFirstChild();
	while (child !is null) {
		if (child.getVisible())
			return;
		child = child.getNextSibling();
	}
	win.orphanSectionBox.hide();
	win.installedSectionHeader.hide();
	win.orphanDivider.hide();
}

// Instantly hides a row whose app was fully removed with no symlink left behind
// Used by the watcher after a complete uninstall
package void silentlyHideRow(ManageWindow win, size_t rowIndex) {
	auto ref rowResult = win.rowResults[rowIndex];
	if (rowResult.revealer !is null)
		rowResult.revealer.setRevealChild(false);
	rowResult.row.removeCssClass("open-row");
	timeoutAdd(PRIORITY_DEFAULT, REVEALER_FADE_MS, {
		rowResult.row.hide();
		if (!hasAnyActiveApps(win))
			win.setChild(win.emptyStateBox);
		return false;
	});
}

// Fades out the installed row, moves it to the orphan section, and shows the banner
package void transitionRowToOrphan(ManageWindow win, size_t rowIndex) {
	auto ref rowResult = win.rowResults[rowIndex];
	string orphanAppName = win.installedApps[rowIndex].appName;

	if (rowResult.revealer !is null)
		rowResult.revealer.setRevealChild(false);
	rowResult.row.removeCssClass("open-row");

	timeoutAdd(PRIORITY_DEFAULT, REVEALER_FADE_MS, {
		rowResult.row.hide();

		if (!win.orphanSectionBox.getVisible()) {
			win.orphanSectionBox.show();
			bool anyInstalled = false;
			foreach (ref installedApp; win.installedApps)
				if (!installedApp.isOrphan) {
					anyInstalled = true;
					break;
				}
			if (anyInstalled) {
				win.installedSectionHeader.show();
				win.orphanDivider.show();
			}
		}

		auto newResult = buildAppRow(win, win.installedApps[rowIndex]);
		win.orphanListBox.append(newResult.row);
		win.rowResults[rowIndex] = newResult;

		timeoutAdd(PRIORITY_DEFAULT, ORPHAN_ICON_DELAY_MS,
			makeReloadCallback(newResult.reloadRow));
		return false;
	});

	showOrphanBanner(win, orphanAppName);
}

// Slides down the notification banner that stays until the user dismisses it
package void showOrphanBanner(ManageWindow win, string appName) {
	win.bannerLabel.setLabel(L("manage.app.banner.gone", appName));
	win.bannerRevealer.setRevealChild(true);
}

// When the app directory disappears, marks the entry as orphan and refreshes the row
private void handleAppGone(ManageWindow win, size_t index) {
	auto ref entry = win.installedApps[index];
	if (entry.isOrphan)
		return;
	entry.isOrphan = true;
	if (hasStaleDesktopSymlink(entry))
		transitionRowToOrphan(win, index);
	else
		silentlyHideRow(win, index);
}

// Watches the appimages and app directories for changes so removed rows hide immediately
// Uses WatchMoves so Thunar trash fires MovedOut without GLib pairing source and destination
package void startWatcher(ManageWindow win) {
	if (win.watcherRunning)
		return;
	string appimajesDir = installBaseDir();
	FileMonitor dirMonitor;
	try {
		dirMonitor = GioFile.newForPath(appimajesDir)
			.monitorDirectory(FileMonitorFlags.WatchMoves, null);
	} catch (ErrorWrap error) {
		writeln("watcher: could not monitor ", appimajesDir, ": ", error.msg);
		return;
	}
	win.watcherRunning = true;
	dirMonitor.connectChanged((GioFile file, GioFile otherFile, FileMonitorEvent eventType) {
		if (eventType != FileMonitorEvent.Deleted
		&& eventType != FileMonitorEvent.MovedOut)
			return;
		string changedPath = file.getPath();
		foreach (i, ref installedApp; win.installedApps) {
			if (installedApp.isOrphan)
				continue;
			if (installedApp.appDirectory == changedPath) {
				handleAppGone(win, i);
				break;
			}
		}
	});
	win.appMonitors ~= dirMonitor;

	foreach (i, ref installedApp; win.installedApps) {
		if (installedApp.isOrphan)
			continue;
		immutable size_t capturedIndex = i;
		FileMonitor appDirMonitor;
		try {
			appDirMonitor = GioFile.newForPath(installedApp.appDirectory)
				.monitorDirectory(FileMonitorFlags.WatchMoves, null);
		} catch (ErrorWrap error) {
			writeln("watcher: could not monitor ", installedApp.appDirectory,
				": ", error.msg);
			continue;
		}
		appDirMonitor.connectChanged((GioFile file, GioFile otherFile, FileMonitorEvent eventType) {
			if (eventType != FileMonitorEvent.Deleted
			&& eventType != FileMonitorEvent.MovedOut)
				return;
			if (!isStillInstalled(win.installedApps[capturedIndex]))
				handleAppGone(win, capturedIndex);
		});
		win.appMonitors ~= appDirMonitor;
	}
}
