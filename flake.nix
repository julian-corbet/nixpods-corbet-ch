{
  description = "Podman Quadlet as a BUILD-TIME translator, never a boot-time generator -- typed Nix options for digest-pinned containers, pods, networks and volumes, rendered to real systemd units inside the Nix build sandbox and installed via systemd.packages.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # Used ONLY by `checks` -- `systemManagerModules.nixpods` itself takes no input from here, the
  # same way `nixosModules.nixpods` does not depend on this flake's nixpkgs. It is here because
  # the claim "one declaration renders on both planes" is worth nothing unevaluated: without it,
  # `nix flake check` would prove the NixOS half and take the other half on faith. Same reason
  # (and same shape) as nixram's own system-manager eval tests.
  inputs.system-manager.url = "github:numtide/system-manager";
  inputs.system-manager.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, system-manager }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: lib.genAttrs systems f;
    in
    {
      # TWO PLANES, ONE DECLARATION. `modules/nixpods.nix` holds the option surface and all of
      # the wiring that is true on both (render -> run the real generator at build time ->
      # install through `systemd.packages` -> drop-in for `wantedBy`); each module below is the
      # thin backend for one plane, and each one's own header says exactly what it adds and why
      # that part could not be shared. A container is declared the same way on either.
      nixosModules.nixpods = ./modules/nixos.nix;
      nixosModules.default = self.nixosModules.nixpods;

      systemManagerModules.nixpods = ./modules/system-manager.nix;
      systemManagerModules.default = self.systemManagerModules.nixpods;

      # The pure pieces, exposed for inspection or reuse without a NixOS evaluation -- same
      # reasoning as nixvm exposing `lib.mkDomainXML` and nixfs exposing its catalogue.
      lib = {
        render = import ./lib/render.nix { inherit lib; };
        build = import ./lib/build.nix { inherit lib; };
        options = import ./lib/options.nix { inherit lib; };
      };

      checks = forAllSystems (system:
        import ./checks
          {
            pkgs = nixpkgs.legacyPackages.${system};
            inherit lib system;
            nixpodsModule = self.nixosModules.nixpods;
          }
        // {
          system-manager-eval-tests = import ./checks/system-manager-eval-tests.nix {
            pkgs = nixpkgs.legacyPackages.${system};
            systemManagerModule = self.systemManagerModules.nixpods;
            systemManagerLib = system-manager.lib;
          };
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
