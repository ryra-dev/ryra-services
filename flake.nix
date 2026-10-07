{
  description = "ryra-services: services to connect to or run yourself";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/151fa4e8ddfdd8dd25d945ad94ed54a13de9f6e4";
  outputs =
    { self, nixpkgs }:
    let
      # Every directory under ./services is a service. Adding one is creating a
      # folder; there is no list to keep in step, and therefore no way to add a
      # service and forget to register it.
      #
      # DIRECTORIES, filtered by type. `builtins.readDir` hands back every entry including plain
      # files, and this took all of them: `import ./services/config.toml` is not a nix expression
      # and brings the whole registry down with it.
      #
      # It has been fine only because that file is untracked, and nix copies just the tracked
      # ones out of a dirty tree. So `git add` was the whole distance between working and a flake
      # that would not evaluate for anybody, and the comment above already said what the code
      # should have done.
      #
      # Keep metadata evaluation independent of nixpkgs; packages pin their runtime separately.
      entries = builtins.readDir ./services;
      names = builtins.filter (n: entries.${n} == "directory") (builtins.attrNames entries);
    in
    {
      # The mechanism: turns an enable list into imported aspects,
      # certificates, backups and datasets.
      nixosModules.services = import ./lib/services-module.nix;

      # Native NixOS Restic, translated to our provider-neutral contract. The
      # service mechanism selects it automatically; exporting it also lets a
      # host wrap or configure the adapter explicitly.
      nixosModules.backup-restic = import ./lib/backup-providers/restic.nix;

      # Compatibility for larger existing ZFS hosts. The low-memory base is
      # Btrfs and gets rollback snapshots from its machine template.
      nixosModules.state-zfs = import ./lib/state-providers/zfs.nix;

      # A design, ready to evaluate: `nix flake init -t <this flake>`.
      #
      # Here rather than in a tool, because nix already has templates and a
      # scaffolding command of our own would be a worse copy of one that
      # exists. Beside the registry rather than in a client, because the five
      # numbered comments in it are facts about THIS mechanism and go stale
      # with it.
      templates.default = {
        path = ./templates/design;
        description = "A design: one repo describing one or more machines";
      };

      # THE REGISTRY IS A FLAKE OUTPUT, AND THAT OUTPUT IS THE SOURCE OF TRUTH.
      #
      # No manifest file sits beside these definitions, so there is nothing
      # that can disagree with them. `.meta` is a pure value: it evaluates
      # without nixpkgs, without a builder and without instantiating a NixOS
      # system, which is what makes the registry listable and checkable
      # cheaply.
      #
      #   nix eval --json .#ryraServices.nextcloud.meta
      #   nix eval --json .#index
      ryraServices = builtins.listToAttrs (
        map (n: {
          name = n;
          value = import ./services/${n};
        }) names
      );

      # The registry as one JSON-able value, for anything that is not Nix.
      #
      # Generated, never authored. A consumer that cannot evaluate Nix reads a
      # committed dump of this rather than a hand-written index, so the two
      # cannot drift: there is one authored source and everything else is
      # derived from it.
      index = builtins.mapAttrs (name: svc: svc.meta // { deployable = svc ? module; }
        // (if svc ? package then { package = name; } else { })) self.ryraServices;

      packages = builtins.listToAttrs (map (system: {
        name = system;
        value = builtins.mapAttrs (_: svc: svc.package (import nixpkgs { inherit system; }))
          (nixpkgs.lib.filterAttrs (_: svc: svc ? package) self.ryraServices);
      }) [ "aarch64-darwin" "aarch64-linux" "x86_64-linux" ]);

      lib.mkAdapter = { pkgs, name, src }:
        import ./adapters/package.nix { inherit pkgs src; service = name; };

      lib.withServices = { pkgs, package, services ? self.ryraServices, index ? builtins.mapAttrs (name: svc: svc.meta // { deployable = svc ? module; } // (if svc ? package then { package = name; } else { })) services }:
        let
          adapters = map (svc: svc.package pkgs)
            (builtins.filter (svc: svc ? package) (builtins.attrValues services));
        in
        pkgs.symlinkJoin {
          name = "ryra-with-services";
          paths = [ package ] ++ adapters;
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postBuild = ''
            wrapProgram "$out/bin/ryra" \
              --set RYRA_SERVICE_INDEX ${pkgs.writeText "ryra-services.json" (builtins.toJSON index)} \
              --prefix PATH : ${pkgs.lib.makeBinPath adapters}
          '';
        };

      # What a registry entry must provide for the mechanism to use it.
      #
      # Deliberately NOT called `checks`: that output has a fixed schema
      # (`checks.<system>.<name>` holding derivations) and putting a plain
      # attrset there breaks `nix flake check` on this repo.
      #
      # This is the job that is genuinely ours. Validating NixOS itself would
      # be a worse copy of something free; validating that a registry entry is
      # well-formed BEFORE a host tries to import it is not.
      #
      # It returns DATA, not an exception: `[ ]` when the registry is sound, a
      # list of complaints when it is not.
      #
      #   nix eval --json .#validate
      #
      # A throw would stop at the first problem and bury the message under a
      # stack trace, so fixing three malformed entries would take three
      # evaluations and three rounds of reading Nix internals. This is for
      # agents, and an agent should get every problem in one read.
      validate = builtins.concatLists (
        builtins.attrValues (
          builtins.mapAttrs (
            name: svc:
            let
              hasMeta = svc ? meta;
              m = svc.meta or { };

              missing =
                field:
                if hasMeta && m ? ${field} then
                  [ ]
                else
                  [ "${name}: missing `meta.${field}`." ];
            in
            (if hasMeta then [ ] else [ "${name}: has no `meta` attribute." ])
            ++ missing "summary"
            # optionRoot is where the mechanism reaches for `.backup` and
            # `.mount`. Without it a host fails deep inside a rebuild rather
            # than here.
            ++ (if svc ? module then missing "optionRoot" else [ ])
          ) self.ryraServices
        )
      );
    };
}
