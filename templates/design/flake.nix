{
  description = "A Ryra machine design";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    ryra-services.url = "github:ryra-dev/ryra-services";
    ryra-services.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, sops-nix, ryra-services }:
    let
      enabled = builtins.fromJSON (builtins.readFile ./modules/ryra/services.json);
      settings = import ./modules/ryra/settings.nix;
      web = builtins.fromJSON (builtins.readFile ./modules/ryra/web.json);
    in {
      ryraDeploy = {};
      ryraCatalog.fsn1.ryra = { flake = "github:ryra-dev/ryra-services"; inherit (ryra-services) index; };
      nixosConfigurations.fsn1 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          sops-nix.nixosModules.default
          (ryra-services.nixosModules.services {
            registries.ryra = ryra-services;
            services = builtins.listToAttrs (map (name: {
              inherit name;
              value = (settings.${name} or {}) // { web = web.${name} or {}; };
            }) enabled);
          })
          {
            networking.hostName = "fsn1";
            system.stateVersion = "25.05";
            # Replace with this machine's real disk layout before deploying.
            fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
            boot.loader.grub.device = "/dev/sda";
            services.openssh.enable = true;
            sops.defaultSopsFile = ./secrets.yaml;
          }
        ];
      };
    };
}
