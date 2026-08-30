{
  description = "ryra-services — a registry of self-hostable services as NixOS aspects";

  # Deliberately input-free.
  #
  # A registry describes services; it does not pin the world they run in. The
  # HOST owns nixpkgs and selfhostblocks and hands its selfhostblocks to the
  # mechanism. Two revisions of SHB on one box is not a thing that can be made
  # to work, so there is exactly one, and it is the host's.
  #
  # It also keeps `nix flake lock` meaningful on a consumer: updating this
  # input moves the service definitions and nothing else.
  outputs =
    { self }:
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
      # `builtins` rather than `lib.filterAttrs` because this flake takes no inputs on purpose:
      # a registry describes services, it does not pin the world they run in.
      entries = builtins.readDir ./services;
      names = builtins.filter (n: entries.${n} == "directory") (builtins.attrNames entries);
    in
    {
      # The mechanism: turns an enable list into imported aspects,
      # certificates, backups and datasets.
      nixosModules.services = import ./lib/services-module.nix;

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
      #   nix eval --json .#services.nextcloud.meta
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
      index = builtins.mapAttrs (_: svc: svc.meta) self.ryraServices;

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
            ++ (if svc ? module then [ ] else [ "${name}: has no `module` attribute." ])
            ++ missing "summary"
            # optionRoot is where the mechanism reaches for `.backup` and
            # `.mount`. Without it a host fails deep inside a rebuild rather
            # than here.
            ++ missing "optionRoot"
          ) self.ryraServices
        )
      );
    };
}
