# macOS-specific Attic client enhancements for Home Manager
#
# This module provides macOS-specific optimizations for the Attic client,
# including Determinate Nix integration and Darwin-specific configuration.
{ config, lib, ... }:

{
  # Enable attic-client by default on macOS systems
  programs.attic-client = {
    enable = lib.mkDefault true;
    enableShellAliases = lib.mkDefault true;
  };

  # Enable user Nix configuration for Determinate Nix systems
  services.nix-user-config.enable = lib.mkDefault true;

  # Ensure attic configuration directory has proper permissions on macOS
  home.activation.attic-darwin-permissions = lib.mkIf config.programs.attic-client.enable (
    lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
      $DRY_RUN_CMD mkdir -p ${config.home.homeDirectory}/.config/attic
      $DRY_RUN_CMD chmod 700 ${config.home.homeDirectory}/.config/attic
    ''
  );
}
