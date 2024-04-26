{
  description = "DDN Engine";

  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs;
    flake-utils.url = github:numtide/flake-utils;

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
  };

  outputs = { self, nixpkgs, flake-utils, crane, rust-overlay }:
    flake-utils.lib.eachDefaultSystem
      (localSystem:
        let
          pkgs = import nixpkgs {
            system = localSystem;
            overlays = [ rust-overlay.overlays.default ];
          };

          rust = import ./nix/rust.nix {
            inherit nixpkgs rust-overlay crane localSystem;
          };

          rust-x86_64-linux = (import ./nix/rust.nix {
            inherit nixpkgs rust-overlay crane localSystem;
            crossSystem = "x86_64-linux";
          });

          rust-aarch64-linux = (import ./nix/rust.nix {
            inherit nixpkgs rust-overlay crane localSystem;
            crossSystem = "aarch64-linux";
          });
        in
        {
          formatter = pkgs.nixpkgs-fmt;

          packages = {

            ###### CUSTOM_CONNECTOR

            # custom-connector binary for whichever is the local machine
            custom-connector = rust.callPackage ./nix/app.nix {
              version = if self ? "dirtyRev" then self.dirtyShortRev else self.shortRev;
              pname = "custom-connector";
            };

            # custom-connector binary for x86_64-linux
            custom-connector-x86_64-linux = rust-x86_64-linux.callPackage ./nix/app.nix
              {
                version = if self ? "dirtyRev" then self.dirtyShortRev else self.shortRev;
                pname = "custom-connector";
              };

            # custom-connector binary for x86_64-linux
            custom-connector-aarch64-linux = rust-aarch64-linux.callPackage ./nix/app.nix
              {
                version = if self ? "dirtyRev" then self.dirtyShortRev else self.shortRev;
                pname = "custom-connector";
              };

            # custom-connector docker files for whichever is the local machine
            custom-connector-docker = pkgs.callPackage ./nix/docker.nix {
              package = self.packages.${localSystem}.custom-connector;
              image-name = "ghcr.io/hasura/v3-custom-connector";
              tag = "dev";
              port = "8181";
            };

            # custom-connector docker for x86_64-linux
            custom-connector-docker-x86_64-linux = pkgs.callPackage ./nix/docker.nix {
              package = self.packages.${localSystem}.custom-connector-x86_64-linux;
              architecture = "amd64";
              image-name = "ghcr.io/hasura/v3-custom-connector";
              port = "8181";
            };

            # custom-connector docker for aarch64-linux
            custom-connector-docker-aarch64-linux = pkgs.callPackage ./nix/docker.nix {
              package = self.packages.${localSystem}.custom-connector-aarch64-linux;
              architecture = "arm64";
              image-name = "ghcr.io/hasura/v3-custom-connector";
              port = "8181";
            };


            ###### ENGINE

            # engine binary for whichever is the local machine
            engine = rust.callPackage ./nix/app.nix {
              version = if self ? "dirtyRev" then self.dirtyShortRev else self.shortRev;
              pname = "engine";
            };

            # engine binary for x86_64-linux
            engine-x86_64-linux = rust-x86_64-linux.callPackage ./nix/app.nix
              {
                version = if self ? "dirtyRev" then self.dirtyShortRev else self.shortRev;
                pname = "engine";
              };

            # engine binary for x86_64-linux
            engine-aarch64-linux = rust-aarch64-linux.callPackage ./nix/app.nix
              {
                version = if self ? "dirtyRev" then self.dirtyShortRev else self.shortRev;
                pname = "engine";
              };

            # engine docker files for whichever is the local machine
            engine-docker = pkgs.callPackage ./nix/docker.nix {
              package = self.packages.${localSystem}.engine;
              image-name = "ghcr.io/hasura/v3-engine";
              tag = "dev";
              port = "3000";
            };

            # engine docker for x86_64-linux
            engine-docker-x86_64-linux = pkgs.callPackage ./nix/docker.nix {
              package = self.packages.${localSystem}.engine-x86_64-linux;
              architecture = "amd64";
              image-name = "ghcr.io/hasura/v3-engine";
              port = "3000";
            };

            # engine docker for aarch64-linux
            engine-docker-aarch64-linux = pkgs.callPackage ./nix/docker.nix {
              package = self.packages.${localSystem}.engine-aarch64-linux;
              architecture = "arm64";
              image-name = "ghcr.io/hasura/v3-engine";
              port = "3000";
            };

            default = self.packages.${localSystem}.engine;

          };

          apps = {
            default = self.apps.${localSystem}.engine;
            engine = flake-utils.lib.mkApp {
              drv = self.packages.${localSystem}.engine;
              name = "engine";
            };
            custom-connector = flake-utils.lib.mkApp {
              drv = self.packages.${localSystem}.custom-connector;
              name = "custom-connector";
            };
          };

          devShells = {
            default = pkgs.mkShell {
              # include dependencies of the default package
              inputsFrom = [ self.packages.${localSystem}.default ];

              # build-time inputs
              nativeBuildInputs = [
                # Development
                pkgs.just
                pkgs.nixpkgs-fmt

                # Rust
                pkgs.cargo-edit
                pkgs.cargo-expand
                pkgs.cargo-flamegraph
                pkgs.cargo-insta
                pkgs.cargo-machete
                pkgs.cargo-nextest
                pkgs.cargo-watch
                rust.rustToolchain
              ];
            };
          };
        });
}
