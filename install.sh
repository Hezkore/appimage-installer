#!/usr/bin/env bash
# Downloads and installs AppImage Installer, then registers it as the default handler for .AppImage files
#

set -euo pipefail

declare -r EXIT_SUCCESS=0
declare -r EXIT_MISSING_VERSION=1
declare -r EXIT_MISSING_DEPENDENCY=2

declare -r BINARY="appimage-installer"
declare -r INSTALL_DIR="${HOME}/.local/bin"
declare -r DESKTOP_DIR="${HOME}/.local/share/applications"
declare -r SYSTEMD_DIR="${HOME}/.config/systemd/user"
ARCH=$(uname -m)
readonly ARCH
declare -r API_URL="https://api.github.com/repos/Hezkore/appimage-installer/releases/latest"

# Detect the system package manager for use in install hints
detect_install_cmd() {
	local pkg="${1}"
	if command -v dnf &>/dev/null; then
		echo "sudo dnf install ${pkg}"
	elif command -v pacman &>/dev/null; then
		echo "sudo pacman -S ${pkg}"
	elif command -v zypper &>/dev/null; then
		echo "sudo zypper install ${pkg}"
	elif command -v apk &>/dev/null; then
		echo "sudo apk add ${pkg}"
	else
		echo "sudo apt install ${pkg}"
	fi
}

# Helper function to check if a required tool is installed
require_command() {
	local cmd="${1}"
	local pkg="${2}"
	if ! command -v "${cmd}" &>/dev/null; then
		echo "Error: '${cmd}' is required but not installed. Try: $(detect_install_cmd "${pkg}")" >&2
		exit ${EXIT_MISSING_DEPENDENCY}
	fi
}

require_command curl curl
require_command tar  tar

VERSION=$(curl -sSL "${API_URL}" | grep -oP '(?<="tag_name": ")[^"]+' | head -1)
readonly VERSION

if [[ -z "${VERSION}" ]]; then
	echo "Error: no releases found. Check https://github.com/Hezkore/appimage-installer/releases" >&2
	exit ${EXIT_MISSING_VERSION}
fi

declare -r DOWNLOAD_URL="https://github.com/Hezkore/appimage-installer/releases/download/${VERSION}/AppImage_Installer-${VERSION}-${ARCH}.tar.gz"

# Ask a yes/no question and return 0 for yes, 1 for no
# Read from /dev/tty so it works when the script is piped via curl | bash
ask() {
	local question="${1}"
	local reply
	read -r -p "${question} [y/N] " reply </dev/tty
	case "${reply}" in
		[yY]) return 0 ;;
		*)    return 1 ;;
	esac
}

mkdir -p "${INSTALL_DIR}" "${DESKTOP_DIR}"

echo "Downloading ${BINARY}..."
curl -sSL "${DOWNLOAD_URL}" | tar xz -C "${INSTALL_DIR}"
echo ""

if ask "Associate .AppImage files with ${BINARY}?"; then
	require_command xdg-mime xdg-utils
	"${INSTALL_DIR}/${BINARY}" --associate
	echo "  -> Double-clicking .AppImage files will open them with ${BINARY}"
else
	echo "  -> Skipping file association"
	echo "  -> To associate later, run: ${BINARY} --associate"
fi
echo ""

if command -v systemctl &>/dev/null && systemctl --user is-system-running &>/dev/null 2>&1 || true; then
	if ask "Install a background service to check for application updates?"; then
		echo "  -> A systemd user timer will run ${BINARY} --background-update on a timer"
		mkdir -p "${SYSTEMD_DIR}"
		"${INSTALL_DIR}/${BINARY}" --check-interval 24 --auto-update false \
			--systemd-service "${SYSTEMD_DIR}"
		"${INSTALL_DIR}/${BINARY}" --timer-interval 4 --systemd-timer "${SYSTEMD_DIR}"
		systemctl --user daemon-reload
		systemctl --user enable --now appimage-installer-update.timer
		echo "  -> Background update timer enabled"
	else
		echo "  -> Skipping background update service."
		echo "  -> To check for updates manually, run: ${BINARY} --background-update --check-interval 1"
	fi
else
	echo "Note: systemd not detected, skipping background update service."
	echo "To check for updates manually, run: ${BINARY} --background-update --check-interval 1"
fi
echo ""

echo "Done"

# Warn if the install directory is not on PATH so the binary can actually be found
if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
	echo "Warning: '${INSTALL_DIR}' is not in your PATH."
	echo "Add this line to your shell config (~/.bashrc, ~/.zshrc, etc.):"
	echo "  export PATH=\"\${HOME}/.local/bin:\${PATH}\""
fi

exit ${EXIT_SUCCESS}
