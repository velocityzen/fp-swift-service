#!/bin/bash
# Usage: install-swift-sdk.sh <archive URL> <SHA-256> [swift sdk install options...]
#
# Installs the Swift SDK bundle at `archive URL`, once it matches `SHA-256`.
# curl downloads it, retrying, and `swift sdk install` gets the file: given a
# URL, SwiftPM downloads with URLSession, which on Linux can crash once the
# download is done ("_MultiHandle deallocated with non-zero retain count") and
# fail the job. Given a path, it downloads nothing.
set -euo pipefail
url=$1 sha256=$2
shift 2

archive="$RUNNER_TEMP/$(basename "$url")"
curl -fsSL --retry 5 --retry-all-errors -o "$archive" "$url"
echo "$sha256  $archive" | sha256sum --check --strict -
swift sdk install "$archive" "$@"
rm "$archive"
