"""Validate a complete npm archive against a separate reviewed source inventory.

This guards packaging boundaries, not arbitrary secret detection in approved
source. Source review and real packaged-runtime checks remain required.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import re
import zlib

MAX_ENTRIES = 256
MAX_EXPANDED = 16 * 1024 * 1024
MAX_TAR = 20 * 1024 * 1024
MAX_COMPRESSED = 16 * 1024 * 1024
MAX_END_PADDING = 10240
# Pinned npm portable tar/gzip bytes. Format changes require review, not fallback.
GZIP_HEADER = bytes.fromhex("1f8b08000000000002ff")
NPM_MTIME = b"3560116604 \0"  # 499162500 seconds
ALLOWED_ROOTS = {"index.ts", "package.json", "README.md", "LICENSE"}
PACK_FILES = ["index.ts", "extension/", "docs/", "README.md", "LICENSE"]
LIFECYCLES = {"preinstall", "install", "postinstall", "prepare", "prepack", "postpack",
              "prepublish", "prepublishOnly", "publish", "postpublish"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def approved_path(name):
    require(isinstance(name, str) and name and "\\" not in name, "invalid inventory path")
    require(not any(ord(c) < 32 or ord(c) == 127 for c in name), "invalid inventory controls")
    p = PurePosixPath(name)
    require(not p.is_absolute() and all(x not in {"", ".", ".."} for x in name.split("/")),
            "noncanonical inventory path")
    require(name in ALLOWED_ROOTS or (len(p.parts) > 1 and p.parts[0] in {"extension", "docs"}),
            "inventory includes a forbidden tree")
    require(name in ALLOWED_ROOTS or p.suffix in {".ts", ".md"}, "inventory includes a non-source file")
    return p


def parse_json(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "duplicate manifest key")
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=unique)


def source_file(root, name):
    target = root
    for part in approved_path(name).parts:
        target = target / part
        require(not target.is_symlink(), "approved source must not traverse symlinks")
    require(target.is_file(), "approved source file is missing")
    return target.read_bytes()


def read_gzip(archive_path):
    with archive_path.open("rb") as stream:
        packed = stream.read(MAX_COMPRESSED + 1)
    require(len(packed) <= MAX_COMPRESSED, "compressed archive limit exceeded")
    require(packed[:10] == GZIP_HEADER, "unapproved gzip wrapper or metadata")
    decoder = zlib.decompressobj(wbits=31)
    try:
        # zlib verifies the member CRC32 and ISIZE. Never follow unused_data:
        # it may be another member, optional padding or an arbitrary payload.
        raw = decoder.decompress(packed, MAX_TAR + 1)
    except zlib.error as error:
        raise ValueError("invalid gzip member CRC, size or compressed data") from error
    require(len(raw) <= MAX_TAR, "expanded tar limit exceeded")
    require(decoder.eof, "truncated gzip member")
    require(not decoder.unused_data and not decoder.unconsumed_tail,
            "data follows gzip member")
    return raw


def npm_octal(field):
    require(re.fullmatch(rb"[0-7]+ \x00", field) is not None,
            "noncanonical archive numeric field")
    return int(field[:-2], 8)


def physical_files(raw, inventory):
    require(len(raw) <= MAX_TAR, "expanded tar limit exceeded")
    require(len(raw) % 512 == 0, "truncated tar block")
    directories = {"package"}
    for name in inventory:
        directories.update("package/" + str(p) for p in PurePosixPath(name).parents if str(p) != ".")
    files, seen = {}, set()
    expanded = offset = 0
    while True:
        require(offset + 512 <= len(raw), "missing tar end markers")
        header = raw[offset:offset + 512]
        if not any(header):
            require(offset + 1024 <= len(raw) and not any(raw[offset:offset + 1024]),
                    "two zero tar end markers required")
            require(len(raw) - offset - 1024 <= MAX_END_PADDING, "tar end padding limit exceeded")
            require(not any(raw[offset + 1024:]), "data follows tar end marker")
            return files
        # Count physical headers, never logical entries resolved by tarfile.
        require(len(seen) < MAX_ENTRIES, "archive entry limit exceeded")
        checksum = npm_octal(header[148:156])
        require(checksum == sum(header[:148]) + 8 * 32 + sum(header[156:]),
                "invalid archive checksum")
        kind = header[156:157]
        require(kind in {b"0", b"5"}, "archive links and special files are forbidden")
        require(header[257:265] == b"ustar\x0000", "unapproved USTAR format")
        require(not any(header[108:124]) and not any(header[157:257])
                and not any(header[265:329]) and not any(header[345:512]),
                "unapproved archive metadata or header tail")
        require(header[329:345] == (b"000000 \0" * 2), "unapproved archive device fields")
        require(header[136:148] == NPM_MTIME, "unapproved archive mtime")
        mode = npm_octal(header[100:108])
        require(mode == (0o755 if kind == b"5" else 0o644), "unapproved archive mode")
        size = npm_octal(header[124:136])
        require(size <= MAX_EXPANDED, "invalid member size")
        name_bytes, separator, tail = header[:100].partition(b"\0")
        require(separator and not any(tail) and name_bytes
                and all(32 <= c < 127 for c in name_bytes), "invalid archive path or name padding")
        name = name_bytes.decode("ascii")
        if kind == b"5" and name.endswith("/"):
            name = name[:-1]
        parts = name.split("/")
        require("\\" not in name and parts[0] == "package"
                and all(x not in {"", ".", ".."} for x in parts), "archive path escapes package")
        require(name not in seen, "duplicate archive member")
        seen.add(name)
        start = offset + 512
        end = start + size
        aligned_end = end + (-size % 512)
        require(aligned_end <= len(raw), "truncated archive payload or padding")
        require(not any(raw[end:aligned_end]), "nonzero archive member padding")
        if kind == b"5":
            require(size == 0 and name in directories, "unapproved directory or directory payload")
        else:
            relative = "/".join(parts[1:])
            require(relative in inventory, "unapproved archive member")
            expanded += size
            require(expanded <= MAX_EXPANDED, "expanded file limit exceeded")
            files[relative] = raw[start:end]
        offset = aligned_end


def validate(archive_path, source, inventory):
    source = Path(source)
    inventory = list(inventory)
    require(len(inventory) == len(set(inventory)) and len(inventory) <= MAX_ENTRIES, "invalid inventory size/duplicates")
    for name in inventory:
        approved_path(name)
    require(ALLOWED_ROOTS <= set(inventory), "inventory omits package roots")
    archive_path = Path(archive_path)
    require(archive_path.is_file() and not archive_path.is_symlink(), "regular package archive required")
    require(archive_path.stat().st_size <= MAX_COMPRESSED, "compressed archive limit exceeded")
    files = physical_files(read_gzip(archive_path), inventory)
    require(set(files) == set(inventory), "archive inventory mismatch")
    for name, data in files.items():
        expected = source_file(source, name)
        if name == "package.json":
            manifest, original = parse_json(data), parse_json(expected)
            require(manifest == original, "packed manifest semantics differ from source")
            require(manifest.get("name") == "pi-switchboard" and manifest.get("type") == "module", "invalid Pi package identity")
            require(manifest.get("files") == PACK_FILES, "package files declaration changed")
            require(manifest.get("pi") == {"extensions": ["./index.ts"]}, "invalid Pi entry declaration")
            require("pi-package" in manifest.get("keywords", []), "missing Pi package keyword")
            require(not any(manifest.get(k) for k in ["dependencies", "optionalDependencies", "bundledDependencies", "bundleDependencies"]), "runtime dependency bundle forbidden")
            require(not LIFECYCLES.intersection(manifest.get("scripts", {})), "package lifecycle scripts forbidden")
        else:
            require(data == expected, "packed source differs from reviewed source")
        require(b"-----BEGIN PRIVATE KEY-----" not in data and b"-----BEGIN OPENSSH PRIVATE KEY-----" not in data,
                "credential material forbidden")
        require(b"PRIVATE_FIXTURE_" not in data and b"packaged-loopback-fixture-only" not in data,
                "test credential material forbidden")
    return files


def verify_pack_reports(archive, files, dry_run, packed):
    for report_path in [dry_run, packed]:
        require(Path(report_path).stat().st_size <= MAX_ENTRIES * 2048 + 4096, "npm report limit exceeded")
    dry = parse_json(Path(dry_run).read_bytes())
    actual = parse_json(Path(packed).read_bytes())
    require(isinstance(actual, list) and len(actual) == 1 and dry == actual,
            "npm dry-run and actual packing metadata differ")
    report = actual[0]
    require(isinstance(report, dict), "invalid npm report")
    entries = report.get("files", [])
    require(isinstance(entries, list) and len(entries) == len(files), "npm report inventory size differs")
    require(all(isinstance(entry, dict) and isinstance(entry.get("path"), str) for entry in entries), "invalid npm file report")
    names = [entry.get("path") for entry in entries]
    require(len(set(names)) == len(names) and set(names) == set(files), "npm report inventory differs from archive")
    for entry in entries:
        require(entry.get("size") == len(files[entry["path"]]) and entry.get("mode") == 0o644,
                "npm report file metadata differs")
    data = Path(archive).read_bytes()
    digest = "sha512-" + base64.b64encode(hashlib.sha512(data).digest()).decode("ascii")
    require(report.get("integrity") == digest and report.get("shasum") == hashlib.sha1(data).hexdigest(),
            "npm report does not identify the inspected archive")
    require(report.get("size") == len(data) and report.get("unpackedSize") == sum(map(len, files.values()))
            and report.get("entryCount") == len(files) and not report.get("bundled"), "invalid npm archive report")


def extract(files, destination):
    destination = Path(destination)
    require(not destination.exists(), "extraction destination must be new")
    destination.mkdir(parents=True)
    for name, data in files.items():
        target = destination.joinpath(*approved_path(name).parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as output:
            output.write(data)
        target.chmod(0o644)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--archives", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--inventory", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--typescript", required=True)
    parser.add_argument("--dry-run", required=True)
    parser.add_argument("--pack-result", required=True)
    args = parser.parse_args()
    archives = list(Path(args.archives).glob("*.tgz"))
    require(len(archives) == 1, "exactly one npm package archive required")
    inventory = json.loads(Path(args.inventory).read_text())
    files = validate(archives[0], args.source, inventory)
    verify_pack_reports(archives[0], files, args.dry_run, args.pack_result)
    # Complete all reference checks before creating the extraction output.
    spec = importlib.util.spec_from_file_location("package_references", Path(__file__).with_name("check-package-references.py"))
    references = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(references)
    references.check(files, args.typescript)
    extract(files, args.output)
    print("Validated npm source inventory, imports, documentation links and extraction")


if __name__ == "__main__":
    main()
