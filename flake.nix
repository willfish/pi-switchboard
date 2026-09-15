{
  description = "Pi Switchboard: Pi session discovery and small-message hub";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  # Public evaluator fixture, independent of consuming dotfiles/private inputs.
  inputs.home-manager = {
    url = "github:nix-community/home-manager/ec172013fa62135f58fb58dd17ae9651e8f39727";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  # Test-only deployment-equivalent Bun binary, retaining its own nixpkgs graph.
  inputs.pi-fixture.url = "github:numtide/llm-agents.nix/3058fbe106199fd207e0e14f969783d88da4a8e9";

  outputs =
    {
      self,
      nixpkgs,
      pi-fixture,
      home-manager,
    }:
    let
      version = "0.1.0";
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            inherit system;
            pkgs = import nixpkgs { inherit system; };
          }
        );
      extensionSrc = nixpkgs.lib.fileset.toSource {
        root = ./.;
        fileset = nixpkgs.lib.fileset.unions [
          ./package.json
          ./index.ts
          ./extension
          ./docs
          ./README.md
          ./LICENSE
        ];
      };
      extensionTestSrc = nixpkgs.lib.fileset.toSource {
        root = ./.;
        fileset = nixpkgs.lib.fileset.unions [
          ./package.json
          ./package-lock.json
          ./tsconfig.json
          ./index.ts
          ./extension
          (nixpkgs.lib.fileset.fileFilter (file: file.hasExt "ts") ./tests)
          (nixpkgs.lib.fileset.fileFilter (file: file.hasExt "json") ./tests/fixtures)
        ];
      };
      extensionDependencySrc = nixpkgs.lib.fileset.toSource {
        root = ./.;
        fileset = nixpkgs.lib.fileset.unions [
          ./package.json
          ./package-lock.json
        ];
      };
      hubSrc = nixpkgs.lib.fileset.toSource {
        root = ./hub;
        fileset = nixpkgs.lib.fileset.unions [
          ./hub/rebar.config
          ./hub/rebar.lock
          ./hub/src
          ./hub/config
          ./hub/priv
        ];
      };
      hubTestSrc = nixpkgs.lib.fileset.toSource {
        root = ./.;
        fileset = nixpkgs.lib.fileset.unions [
          ./hub/rebar.config
          ./hub/rebar.lock
          ./hub/src
          ./hub/config
          ./hub/priv
          ./hub/test
          (nixpkgs.lib.fileset.fileFilter (file: file.hasExt "json") ./tests/fixtures)
        ];
      };
      dependencyHash = "sha256-mf+AeEOOzZHkRmnB9dS7r+mLzuxsq5wfn1X2wBDkDZs=";
    in
    {
      nixosModules.default = import ./nix/nixos-module.nix { inherit self; };
      homeManagerModules.default = import ./nix/home-manager-module.nix { inherit self; };

      lib.mkPiRuntimeCheck =
        {
          pkgs,
          piPackage,
          hubPackage,
          extensionPackage,
        }:
        import ./nix/pi-runtime-check.nix {
          inherit
            pkgs
            piPackage
            hubPackage
            extensionPackage
            ;
        };

      packages = forAllSystems (
        { pkgs, ... }:
        rec {
          hub = pkgs.callPackage ./nix/hub.nix {
            inherit version dependencyHash;
            src = hubSrc;
          };
          pi-extension = pkgs.callPackage ./nix/extension.nix {
            inherit version;
            src = extensionSrc;
          };
          npm-pack = pkgs.callPackage ./nix/npm-pack.nix {
            inherit version;
            # Pack the whole Git-filtered public checkout, not a prefiltered client.
            src = self.outPath;
          };
          default = hub;
        }
      );

      apps = forAllSystems (
        { system, ... }:
        {
          hub = {
            type = "app";
            program = "${self.packages.${system}.hub}/bin/pi-agent-bus";
          };
          default = self.apps.${system}.hub;
        }
      );

      checks = forAllSystems (
        { system, pkgs }:
        {
          pi-runtime = self.lib.mkPiRuntimeCheck {
            inherit pkgs;
            piPackage = pi-fixture.packages.${system}.pi;
            hubPackage = self.packages.${system}.hub;
            extensionPackage = self.packages.${system}.pi-extension;
          };
          npm-pack = self.packages.${system}.npm-pack;
          npm-runtime = self.lib.mkPiRuntimeCheck {
            inherit pkgs;
            piPackage = pi-fixture.packages.${system}.pi;
            hubPackage = self.packages.${system}.hub;
            extensionPackage = self.packages.${system}.npm-pack.client;
          };
          hub-build = self.packages.${system}.hub;
          extension-build = self.packages.${system}.pi-extension;
          extension-tests = pkgs.callPackage ./nix/client-checks.nix {
            src = extensionTestSrc;
            dependencySrc = extensionDependencySrc;
          };
          dashboard-tests = pkgs.callPackage ./nix/dashboard-checks.nix {
            src = nixpkgs.lib.fileset.toSource {
              root = ./.;
              fileset = nixpkgs.lib.fileset.unions [
                ./hub/priv/dashboard
                ./package.json
                (nixpkgs.lib.fileset.fileFilter (file: file.hasExt "json") ./tests/fixtures)
                (nixpkgs.lib.fileset.fileFilter (
                  file: nixpkgs.lib.hasPrefix "dashboard" file.name && file.hasExt "mjs"
                ) ./tests)
              ];
            };
          };
          integration = self.checks.${system}.hub-boot;
          hub-boot =
            pkgs.runCommand "pi-agent-bus-packaged-boot"
              {
                allowSubstitutes = false;
                preferLocalBuild = true;
                nativeBuildInputs = [ pkgs.nodejs ];
                __darwinAllowLocalNetworking = pkgs.stdenv.hostPlatform.isDarwin;
                PI_AGENT_BUS_TEST_EXECUTABLE = "${self.packages.${system}.hub}/bin/pi-agent-bus";
                PI_AGENT_BUS_TEST_STRACE = pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux "${pkgs.strace}/bin/strace";
              }
              ''
                node --test ${./tests/packaged-hub.test.mjs} ${./tests/packaged-startup.test.mjs}
                touch "$out"
              '';
          hub-tests = pkgs.callPackage ./nix/checks.nix {
            inherit version dependencyHash;
            src = hubTestSrc;
          };
        }
        // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          hardened-service = import ./nix/hardened-service.nix {
            inherit pkgs;
            hubPackage = self.packages.${system}.hub;
            nixosModule = self.nixosModules.default;
          };
          operator-hardened = import ./nix/operator-hardened.nix {
            inherit pkgs;
            hubPackage = self.packages.${system}.hub;
            nixosModule = self.nixosModules.default;
          };
        }
        // import ./nix/module-checks.nix {
          inherit
            self
            nixpkgs
            home-manager
            pkgs
            ;
        }
      );

      devShells = forAllSystems (
        { pkgs, ... }:
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.beamMinimal28Packages.erlang
              pkgs.beamMinimal28Packages.rebar3
              pkgs.coreutils
              pkgs.curl
              pkgs.nixfmt
              pkgs.patch
              pkgs.nodejs
            ];
          };
        }
      );
    };
}
