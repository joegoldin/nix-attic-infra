# NixOS module for Attic post-build hook automation
#
# This module provides zero-touch binary cache population by automatically
# pushing build outputs to your Attic cache after successful builds.
#
# IMPORTANT: Do NOT enable this on the host running atticd to avoid circular dependencies!
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.attic-post-build-hook;

  tokenFilePath = if cfg.tokenFile == null then "" else toString cfg.tokenFile;

  postBuildScript = pkgs.writeShellScript "attic-post-build-hook" ''
    set -u
    set -f # disable globbing
    export IFS=' '

    # Never fail the build due to cache issues.
    if [ -z "''${OUT_PATHS:-}" ]; then
      exit 0
    fi

    echo "Attic post-build hook triggered" >&2
    echo "  DRV_PATH: ''${DRV_PATH:-}" >&2
    echo "  OUT_PATHS: ''${OUT_PATHS}" >&2

    # Skip source/temporary derivations.
    if [[ "''${DRV_PATH:-}" == *"-source.drv" ]] || [[ "''${DRV_PATH:-}" == *"tmp"* ]]; then
      echo "Skipping source/temporary derivation: ''${DRV_PATH:-}" >&2
      exit 0
    fi

    token_file="${tokenFilePath}"
    if [ -z "$token_file" ] || [ ! -f "$token_file" ]; then
      echo "Attic: token file missing; skipping push" >&2
      exit 0
    fi

    token="$(${pkgs.coreutils}/bin/cat "$token_file" 2>/dev/null || true)"
    if [ -z "$token" ]; then
      echo "Attic: token empty; skipping push" >&2
      exit 0
    fi

    # Generate ephemeral config (never store token in Nix store).
    tmpdir="$(${pkgs.coreutils}/bin/mktemp -d)"
    trap '${pkgs.coreutils}/bin/rm -rf "$tmpdir"' EXIT

    export XDG_CONFIG_HOME="$tmpdir"
    ${pkgs.coreutils}/bin/mkdir -p "$XDG_CONFIG_HOME/attic"

    ${pkgs.coreutils}/bin/cat > "$XDG_CONFIG_HOME/attic/config.toml" <<EOF
    [servers.${cfg.serverName}]
    endpoint = "${cfg.serverEndpoint}"
    token = "$token"
    EOF

    echo "Attic: pushing to ${cfg.serverName}:${cfg.cacheName} (${cfg.serverEndpoint})" >&2

    for path in ''${OUT_PATHS}; do
      ${pkgs.attic-client}/bin/attic push "${cfg.serverName}:${cfg.cacheName}" "$path" 2>&1 || true
    done

    exit 0
  '';
in
{
  options.services.attic-post-build-hook = {
    enable = lib.mkEnableOption "Attic post-build hook for automatic cache uploads";

    serverName = lib.mkOption {
      type = lib.types.str;
      default = "cache-build-server";
      description = ''
        Name of the server in the generated Attic config (used as the prefix for
        pushes like `serverName:cacheName`).
      '';
      example = "attic";
    };

    serverEndpoint = lib.mkOption {
      type = lib.types.str;
      default = "http://cache-build-server:5001";
      description = "Attic server base URL.";
      example = "https://cache.example.com";
    };

    cacheName = lib.mkOption {
      type = lib.types.str;
      default = "cache-local";
      description = ''
        Name of the attic cache to push builds to.
      '';
      example = "my-team-cache";
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a file containing the Attic token (plain text). If set, the
        post-build hook generates an ephemeral config using this token.
      '';
      example = "/run/secrets/attic-client-token";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "builder";
      description = ''
        User account that has attic-client configured with appropriate tokens.
        This user must have push access to the specified cache.
      '';
      example = "builduser";
    };

    serverHostnames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "atticd"
        "cache-server"
        "cache-build-server"
      ];
      description = ''
        List of hostnames running atticd that should not have post-build hooks enabled
        to prevent circular dependencies.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Safety check: prevent enabling on cache servers
    assertions = [
      {
        assertion = !(builtins.elem config.networking.hostName cfg.serverHostnames);
        message = ''
          attic-post-build-hook should NOT be enabled on attic cache servers
          (hostnames: ${builtins.concatStringsSep ", " cfg.serverHostnames})
          to avoid circular dependencies!
        '';
      }
    ];

    # Configure the post-build hook
    nix.settings.post-build-hook = toString postBuildScript;

    # Ensure the hook runs as the user with attic access
    nix.settings.allowed-users = [ cfg.user ];

    # Trust the user to modify the nix store (needed for post-build hooks)
    nix.settings.trusted-users = [ cfg.user ];

    # Ensure attic-client is available system-wide
    environment.systemPackages = [ pkgs.attic-client ];
  };
}
