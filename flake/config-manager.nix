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
    modules, # The list of user-provided modules (configuration and shared) under home-(host|shared)-modules/
    imports, # The list of user-provided imports passed to this config via the `imports` option.
  }:
    lib.mapAttrs (hostname: hostModule: let
      host = hosts.${hostname} or defaults;
      inherit (host) system user;

      supportedSystems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      throwForUnsupportedSystems = expr:
        lib.throwIfNot (builtins.elem system supportedSystems) "Unsupported system '${system}'" expr;
    in
      throwForUnsupportedSystems (requireHomeManagerInput.lib.homeManagerConfiguration {
        extraSpecialArgs = {
          inherit inputs;
          globalModules = modules.global // imports.modules.global;
          sharedModules = modules.shared // imports.modules.shared;
        };
        # NOTE: automatically backing up existing files is currently unsupported
        # for standalone home-manager setups.
        # See https://github.com/nix-community/home-manager/issues/5649.
        # Instead, we the `-b <backup-file-extension>` to `home-manager switch`.
        # TODO: contribute support, or find an alternative.
        # backupFileExtension = cfg.backupFileExtension;
        modules = [
          # Install overlays.
          {nixpkgs.overlays = cfg.overlays ++ imports.overlays;}

          # Default home-manager shared module, if any.
          modules.shared.default or {}
          # Default imported home-manager shared module, if any.
          imports.modules.shared.default or {}

          # home-manager configuration.
          hostModule
          # Default home-manager configuration module, if any.
          modules.hosts.default or {}
          # Default imported home-manager configuration module, if any.
          imports.modules.hosts.default or {}

          # User configuration.
          # TODO: consider failing if the user configuration and default are both missing.
          modules.users.${user} or modules.users.default or {}
          imports.modules.users.${user} or imports.modules.users.default or {}
        ];
      }))
    modules.hosts;

  # Creates specialized configuration factory functions.
  mkMkSystemConfigurations = {
    mkSystem,
    mkHomeManager,
  }: {
    hosts, # The list of user-defined hosts (i.e. from the flake config).
    defaults, # Default configuration values.
    modules, # The list of user-provided modules (configuration and shared) under (darwin|nixos)-(host|shared)-modules/
    imports, # The list of user-provided imports passed to this config via the `imports` option.
  }:
    lib.mapAttrs (hostname: hostModule: let
      host = hosts.${hostname} or defaults;
      inherit (host) user;
    in
      mkSystem {
        specialArgs = {
          inherit inputs host;
          globalModules = modules.global // imports.modules.global;
          sharedModules = modules.shared // imports.modules.shared;
        };
        modules = [
          # Install overlays.
          {nixpkgs.overlays = cfg.overlays ++ imports.overlays;}

          # Default system shared module, if any.
          modules.shared.default or {}
          # Default imported system shared modules, if any.
          imports.modules.shared.default or {}

          # System configuration.
          hostModule
          # Default system configuration module, if any.
          modules.hosts.default or {}
          # Default imported system configuration module, if any.
          imports.modules.hosts.default or {}

          # User configuration.
          mkHomeManager
          {
            home-manager.extraSpecialArgs = {
              inherit inputs;
              globalModules = modules.global // imports.modules.global;
            };
            home-manager.backupFileExtension = cfg.backupFileExtension;
            # TODO: consider failing if the user configuration and default are both missing.
            home-manager.users.${user}.imports = [
              # Install overlays.
              {nixpkgs.overlays = cfg.overlays ++ imports.overlays;}

              modules.users.${user} or modules.users.default or {}
              imports.modules.users.${user} or imports.modules.users.default or {}
            ];
          }
        ];
      })
    modules.hosts;

  mkDarwinConfigurations = mkMkSystemConfigurations {
    mkSystem = requireDarwinInput.lib.darwinSystem;
    mkHomeManager = requireHomeManagerInput.darwinModules.home-manager;
  };

  mkNixosConfigurations = mkMkSystemConfigurations {
    mkSystem = requireNixpkgsInput.lib.nixosSystem;
    mkHomeManager = requireHomeManagerInput.nixosModules.home-manager;
  };
in {
  options = {inherit (options) config-manager;};

  config.flake = {
    homeConfigurations = mkHomeConfigurations {
      inherit (cfg.home) hosts;
      defaults = options.defaults.home;
      modules = {
        users = crawlModuleDir cfg.usersModulesDirectory;
        hosts = crawlModuleDir cfg.home.configModulesDirectory;
        shared = crawlModuleDir cfg.home.sharedModulesDirectory;
        global = crawlModuleDir cfg.globalModulesDirectory;
      };
      imports = with cfg.imports; {
        inherit overlays;
        modules = {
          inherit (modules) global users;
          inherit (modules.home) hosts shared;
        };
      };
    };

    darwinConfigurations = mkDarwinConfigurations {
      inherit (cfg.darwin) hosts;
      defaults = options.defaults.darwin;
      modules = {
        users = crawlModuleDir cfg.usersModulesDirectory;
        hosts = crawlModuleDir cfg.darwin.configModulesDirectory;
        shared = crawlModuleDir cfg.darwin.sharedModulesDirectory;
        global = crawlModuleDir cfg.globalModulesDirectory;
      };
      imports = with cfg.imports; {
        inherit overlays;
        modules = {
          inherit (modules) global users;
          inherit (modules.darwin) hosts shared;
        };
      };
    };

    nixosConfigurations = mkNixosConfigurations {
      inherit (cfg.nixos) hosts;
      defaults = options.defaults.nixos;
      modules = {
        users = crawlModuleDir cfg.usersModulesDirectory;
        hosts = crawlModuleDir cfg.nixos.configModulesDirectory;
        shared = crawlModuleDir cfg.nixos.sharedModulesDirectory;
        global = crawlModuleDir cfg.globalModulesDirectory;
      };
      imports = with cfg.imports; {
        inherit overlays;
        modules = {
          inherit (modules) global users;
          inherit (modules.nixos) hosts shared;
        };
      };
    };

    config-manager = lib.mkIf (!cfg.final) {
      inherit (cfg) overlays;
      modules = {
        home = {
          hosts = crawlModuleDir cfg.home.configModulesDirectory;
          shared = crawlModuleDir cfg.home.sharedModulesDirectory;
        };
        darwin = {
          hosts = crawlModuleDir cfg.darwin.configModulesDirectory;
          shared = crawlModuleDir cfg.darwin.sharedModulesDirectory;
        };
        nixos = {
          hosts = crawlModuleDir cfg.nixos.configModulesDirectory;
          shared = crawlModuleDir cfg.nixos.sharedModulesDirectory;
        };
        global = crawlModuleDir cfg.globalModulesDirectory;
        users = crawlModuleDir cfg.usersModulesDirectory;
      };
    };
  };
}
