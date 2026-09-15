{ self }:
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.services.pi-agent-bus;
  firewall = config.networking.firewall;
  opensPort =
    settings:
    lib.elem cfg.port (settings.allowedTCPPorts or [ ])
    || lib.any (range: range.from <= cfg.port && cfg.port <= range.to) (
      settings.allowedTCPPortRanges or [ ]
    );
  tailnetBoundary =
    firewall.enable
    && config.services.tailscale.enable
    && cfg.operatorInterface == config.services.tailscale.interfaceName
    && cfg.operatorInterface != "userspace-networking"
    && !opensPort firewall
    && lib.all (name: name == cfg.operatorInterface || name == "lo") firewall.trustedInterfaces
    && lib.all (
      name: name == cfg.operatorInterface || name == "lo" || !opensPort firewall.interfaces.${name}
    ) (builtins.attrNames firewall.interfaces)
    && (
      lib.elem cfg.operatorInterface firewall.trustedInterfaces
      || opensPort (firewall.interfaces.${cfg.operatorInterface} or { })
    );
  runtimePath = lib.types.addCheck lib.types.str (
    value:
    !builtins.hasContext value
    && lib.hasPrefix "/" value
    && value != "/"
    && value != "/nix/store"
    && !lib.hasPrefix "/nix/store/" value
    && builtins.match ".*[[:cntrl:]].*" value == null
    # systemd 260's executor serializes this path as an unescaped word.
    && !lib.any (character: lib.hasInfix character value) [
      "%"
      " "
      "\""
      "'"
      "\\"
    ]
    && lib.all (part: part != "" && part != "." && part != "..") (
      builtins.tail (lib.splitString "/" value)
    )
  );
in
{
  options.services.pi-agent-bus = {
    enable = lib.mkEnableOption "the volatile Pi agent bus relay";
    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.hub;
      defaultText = lib.literalExpression "self.packages.\${pkgs.stdenv.hostPlatform.system}.hub";
      description = "Relay package providing bin/pi-agent-bus.";
    };
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address on which the relay listens. No firewall ports are opened.";
    };
    port = lib.mkOption {
      type = lib.types.ints.between 1 65535;
      default = 7420;
      description = "TCP listening port.";
    };
    operatorAccess = lib.mkOption {
      type = lib.types.enum [
        "disabled"
        "loopback"
        "tailnet"
      ];
      default = "disabled";
      description = ''
        Automatic operator access without a user-managed credential. Tailnet mode
        trusts peers admitted by the existing network policy, not a named human.
        It requires a verified ingress boundary; this module opens no ports.
        Legacy native APIs still require their runtime bearer credential.
      '';
    };
    operatorInterface = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_.-]{1,64}";
      default = "tailscale0";
      description = ''
        Exact kernel interface used for operator destination verification.
        In tailnet mode it must match the managed Tailscale tunnel interface.
        This is not a network namespace or a substitute for ingress filtering.
      '';
    };
    tokenFile = lib.mkOption {
      type = lib.types.nullOr runtimePath;
      default = null;
      example = "/run/secrets/pi-agent-bus-token";
      description = ''
        Absolute, normalized runtime path string to the bearer token, required
        when enabled. Store paths, string context, controls, spaces, quotes,
        backslashes and systemd specifiers are rejected. The pinned systemd
        executor cannot safely serialize these path characters. The file is
        never read during evaluation.
        The consumer owns installation ordering and rotation.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.tokenFile != null;
        message = "services.pi-agent-bus.tokenFile must be a runtime path string when enabled.";
      }
      {
        assertion = cfg.operatorAccess != "tailnet" || tailnetBoundary;
        message = ''
          Tailnet operator access requires the enabled firewall and managed
          Tailscale interface, with this TCP port admitted only on that interface
          or loopback, not through global allowances or other trusted interfaces.
          Custom firewall/forwarding rules still require deployment verification.
        '';
      }
    ];
    systemd.services.pi-agent-bus = {
      description = "Pi agent bus relay";
      wantedBy = [ "multi-user.target" ];
      environment = {
        PI_AGENT_BUS_BIND_HOST = cfg.listenAddress;
        PI_AGENT_BUS_PORT = toString cfg.port;
        PI_AGENT_BUS_TOKEN_FILE = "%d/bus-token";
        PI_AGENT_BUS_OPERATOR_ACCESS = cfg.operatorAccess;
        PI_AGENT_BUS_OPERATOR_INTERFACE = cfg.operatorInterface;
        ERL_CRASH_DUMP = "/dev/null";
      };
      serviceConfig = {
        ExecStart = utils.escapeSystemdExecArgs [ "${cfg.package}/bin/pi-agent-bus" ];
        # systemd parses the portion after ':' literally, without unquoting or
        # C-unescaping. Quoting would become part of the credential filename.
        LoadCredential = lib.optional (cfg.tokenFile != null) "bus-token:${cfg.tokenFile}";
        DynamicUser = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        RuntimeDirectory = "pi-agent-bus";
        Restart = "on-failure";
        RestartSec = 2;
        TimeoutStopSec = "10s";
        KillSignal = "SIGTERM";
        KillMode = "control-group";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
        LimitCORE = 0;
        CPUAccounting = true;
        MemoryAccounting = true;
        TasksAccounting = true;
      };
    };
  };
}
