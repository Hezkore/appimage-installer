module types;

// The three modes the app can run in, set by CLI arguments
enum AppMode {
	Manage,
	Install,
	Uninstall,
	Update,
	BackgroundUpdate,
}

// How the AppImage was installed in the app directory
enum InstallMethod : string {
	AppImage = "appimage",
	Extracted = "extracted",
}

// Passed from the worker thread back to the GTK thread when background work finishes
struct DoneMessage {
	bool success;
}
