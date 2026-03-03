# Home Manager module for Attic binary cache client
#
# This module provides cross-platform Attic client configuration with:
# - Native token-file support for agenix/SOPS integration
# - Legacy token substitution for inline tokens
# - Multi-server configuration support
# - Default server selection
# - Convenient shell aliases
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.attic-client;

  # Servers that need sed-based token substitution (no tokenPath set)
  substitutionServers = lib.filterAttrs (
    _: s: s.tokenPath == null && s.tokenSubstitutionPath != null
  ) cfg.servers;
  needsSubstitution = substitutionServers != { };

  # Generate TOML for a single server
  serverToml =
    name: server:
    let
      tokenLine =
        if server.tokenPath != null then
          ''token-file = "${server.tokenPath}"''
        else if server.tokenSubstitutionPath != null then
          ''token = "@ATTIC_CLIENT_TOKEN_${lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] name)}@"''
        else
          "";
    in
    lib.concatStringsSep "\n" (
      lib.filter (s: s != "") [
        "[servers.${name}]"
        ''endpoint = "${server.endpoint}"''
        tokenLine
      ]
    );
in
{
  options.programs.attic-client = {
    enable = lib.mkEnableOption "Attic binary cache client";

    defaultServer = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Name of the default server. Must match a key in `servers`.
        When set, adds `default-server = "<name>"` to config.toml.
      '';
      example = "default-server";
    };

    servers = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            endpoint = lib.mkOption {
              type = lib.types.str;
              description = "Attic server endpoint URL";
              example = "https://cache.example.com";
            };
            tokenPath = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Path to a file containing the authentication token.
                Uses Attic's native token-file support, making it compatible
                with agenix, SOPS, and other secret managers that provision
                files at runtime.

                Mutually exclusive with tokenSubstitutionPath.
              '';
              example = "/run/agenix/attic-token";
            };
            tokenSubstitutionPath = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Path to a file containing the authentication token.
                The token is read from this file and substituted inline into
                config.toml during home-manager activation.

                Use tokenPath instead for a simpler approach that leverages
                Attic's native token-file support.

                Mutually exclusive with tokenPath.
              '';
              example = "/run/secrets/attic-token";
            };
            aliases = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = ''
                List of cache names to create shell aliases for.
                Creates 'attic-push-{name}' aliases for each entry.
              '';
              example = [
                "main"
                "dev"
              ];
            };
          };
        }
      );
      default = { };
      description = "Attic servers configuration";
      example = {
        default-server = {
          endpoint = "https://cache.example.com";
          tokenPath = "/run/agenix/attic-token";
          aliases = [ "main" ];
        };
      };
    };

    enableShellAliases = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to create convenient shell aliases for attic push commands";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = lib.mapAttrsToList (name: server: {
      assertion = !(server.tokenPath != null && server.tokenSubstitutionPath != null);
      message = "Server '${name}': tokenPath and tokenSubstitutionPath are mutually exclusive.";
    }) cfg.servers;

    home = {
      # Install attic-client
      packages = [ pkgs.attic-client ];

      # Activation script to substitute tokens for servers using tokenSubstitutionPath
      activation.attic-config = lib.mkIf needsSubstitution (
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          $DRY_RUN_CMD mkdir -p ${config.home.homeDirectory}/.config/attic

          if [[ -f ${config.home.homeDirectory}/.config/attic/config.toml ]]; then
            config_file="${config.home.homeDirectory}/.config/attic/config.toml"
            temp_file="/tmp/attic-config-$$.toml"

            # Copy the template
            cp "$config_file" "$temp_file"

            ${lib.concatStringsSep "\n          " (
              lib.mapAttrsToList (name: server: ''
                # Substitute token for ${name}
                if [[ -f "${server.tokenSubstitutionPath}" ]]; then
                  token=$(cat "${server.tokenSubstitutionPath}")
                  placeholder="@ATTIC_CLIENT_TOKEN_${lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] name)}@"
                  $DRY_RUN_CMD sed -i "s|$placeholder|$token|g" "$temp_file"
                else
                  $VERBOSE_ECHO "Warning: Token file not found for ${name}: ${server.tokenSubstitutionPath}"
                fi
              '') substitutionServers
            )}

            # Move the configured file into place
            $DRY_RUN_CMD mv "$temp_file" "$config_file"
            $VERBOSE_ECHO "Attic client configuration updated with tokens"
          fi
        ''
      );

      # Create shell aliases for convenient attic operations
      shellAliases = lib.mkIf cfg.enableShellAliases (
        lib.mkMerge [
          # Generic aliases
          {
            attic-list = "attic cache list";
            attic-info = "attic cache info";
          }

          # Server-specific aliases
          (lib.mkMerge (
            lib.flatten (
              lib.mapAttrsToList (
                _serverName: server:
                map (aliasName: {
                  "attic-push-${aliasName}" = "attic push ${aliasName}";
                  "attic-pull-${aliasName}" = "attic pull ${aliasName}";
                }) server.aliases
              ) cfg.servers
            )
          ))
        ]
      );
    };

    # Create Attic client configuration
    xdg.configFile."attic/config.toml".text =
      let
        defaultServerLine = lib.optionalString (
          cfg.defaultServer != null
        ) ''default-server = "${cfg.defaultServer}"'';
        serverConfigs = lib.mapAttrsToList serverToml cfg.servers;
      in
      lib.concatStringsSep "\n\n" (lib.filter (s: s != "") ([ defaultServerLine ] ++ serverConfigs))
      + "\n";
  };
}
