# Architecture Overview

This document explains the design principles and architecture of nix-attic-infra.

## Design Goals

1. **Zero-Configuration Automation**: Post-build hooks should work without manual intervention
2. **Security by Default**: SOPS integration for token management, secure defaults
3. **Cross-Platform Support**: Works on NixOS, macOS, and standalone Home Manager
4. **Circular Dependency Prevention**: Smart hostname detection to avoid cache servers pushing to themselves
5. **Enterprise Ready**: Multi-server support, role-based access, professional tooling

## Module Architecture

```
nix-attic-infra/
├── modules/
│   ├── nixos/                    # System-level NixOS modules
│   │   ├── attic-post-build-hook.nix    # Automated cache uploads
│   │   └── attic-client.nix             # NixOS client configuration
│   └── home-manager/             # User-level modules
│       ├── attic-client.nix             # Cross-platform client
│       └── attic-client-darwin.nix      # macOS-specific enhancements
├── examples/                     # Complete configuration templates
└── lib/                         # Helper functions and common configs
```

### Module Responsibilities

#### NixOS Modules

**attic-post-build-hook.nix**
- Configures Nix post-build hooks for automatic cache population
- Manages hook scripts and permissions
- Prevents circular uploads on cache servers
- Handles SOPS token integration

**attic-client.nix**
- System-wide Attic client configuration
- Nix substituter and trusted key management
- Global cache server configuration

#### Home Manager Modules

**attic-client.nix**
- Cross-platform user-level client setup
- Shell aliases and environment configuration
- Per-user token management
- Multiple server support

**attic-client-darwin.nix**
- macOS-specific application integration
- Darwin-specific path handling
- Enhanced macOS user experience

## Key Features

### Automated Post-Build Hooks

```nix
# Automatically configured when enabled
nix.settings.post-build-hook = "${postBuildHookScript}/bin/attic-post-build-hook";
```

The post-build hook:
1. Receives built paths from Nix
2. Filters based on success/failure
3. Authenticates using SOPS-managed tokens
4. Uploads to configured cache
5. Handles errors gracefully

### Circular Dependency Prevention

```nix
# Smart hostname detection
serverHostnames = [ "atticd" "cache-server" "cache-build-server" ];

# Hook disabled if current hostname matches
config = lib.mkIf (cfg.enable && !(lib.elem config.networking.hostName cfg.serverHostnames))
```

This prevents cache servers from trying to upload to themselves, which would cause:
- Infinite loops
- Build failures
- Performance degradation

### SOPS Integration

```nix
# Secure token management
tokenPath = "/run/secrets/attic-client-token";

# Runtime token substitution
ExecStartPre = "${pkgs.coreutils}/bin/install -m 600 ${cfg.tokenPath} /tmp/attic-token";
```

Tokens are:
- Encrypted at rest with SOPS
- Decrypted only when needed
- Never stored in Nix store
- Proper permission management

### Cross-Platform Compatibility

The modules handle platform differences transparently:

**NixOS**
- System services and hooks
- Global Nix configuration
- SOPS secrets integration

**macOS (Darwin)**
- User-level configuration
- Application bundle integration
- Keychain compatibility (future)

**Standalone Home Manager**
- Works without system integration
- User directory token storage
- Shell environment setup

## Configuration Flow

### 1. Module Import and Evaluation

```nix
# Flake structure ensures proper module loading
nixosModules.attic-post-build-hook = import ./modules/nixos/attic-post-build-hook.nix;
homeManagerModules.attic-client = import ./modules/home-manager/attic-client.nix;
```

### 2. Option Processing

```nix
# Type-safe configuration with validation
servers = lib.mkOption {
  type = lib.types.attrsOf (lib.types.submodule {
    options = {
      endpoint = lib.mkOption { type = lib.types.str; };
      tokenPath = lib.mkOption { type = lib.types.str; };
      aliases = lib.mkOption { type = lib.types.listOf lib.types.str; };
    };
  });
};
```

### 3. Service Generation

```nix
# Automatic service creation
systemd.services.attic-client = {
  description = "Attic binary cache client setup";
  wantedBy = [ "multi-user.target" ];
  # Dynamic configuration based on user options
};
```

### 4. Environment Integration

```nix
# Shell aliases and environment
home.shellAliases = lib.mkIf cfg.enableShellAliases {
  attic-push-local = "attic push local";
  attic-push-main = "attic push main";
};
```

## Security Model

### Token Lifecycle

1. **Storage**: Encrypted with SOPS, stored in repository
2. **Decryption**: Only on target systems with proper keys
3. **Access**: Restricted file permissions (0400 for SOPS secrets, 0600 for runtime tokens)
4. **Usage**: Temporary copies for service operations
5. **Cleanup**: Automatic cleanup of temporary files

### File Permission Hardening

The `attic-client` module includes enhanced security through strict file permissions:

- **SOPS secrets** (`/run/secrets/attic-client-token`): Set to mode `0400` (owner-only read)
- **Runtime token bearer** (`/run/nix/attic-token-bearer`): Set to mode `0600` (owner-only read/write)
- **Token creation**: Uses `umask 0077` to ensure newly created files are not world-readable
- **Readability checks**: Verifies token files are readable before access, logging appropriate errors

These restrictions ensure that sensitive authentication tokens are never accessible to other users on the system, preventing privilege escalation and token theft.

### Access Control

```nix
# Role-based server configuration
servers = {
  production = {
    tokenPath = "/run/secrets/attic-prod-token";    # Admin access
  };
  staging = {
    tokenPath = "/run/secrets/attic-staging-token"; # Developer access
  };
  readonly = {
    tokenPath = "/run/secrets/attic-read-token";    # CI access
  };
};
```

### Network Security

- HTTPS enforcement for production endpoints
- Certificate validation
- Token transmission only over secure channels
- No token storage in Nix store paths

## Performance Considerations

### Build Hook Efficiency

- Minimal overhead during builds
- Asynchronous uploads when possible
- Error handling doesn't block builds
- Smart path filtering to avoid unnecessary uploads

### Cache Efficiency

- Intelligent substituter ordering
- Trusted key management
- Parallel downloads when available
- Fallback to public caches

### Resource Management

- Controlled concurrent uploads
- Disk space monitoring
- Network bandwidth awareness
- Memory-efficient operations

## Extensibility

### Custom Hooks

```nix
# Framework supports custom hook scripts
postBuildHookScript = pkgs.writeShellScript "custom-attic-hook" ''
  ${baseHookScript}
  # Custom post-processing
  custom-notify-system "$@"
'';
```

### Server Adapters

```nix
# Pluggable server configuration
lib.commonServers = {
  local = { endpoint = "http://localhost:8080"; };
  # Easy to add new common configurations
};
```

### Integration Points

- Pre/post activation scripts
- Custom token providers
- Alternative authentication methods
- Third-party cache integrations

## Error Handling

### Graceful Degradation

1. **Token unavailable**: Continue without cache uploads
2. **Network issues**: Retry with exponential backoff
3. **Server errors**: Fall back to public caches
4. **Permission errors**: Log and continue build

### Monitoring and Debugging

```bash
# Built-in debugging support
ATTIC_DEBUG=1 nix-build  # Verbose hook output
journalctl -u attic-client  # Service logs
attic cache info  # Server connectivity test
```

## Future Architecture

### Planned Enhancements

1. **Multi-Region Support**: Intelligent server selection based on location
2. **Compression Optimization**: Content-aware compression strategies
3. **Deduplication**: Cross-cache deduplication for storage efficiency
4. **Analytics Integration**: Build metrics and cache hit rates
5. **Federation**: Multi-organization cache federation

### Compatibility Roadmap

- Maintain backward compatibility for existing configurations
- Gradual migration paths for breaking changes
- Version-aware configuration validation
- Legacy fallback support