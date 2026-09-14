#!/usr/bin/env bash
set -euo pipefail
: "${EXPECTED_SYSTEM:?native system required}"
: "${NIX_SYSTEM_FEATURES:?successful native preflight required}"
case "$EXPECTED_SYSTEM" in x86_64-linux|aarch64-darwin) ;; *) exit 1 ;; esac
options=(--print-build-logs --option builders '' --option max-jobs 1 --option always-allow-substitutes false --option system-features "$NIX_SYSTEM_FEATURES")
if [[ "$EXPECTED_SYSTEM" = x86_64-linux ]]; then
  nix build --impure --no-link --file .github/scripts/kvm-probe.nix "${options[@]}"
fi
# Bootstrap only the environment loader; dependencies remain pinned by this flake.
direnv_package=$(nix build --impure --no-link --print-out-paths "${options[@]}" --expr \
  "(builtins.getFlake (toString ./.)).inputs.nixpkgs.legacyPackages.\"$EXPECTED_SYSTEM\".direnv")
"$direnv_package/bin/direnv" allow .
"$direnv_package/bin/direnv" exec . bash -c '
  set -euo pipefail
  options=(--print-build-logs --option builders "" --option max-jobs 1 --option always-allow-substitutes false --option system-features "$NIX_SYSTEM_FEATURES")
  nix flake check --all-systems --no-build --no-update-lock-file "${options[@]}"
  nix build .#hub .#pi-extension --no-link --no-update-lock-file "${options[@]}"
  nix flake check --no-update-lock-file "${options[@]}"
  nixfmt --check flake.nix nix/*.nix .github/scripts/*.nix
  git diff --check
  git diff --exit-code
'
