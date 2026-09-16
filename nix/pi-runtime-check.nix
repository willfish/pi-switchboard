{
  pkgs,
  piPackage,
  hubPackage,
  extensionPackage,
}:
let
  src = pkgs.lib.fileset.toSource {
    root = ../.;
    fileset = pkgs.lib.fileset.unions [
      ../tests/pi-runtime.test.mjs
      ../tests/fixtures/pi-runtime
      ../tests/fixtures/operator-work.json
    ];
  };
in
pkgs.runCommand "pi-switchboard-pi-runtime"
  {
    allowSubstitutes = false;
    preferLocalBuild = true;
    nativeBuildInputs = [
      pkgs.nodejs
      pkgs.python3
    ];
    PI_AGENT_BUS_TEST_PI_PACKAGE = piPackage;
    PI_AGENT_BUS_TEST_EXTENSION_PACKAGE = extensionPackage;
    PI_AGENT_BUS_TEST_EXECUTABLE = "${hubPackage}/bin/pi-agent-bus";
    PI_AGENT_BUS_TEST_PYTHON = "${pkgs.python3}/bin/python3";
    PI_AGENT_BUS_TEST_TOOL_PATH = pkgs.lib.makeBinPath [
      pkgs.fd
      pkgs.ripgrep
    ];
    # Ordinary sandboxed check. Darwin needs only the loopback exception.
    __darwinAllowLocalNetworking = true;
  }
  ''
    node --test ${src}/tests/pi-runtime.test.mjs
    touch "$out"
  ''
