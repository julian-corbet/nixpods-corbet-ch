{
  description = "Podman Quadlet as a BUILD-TIME translator, never a boot-time generator -- typed Nix options for digest-pinned containers, pods, networks and volumes, rendered to real systemd units inside the Nix build sandbox and installed via systemd.packages.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: lib.genAttrs systems f;
    in
    {
      # The one NixOS module: `modules/default.nix` imports containers/pods/networks/volumes and
      # does the build-time-generation + systemd.packages wiring. See its own header comment.
      nixosModules.nixpods = ./modules;
      nixosModules.default = self.nixosModules.nixpods;

      # The pure pieces, exposed for inspection or reuse without a NixOS evaluation -- same
      # reasoning as nixvm exposing `lib.mkDomainXML` and nixfs exposing its catalogue.
      lib = {
        render = import ./lib/render.nix { inherit lib; };
        build = import ./lib/build.nix { inherit lib; };
        options = import ./lib/options.nix { inherit lib; };
      };

      checks = forAllSystems (system:
        import ./checks {
          pkgs = nixpkgs.legacyPackages.${system};
          inherit lib system;
          nixpodsModule = self.nixosModules.nixpods;
        }
      );

      # A deliberately-failing demonstration, left OUT of `checks` on purpose: `nix flake check`
      # requires every `checks.<system>.*` derivation to actually build (see `nix flake check
      # --help`), but `packages.<system>.*` need only evaluate as a valid derivation -- nix never
      # attempts to build them as part of the check. That asymmetry is exactly what this needs:
      #
      #     nix build .#demo-malformed-container-fails-build
      #
      # is expected, on purpose, to fail -- see checks/demo-malformed-fails-build.nix's own header
      # for why this is the repo's actual thesis, not a contrived example.
      packages = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          demo-malformed-container-fails-build = import ./checks/demo-malformed-fails-build.nix {
            inherit pkgs lib;
            podman = pkgs.podman;
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
