# A design: one repo describing one or more machines.
#
# Made with `nix flake init -t <this registry>` and yours from then on. The only
# file `ryra design` keeps writing is ./modules/ryra/services.json, which is the
# list of enabled services and nothing else. JSON rather than Nix so that nix
# reads it with `builtins.fromJSON` and anything else reads it with `jq`: there
# is no bespoke format and nothing hand-parses Nix.
#
# Five things in here each cost an evaluation round when this was first built by
# hand against a real box. They are numbered, because none of them is guessable
# and every one of them fails deep in a trace rather than where you can see it.
{
  description = "a design";

  inputs = {
    selfhostblocks.url = "github:ibizaman/selfhostblocks";
    sops-nix.url = "github:Mic92/sops-nix";
    # While this registry has no remote, point at your checkout:
    #   ryra-services.url = "path:/home/you/code/ryra-services";
    ryra-services.url = "github:ryra/ryra-services";
  };

  outputs =
    { self, selfhostblocks, sops-nix, ryra-services }:
    let
      system = "x86_64-linux";
      # SHB requires its own patched tree, so there is no plain nixpkgs input.
      # This is a DERIVATION, not a path, so evaluating this design needs a
      # Linux builder: on a Mac that means `nix.linux-builder.enable = true`,
      # or running `ryra design --ssh <box>`.
      nixpkgs' = selfhostblocks.lib.${system}.patchedNixpkgs;

      enabled = builtins.fromJSON (builtins.readFile ./modules/ryra/services.json);
      settings = import ./modules/ryra/settings.nix;
    in
    {
      # Which machine each host deploys to. A pure output, so reading it costs
      # no module evaluation, and a fact in the repo rather than a flag somebody
      # has to remember.
      ryraDeploy = {
        # fsn1 = "your-ssh-destination";
      };

      nixosConfigurations.fsn1 = nixpkgs'.nixosSystem {
        inherit system;
        modules = [
          sops-nix.nixosModules.default
          selfhostblocks.nixosModules.nginx
          selfhostblocks.nixosModules.ssl
          selfhostblocks.nixosModules.sops
          selfhostblocks.nixosModules.restic
          # (1) Needed even with `zfsPool = null`: the mechanism names `shb.zfs`
          # inside an `mkIf false`, and the option must exist even when the
          # branch is dead.
          selfhostblocks.nixosModules.zfs

          ({ config, ... }: {
            networking.hostName = "fsn1";
            system.stateVersion = "25.05";

            # Replace with this machine's real disk layout.
            fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
            boot.loader.grub.device = "/dev/sda";

            # (2) sops needs a key source, and in practice that means sshd.
            services.openssh.enable = true;
            # (3) The path must exist at eval. Decryption happens on the box.
            sops.defaultSopsFile = ./secrets.yaml;

            # (4) Selfsigned certificates need a CA declared separately. This is
            # the SSL provider with no tailnet; swap `sslFor` below for Tailscale
            # or ACME and nothing else changes. That is the contract working.
            shb.certs.cas.selfsigned.myca = { };
          })

          # (5) The mechanism is a function RETURNING a module, so it goes
          # through `imports` inside one: `imports` may not depend on `config`,
          # and `sslFor` does.
          ({ config, ... }: {
            imports = [
              (ryra-services.nixosModules.services {
                registries.ryra = ryra-services;
                selfhostblocks = selfhostblocks;
                domain = "example.ts.net";
                zfsPool = null;
                sslFor = name: config.shb.certs.certs.selfsigned.${name};
                services = builtins.listToAttrs (
                  map (n: {
                    name = n;
                    value = settings.${n} or { };
                  }) enabled
                );
              })
            ];

            # One certificate per enabled service, derived rather than listed,
            # so the list cannot fall out of step with the services.
            shb.certs.certs.selfsigned = builtins.listToAttrs (
              map (n: {
                name = n;
                value = {
                  ca = config.shb.certs.cas.selfsigned.myca;
                  domain = "example.ts.net";
                  group = "nginx";
                };
              }) config.ryra.services.names
            );
          })
        ];
      };
    };
}
