let
  flake = builtins.getFlake (toString ../..);
  pkgs = flake.inputs.nixpkgs.legacyPackages.x86_64-linux;
in
pkgs.runCommand "pi-switchboard-kvm-sandbox-probe"
  {
    requiredSystemFeatures = [ "kvm" ];
    allowSubstitutes = false;
    preferLocalBuild = true;
  }
  ''
    ${pkgs.python3}/bin/python3 -I - <<'PY'
    import fcntl
    import os
    fd = os.open('/dev/kvm', os.O_RDWR | os.O_CLOEXEC)
    try:
        if fcntl.ioctl(fd, 0xAE00, 0) != 12:
            raise SystemExit('KVM is unavailable inside the Nix build sandbox')
    finally:
        os.close(fd)
    PY
    touch "$out"
  ''
