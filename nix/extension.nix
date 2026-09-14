{
  pkgs,
  src,
  version,
}:
let
  inherit (pkgs) lib;
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "pi-switchboard";
  inherit version src;
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp package.json index.ts README.md LICENSE "$out/"
    cp -R extension "$out/extension"
    cp -R docs "$out/docs"
    runHook postInstall
  '';
  meta = {
    description = "Pi Switchboard client extension";
    license = lib.licenses.mit;
  };
}
