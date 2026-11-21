#!/bin/bash
# Builds the QIDI Q1 Pro Armbian image: ./build.sh [Armbian KEY=VALUE ...]
# ARMBIAN_DIR uses that checkout as it is; otherwise Armbian is cloned at ARMBIAN_REF (as in CI).
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
ARMBIAN_REPO=https://github.com/armbian/build.git
ARMBIAN_REF=$(cat "$HERE/ARMBIAN_REF")

if [ -n "${ARMBIAN_DIR:-}" ]; then
	head=$(git -C "$ARMBIAN_DIR" rev-parse HEAD)
	[ "$head" = "$ARMBIAN_REF" ] ||
		echo "build.sh: $ARMBIAN_DIR is at $head, CI builds $ARMBIAN_REF" >&2
else
	ARMBIAN_DIR=$HERE/armbian_build
	if [ ! -d "$ARMBIAN_DIR/.git" ]; then
		git init -q "$ARMBIAN_DIR"
		git -C "$ARMBIAN_DIR" remote add origin "$ARMBIAN_REPO"
	fi
	git -C "$ARMBIAN_DIR" fetch -q --depth 1 origin "$ARMBIAN_REF"
	git -C "$ARMBIAN_DIR" checkout -q --detach FETCH_HEAD
fi

exec "$ARMBIAN_DIR/compile.sh" build libreq1pro USERPATCHES_PATH="$HERE/userpatches" "$@"
