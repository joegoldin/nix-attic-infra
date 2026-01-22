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

  tokenFilePath =
    if cfg.tokenFile != null then
      config.sops.secrets."attic-client-token".path
    else
      "/run/secrets/attic-client-token";

  substituterUrl = "${lib.removeSuffix "/" cfg.server}/${cfg.cache}";

in
{
  options.services.attic-client = {
    enable = lib.mkEnableOption "Attic client for NixOS with SOPS token management";

    server = lib.mkOption {
      type = lib.types.str;
      default = "http://cache-build-server:5001";
      description = "The URL of the Attic cache server";
      example = "https://cache.example.com";
    };

    serverName = lib.mkOption {
      type = lib.types.str;
      default = "cache-build-server";
      description = ''
        The name used in the generated Attic config (used as the prefix for
        pushes like `serverName:cache`).
      '';
      example = "attic";
    };

    cache = lib.mkOption {
      type = lib.types.str;
      default = "cache-local";
      description = "The name of the cache to use for pulls and pushes";
      example = "main";
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to the SOPS encrypted token file. If null, you must ensure a token is
        available at `${tokenFilePath}`.
      '';
    };

    tokenKey = lib.mkOption {
      type = lib.types.str;
      default = "ATTIC_CLIENT_JWT_TOKEN";
      description = "The key name in the SOPS file containing the token";
    };

    enablePostBuildHook = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable automatic pushing to the cache via `nix.settings.post-build-hook`.

        Prefer the dedicated `services.attic-post-build-hook` module when possible.
      '';
    };

    trustedPublicKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional trusted public keys for the configured substituter.";
    };

    configureNixSubstituter = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to configure Nix substituters for the cache.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."attic-client-token" = lib.mkIf (cfg.tokenFile != null) {
      sopsFile = cfg.tokenFile;
      key = cfg.tokenKey;
      path = "/run/secrets/attic-client-token";
      owner = config.users.users.root.name;
      group = config.users.users.root.group;
    };

    environment.systemPackages = [ pkgs.attic-client ];

    environment.etc."nix/attic-upload.sh" = lib.mkIf cfg.enablePostBuildHook {
      mode = "0755";
      text = ''
        #!${pkgs.bash}/bin/bash
        # Fail-safe post-build hook - never blocks builds.
        set -uo pipefail

        out_paths="''${OUT_PATHS-}"
        drv_path="''${DRV_PATH-}"

        if [ -z "$out_paths" ]; then
          exit 0
        fi

        # Skip source/temporary derivations.
        if [[ "$drv_path" == *"-source.drv" ]] || [[ "$drv_path" == *"tmp"* ]]; then
          exit 0
        fi

        token_file="${tokenFilePath}"
        if [ ! -f "$token_file" ]; then
          echo "Attic: Token not available, skipping push" >&2
          exit 0
        fi

        token=$(cat "$token_file" 2>/dev/null || true)
        if [ -z "$token" ]; then
          echo "Attic: Token empty, skipping push" >&2
          exit 0
        fi

        tmpdir=$(mktemp -d)
        trap 'rm -rf "$tmpdir"' EXIT

        export XDG_CONFIG_HOME="$tmpdir"
        mkdir -p "$XDG_CONFIG_HOME/attic"

        cat > "$XDG_CONFIG_HOME/attic/config.toml" <<EOF
        [servers.${cfg.serverName}]
        endpoint = "${cfg.server}"
        token = "$token"
        EOF

        {
          echo "Attic: pushing to ${cfg.serverName}:${cfg.cache}" >&2
          # shellcheck disable=SC2086
          ${pkgs.attic-client}/bin/attic push "${cfg.serverName}:${cfg.cache}" $out_paths 2>&1 || true
        } || true

        exit 0
      '';
    };

    nix.settings = lib.mkMerge [
      (lib.mkIf cfg.enablePostBuildHook {
        post-build-hook = "/etc/nix/attic-upload.sh";
      })
      (lib.mkIf cfg.configureNixSubstituter {
        substituters = lib.mkDefault [ substituterUrl ];
        trusted-public-keys = lib.mkDefault cfg.trustedPublicKeys;
      })
    ];

    systemd.services.nix-attic-token = {
      description = "Prepare Attic authentication token for Nix daemon";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        token_file="${tokenFilePath}"

        if [[ -f "$token_file" ]]; then
          echo "Preparing Attic token for Nix daemon cache access..."
          mkdir -p /run/nix
          token=$(cat "$token_file")
          echo "bearer $token" > /run/nix/attic-token-bearer
          chmod 0644 /run/nix/attic-token-bearer
        else
          echo "Warning: Attic client token not found at $token_file" >&2
        fi
      '';
    };

    systemd.services.nix-daemon = {
      requires = [ "nix-attic-token.service" ];
      after = [ "nix-attic-token.service" ];
    };
  };
}
