{
  pkgs,
  src,
  version,
  dependencyHash,
}:
let
  inherit (pkgs) lib;
  beam = pkgs.beamMinimal28Packages;
  release = beam.rebar3Relx {
    pname = "pi-agent-bus";
    inherit src version;
    releaseType = "release";
    profile = "default";
    checkouts = import ./cowboy-checkouts.nix {
      inherit
        pkgs
        src
        version
        dependencyHash
        ;
    };
  };
in
pkgs.stdenv.mkDerivation {
  pname = "pi-agent-bus";
  inherit version;
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.makeWrapper ];
  buildInputs = [ release ];
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    makeWrapper ${release}/rel/pi_agent_bus/bin/pi_agent_bus "$out/bin/pi-agent-bus" \
      --prefix PATH : ${lib.makeBinPath [ pkgs.coreutils ]} \
      --unset ERL_FLAGS \
      --unset ERL_AFLAGS \
      --unset ERL_ZFLAGS \
      --set ERL_CRASH_DUMP /dev/null \
      --add-flags "-noinput +Bd -mode embedded -start_epmd false"
    runHook postInstall
  '';
  meta = {
    description = "Pi Switchboard hub";
    mainProgram = "pi-agent-bus";
    platforms = lib.platforms.unix;
  };
}
