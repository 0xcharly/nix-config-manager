{
  config,
  lib,
}: let
  inherit (lib) mkOption types;
  cfg = config.config-manager;

  requireConfigRoot = lib.throwIfNot (cfg ? root) "config-manager.root must be set" cfg.root;

  homeOptionsSubmodule.options = {
    system = mkOption {
      default = cfg.home.defaultSystem;
      type = types.str;
      description = ''
        The default system to use for this user configuration.
      '';
    };

    user = mkOption {
      default = cfg.defaultUser;
      type = types.nullOr types.str;
      description = ''
        The name of the owning user.
      '';
    };
  };

  mkModulesDirectoriesOptions = prefix: let
    supportedPrefixes = [
      "home"
      "darwin"
      "nixos"
    ];
    throwForUnsupportedPrefix = expr:
      lib.throwIfNot (builtins.elem prefix supportedPrefixes) "Internal error: unsupported prefix '${prefix}'" expr;
  in
    throwForUnsupportedPrefix {
      configModulesDirectory = mkOption {
        default = "${requireConfigRoot}/hosts/${prefix}-configs";
        defaultText = lib.literalExpression "\"\${config-manager.root}/hosts/${prefix}-configs\"";
        type = types.path;
        description = ''
          The directory containing configuration modules for ${prefix}.
        '';
      };

      systemModulesDirectory = mkOption {
        default = "${requireConfigRoot}/hosts/${prefix}-modules";
        defaultText = lib.literalExpression "\"\${config-manager.root}/hosts/${prefix}-modules\"";
        type = types.path;
        description = ''
          The directory containing shared modules for ${prefix}.
        '';
      };
    };

  systemOptionsSubmodule.options = {
    user = mkOption {
      default = cfg.defaultUser;
      type = types.nullOr types.str;
      description = ''
        The name of the owning user.
      '';
    };
  };

  mkSystemConfigurationOptions = system: let
    supportedSystems = ["darwin" "nixos"];
    throwForUnsupportedSystems = expr:
      lib.throwIfNot (builtins.elem system supportedSystems) "Internal error: unsupported system '${system}'" expr;
  in
    throwForUnsupportedSystems {
      hosts = mkOption {
        default = {};
        type = types.attrsOf (types.submodule systemOptionsSubmodule);
        example = lib.literalExpression ''
          {
            hostname = {
              user = "bob";
            };
          }
        '';
        description = ''
          Settings for creating ${system}Configurations.

          It's not neccessary to specify this option to create flake outputs.
          It's only needed if you want to change the defaults for specific ${system}Configurations.
        '';
      };
    };

  nixosConfigurationOptions =
    mkModulesDirectoriesOptions "nixos"
    // mkSystemConfigurationOptions "nixos";

  darwinConfigurationOptions =
    mkModulesDirectoriesOptions "darwin"
    // mkSystemConfigurationOptions "darwin";

  homeConfigurationOptions =
    mkModulesDirectoriesOptions "home"
    // {
      defaultSystem = mkOption {
        default = "x86_64-linux";
        type = types.str;
        description = ''
          The default system to use for standalone user configurations.
        '';
      };

      hosts = mkOption {
        default = {};
        type = types.attrsOf (types.submodule homeOptionsSubmodule);
        example = lib.literalExpression ''
          {
            alice = {
              system = "x86_64-linux";
            };
          }
        '';
        description = ''
          Settings for creating homeConfigurations.

          It's not neccessary to specify this option to create flake outputs.
          It's only needed if you want to change the defaults for specific homeConfigurations.
        '';
      };
    };

  mkImportsOptions = let
    mkModuleDirectoryOption = mkOption {
      type = types.attrsOf types.raw;
      default = {};
      internal = true;
      visible = false;
    };
  in {
    modules = {
      home = {
        hosts = mkModuleDirectoryOption;
        system = mkModuleDirectoryOption;
      };
      darwin = {
        hosts = mkModuleDirectoryOption;
        system = mkModuleDirectoryOption;
      };
      nixos = {
        hosts = mkModuleDirectoryOption;
        system = mkModuleDirectoryOption;
      };
      global = mkModuleDirectoryOption;
      users = mkModuleDirectoryOption;
    };
  };

  mkDefaultOptions = options: let
    requireDefault = name: value: lib.throwIfNot (value ? default) "Internal error: missing default value for option '${name}" value.default;
  in
    lib.mapAttrs (name: value: requireDefault name value) options;
in {
  config-manager = {
    root = mkOption {
      type = types.path;
      example = lib.literalExpression "./.";
      description = ''
        The root from which configurations and modules should be searched.
      '';
    };

    final = mkOption {
      default = true;
      type = types.bool;
      description = ''
        If false, opens this config for extension. Do this if you want to build
        upon this config from another, separated one.
      '';
    };

    # TODO: what happens if there's multiple `default` modules defined, or
    # multiple modules of the same name for that matter?
    imports = mkImportsOptions;

    defaultUser = mkOption {
      default = null;
      type = types.nullOr types.str;
      description = ''
        Default user to install for all systems.
      '';
    };

    backupFileExtension = mkOption {
      type = types.nullOr types.str;
      default = "nix-backup";
      example = "nix-backup";
      description = ''
        On activation move existing files by appending the given file
        extension rather than exiting with an error.
      '';
    };

    globalModulesDirectory = mkOption {
      default = "${requireConfigRoot}/modules";
      defaultText = lib.literalExpression "\"\${config-manager.root}/modules\"";
      type = types.path;
      description = ''
        The directory containing modules shared with all configurations.
      '';
    };

    usersModulesDirectory = mkOption {
      default = "${requireConfigRoot}/users";
      defaultText = lib.literalExpression "\"\${config-manager.root}/users\"";
      type = types.path;
      description = ''
        The directory containing user configuration modules shared with all systems.
      '';
    };

    home = homeConfigurationOptions;
    nixos = nixosConfigurationOptions;
    darwin = darwinConfigurationOptions;
  };

  defaults = {
    home = mkDefaultOptions homeOptionsSubmodule.options;
    darwin = mkDefaultOptions systemOptionsSubmodule.options;
    nixos = mkDefaultOptions systemOptionsSubmodule.options;
  };
}
