{
  pkgs,
  src,
  version,
}:
let
  lock = builtins.fromJSON (builtins.readFile (src + "/package-lock.json"));
  compiler = pkgs.typescript;
in
assert compiler.version == lock.packages."node_modules/typescript".version;
pkgs.stdenvNoCC.mkDerivation {
  pname = "pi-switchboard-npm-package";
  inherit src version;
  outputs = [
    "out"
    "client"
  ];
  nativeBuildInputs = [
    pkgs.nodejs
    pkgs.python3
  ];
  allowSubstitutes = false;
  preferLocalBuild = true;
  dontConfigure = true;
  dontFixup = true;
  buildPhase = ''
    runHook preBuild
    for config in .npmrc .npmignore npm-shrinkwrap.json; do
      if [ -e "$config" ] || [ -L "$config" ]; then
        echo "Unexpected repository npm packing configuration" >&2
        exit 1
      fi
    done
    test "$(node -p 'JSON.parse(require("fs").readFileSync("package.json", "utf8")).version')" = "$version"
    export PI_PACKAGE_TYPESCRIPT="${compiler}/lib/node_modules/typescript/lib/typescript.js"
    python3 -I tests/npm-package.test.py
    python3 -I tests/npm-references.test.py
    mkdir -p "$TMPDIR/npm-home" "$TMPDIR/npm-cache" "$TMPDIR/archive"
    : > "$TMPDIR/npm-user-config"
    : > "$TMPDIR/npm-global-config"
    pack() {
      env -i PATH="$PATH" HOME="$TMPDIR/npm-home" TMPDIR="$TMPDIR" \
        NPM_CONFIG_USERCONFIG="$TMPDIR/npm-user-config" \
        NPM_CONFIG_GLOBALCONFIG="$TMPDIR/npm-global-config" \
        NPM_CONFIG_CACHE="$TMPDIR/npm-cache" NPM_CONFIG_UPDATE_NOTIFIER=false \
        npm pack --ignore-scripts --offline --json --pack-destination "$TMPDIR/archive" "$@"
    }
    pack --dry-run > "$TMPDIR/npm-dry-run.json"
    pack > "$TMPDIR/npm-pack-result.json"
    python3 -I scripts/verify-npm-package.py \
      --archives "$TMPDIR/archive" --source . \
      --inventory tests/fixtures/npm-package-files.json --output "$client" \
      --typescript "$PI_PACKAGE_TYPESCRIPT" \
      --dry-run "$TMPDIR/npm-dry-run.json" --pack-result "$TMPDIR/npm-pack-result.json"
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp "$TMPDIR/archive/"*.tgz "$out/"
    runHook postInstall
  '';
}
