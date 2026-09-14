#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source=${1:?usage: test-patch-cowboy.sh PRISTINE_COWBOY_SOURCE_DIRECTORY}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/cowboy/src"
cp "$source/src/cowboy_http.erl" "$tmp/cowboy/src/"
sh "$root/scripts/patch-cowboy.sh" "$tmp/cowboy"
cp "$tmp/cowboy/src/cowboy_http.erl" "$tmp/once"
sh "$root/scripts/patch-cowboy.sh" "$tmp/cowboy"
cmp "$tmp/once" "$tmp/cowboy/src/cowboy_http.erl"
printf '\n%% unexpected source change\n' >> "$tmp/cowboy/src/cowboy_http.erl"
cp "$tmp/cowboy/src/cowboy_http.erl" "$tmp/mismatch"
if sh "$root/scripts/patch-cowboy.sh" "$tmp/cowboy"; then
    echo 'Unexpectedly accepted mismatched source' >&2
    exit 1
fi
cmp "$tmp/mismatch" "$tmp/cowboy/src/cowboy_http.erl"
echo 'Patch application, idempotence and fail-closed mismatch checks passed'
