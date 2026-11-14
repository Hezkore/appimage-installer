#!/usr/bin/env bash
# Downloads and installs AppImage Installer, then registers it as the default handler for .AppImage files
#

set -euo pipefail

declare -r EXIT_SUCCESS=0
declare -r EXIT_MISSING_VERSION=1
declare -r EXIT_MISSING_DEPENDENCY=2
declare -r EXIT_DOWNLOAD_FAILED=3
declare -r EXIT_BAD_DOWNLOAD=4

declare -r BINARY="appimage-installer"
declare -r INSTALL_DIR="${HOME}/.local/bin"
declare -r DESKTOP_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/applications"
declare -r SYSTEMD_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
ARCH=$(uname -m)
readonly ARCH
declare -r RELEASES_URL="https://github.com/Hezkore/appimage-installer/releases"
declare -r VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'
# Work directories beside the install location start with this, followed by random characters
declare -r WORK_DIR_PREFIX="${INSTALL_DIR}/.${BINARY}.install."

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

# Download one file of the release into the work directory
download() {
	local file="${1}"
	if ! curl -fsSL -o "${WORK_DIR}/${file}" "${DOWNLOAD_URL}/${file}"; then
		echo "Error: could not download ${file}. Check that ${RELEASES_URL} has a build for ${ARCH}." >&2
		exit ${EXIT_DOWNLOAD_FAILED}
	fi
}

# Ask a yes/no question and return 0 for yes, 1 for no
# Read from /dev/tty so it works when the script is piped via curl | bash
ask() {
	local question="${1}"
	local reply=""
	# Without a terminal nobody can answer, and that counts as no
	if ! { : </dev/tty; } 2>/dev/null; then
		return 1
	fi
	read -r -p "${question} [y/N] " reply </dev/tty
	case "${reply}" in
		[yY]) return 0 ;;
		*)    return 1 ;;
	esac
}

# Everything runs from one function, so a download of this script that was cut off runs nothing
main() {
	require_command curl curl
	require_command tar  tar
	require_command sha256sum coreutils

	# The page of the latest release redirects to its tag, and the tag is the version
	LATEST_RELEASE_URL=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "${RELEASES_URL}/latest" || true)
	declare -r VERSION="${LATEST_RELEASE_URL##*/}"

	if [[ ! "${VERSION}" =~ ${VERSION_PATTERN} ]]; then
		echo "Error: no releases found. Check ${RELEASES_URL}" >&2
		exit ${EXIT_MISSING_VERSION}
	fi

	declare -r ARCHIVE="AppImage_Installer-${VERSION}-${ARCH}.tar.gz"
	declare -r DOWNLOAD_URL="${RELEASES_URL}/download/${VERSION}"

	mkdir -p "${INSTALL_DIR}" "${DESKTOP_DIR}"

	# Remove what a run that was cut off left behind
	rm -rf "${WORK_DIR_PREFIX}"*
	# The work directory is beside the install location, so the checked file moves into place in one step
	WORK_DIR=$(mktemp -d "${WORK_DIR_PREFIX}XXXXXX")
	readonly WORK_DIR
	trap 'rm -rf "${WORK_DIR}"' EXIT

	echo "Downloading ${BINARY} ${VERSION}..."
	download "${ARCHIVE}"
	download "${ARCHIVE}.sha256"

	if ! (cd "${WORK_DIR}" && sha256sum -c "${ARCHIVE}.sha256" >/dev/null); then
		echo "Error: the download fails the checksum. Run this script again." >&2
		exit ${EXIT_BAD_DOWNLOAD}
	fi

	tar xzf "${WORK_DIR}/${ARCHIVE}" -C "${WORK_DIR}" "${BINARY}"
	if ! "${WORK_DIR}/${BINARY}" --version >/dev/null; then
		echo "Error: ${BINARY} ${VERSION} does not start on this system." >&2
		exit ${EXIT_BAD_DOWNLOAD}
	fi
	mv -f "${WORK_DIR}/${BINARY}" "${INSTALL_DIR}/${BINARY}"
	echo ""

	"${INSTALL_DIR}/${BINARY}" --desktop "${DESKTOP_DIR}" >/dev/null

	local associated="false"
	if ask "Associate .AppImage files with ${BINARY}?"; then
		require_command xdg-mime xdg-utils
		"${INSTALL_DIR}/${BINARY}" --associate
		associated="true"
	else
		echo "  -> Skipping file association"
		echo "  -> To associate later, run: ${BINARY} --associate"
	fi
	echo ""

	if command -v systemctl &>/dev/null && systemctl --user show-environment &>/dev/null; then
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
	echo ""
	echo "You'll find the AppImage Installer in your application launcher as 'AppImage Installer'"
	if [[ "${associated}" == "true" ]]; then
		echo "Double-click any .AppImage file in your file manager to install the file"
	fi

	# Warn if the install directory is not on PATH so the binary can actually be found
	if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
		echo "Warning: '${INSTALL_DIR}' is not in your PATH."
		echo "Add this line to your shell config (~/.bashrc, ~/.zshrc, etc.):"
		echo "  export PATH=\"\${HOME}/.local/bin:\${PATH}\""
	fi
}

main
exit ${EXIT_SUCCESS}
