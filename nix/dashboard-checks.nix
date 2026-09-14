{ pkgs, src }:
pkgs.runCommand "pi-switchboard-dashboard-tests"
  {
    inherit src;
    nativeBuildInputs = [ pkgs.nodejs ];
    allowSubstitutes = false;
    preferLocalBuild = true;
  }
  ''
    cp -R "$src" source
    cd source
    node --test tests/dashboard*.test.mjs
    touch "$out"
  ''
