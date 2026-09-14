{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.pi-agent-bus;
in
{
  options.programs.pi-agent-bus = {
    enable = lib.mkEnableOption "the Pi agent bus client extension";
    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.pi-extension;
      defaultText = lib.literalExpression "self.packages.\${pkgs.stdenv.hostPlatform.system}.pi-extension";
      description = "Complete source-only Pi extension package root.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.file.".pi/agent/extensions/agent-bus" = {
      source = cfg.package;
      recursive = false;
    };
  };
}
