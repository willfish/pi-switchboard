"""Offline CI control-flow fixtures, not native-runner or installer acceptance."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
BASH = shutil.which("bash")
CUT = shutil.which("cut")
HASH = "9adda97297d9e8ab360df95c729eabff4f4f93d6db091953c3a68f29e3fb130c"


class CiScripts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="switchboard-ci-")
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.bin = self.path / "bin"
        self.bin.mkdir()
        self.env = {"PATH": str(self.bin), "HOME": str(self.path),
                    "RUNNER_TEMP": str(self.path), "GITHUB_OUTPUT": str(self.path / "output"),
                    "GITHUB_ENV": str(self.path / "environment"), "EXPECTED_SYSTEM": "aarch64-darwin"}
        (self.bin / "cut").symlink_to(CUT)

    def executable(self, name, body):
        file = self.bin / name
        file.write_text("#!/bin/sh\nset -eu\n" + body + "\n")
        file.chmod(0o700)

    def run_script(self, name):
        return subprocess.run([BASH, str(ROOT / name)], env=self.env,
                              text=True, capture_output=True, timeout=5)

    def bootstrap(self, digest=HASH):
        self.executable("curl", 'printf called > "$RUNNER_TEMP/downloaded"\n'
                        'while [ "$1" != -o ]; do shift; done\nshift\nprintf fixture > "$1"')
        self.executable("shasum", f"printf '{digest}  fixture\\n'")

    def native(self, version="2.35.2", arch="arm64", translated="0", system="aarch64-darwin"):
        self.executable("nix", f'if [ "$1" = --version ]; then printf "nix (Nix) {version}\\n"; '
                        f'else printf "{system}"; fi')
        self.executable("uname", f'if [ "$1" = -s ]; then printf Darwin; else printf {arch}; fi')
        self.executable("sysctl", f"printf {translated}")

    def linux(self, probe_status=0, system="x86_64-linux", sudo_status=0, restart_status=0):
        self.native(arch="x86_64", system=system)
        self.env["EXPECTED_SYSTEM"] = "x86_64-linux"
        self.executable("uname", 'if [ "$1" = -s ]; then printf Linux; else printf x86_64; fi')
        # Model device availability independently of the machine running these fixtures.
        startup = self.path / "bash-env"
        startup.write_text('test() { if [[ "$1" = -c && "$2" = /dev/kvm ]]; then return 0; fi; builtin test "$@"; }\n')
        self.env["BASH_ENV"] = str(startup)
        self.executable("python3", 'printf "host-probe\\n" >> "$RUNNER_TEMP/order"\n'
                        f'exit {probe_status}')
        self.executable("sudo", 'printf "%s\\n" "$*" >> "$RUNNER_TEMP/order"\n'
                        f'[ {sudo_status} = 0 ] || exit {sudo_status}\n'
                        f'if [ "$1" = systemctl ]; then exit {restart_status}; fi\n'
                        'if [ "$1" = tee ]; then while IFS= read -r line; do '
                        'printf "%s\\n" "$line" >> "$RUNNER_TEMP/daemon-config"; done; fi')

    def test_linux_advertises_daemon_kvm_only_after_host_proof(self):
        self.linux()
        result = self.run_script("native-preflight.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.path / "order").read_text().splitlines(),
                         ["host-probe", "tee -a /etc/nix/nix.conf", "systemctl restart nix-daemon.service"])
        self.assertEqual((self.path / "daemon-config").read_text(), "extra-system-features = kvm\n")
        self.assertEqual((self.path / "environment").read_text(),
                         "NIX_SYSTEM_FEATURES=nixos-test benchmark big-parallel kvm\n")

    def test_failed_linux_proof_never_changes_daemon_or_exports_features(self):
        for options in [{"probe_status": 1}, {"system": "aarch64-darwin"}]:
            with self.subTest(options=options):
                (self.path / "order").unlink(missing_ok=True)
                self.linux(**options)
                self.assertNotEqual(self.run_script("native-preflight.sh").returncode, 0)
                self.assertEqual((self.path / "order").read_text(), "host-probe\n")
                self.assertFalse((self.path / "environment").exists())
                self.assertFalse((self.path / "daemon-config").exists())

    def test_linux_daemon_configuration_failure_stops_preflight(self):
        self.linux(sudo_status=1)
        self.assertNotEqual(self.run_script("native-preflight.sh").returncode, 0)
        self.assertFalse((self.path / "environment").exists())

    def test_linux_daemon_restart_failure_stops_preflight(self):
        self.linux(restart_status=1)
        self.assertNotEqual(self.run_script("native-preflight.sh").returncode, 0)
        self.assertFalse((self.path / "environment").exists())

    def test_existing_nix_stops_before_download(self):
        self.bootstrap()
        self.executable("nix", "exit 0")
        result = self.run_script("prepare-nix.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unexpected preinstalled Nix", result.stderr)
        self.assertFalse((self.path / "downloaded").exists())
        self.assertFalse((self.path / "output").exists())

    def test_matching_digest_emits_local_installer_url(self):
        self.bootstrap()
        self.assertEqual(self.run_script("prepare-nix.sh").returncode, 0)
        self.assertEqual((self.path / "output").read_text(), f"url=file://{self.path}/nix-installer\n")

    def test_wrong_digest_never_emits_installer_url(self):
        self.bootstrap("0" * 64)
        self.assertNotEqual(self.run_script("prepare-nix.sh").returncode, 0)
        self.assertFalse((self.path / "output").exists())

    def test_native_preflight_checks_version_architecture_and_translation(self):
        self.native()
        self.assertEqual(self.run_script("native-preflight.sh").returncode, 0)
        self.assertEqual((self.path / "environment").read_text(),
                         "NIX_SYSTEM_FEATURES=nixos-test benchmark big-parallel\n")
        for options in [{"version": "2.35.1"}, {"arch": "x86_64"}, {"translated": "1"}, {"system": "x86_64-linux"}]:
            with self.subTest(options=options):
                (self.path / "environment").unlink(missing_ok=True)
                self.native(**options)
                self.assertNotEqual(self.run_script("native-preflight.sh").returncode, 0)
                self.assertFalse((self.path / "environment").exists())


if __name__ == "__main__":
    unittest.main()
