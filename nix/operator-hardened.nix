{
  pkgs,
  hubPackage,
  nixosModule,
}:
let
  inherit (pkgs) lib;
  python = "${pkgs.python3}/bin/python3";
  fixture = ../tests/fixtures/operator-hardened.py;
  connectivity = ../tests/fixtures/hardened-service.py;
in
(pkgs.testers.runNixOSTest {
  requiredFeatures.kvm = true;
  name = "pi-operator-hardened-ingress";
  defaults = {
    virtualisation = {
      memorySize = 1024;
      cores = 2;
      vlans = [
        1
        2
      ];
      restrictNetwork = true;
      qemu.forceAccel = lib.mkForce true;
    };
    networking.firewall.enable = true;
    environment.systemPackages = [
      pkgs.python3
      pkgs.iproute2
    ];
    services.journald.extraConfig = "ForwardToConsole=no";
  };
  nodes = {
    operator = { lib, ... }: {
      imports = [ nixosModule ];
      # eth2 is a synthetic trusted ingress. This tests interface discovery and
      # firewall isolation, not Tailscale cryptography or the live tailnet ACL.
      services.tailscale = {
        enable = true;
        interfaceName = "eth2";
      };
      systemd.services.tailscaled.enable = lib.mkForce false;
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
        {
          address = "192.0.2.1";
          prefixLength = 24;
        }
      ];
      networking.interfaces.eth2.ipv4.addresses = lib.mkForce [
        {
          address = "198.51.100.1";
          prefixLength = 24;
        }
      ];
      networking.firewall.interfaces.eth2.allowedTCPPorts = [ 7420 ];
      networking.firewall.allowedTCPPorts = [ 8080 ];
      services.pi-agent-bus = {
        enable = true;
        package = hubPackage;
        tokenFile = "/run/pi-operator-fixture/token";
        listenAddress = "0.0.0.0";
        operatorAccess = "tailnet";
        operatorInterface = "eth2";
      };
      systemd.services.pi-operator-fixture-token = {
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
        requires = [ "pi-operator-fixture-token.service" ];
        after = [ "pi-operator-fixture-token.service" ];
        environment = {
          HOME = "/root/pi-operator-inaccessible";
          PATH = lib.mkForce "/no-fixture-path";
        };
      };
      systemd.services.pi-operator-connectivity = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${python} ${connectivity} connectivity";
          DynamicUser = true;
          NoNewPrivileges = true;
        };
      };
    };
    peer = { lib, ... }: {
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
        {
          address = "192.0.2.2";
          prefixLength = 24;
        }
      ];
      networking.interfaces.eth2.ipv4.addresses = lib.mkForce [
        {
          address = "198.51.100.2";
          prefixLength = 24;
        }
      ];
    };
  };
  testScript = ''
    import fcntl
    with open("/dev/kvm", "rb+") as kvm:
        assert fcntl.ioctl(kvm.fileno(), 0xAE00, 0) == 12
    start_all()
    operator.wait_for_unit("pi-agent-bus.service", timeout=30)
    operator.wait_for_unit("pi-operator-connectivity.service")
    peer.wait_for_unit("multi-user.target")
    with subtest("independent physical-path connectivity"):
        peer.succeed("${python} -c \"import socket; socket.create_connection(('192.0.2.1',8080),3).close()\"")
    with subtest("untrusted ingress cannot reach operator port"):
        peer.succeed("${python} ${fixture} blocked 192.0.2.1 7420")
    with subtest("trusted interface supports zero-touch operator API under hardening"):
        print(peer.succeed("${python} ${fixture} exercise http://198.51.100.1:7420", timeout=30))
    with subtest("trusted destination alone is not ingress authority"):
        peer.succeed("ip route add 198.51.100.1/32 via 192.0.2.1 dev eth1")
        peer.succeed("${python} ${fixture} blocked 198.51.100.1 7420")
        peer.succeed("ip route del 198.51.100.1/32 via 192.0.2.1 dev eth1")
    with subtest("native bearer and credential isolation survive operator access"):
        print(operator.succeed("${python} ${fixture} native http://127.0.0.1:7420"))
    with subtest("service restart preserves the enforced ingress boundary"):
        operator.succeed("systemctl restart pi-agent-bus.service")
        operator.wait_for_unit("pi-agent-bus.service", timeout=30)
        peer.succeed("${python} ${fixture} blocked 192.0.2.1 7420")
        print(peer.succeed("${python} ${fixture} exercise http://198.51.100.1:7420", timeout=30))
    operator.succeed("systemctl stop pi-agent-bus.service", timeout=15)
  '';
}).overrideTestDerivation
  (_: {
    allowSubstitutes = false;
    preferLocalBuild = true;
  })
