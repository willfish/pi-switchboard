{
  pkgs,
  hubPackage,
  nixosModule,
}:
let
  inherit (pkgs) lib;
  fixture = ../tests/fixtures/hardened-service.py;
  python = "${pkgs.python3}/bin/python3";
  serviceNode = wildcard: { lib, ... }: {
    imports = [ nixosModule ];
    services.pi-agent-bus = {
      enable = true;
      package = hubPackage;
      tokenFile = "/run/pi-bus-fixture/token$literal";
    }
    // lib.optionalAttrs wildcard { listenAddress = "0.0.0.0"; };
    systemd.services.pi-bus-fixture-token = {
      wantedBy = [ "multi-user.target" ];
      before = [ "pi-agent-bus.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
        ExecStart = "${python} ${fixture} generate";
      };
    };
    systemd.services.pi-agent-bus = {
      requires = [ "pi-bus-fixture-token.service" ];
      after = [ "pi-bus-fixture-token.service" ];
      # Exercise the ordinary package, not an Erlang diagnostic init hook.
      environment = {
        HOME = "/root/pi-bus-inaccessible";
        PATH = lib.mkForce "/no-fixture-path";
      };
    };
    # This unrelated endpoint proves peer reachability independently of 7420.
    networking.firewall.allowedTCPPorts = [ 8080 ];
    systemd.services.pi-bus-connectivity = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${python} ${fixture} connectivity";
        DynamicUser = true;
        NoNewPrivileges = true;
      };
    };
  };
in
(pkgs.testers.runNixOSTest {
  requiredFeatures.kvm = true;
  name = "pi-agent-bus-hardened-service";
  defaults = {
    virtualisation = {
      memorySize = 1024;
      cores = 2;
      vlans = [ 1 ];
      # No user-mode network route to the host or Internet.
      restrictNetwork = true;
      qemu.forceAccel = lib.mkForce true;
    };
    networking.firewall.enable = true;
    environment.systemPackages = [
      pkgs.python3
      pkgs.util-linux
      pkgs.iproute2
    ];
    services.journald.extraConfig = "ForwardToConsole=no";
  };
  nodes = {
    service = serviceNode false;
    wildcard = serviceNode true;
    peer = { };
  };
  testScript = ''
    import fcntl

    with open("/dev/kvm", "rb+") as kvm:
        assert fcntl.ioctl(kvm.fileno(), 0xAE00, 0) == 12, "sandbox KVM API gate failed"
    start_all()
    peer.wait_for_unit("multi-user.target")
    for guest, bind in [(service, "127.0.0.1"), (wildcard, "0.0.0.0")]:
        guest.wait_for_unit("pi-agent-bus.service", timeout=30)
        guest.wait_for_unit("pi-bus-connectivity.service")
        guest.wait_for_open_port(7420)
        with subtest(guest.name + ": independent peer connectivity and bus denial"):
            peer.succeed("${python} ${fixture} peer " + guest.name)
        with subtest(guest.name + ": hardened packaged relay lifecycle"):
            # The helper captures HTTP and journal content internally. Only safe
            # assertions and a resource-property allowlist reach the driver log.
            print(guest.succeed("${python} ${fixture} exercise " + bind + " ${hubPackage}", timeout=90))
        with subtest(guest.name + ": peer denial after recovery"):
            peer.succeed("${python} ${fixture} peer " + guest.name)
        guest.succeed("${python} ${fixture} final-stop", timeout=15)
  '';
}).overrideTestDerivation
  (_: {
    allowSubstitutes = false;
    preferLocalBuild = true;
  })
