// A GTK4 Linux desktop app for installing and managing .AppImage files
//
module app;

import application : App;
import apputils : repairInstallerLaunchers;

private enum size_t LOG_BUFFER_SIZE = 4096;

version (unittest) {
} else
	void main(string[] args) {
	import core.stdc.stdio : _IOLBF;
	import std.stdio : stdout;

	// Line by line, so a log that goes to a file or another program shows each step as it happens
	stdout.setvbuf(LOG_BUFFER_SIZE, _IOLBF);

	auto application = new App(args);
	if (application.shouldQuit)
		return;
	repairInstallerLaunchers();
	application.run();
}
