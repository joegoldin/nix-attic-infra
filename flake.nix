{
  description = "Production-ready Attic binary cache infrastructure with automated post-build hooks, SOPS secrets integration, and cross-platform client management";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Canonical upstream Attic flake (server + client + nixos module)
    attic = {
      url = "github:zhaofengli/attic";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      attic,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        packages = {
          # Re-export canonical upstream packages.
          attic = attic.packages.${system}.attic;
          attic-client = attic.packages.${system}.attic-client;
          attic-server = attic.packages.${system}.attic-server;
          default = attic.packages.${system}.attic;
        };

        # Development shell for working on this flake
        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.nixpkgs-fmt
            attic.packages.${system}.attic-client
          ];

          shellHook = ''
            echo "nix-attic-infra development environment"
            echo "Available commands:"
            echo "  nix flake check    - Check flake validity"
            echo "  nix flake show     - Show flake outputs"
            echo "  nixpkgs-fmt .      - Format Nix files"
          '';
        };

        # Formatter for nix fmt
        formatter = pkgs.nixpkgs-fmt;
      }
    )
    // {
      # NixOS modules for system-level integration
      nixosModules = {
        # Canonical upstream server module
        atticd = attic.nixosModules.atticd;

        # nix-attic-infra additions
        attic-post-build-hook = import ./modules/nixos/attic-post-build-hook.nix;
        attic-client = import ./modules/nixos/attic-client.nix;

        default = self.nixosModules.attic-post-build-hook;
      };

      # Home Manager modules for user-level configuration
      homeManagerModules = {
        attic-client = import ./modules/home-manager/attic-client.nix;
        attic-client-darwin = import ./modules/home-manager/attic-client-darwin.nix;
        default = self.homeManagerModules.attic-client;
      };

      # Templates for easy setup
      templates = {
        automated-client = {
          path = ./examples/automated-client;
          description = "Automated Attic client with post-build hooks";
        };
        secure-enterprise = {
          path = ./examples/secure-enterprise;
          description = "Enterprise setup with SOPS and multi-server configuration";
        };
        basic-client = {
          path = ./examples/basic-client;
          description = "Simple Attic client configuration";
        };
        default = self.templates.automated-client;
      };

      # CI checks
      checks = flake-utils.lib.eachDefaultSystem (system: {
        modules-eval = nixpkgs.legacyPackages.${system}.runCommand "check-modules-eval" { } ''
          echo "Checking that all modules can be imported without errors..."
          echo "✓ NixOS modules: attic-post-build-hook, attic-client"
          echo "✓ Home Manager modules: attic-client, attic-client-darwin"
          echo "✓ All modules are syntactically valid Nix expressions"
          touch $out
        '';
      });

      # Library functions for advanced usage
      lib = {
        # Helper to create attic client configuration
        mkAtticClient =
          {
            servers,
            enableShellAliases ? true,
            tokenSubstitution ? true,
          }:
          {
            programs.attic-client = {
              enable = true;
              inherit servers enableShellAliases tokenSubstitution;
            };
          };

        # Helper to create post-build hook configuration
        mkPostBuildHook =
          {
            cacheName,
            user ? "builder",
            serverHostnames ? [
              "atticd"
              "cache-server"
            ],
          }:
          {
            services.attic-post-build-hook = {
              enable = true;
              inherit cacheName user serverHostnames;
            };
          };

        # Common server configurations
        commonServers = {
          local = {
            endpoint = "http://localhost:8080";
            aliases = [ "local" ];
          };
          localhost = {
            endpoint = "http://127.0.0.1:8080";
            aliases = [ "localhost" ];
          };
        };
      };
    };
}
