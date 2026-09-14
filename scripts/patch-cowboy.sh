#!/bin/sh
# Apply only to the exact locked Cowboy source, or accept its exact patched form.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
target=${1:?usage: patch-cowboy.sh COWBOY_SOURCE_DIRECTORY}
file="$target/src/cowboy_http.erl"
original=70bb9c54fb6e1861c5b97c7705de322e9834fa10f1d374908fdf7f31006776b8
patched=f080df3809e8d99fd94b8b4cc194e0b4080959e2afd3e264ca46a7e7c3d5dc91
digest() { sha256sum "$file" | cut -d ' ' -f 1; }
case $(digest) in
    "$patched") echo "Cowboy 2.14.0 limits patch already verified" ;;
    "$original")
        patch --batch --fuzz=0 -d "$target" -p1 < "$root/patches/cowboy-2.14.0-complete-input-limits.patch"
        test "$(digest)" = "$patched" || { echo 'Patched Cowboy digest mismatch' >&2; exit 1; }
        ;;
    *) echo 'Refusing unknown Cowboy source' >&2; exit 1 ;;
esac
