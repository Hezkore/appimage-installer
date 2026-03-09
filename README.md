A GTK4 desktop application for Linux that installs
[AppImage](https://appimage.org) applications on Linux and adds desktop
integration for them.

You open an AppImage once, install it, and then use it from the app launcher
like any other installed app. Later update and removal can happen from the
installed launcher entry.

## Why

AppImages are portable, but the normal workflow is still manual. You download a
file, keep track of where it lives, make it executable, create launcher entries
yourself if you want them, and later work out how to update or remove it.

This application handles that part. It installs the app into one place,
creates the launcher entry and icon, adds desktop actions for update and
uninstall, and keeps per app metadata so the app manager can handle the rest.

## How

### Install and desktop integration

When you open an AppImage, the installer reads its metadata, shows the path,
size, timestamp, architecture, and signature state, then installs it under
`~/.local/share/appimages/<sanitizedName>/`. It writes a desktop entry, copies
the icon into the icon theme, and adds desktop actions for update and
uninstall. The installer can also register itself as the default handler for
`.AppImage` files.

### App manager

Running `appimage-installer` with no file opens the manager window. It shows
the installed applications in one searchable list and lets you launch, browse,
update, uninstall, optimize, and clean up orphaned entries. It also checks for
broken launchers, missing icons, missing files, and non executable `AppRun`
files, then offers a fix path where the problem can be repaired.

### Update methods

If an app does not already have usable update data, you can add it from the add
update method flow or later from the options page. The application supports
zsync, GitHub Releases with matched AppImage assets, GitHub Releases with
`.zsync` assets, GitHub Releases with `latest-linux.yml`, AppImageHub through
Pling, and direct link URLs. Update can happen per app, from the manager for
multiple apps at once, or from a background check through a user systemd timer.

### Storage and options

Each installed app can stay as a single AppImage file for smaller storage use
or switch to extracted mode for faster startup. The options and settings pages
also let you change per app update settings, manage portable `HOME` and
`XDG_CONFIG_HOME` directories, move the install directory, set a GitHub token
for higher API limits, and choose the user interface language.

## Install

### Build from source

The direct build path is to clone the repository and run it from the checkout.

```sh
git clone https://github.com/Hezkore/appimage-installer.git
cd appimage-installer
./build.sh
```

### Release install

This downloads the binary to `~/.local/bin/` and asks whether to register it as
the default handler for `.AppImage` files and whether to install a systemd
timer for background update checks.

```sh
curl -sSL https://raw.githubusercontent.com/Hezkore/appimage-installer/main/install.sh | bash
```

### Manual install

You can also [download the latest build](https://github.com/Hezkore/appimage-installer/releases/latest)
for your architecture, extract it, and install it.

```sh
tar xzf appimage-installer.tar.gz
chmod +x appimage-installer
mv appimage-installer ~/.local/bin/
```

You can also build it locally.

```sh
dub build
cp -f ./appimage-installer ~/.local/bin/appimage-installer
```

Register it as the default handler for `.AppImage` files.

```sh
appimage-installer --associate
```

Optionally enable the background update timer.

```sh
appimage-installer --systemd-service ~/.config/systemd/user --check-interval 1 --auto-update false
appimage-installer --systemd-timer ~/.config/systemd/user
systemctl --user daemon-reload
systemctl --user enable --now appimage-installer-update.timer
```

Check the current install state.

```sh
appimage-installer --health
```