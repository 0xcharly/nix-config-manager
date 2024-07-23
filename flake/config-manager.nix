{
  config,
  inputs,
  lib,
  ...
}: let
  inherit (builtins) pathExists readDir readFileType;
  inherit (lib.strings) hasSuffix removeSuffix;

  options = import ./config-manager-options.nix {inherit config lib;};
  cfg = config.config-manager;

  # TODO: consider adding options to pass in the user's inputs name.
  requireInput = name: lib.throwIfNot (inputs ? ${name}) "Missing input: '${name}'" inputs.${name};
  requireDarwinInput = requireInput "darwin";
  requireNixpkgsInput = requireInput "nixpkgs";
  requireHomeManagerInput = requireInput "home-manager";

  crawlModuleDir = dir:
    lib.optionalAttrs (pathExists dir && readFileType dir == "directory")
    (lib.mapAttrs' (
        entry: type: let
          moduleAsSubdirWithDefault = "${dir}/${entry}/default.nix";
        in
          if (type == "regular" && hasSuffix ".nix" entry)
          then lib.nameValuePair (removeSuffix ".nix" entry) "${dir}/${entry}"
          else if (pathExists moduleAsSubdirWithDefault && readFileType moduleAsSubdirWithDefault == "regular")
          then lib.nameValuePair entry moduleAsSubdirWithDefault
          else lib.warn "Unexpected module shape: ${entry}" {}
      )
      (readDir dir));

  # Crawls the home-configs-modules/ and home-shared-modules/ directories (or
  # whichever directory specified by the config) and generates all standalone
  # home-manager configurations.
  mkHomeConfigurations = {
    hosts, # The list of user-defined hosts (i.e. from the flake config).
    defaults, # Default configuration values.
    modules, # The list of user-provided modules (configuration and shared) under (darwin|nixos)-(config|shared)-modules/
    imports, # The list of user-provided imports passed to this config via the `imports` option.
  }:
    lib.mapAttrs (name: hmConfigModule: let
      host = hosts.${name} or defaults;
      inherit (host) system user;

      supportedSystems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      throwForUnsupportedSystems = expr:
        lib.throwIfNot (builtins.elem system supportedSystems) "Unsupported system '${system}'" expr;
    in
      throwForUnsupportedSystems (requireHomeManagerInput.lib.homeManagerConfiguration {
        pkgs = import requireNixpkgsInput {inherit system;};
        extraSpecialArgs = {
          inherit inputs;
          globalModules = modules.global // imports.modules.global;
          systemModules = modules.system // imports.modules.system;
        };
        # NOTE: automatically backing up existing files is currently unsupported
        # for standalone home-manager setups.
        # See https://github.com/nix-community/home-manager/issues/5649.
        # Instead, we the `-b <backup-file-extension>` to `home-manager switch`.
        # TODO: contribute support, or find an alternative.
        # backupFileExtension = cfg.backupFileExtension;
        modules = [
          # System options.
          {nixpkgs.overlays = cfg.overlays ++ imports.overlays;}

          # Default home-manager shared module, if any.
          modules.system.default or {}
          # Default imported home-manager shared module, if any.
          imports.modules.system.default or {}

          # home-manager configuration.
          hmConfigModule
          # Default home-manager configuration module, if any.
          modules.config.default or {}
          # Default imported home-manager configuration module, if any.
          imports.modules.config.default or {}

          # User configuration.
          # TODO: consider failing if the user configuration and default are both missing.
          modules.users.${user} or modules.users.default or {}
          imports.modules.users.${user} or imports.modules.users.default or {}
        ];
      }))
    modules.config;

  # Creates specialized configuration factory functions.
  mkMkSystemConfigurations = {
    mkSystem,
    mkSystemHomeManagerModule,
  }: {
    hosts, # The list of user-defined hosts (i.e. from the flake config).
    defaults, # Default configuration values.
    modules, # The list of user-provided modules (configuration and shared) under (darwin|nixos)-(config|shared)-modules/
    imports, # The list of user-provided imports passed to this config via the `imports` option.
  }:
    lib.mapAttrs (hostname: configModule: let
      host = hosts.${hostname} or defaults;
      inherit (host) user;
    in
      mkSystem {
        specialArgs = {
          inherit inputs host;
          globalModules = modules.global // imports.modules.global;
          systemModules = modules.system // imports.modules.system;
        };
        modules = [
          # System options.
          {nixpkgs.overlays = cfg.overlays ++ imports.overlays;}

          # Default system shared module, if any.
          modules.system.default or {}
          # Default imported system shared modules, if any.
          imports.modules.system.default or {}

          # System configuration.
          configModule
          # Default system configuration module, if any.
          modules.config.default or {}
          # Default imported system configuration module, if any.
          imports.modules.config.default or {}

          # User configuration.
          mkSystemHomeManagerModule
          {
            home-manager.extraSpecialArgs = {
              inherit inputs;
              globalModules = modules.global // imports.modules.global;
            };
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.backupFileExtension = cfg.backupFileExtension;
            # TODO: consider failing if the user configuration and default are both missing.
            home-manager.users.${user}.imports = [
              modules.users.${user} or modules.users.default or {}
              imports.modules.users.${user} or imports.modules.users.default or {}
            ];
          }
        ];
      })
    modules.config;

  mkDarwinConfigurations = mkMkSystemConfigurations {
    mkSystem = requireDarwinInput.lib.darwinSystem;
    mkSystemHomeManagerModule = requireHomeManagerInput.darwinModules.home-manager;
  };

  mkNixosConfigurations = mkMkSystemConfigurations {
    mkSystem = requireNixpkgsInput.lib.nixosSystem;
    mkSystemHomeManagerModule = requireHomeManagerInput.nixosModules.home-manager;
  };
in {
  options = {inherit (options) config-manager;};

  config.flake = {
    homeConfigurations = mkHomeConfigurations {
      inherit (cfg.home) hosts;
      defaults = options.defaults.home;
      modules = {
        config = crawlModuleDir cfg.home.configModulesDirectory;
        system = crawlModuleDir cfg.home.sharedModulesDirectory;
        global = crawlModuleDir cfg.globalModulesDirectory;
        users = crawlModuleDir cfg.usersModulesDirectory;
      };
      imports = with cfg.imports; {
        inherit overlays;
        modules = {
          inherit (modules) global users;
          inherit (modules.home) config system;
        };
      };
    };

    darwinConfigurations = mkDarwinConfigurations {
      inherit (cfg.darwin) hosts;
      defaults = options.defaults.darwin;
      modules = {
        config = crawlModuleDir cfg.darwin.configModulesDirectory;
        system = crawlModuleDir cfg.darwin.sharedModulesDirectory;
        global = crawlModuleDir cfg.globalModulesDirectory;
        users = crawlModuleDir cfg.usersModulesDirectory;
      };
      imports = with cfg.imports; {
        inherit overlays;
        modules = {
          inherit (modules) global users;
          inherit (modules.darwin) config system;
        };
      };
    };

    nixosConfigurations = mkNixosConfigurations {
      inherit (cfg.nixos) hosts;
      defaults = options.defaults.nixos;
      modules = {
        config = crawlModuleDir cfg.nixos.configModulesDirectory;
        system = crawlModuleDir cfg.nixos.sharedModulesDirectory;
        global = crawlModuleDir cfg.globalModulesDirectory;
        users = crawlModuleDir cfg.usersModulesDirectory;
      };
      imports = with cfg.imports; {
        inherit overlays;
        modules = {
          inherit (modules) global users;
          inherit (modules.nixos) config system;
        };
      };
    };

    config-manager = lib.mkIf (!cfg.final) {
      inherit (cfg) overlays;
      modules = {
        home = {
          config = crawlModuleDir cfg.home.configModulesDirectory;
          system = crawlModuleDir cfg.home.sharedModulesDirectory;
        };
        darwin = {
          config = crawlModuleDir cfg.darwin.configModulesDirectory;
          system = crawlModuleDir cfg.darwin.sharedModulesDirectory;
        };
        nixos = {
          config = crawlModuleDir cfg.nixos.configModulesDirectory;
          system = crawlModuleDir cfg.nixos.sharedModulesDirectory;
        };
        global = crawlModuleDir cfg.globalModulesDirectory;
        users = crawlModuleDir cfg.usersModulesDirectory;
      };
    };
  };
}
