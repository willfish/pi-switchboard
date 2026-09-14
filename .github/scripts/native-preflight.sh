#!/usr/bin/env bash
set -euo pipefail
: "${EXPECTED_SYSTEM:?native matrix system required}"
: "${GITHUB_ENV:?GitHub job environment file required}"
test "$(nix --version)" = 'nix (Nix) 2.35.2' || { echo 'Unexpected Nix bootstrap version' >&2; exit 1; }
printf 'Runner image: %s %s\n' "${ImageOS:-unknown}" "${ImageVersion:-unknown}"
features='nixos-test benchmark big-parallel'
case "$EXPECTED_SYSTEM" in
  x86_64-linux)
    test "$(uname -s)" = Linux
    test "$(uname -m)" = x86_64
    test -c /dev/kvm || { echo 'Required Linux runner has no KVM device' >&2; exit 1; }
    python3 -I - <<'PY'
import fcntl
import os
fd = os.open('/dev/kvm', os.O_RDWR | os.O_CLOEXEC)
try:
    if fcntl.ioctl(fd, 0xAE00, 0) != 12:
        raise SystemExit('Required KVM API is unavailable')
finally:
    os.close(fd)
PY
    features="$features kvm"
    ;;
  aarch64-darwin)
    test "$(uname -s)" = Darwin
    test "$(uname -m)" = arm64
    translated=$(sysctl -in sysctl.proc_translated 2>/dev/null || printf '0')
    test "$translated" != 1 || { echo 'Rosetta is not native Darwin acceptance' >&2; exit 1; }
    ;;
  *) echo 'Unsupported native matrix system' >&2; exit 1 ;;
esac
actual=$(nix eval --impure --raw --expr builtins.currentSystem)
test "$actual" = "$EXPECTED_SYSTEM" || { echo 'Nix native system differs from runner matrix' >&2; exit 1; }
# Never dump Nix configuration: the installer can store its read-only GitHub token there.
printf 'NIX_SYSTEM_FEATURES=%s\n' "$features" >> "$GITHUB_ENV"
