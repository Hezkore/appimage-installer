#!/usr/bin/env bash
# Builds and runs appimage-installer from the current checkout
#

set -euo pipefail

declare -r EXIT_SUCCESS=0
declare -r EXIT_MISSING_DEPENDENCY=1
declare -r EXIT_LAUNCH_FAILED=2

declare -a BUILD_ARGS=()
declare -a RUN_ARGS=()
declare -r BUILD_ONLY_FLAG="--build-only"
declare BUILD_ONLY="false"

while (($#)); do
	case "$1" in
		"${BUILD_ONLY_FLAG}")
			BUILD_ONLY="true"
			shift
			;;
		--)
			shift
			RUN_ARGS=("$@")
			break
			;;
		*)
			BUILD_ARGS+=("$1")
			shift
			;;
	esac
done

if ! command -v dub &>/dev/null; then
	echo "Error: 'dub' is required but not installed."
	echo "Install the D compiler and DUB from https://dlang.org/download.html"
	exit ${EXIT_MISSING_DEPENDENCY}
fi

dub build "${BUILD_ARGS[@]}"

if [[ "${BUILD_ONLY}" == "true" ]]; then
	exit ${EXIT_SUCCESS}
fi

exec ./appimage-installer "${RUN_ARGS[@]}"
exit ${EXIT_LAUNCH_FAILED}
