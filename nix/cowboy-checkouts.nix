{
  pkgs,
  src,
  version,
  dependencyHash,
}:
let
  locked = pkgs.beamMinimal28Packages.fetchRebar3Deps {
    name = "pi-agent-bus";
    inherit src version;
    sha256 = dependencyHash;
  };
in
pkgs.runCommand "pi-agent-bus-patched-checkouts"
  {
    nativeBuildInputs = [
      pkgs.patch
      pkgs.coreutils
    ];
  }
  ''
    cp --no-preserve=all -R ${locked} "$out"
    mkdir -p scripts patches
    cp ${../scripts/patch-cowboy.sh} scripts/patch-cowboy.sh
    cp ${../scripts/test-patch-cowboy.sh} scripts/test-patch-cowboy.sh
    cp ${../patches/cowboy-2.14.0-complete-input-limits.patch} patches/cowboy-2.14.0-complete-input-limits.patch
    sh scripts/test-patch-cowboy.sh "$out/_checkouts/cowboy"
    sh scripts/patch-cowboy.sh "$out/_checkouts/cowboy"
  ''
