// A GTK4 Linux desktop app for installing and managing .AppImage files
//
module app;

import application : App;

version (unittest) {
} else
	void main(string[] args) {
	auto application = new App(args);
	if (!application.shouldQuit)
		application.run();
}
