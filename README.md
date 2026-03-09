A desktop application for Linux that installs [AppImage](https://appimage.org) files and gives them proper desktop integration.

Simply double-click an AppImage to install it, and your new application appears in your launcher.\
Right-click any installed application to instantly update or uninstall it.

## Why

AppImages come as a single file with no installer.\
To use one you have to make it executable, decide where to keep it, and create a .desktop entry yourself. Updating means downloading a new file and going through the whole process again.

This application handles all of that for you, making every AppImage behave like a normal installed application.

## How

### Installing an application

When you open an AppImage, the installer reads its embedded metadata and shows you the file path, size, last modified date, architecture, and signature status. Once you confirm, the application is placed under `~/.local/share/appimages/` (by default), and a desktop entry and icon are written into the system so that the application appears in your launcher properly and straight away.

### The application manager

Opening the application manager shows all your installed AppImages in a searchable list. From here you can launch any application, check for updates, uninstall, or open its settings. The manager also flags problems like missing files, broken launcher entries, or non-executable AppRun files, and offers a way to repair them.

### Updates

If an AppImage includes update information the manager can check for and apply updates automatically. If it does not, you can add an update method from the options page. Supported methods are zsync, multiple types of GitHub Releases, AppImageHub through Pling, and direct download URLs.

An optional background service can also check for updates periodically and send a notification when updates are available.

### Storage and Optimization

Each installed application can be kept as a single AppImage file or unpacked into its individual files.\
Keeping the application as a file uses less disk space and works with zsync delta updates. Unpacking it trades those benefits for faster startup time.

You can switch between the two at any time from the application options.

## Install

<details open>
<summary>Automatic</summary>
<br>

This downloads the binary to `~/.local/bin/` and asks whether to register it as the default handler for `.AppImage` files and whether to install a systemd timer for background update checks:

```sh
curl -sSL https://raw.githubusercontent.com/Hezkore/appimage-installer/main/install.sh | bash
```

</details>

<details>
<summary>Manual</summary>
<br>

[Download the latest build](https://github.com/Hezkore/appimage-installer/releases/latest) for your architecture, extract it, and place the binary in your path:

```sh
tar xzf AppImage_Installer-*.tar.gz
mv appimage-installer ~/.local/bin/
```

Register it as the default handler for `.AppImage` files:

```sh
appimage-installer --associate
```

Optionally enable the background update timer:

```sh
appimage-installer --systemd-service ~/.config/systemd/user --check-interval 1 --auto-update false
appimage-installer --systemd-timer ~/.config/systemd/user
systemctl --user daemon-reload
systemctl --user enable --now appimage-installer-update.timer
```

Check the current install state:

```sh
appimage-installer --health
```

</details>

## Building

Clone the repository and run the build script:

```sh
git clone https://github.com/Hezkore/appimage-installer.git
cd appimage-installer
./build.sh
```