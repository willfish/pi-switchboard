{
  pkgs,
  src,
  dependencySrc,
}:
let
  # Pi's shrinkwrap omits five internal-package integrities. When regenerating
  # the root lock, restore those exact registry digests before updating this hash.
  npmDeps =
    (pkgs.fetchNpmDeps {
      name = "pi-switchboard-client-npm-deps";
      src = dependencySrc;
      hash = "sha256-tCWk6aumjryCsxCltR/xExdThLjE2R/yl0Aj/jbrhvE=";
      npmRegistryOverridesString = "{}";
    }).overrideAttrs
      (_: {
        impureEnvVars = [ ];
      });
in
pkgs.runCommand "pi-switchboard-extension-tests"
  {
    allowSubstitutes = false;
    preferLocalBuild = true;
    nativeBuildInputs = [
      pkgs.nodejs
      pkgs.coreutils
    ];
  }
  ''
    cp -R ${src} source
    chmod -R u+w source
    cd source
    mkdir -p "$TMPDIR/home"
    cp -R ${npmDeps} "$TMPDIR/npm-cache"
    chmod -R u+w "$TMPDIR/npm-cache"
    printf 'ignore-scripts=true\nregistry=https://registry.npmjs.org/\n' > "$TMPDIR/npmrc"
    touch "$TMPDIR/globalnpmrc"
    # npm and test processes receive no inherited authentication or user config.
    export HOME="$TMPDIR/home"
    export NPM_CONFIG_USERCONFIG="$TMPDIR/npmrc"
    export NPM_CONFIG_GLOBALCONFIG="$TMPDIR/globalnpmrc"
    export NPM_CONFIG_CACHE="$TMPDIR/npm-cache"
    export NPM_CONFIG_IGNORE_SCRIPTS=true
    export NPM_CONFIG_OFFLINE=true
    env -i PATH="$PATH" HOME="$HOME" \
      NPM_CONFIG_USERCONFIG="$NPM_CONFIG_USERCONFIG" \
      NPM_CONFIG_GLOBALCONFIG="$NPM_CONFIG_GLOBALCONFIG" \
      NPM_CONFIG_CACHE="$NPM_CONFIG_CACHE" \
      npm ci --offline --ignore-scripts --no-audit --no-fund
    env -i PATH="$PATH" HOME="$HOME" \
      node node_modules/typescript/bin/tsc --project tsconfig.json
    # Compile the real SDK, including a negative assertion against an invented API.
    cat > sdk-contract.mts <<'TS'
    import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
    import type { Api, Model } from "@earendil-works/pi-ai";
    import type { Component } from "@earendil-works/pi-tui";
    import { Type } from "typebox";
    declare const pi: ExtensionAPI;
    declare const model: Model<Api>;
    const provider: string = model.provider;
    const schema = Type.Object({ label: Type.String() });
    pi.on("session_start", (_event, ctx) => {
      const mode: "tui" | "rpc" | "json" | "print" = ctx.mode;
    });
    // @ts-expect-error Pi has no session_switch event.
    pi.on("session_switch", () => {});
    const component: Component = { render: () => [], invalidate: () => {} };
    TS
    env -i PATH="$PATH" HOME="$HOME" \
      node node_modules/typescript/bin/tsc --strict --noEmit --skipLibCheck \
        --target ES2023 --module NodeNext --moduleResolution NodeNext --types node sdk-contract.mts
    # Actual-binary integration is an explicit test:pi-runtime target, not a unit test.
    env -i PATH="$PATH" HOME="$HOME" \
      NPM_CONFIG_USERCONFIG="$NPM_CONFIG_USERCONFIG" \
      NPM_CONFIG_GLOBALCONFIG="$NPM_CONFIG_GLOBALCONFIG" \
      NPM_CONFIG_CACHE="$NPM_CONFIG_CACHE" \
      NPM_CONFIG_IGNORE_SCRIPTS=true NPM_CONFIG_OFFLINE=true \
      timeout 60s npm test
    touch "$out"
  ''
