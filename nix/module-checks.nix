{
  self,
  nixpkgs,
  home-manager,
  pkgs,
}:
let
  inherit (pkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  link = ".pi/agent/extensions/agent-bus";
  unavailable.packages = throw "disabled module forced its package default";
  nixosModule = self.nixosModules.default;
  hmModule = self.homeManagerModules.default;
  evalNixos =
    module: settings:
    nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        module
        {
          boot.isContainer = true;
          system.stateVersion = "26.05";
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          services.pi-agent-bus = settings;
        }
      ];
    };
  evalHome =
    module: settings:
    home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        module
        {
          home.username = "module-test";
          home.homeDirectory = if pkgs.stdenv.isDarwin then "/Users/module-test" else "/home/module-test";
          home.stateVersion = "26.05";
          programs.pi-agent-bus = settings;
        }
      ];
    };
  disabledNixos = evalNixos (import ./nixos-module.nix { self = unavailable; }) { };
  disabledHome = evalHome (import ./home-manager-module.nix { self = unavailable; }) { };
  tokenPath = "/run/synthetic-credential/dollar$token";
  enabledNixos = evalNixos nixosModule {
    enable = true;
    tokenFile = tokenPath;
  };
  enabledHome = evalHome hmModule { enable = true; };
  loopbackOperator = evalNixos nixosModule {
    enable = true;
    tokenFile = tokenPath;
    operatorAccess = "loopback";
  };
  tailnetOperator =
    extra:
    evalNixos
      {
        imports = [
          nixosModule
          {
            services.tailscale.enable = true;
            networking.firewall.trustedInterfaces = [ "tailscale0" ];
          }
          extra
        ];
      }
      {
        enable = true;
        tokenFile = tokenPath;
        operatorAccess = "tailnet";
      };
  overrideHub = pkgs.runCommand "pi-agent-bus-override" { } ''
    mkdir -p "$out/bin"
    printf '#!/bin/sh\nexit 0\n' > "$out/bin/pi-agent-bus"
    chmod +x "$out/bin/pi-agent-bus"
  '';
  overrideExtension = pkgs.runCommand "pi-extension-override" { } ''
    mkdir -p "$out"
    cp -R ${self.packages.${system}.pi-extension}/. "$out/"
    echo override > "$out/override-marker"
  '';
  overriddenNixos = evalNixos nixosModule {
    enable = true;
    tokenFile = "/run/nonexistent-test-token";
    package = overrideHub;
    listenAddress = "0.0.0.0";
    port = 17420;
  };
  overriddenHome = evalHome hmModule {
    enable = true;
    package = overrideExtension;
  };
  service = enabledNixos.config.systemd.services.pi-agent-bus;
  hardening = service.serviceConfig;
  unit = enabledNixos.config.systemd.units."pi-agent-bus.service".text;
  valid = evaluation: lib.all (a: a.assertion) evaluation.config.assertions;
  rejects =
    settings:
    let
      evaluated = evalNixos nixosModule (
        {
          enable = true;
          tokenFile = "/run/nonexistent-test-token";
        }
        // settings
      );
      attempt = builtins.tryEval (
        builtins.deepSeq [
          (valid evaluated)
          evaluated.config.systemd.units."pi-agent-bus.service".text
        ] (valid evaluated)
      );
    in
    !attempt.success || !attempt.value;
  invalidTokens = [
    null
    "relative/token"
    "/nix/store"
    "/nix/store/synthetic/token"
    "/run/../nix/store/token"
    "//nix/store/token"
    "/run/%d/token"
    "/run/%%/token"
    "/run/new\nline"
    "/run/tab\tfile"
    "/run/return\rfile"
    "/run/embedded space"
    "/run/quote\"file"
    "/run/quote'file"
    "/run/back\\slash"
    "/run/trailing-space "
    "/run/trailing-backslash\\"
    ./nixos-module.nix
    "${self.packages.${system}.hub}/token"
    (builtins.appendContext "/run/context-token" (builtins.getContext "${self.packages.${system}.hub}"))
  ];
  homeAssertions =
    assert valid enabledHome && valid overriddenHome && valid disabledHome;
    assert !(disabledHome.config.home.file ? ${link});
    assert disabledHome.config.home.packages == (evalHome hmModule { }).config.home.packages;
    assert enabledHome.config.home.packages == disabledHome.config.home.packages;
    assert
      builtins.attrNames (builtins.removeAttrs enabledHome.config.home.file [ link ])
      == builtins.attrNames disabledHome.config.home.file;
    assert
      builtins.attrNames enabledHome.options.programs.pi-agent-bus == [
        "enable"
        "package"
      ];
    assert enabledHome.config.programs.pi-agent-bus.package == self.packages.${system}.pi-extension;
    assert enabledHome.config.home.file.${link}.source == self.packages.${system}.pi-extension;
    assert !enabledHome.config.home.file.${link}.recursive;
    assert overriddenHome.config.home.file.${link}.source == overrideExtension;
    assert enabledHome.config.home.sessionVariables == disabledHome.config.home.sessionVariables;
    assert enabledHome.config.systemd.user.services == disabledHome.config.systemd.user.services;
    true;
  nixosAssertions =
    assert valid disabledNixos && valid enabledNixos && valid overriddenNixos;
    assert !(disabledNixos.config.systemd.services ? pi-agent-bus);
    assert disabledNixos.config.services.pi-agent-bus.tokenFile == null;
    assert !(valid (evalNixos nixosModule { enable = true; }));
    assert
      builtins.attrNames enabledNixos.options.services.pi-agent-bus == [
        "enable"
        "listenAddress"
        "operatorAccess"
        "operatorInterface"
        "package"
        "port"
        "tokenFile"
      ];
    assert
      enabledNixos.config.environment.systemPackages == disabledNixos.config.environment.systemPackages;
    assert enabledNixos.config.services.pi-agent-bus.package == self.packages.${system}.hub;
    assert service.environment.PI_AGENT_BUS_BIND_HOST == "127.0.0.1";
    assert service.environment.PI_AGENT_BUS_PORT == "7420";
    assert service.environment.PI_AGENT_BUS_TOKEN_FILE == "%d/bus-token";
    assert service.environment.PI_AGENT_BUS_OPERATOR_ACCESS == "disabled";
    assert service.environment.PI_AGENT_BUS_OPERATOR_INTERFACE == "tailscale0";
    assert valid loopbackOperator;
    assert
      loopbackOperator.config.systemd.services.pi-agent-bus.environment.PI_AGENT_BUS_OPERATOR_ACCESS
      == "loopback";
    assert valid (tailnetOperator { });
    assert
      !(valid (tailnetOperator {
        networking.firewall.enable = false;
      }));
    assert
      !(valid (tailnetOperator {
        services.tailscale.enable = lib.mkForce false;
      }));
    assert
      !(valid (tailnetOperator {
        networking.firewall.allowedTCPPorts = [ 7420 ];
      }));
    assert
      !(valid (tailnetOperator {
        networking.firewall.allowedTCPPortRanges = [
          {
            from = 7400;
            to = 7500;
          }
        ];
      }));
    assert
      !(valid (tailnetOperator {
        networking.firewall.trustedInterfaces = [ "eth0" ];
      }));
    assert
      !(valid (tailnetOperator {
        networking.firewall.interfaces.eth0.allowedTCPPorts = [ 7420 ];
      }));
    assert
      !(valid (tailnetOperator {
        networking.firewall.interfaces.eth0.allowedTCPPortRanges = [
          {
            from = 7400;
            to = 7500;
          }
        ];
      }));
    assert
      !(valid (tailnetOperator {
        services.pi-agent-bus.operatorInterface = "other0";
      }));
    assert rejects { operatorAccess = "unknown"; };
    assert rejects { operatorInterface = "../namespace"; };
    assert valid (tailnetOperator {
      networking.firewall.trustedInterfaces = lib.mkForce [ ];
      networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 7420 ];
    });
    assert service.environment.ERL_CRASH_DUMP == "/dev/null";
    assert hardening.LoadCredential == [ "bus-token:${tokenPath}" ];
    assert lib.elem "LoadCredential=bus-token:${tokenPath}" (lib.splitString "\n" unit);
    assert lib.elem "ExecStart=\"${self.packages.${system}.hub}/bin/pi-agent-bus\"" (
      lib.splitString "\n" unit
    );
    assert
      hardening.DynamicUser && hardening.ProtectHome && hardening.PrivateTmp && hardening.NoNewPrivileges;
    assert hardening.ProtectSystem == "strict" && hardening.RuntimeDirectory == "pi-agent-bus";
    assert hardening.Restart == "on-failure" && hardening.RestartSec == 2;
    assert
      hardening.TimeoutStopSec == "10s"
      && hardening.KillSignal == "SIGTERM"
      && hardening.KillMode == "control-group";
    assert hardening.CPUAccounting && hardening.MemoryAccounting && hardening.TasksAccounting;
    assert
      hardening.RestrictAddressFamilies == [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
      ];
    assert hardening.LimitCORE == 0;
    assert lib.all (key: !(builtins.hasAttr key hardening)) [
      "MemoryDenyWriteExecute"
      "MemoryMax"
      "MemoryHigh"
      "TasksMax"
      "LimitNOFILE"
    ];
    assert enabledNixos.config.networking.firewall == disabledNixos.config.networking.firewall;
    assert overriddenNixos.config.networking.firewall == disabledNixos.config.networking.firewall;
    assert
      overriddenNixos.config.systemd.services.pi-agent-bus.serviceConfig.ExecStart
      == "\"${overrideHub}/bin/pi-agent-bus\"";
    assert
      overriddenNixos.config.systemd.services.pi-agent-bus.environment.PI_AGENT_BUS_BIND_HOST
      == "0.0.0.0";
    assert
      overriddenNixos.config.systemd.services.pi-agent-bus.environment.PI_AGENT_BUS_PORT == "17420";
    assert lib.all (tokenFile: rejects { inherit tokenFile; }) invalidTokens;
    assert lib.all (port: rejects { inherit port; }) [
      0
      65536
      (-1)
      "7420"
    ];
    assert valid (
      evalNixos nixosModule {
        enable = true;
        tokenFile = "/run/absent";
        port = 1;
      }
    );
    assert valid (
      evalNixos nixosModule {
        enable = true;
        tokenFile = "/run/absent";
        port = 65535;
      }
    );
    true;
  extension = self.packages.${system}.pi-extension;
  closure = pkgs.closureInfo { rootPaths = [ extension ]; };
in
{
  module-home-manager =
    assert homeAssertions;
    pkgs.runCommand "pi-agent-bus-home-manager-module"
      {
        allowSubstitutes = false;
        preferLocalBuild = true;
        nativeBuildInputs = [ pkgs.nodejs ];
      }
      ''
        root=${enabledHome.config.home-files}/${link}
        test -L "$root"
        test "$(readlink -f "$root")" = ${extension}
        override=${overriddenHome.config.home-files}/${link}
        test -L "$override"
        test "$(readlink -f "$override")" = ${overrideExtension}
        test -f "$override/override-marker"
        test ! -e ${disabledHome.config.home-files}/${link}
        test ! -e "$root/node_modules"
        # Source-only output must have no runtime closure, including hub/ERTS/devdeps.
        test "$(wc -l < ${closure}/store-paths)" -eq 1
        grep -Fx ${extension} ${closure}/store-paths
        node --input-type=module - "$root" <<'JS'
        import fs from 'node:fs';
        import path from 'node:path';
        const root = process.argv[2];
        for (const file of ['package.json', 'index.ts', 'README.md', 'LICENSE', 'extension/index.ts', 'docs/protocol.md', 'docs/operations.md', 'docs/compatibility.md']) {
          if (!fs.statSync(path.join(root, file)).isFile()) throw Error('missing package file: ' + file);
        }
        function check(dir) {
          for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
            const file = path.join(dir, entry.name);
            if (entry.isDirectory()) check(file);
            else if (file.endsWith('.ts')) {
              for (const match of fs.readFileSync(file, 'utf8').matchAll(/(?:from\s*|import\s*)["'](\.[^"']+)["']/g)) {
                if (!fs.statSync(path.resolve(path.dirname(file), match[1])).isFile()) throw Error('missing import: ' + match[1]);
              }
            }
          }
        }
        check(root);
        JS
        touch "$out"
      '';
}
// lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
  module-nixos =
    assert nixosAssertions;
    pkgs.runCommand "pi-agent-bus-nixos-module"
      {
        allowSubstitutes = false;
        preferLocalBuild = true;
        generatedUnit = unit;
        passAsFile = [ "generatedUnit" ];
      }
      ''
        mkdir -p "$out"
        cp "$generatedUnitPath" "$out/pi-agent-bus.service"
      '';
}
