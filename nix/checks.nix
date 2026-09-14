{
  pkgs,
  src,
  version,
  dependencyHash,
}:
let
  inherit (pkgs) lib;
  beam = pkgs.beamMinimal28Packages;
  checkouts = import ./cowboy-checkouts.nix {
    inherit pkgs version dependencyHash;
    src = "${src}/hub";
  };
in
pkgs.stdenv.mkDerivation {
  pname = "pi-agent-bus-hub-tests";
  allowSubstitutes = false;
  preferLocalBuild = true;
  inherit version src;
  sourceRoot = "source/hub";
  __darwinAllowLocalNetworking = pkgs.stdenv.hostPlatform.isDarwin;
  nativeBuildInputs = [
    beam.erlang
    beam.rebar3
  ];
  configurePhase = ''
    runHook preConfigure
    cp --no-preserve=all -R ${checkouts}/_checkouts .
    runHook postConfigure
  '';
  buildPhase = ''
    runHook preBuild
    export HOME="$TMPDIR"
    rebar3 eunit
    rebar3 ct
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    touch "$out/passed"
    runHook postInstall
  '';
  meta = {
    description = "Pi Switchboard hub EUnit and Common Test";
    platforms = lib.platforms.unix;
  };
}
