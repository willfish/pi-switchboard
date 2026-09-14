#!/usr/bin/env bash
set -euo pipefail
# The installer otherwise succeeds without applying configuration when Nix exists.
if command -v nix >/dev/null 2>&1; then
  echo 'Unexpected preinstalled Nix; refusing to bypass the pinned bootstrap' >&2
  exit 1
fi
: "${RUNNER_TEMP:?ephemeral runner directory required}"
: "${GITHUB_OUTPUT:?GitHub step output file required}"
installer="$RUNNER_TEMP/nix-installer"
curl --fail --silent --show-error --location \
  https://releases.nixos.org/nix/nix-2.35.2/install -o "$installer"
expected=9adda97297d9e8ab360df95c729eabff4f4f93d6db091953c3a68f29e3fb130c
actual=$(shasum -a 256 "$installer" | cut -d ' ' -f 1)
test "$actual" = "$expected"
printf 'url=file://%s\n' "$installer" >> "$GITHUB_OUTPUT"
