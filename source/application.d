// GTK Application subclass that parses arguments and opens the matching window
//
module application;

import std.concurrency : Tid, thisTid;

import gio.types : ApplicationFlags;
import adw.application : Application;

import styles : applyGlobalStyles;
import args : AppArgs, parseArgs;
import types : AppMode;
import windows.base : AppWindow;
import windows.install : InstallWindow;
import windows.manage : ManageWindow;
import windows.uninstall : UninstallWindow;
import windows.update : UpdateWindow;
import constants : APP_ID, BGUPDATE_APP_ID;

// GTK Application subclass that picks a mode and shows the matching window
class App : Application {
	AppWindow mainWindow;
	Tid mainThreadId;
	bool shouldQuit;

	private AppArgs parsedArgs;

	this(string[] args) {
		AppArgs parsed = parseArgs(args);
		bool isBg = parsed.mode == AppMode.BackgroundUpdate;
		super(isBg ? BGUPDATE_APP_ID : APP_ID, ApplicationFlags.NonUnique);
		this.mainThreadId = thisTid;
		this.parsedArgs = parsed;
		this.shouldQuit = this.parsedArgs.shouldQuit;
		connectActivate(&onActivate);
	}

	private void onActivate() {
		import apputils : readConfigLang, detectSystemLang;
		import lang : setLang;

		string lang = readConfigLang();
		if (!lang.length)
			lang = detectSystemLang();
		if (lang.length)
			setLang(lang);

		applyGlobalStyles();
		if (this.parsedArgs.mode == AppMode.BackgroundUpdate) {
			import bgupdate : runBackgroundUpdate;
			import gtk.application : GtkApplication = Application;

			this.hold();
			runBackgroundUpdate(
				this.parsedArgs.checkIntervalHours,
				this.parsedArgs.autoUpdate,
				cast(GtkApplication) this);
			return;
		}
		final switch (this.parsedArgs.mode) {
		case AppMode.Install:
			this.mainWindow = new InstallWindow(this, this.parsedArgs.appImage);
			break;
		case AppMode.Uninstall:
			this.mainWindow = new UninstallWindow(
				this, this.parsedArgs.targetAppName, this.parsedArgs.targetAppDir,
				this.parsedArgs.targetSanitizedName, this.parsedArgs.targetIconName,
				this.parsedArgs.targetDesktopSymlink);
			break;
		case AppMode.Manage:
			this.mainWindow = new ManageWindow(this);
			break;
		case AppMode.Update:
			this.mainWindow = new UpdateWindow(
				this, this.parsedArgs.targetAppName, this.parsedArgs.targetSanitizedName,
				this.parsedArgs.targetAppDir, this.parsedArgs.targetUpdateInfo);
			break;
		case AppMode.BackgroundUpdate:
			assert(false, "handled above");
		}

		this.mainWindow.present();
		this.mainWindow.loadingSpinner.start();
		this.mainWindow.doThreadedWork(
			&this.mainWindow.loadWindow,
			&this.mainWindow.showWindow);
	}
}
