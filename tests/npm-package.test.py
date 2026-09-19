"""Archive adversarial fixtures. No package scripts, network or credentials."""
import base64
import gzip
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("validator", ROOT / "scripts/verify-npm-package.py")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)
INVENTORY = json.loads((ROOT / "tests/fixtures/npm-package-files.json").read_text())


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="switchboard-archive-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.files = {name: b"export {};\n" if name.endswith(".ts") else ("source " + name + "\n").encode()
                      for name in INVENTORY}
        self.files["index.ts"] = b'export { default } from "./extension/index.ts";\n'
        self.files["README.md"] = b'[Protocol](docs/protocol.md)\n'
        self.manifest = {"name": "pi-switchboard", "version": "0.1.0", "type": "module",
                         "files": validator.PACK_FILES, "keywords": ["pi-package"],
                         "pi": {"extensions": ["./index.ts"]}}
        self.files["package.json"] = json.dumps(self.manifest).encode()
        self.sync()

    def sync(self):
        for name, data in self.files.items():
            target = self.source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)

    @staticmethod
    def checksum(header):
        header = bytearray(header)
        header[148:156] = b" " * 8
        header[148:156] = f"{sum(header):06o} ".encode() + b"\0"
        return bytes(header)

    @classmethod
    def member(cls, info, data=b""):
        # Physical fixture format observed in pinned npm, not tarfile defaults.
        data = data or b""
        header = bytearray(512)
        name = info.name.encode("ascii")
        header[:len(name)] = name
        header[100:108] = f"{info.mode:06o} ".encode() + b"\0"
        header[124:136] = f"{info.size:010o} ".encode() + b"\0"
        header[136:148] = b"3560116604 \0"
        header[156:157] = info.type
        link = info.linkname.encode("ascii")
        header[157:157 + len(link)] = link
        header[257:265] = b"ustar\00000"
        header[329:345] = (b"000000 " + b"\0") * 2
        return cls.checksum(header) + data + b"\0" * (-len(data) % 512)

    @staticmethod
    def gzip_bytes(raw):
        # GzipFile gives a portable OS=255 unlike gzip.compress on Python 3.11.
        buf = io.BytesIO()
        with gzip.GzipFile(fileobj=buf, mode="wb", filename="", mtime=0) as stream:
            stream.write(raw)
        return buf.getvalue()

    def write_raw(self, raw):
        archive = self.root / "package.tgz"
        archive.write_bytes(self.gzip_bytes(raw))
        return archive

    def archive(self, files=None, extras=(), tail=b""):
        raw = b""
        for name, data in (self.files if files is None else files).items():
            info = tarfile.TarInfo("package/" + name)
            info.size = len(data)
            info.mode = 0o644
            raw += self.member(info, data)
        for info, data in extras:
            if info.isdir() and info.mode == 0o644:
                info.mode = 0o755
            raw += self.member(info, data)
        return self.write_raw(raw + b"\0" * 1024 + tail)

    def verify(self, archive):
        return validator.validate(archive, self.source, INVENTORY)

    def test_valid_contents_normalized_manifest_and_safe_extraction(self):
        files = dict(self.files)
        files["package.json"] = json.dumps(self.manifest, indent=2).encode()
        directory = tarfile.TarInfo("package/docs/")
        directory.type = tarfile.DIRTYPE
        checked = self.verify(self.archive(files, [(directory, None)]))
        out = self.root / "client"
        validator.extract(checked, out)
        self.assertEqual((out / "index.ts").read_bytes(), self.files["index.ts"])
        with self.assertRaises(ValueError):
            validator.extract(checked, out)

    def test_inventory_paths_allow_docs_svg_only(self):
        validator.approved_path("docs/diagrams/hero.svg")
        for name in ["hero.svg", "docs/secret.bin", "docs/hero.png", "extension/x.svg"]:
            with self.subTest(name=name), self.assertRaises(ValueError):
                validator.approved_path(name)

    def test_missing_extra_and_unapproved_directory(self):
        files = dict(self.files)
        del files["extension/client.ts"]
        with self.assertRaises(ValueError):
            self.verify(self.archive(files))
        files = dict(self.files, **{"hub/secret": b"not permitted"})
        with self.assertRaises(ValueError):
            self.verify(self.archive(files))
        info = tarfile.TarInfo("package/hub/")
        info.type = tarfile.DIRTYPE
        with self.assertRaises(ValueError):
            self.verify(self.archive(extras=[(info, None)]))

    def test_traversal_absolute_noncanonical_and_control_paths(self):
        for name in ["../escape", "/package/escape", "package/../escape", "package//escape",
                     "package/./escape", "package\\escape", "package/bad\npath"]:
            with self.subTest(name=name):
                info = tarfile.TarInfo(name)
                with self.assertRaises(ValueError):
                    self.verify(self.archive(extras=[(info, b"")]))

    def test_links_special_files_and_privileged_modes(self):
        for kind in [tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.CHRTYPE, tarfile.FIFOTYPE, tarfile.CONTTYPE, tarfile.GNUTYPE_SPARSE]:
            info = tarfile.TarInfo("package/extra")
            info.type = kind
            info.linkname = "../../outside"
            with self.assertRaisesRegex(ValueError, "links and special files"):
                self.verify(self.archive(extras=[(info, None)]))
        info = tarfile.TarInfo("package/extra")
        info.mode = 0o4755
        with self.assertRaises(ValueError):
            self.verify(self.archive(extras=[(info, b"")]))

    def test_duplicate_member_and_hidden_trailing_data(self):
        info = tarfile.TarInfo("package/index.ts")
        with self.assertRaises(ValueError):
            self.verify(self.archive(extras=[(info, b"")]))
        with self.assertRaises(ValueError):
            self.verify(self.archive(tail=b"hidden archive payload"))

    def test_finite_archive_limits(self):
        archive = self.archive()
        for setting in ["MAX_ENTRIES", "MAX_EXPANDED", "MAX_TAR", "MAX_COMPRESSED"]:
            with self.subTest(setting=setting), patch.object(validator, setting, 1):
                with self.assertRaises(ValueError):
                    self.verify(archive)

    def test_source_mismatch_and_duplicate_manifest_keys(self):
        files = dict(self.files, **{"index.ts": b"tampered"})
        with self.assertRaises(ValueError):
            self.verify(self.archive(files))
        files = dict(self.files)
        files["package.json"] = b'{"name":"hidden",' + self.files["package.json"][1:]
        with self.assertRaises(ValueError):
            self.verify(self.archive(files))

    def test_runtime_dependencies_and_lifecycle_scripts(self):
        for key, value in [("dependencies", {"other": "1.0.0"}), ("optionalDependencies", {"other": "1.0.0"}),
                           ("bundleDependencies", ["other"]), ("scripts", {"prepare": "echo unsafe"})]:
            with self.subTest(key=key):
                self.files["package.json"] = json.dumps({**self.manifest, key: value}).encode()
                self.sync()
                with self.assertRaises(ValueError):
                    self.verify(self.archive())

    def test_known_credential_material(self):
        # Syntax-aware link/import rejection has its own reference-check suite.
        for name, data in [("index.ts", b"PRIVATE_FIXTURE_do_not_publish")]:
            with self.subTest(name=name, data=data):
                original = self.files[name]
                self.files[name] = data
                self.sync()
                with self.assertRaises(ValueError):
                    self.verify(self.archive())
                self.files[name] = original
                self.sync()

    def test_hidden_extension_headers_are_rejected(self):
        raw = gzip.decompress(self.archive().read_bytes())
        for kind in [b"x", b"g", b"L", b"K", b"S", b"X"]:
            info = tarfile.TarInfo("package/index.ts")
            info.type = kind
            data = b"25 comment=hidden-secret\n" if kind in {b"x", b"g", b"X"} else b"package/index.ts\0"
            info.size = len(data)
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                self.verify(self.write_raw(self.member(info, data) + raw))

    def test_tarfile_hides_valid_pax_global_and_gnu_records(self):
        raw = gzip.decompress(self.archive().read_bytes())
        for kind, payload in [(b"x", b"25 comment=hidden-secret\n"),
                              (b"g", b"25 comment=hidden-secret\n"),
                              (b"L", b"package/LICENSE\0")]:
            # Compute valid PAX record lengths, so extraction really is unchanged.
            if kind in {b"x", b"g"}:
                body = b"comment=hidden-secret\n"
                length = len(body) + 3
                payload = str(length).encode() + b" " + body
                self.assertEqual(len(payload), length)
            info = tarfile.TarInfo("package/metadata")
            info.type = kind
            info.size = len(payload)
            hidden = self.member(info, payload) + raw
            with tarfile.open(fileobj=io.BytesIO(hidden), mode="r:") as archive:
                logical = {entry.name.removeprefix("package/"): archive.extractfile(entry).read()
                           for entry in archive}
            self.assertEqual(logical, self.files)
            with self.subTest(kind=kind), self.assertRaisesRegex(ValueError, "special files"):
                self.verify(self.write_raw(hidden))

    def test_strict_header_metadata_numeric_fields_and_checksum(self):
        raw = gzip.decompress(self.archive().read_bytes())
        mutations = [(30, b"hidden"), (99, b"x"), (100, b"000755 \0"),
                     (108, b"000000 \0"), (116, b"000001 \0"),
                     (124, b"00000000001\0"), (124, b"-000000001 \0"),
                     (124, b"8000000000 \0"), (124, b"\x80" + b"\0" * 11),
                     (136, b"0000000000 \0"), (157, b"hidden"),
                     (257, b"ustar  \0"), (263, b"01"), (265, b"user"),
                     (297, b"group"), (329, b"000001 \0"), (337, b"000001 \0"),
                     (345, b"prefix"), (500, b"hidden"), (511, b"x"), (156, b"\0"),
                     (0, b"\xff"), (0, b"a" * 100)]
        for offset, value in mutations:
            h = bytearray(raw[:512])
            h[offset:offset + len(value)] = value
            with self.subTest(offset=offset, value=value), self.assertRaises(ValueError):
                self.verify(self.write_raw(self.checksum(h) + raw[512:]))
        for value in [b"000000 \0", raw[148:154] + b"\0 ", b"        "]:
            with self.subTest(checksum=value), self.assertRaises(ValueError):
                self.verify(self.write_raw(raw[:148] + value + raw[156:]))

    def test_payload_padding_bounds_and_end_markers(self):
        raw = gzip.decompress(self.archive().read_bytes())
        size = len(next(iter(self.files.values())))
        for damaged in [raw[:512 + size] + b"x" + raw[513 + size:],
                        raw[:-1024], raw[:-512], raw[:-1], raw + b"\0",
                        raw[:-512] + b"x" + raw[-511:], raw + b"x" * 512,
                        raw[:511], raw[:512 + size - 1]]:
            with self.subTest(length=len(damaged)), self.assertRaises(ValueError):
                self.verify(self.write_raw(damaged))
        h = bytearray(raw[:512])
        h[124:136] = b"7777777777 \0"
        with self.assertRaisesRegex(ValueError, "member size"):
            self.verify(self.write_raw(self.checksum(h) + raw[512:]))
        h[124:136] = f"{len(raw):010o} ".encode() + b"\0"
        with self.assertRaisesRegex(ValueError, "payload"):
            self.verify(self.write_raw(self.checksum(h) + raw[512:]))

    def test_gzip_wrapper_metadata_members_crc_size_and_truncation(self):
        archive = self.archive()
        packed = archive.read_bytes()
        variants = [packed + self.gzip_bytes(b""), packed + b"hidden", packed + b"\0",
                    packed[:-1], packed[:-8], packed[:9]]
        # Structurally valid optional metadata fields, not just invalid flags.
        for flag, field in [(4, b"\x06\0secret"), (8, b"secret\0"), (16, b"secret\0")]:
            variants.append(packed[:3] + bytes([flag]) + packed[4:10] + field + packed[10:])
        for offset in [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, len(packed)-8, len(packed)-4]:
            altered = bytearray(packed)
            altered[offset] ^= 1
            variants.append(bytes(altered))
        for variant in variants:
            with self.subTest(length=len(variant)), self.assertRaises(ValueError):
                archive.write_bytes(variant)
                self.verify(archive)

    def test_exact_and_one_over_limits_include_directories_and_cumulative_bytes(self):
        directory = tarfile.TarInfo("package/docs/")
        directory.type = tarfile.DIRTYPE
        archive = self.archive(extras=[(directory, None)])
        raw = gzip.decompress(archive.read_bytes())
        limits = {"MAX_ENTRIES": len(self.files) + 1,
                  "MAX_EXPANDED": sum(map(len, self.files.values())),
                  "MAX_TAR": len(raw), "MAX_COMPRESSED": archive.stat().st_size}
        for setting, exact in limits.items():
            with self.subTest(setting=setting), patch.object(validator, setting, exact):
                self.verify(archive)
            with self.subTest(setting=setting), patch.object(validator, setting, exact - 1):
                with self.assertRaises(ValueError):
                    self.verify(archive)
        with patch.object(validator, "MAX_EXPANDED", max(map(len, self.files.values()))):
            with self.assertRaisesRegex(ValueError, "expanded file limit"):
                self.verify(archive)
        # Repeated empty physical headers cannot disappear into logical iteration.
        info = tarfile.TarInfo("package/docs/")
        info.type = tarfile.DIRTYPE
        with self.assertRaises(ValueError):
            self.verify(self.archive(extras=[(info, None)] * (validator.MAX_ENTRIES + 1)))

    def test_single_member_expanded_boundary_and_payload_that_looks_like_header(self):
        data = b"\0" * 512 + b"ustar\0" + b"x" * 511
        info = tarfile.TarInfo("package/LICENSE")
        info.size = len(data)
        raw = self.member(info, data) + b"\0" * 1024
        with patch.object(validator, "MAX_EXPANDED", len(data)):
            self.assertEqual(validator.physical_files(raw, ["LICENSE"]), {"LICENSE": data})
        with patch.object(validator, "MAX_EXPANDED", len(data) - 1):
            with self.assertRaisesRegex(ValueError, "member size"):
                validator.physical_files(raw, ["LICENSE"])

    def test_bounded_zero_post_end_padding(self):
        self.verify(self.archive(tail=b"\0" * validator.MAX_END_PADDING))
        for extra in [1, 512]:
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                self.verify(self.archive(tail=b"\0" * (validator.MAX_END_PADDING + extra)))

    def test_directory_payload_and_mode(self):
        directory = tarfile.TarInfo("package/docs/")
        directory.type = tarfile.DIRTYPE
        directory.size = 1
        with self.assertRaises(ValueError):
            self.verify(self.archive(extras=[(directory, b"x")]))
        directory.size = 0
        directory.mode = 0o777
        with self.assertRaises(ValueError):
            self.verify(self.archive(extras=[(directory, None)]))

    def test_source_parent_symlink_is_not_followed(self):
        archive = self.archive()
        original = self.source / "extension"
        moved = self.root / "outside"
        original.rename(moved)
        original.symlink_to(moved, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlinks"):
            self.verify(archive)

    def test_dry_run_actual_report_and_inspected_archive_must_agree(self):
        archive = self.archive()
        data = archive.read_bytes()
        report = {"files": [{"path": name, "size": len(body), "mode": 0o644}
                            for name, body in self.files.items()],
                  "integrity": "sha512-" + base64.b64encode(hashlib.sha512(data).digest()).decode(),
                  "shasum": hashlib.sha1(data).hexdigest(), "size": len(data),
                  "unpackedSize": sum(map(len, self.files.values())),
                  "entryCount": len(self.files), "bundled": []}
        dry, actual = self.root / "dry.json", self.root / "actual.json"
        dry.write_text(json.dumps([report])); actual.write_text(json.dumps([report]))
        validator.verify_pack_reports(archive, self.files, dry, actual)
        wrong_mode = json.loads(json.dumps(report))
        wrong_mode["files"][0]["mode"] = 0o755
        dry.write_text(json.dumps([wrong_mode])); actual.write_text(json.dumps([wrong_mode]))
        with self.assertRaises(ValueError):
            validator.verify_pack_reports(archive, self.files, dry, actual)
        for field in ["integrity", "size", "entryCount", "files"]:
            bad = dict(report, **{field: [] if field == "files" else "wrong"})
            for both in [False, True]:
                dry.write_text(json.dumps([bad if both else report]))
                actual.write_text(json.dumps([bad]))
                with self.subTest(field=field, both=both), self.assertRaises(ValueError):
                    validator.verify_pack_reports(archive, self.files, dry, actual)

    def test_source_symlink_is_not_followed(self):
        archive = self.archive()
        original = self.source / "index.ts"
        original.unlink()
        original.symlink_to(self.root / "outside")
        with self.assertRaises(ValueError):
            self.verify(archive)


if __name__ == "__main__":
    unittest.main()
