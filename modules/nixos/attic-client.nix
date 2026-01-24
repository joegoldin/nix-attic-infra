# NixOS module for Attic client configuration
#
# This module configures the Nix daemon to use an Attic cache with
# automatic authentication token management via SOPS.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.attic-client;
in
{
  options.services.attic-client = {
    enable = lib.mkEnableOption "Attic client for NixOS with SOPS token management";

    server = lib.mkOption {
      type = lib.types.str;
      description = "The URL of the Attic cache server";
      example = "https://cache.example.com";
    };

    cache = lib.mkOption {
      type = lib.types.str;
      description = "The name of the cache to use for pulls and pushes";
      example = "main";
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to the SOPS encrypted token file. If null, the token must be
        configured manually in the attic client configuration.
      '';
    };

    tokenKey = lib.mkOption {
      type = lib.types.str;
      default = "ATTIC_CLIENT_JWT_TOKEN";
      description = "The key name in the SOPS file containing the token";
    };

    enablePostBuildHook = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to enable automatic pushing to the cache via post-build hooks.
        Disable this if using the attic-post-build-hook module instead.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Define the system-level SOPS secret for the client token
    sops.secrets."attic-client-token" = lib.mkIf (cfg.tokenFile != null) {
      sopsFile = cfg.tokenFile;
      key = cfg.tokenKey;
      path = "/run/secrets/attic-client-token";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
      mode = "0400";
    };

    # Install attic-client system-wide
    environment.systemPackages = [ pkgs.attic-client ];

    # Create the post-build hook script with comprehensive error handling
    environment.etc."nix/attic-upload.sh" = lib.mkIf cfg.enablePostBuildHook {
      mode = "0755";
      text = ''
        #!${pkgs.bash}/bin/bash
        # Fail-safe post-build hook - never blocks builds
        set -uo pipefail

        if [ -z "$OUT_PATHS" ]; then
          exit 0
        fi

        token_file="${config.sops.secrets."attic-client-token".path}"

        if [ ! -f "$token_file" ]; then
          echo "Attic: Token not available, skipping push" >&2
          exit 0
        fi

        if [ ! -r "$token_file" ]; then
          echo "Attic: Token file not readable, skipping push" >&2
          exit 0
        fi

        token=$(cat "$token_file")

        # Create a temporary config file for the push
        temp_config=$(mktemp)
        trap 'rm -f "$temp_config"' EXIT

        cat > "$temp_config" <<EOF
        [servers.${cfg.cache}]
        endpoint = "${cfg.server}"
        token = "$token"
        EOF

        # Robust error handling - never fail the build
        {
          echo "Attic: Pushing to cache '${cfg.cache}' at ${cfg.server}" >&2

          if ${pkgs.attic-client}/bin/attic --config "$temp_config" push ${cfg.cache} $OUT_PATHS; then
            echo "Attic: Successfully pushed paths" >&2
          else
            echo "Attic: Push failed - testing connectivity..." >&2
            # Test server connectivity with timeout
            if ${pkgs.curl}/bin/curl -s -f --max-time 10 \
               "${cfg.server}/_attic/v1/cache/${cfg.cache}/info" \
               -H "Authorization: Bearer $token" >/dev/null 2>&1; then
              echo "Attic: Server reachable, possible permission issue" >&2
            else
              echo "Attic: Server unreachable or authentication failed" >&2
            fi
          fi
        } || {
          echo "Attic: Hook failed unexpectedly, continuing build" >&2
        }

        # Always exit successfully
        exit 0
      '';
    };

    # Configure Nix to use the post-build hook
    nix.settings.post-build-hook = lib.mkIf cfg.enablePostBuildHook "/etc/nix/attic-upload.sh";

    # Prepare the token for Nix daemon cache access
    systemd.services.nix-attic-token = lib.mkIf (cfg.tokenFile != null) {
      description = "Prepare Attic authentication token for Nix daemon";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        if [[ -f "${config.sops.secrets."attic-client-token".path}" ]]; then
          if [[ ! -r "${config.sops.secrets."attic-client-token".path}" ]]; then
            echo "Warning: Attic client token not readable. Cache pulls may fail."
          else
            echo "Preparing Attic token for Nix daemon cache access..."
            mkdir -p /run/nix
            token=$(cat "${config.sops.secrets."attic-client-token".path}")
            umask 0077
            echo "bearer $token" > /run/nix/attic-token-bearer
            chmod 0600 /run/nix/attic-token-bearer
          fi
        else
          echo "Warning: Attic client token not found. Cache pulls may fail."
        fi
      '';
    };

    # Ensure Nix daemon waits for token preparation
    systemd.services.nix-daemon = lib.mkIf (cfg.tokenFile != null) {
      requires = [ "nix-attic-token.service" ];
      after = [ "nix-attic-token.service" ];
    };

    # Add the cache to Nix configuration for pulls
    nix.settings = {
      substituters = [ cfg.server ];
      trusted-public-keys = [
        # Users should add their cache public keys here
      ];
    };
  };
}
