# Turn qualified service names into modules, certificates, backups and state.
# This function returns a module because imports cannot depend on config.
{
  # Registry name -> path to a registry root. The key is the namespace:
  # `{ ryra = ...; acme = ...; }` makes "ryra/nextcloud" and "acme/nextcloud"
  # both addressable, and distinct.
  registries,

  # Optional upstream application modules, pinned by the host.
  selfhostblocks ? null,

  # Services to run, keyed by QUALIFIED name: "ryra/nextcloud".
  #
  # No unqualified form here on purpose. A config is read far more often than
  # written, usually by someone (or something) that did not write it, and
  # `nextcloud = { }` answers "from where?" only by knowing an unwritten rule.
  services,

  # The DNS suffix web services hang off: a tailnet's MagicDNS suffix. A
  # machine containing only local tools and loopback services needs none.
  domain ? null,

  # name -> the ssl contract for that name. The host owns this because the
  # provider is a host decision: Tailscale here, ACME elsewhere. It is only
  # called for entries whose metadata names `ssl`; a loopback-only service can
  # therefore run on a machine with no certificate provider at all.
  sslFor ? null,

  # ZFS pool to carve per-service datasets out of, or null to manage none.
  zfsPool ? null,

  # A module consuming `ryra.services.state`. Kept separate from the service
  # compositor so a Btrfs host does not need ZFS options. `zfsPool` selects
  # the compatibility provider for existing hosts.
  stateProvider ? (
    if zfsPool == null then null else import ./state-providers/zfs.nix { inherit zfsPool; }
  ),

  # Backwards-compatible local destination for the default Restic provider.
  # A Ryra organization normally overrides `backupRepositoryFor` below with
  # its default storage target; keeping this argument means existing hosts do
  # not move repositories merely by updating the registry.
  backupRoot ? "/srv/backups",

  # name -> {
  #   path;
  #   environmentFile ? null;
  #   credentialService ? null;
  # }
  #
  # This is the seam between an organization's default storage and the backup
  # implementation. `path` may be a local path, SFTP URL or S3/R2 URL;
  # `environmentFile` carries provider credentials in the format NixOS's
  # Restic module accepts. The repository encryption passphrase is separate
  # and remains in the organization's vault.
  backupRepositoryFor ? (name: { path = "${backupRoot}/${name}"; }),

  # null uses a generated `sops.secrets.restic-<name>` from the organization
  # vault. Another vault provider supplies `name: <password-file-path>`.
  backupPasswordFileFor ? null,

  # A module implementing `ryra.services.backup.requests -> results`. Restic
  # remains the default, but replacing it no longer changes this compositor or
  # any service definition.
  backupProvider ? (import ./backup-providers/restic.nix {
    repositoryFor = backupRepositoryFor;
    passwordFileFor = backupPasswordFileFor;
    onCalendar = backupOnCalendar;
    retention = backupRetention;
  }),

  backupOnCalendar ? "hourly",
  backupRetention ? {
    keep_within = "1d";
    keep_hourly = 24;
    keep_daily = 7;
    keep_weekly = 4;
    keep_monthly = 6;
  },
}:

{ config, lib, options, pkgs, ... }:

let
  inherit (lib) mkMerge mapAttrsToList getAttrFromPath;

  contracts = import ./contracts { inherit lib; };

  # "ryra/nextcloud" -> { registry = "ryra"; service = "nextcloud"; }
  #
  # Purely syntactic, and it never falls back. An unknown namespace is an
  # error, not a search across the other registries: adding a registry must not
  # be able to change what an existing name already means.
  #
  # Returns a value rather than throwing, so that three bad names produce three
  # complaints in one evaluation instead of one complaint three times. Same
  # reason `.#validate` returns a list: this is read by agents, and a stack
  # trace naming the first casualty is the least useful shape available.
  parse =
    qualified:
    let
      parts = lib.splitString "/" qualified;
      registry = builtins.elemAt parts 0;
      have = lib.concatStringsSep ", " (builtins.attrNames registries);
    in
    if builtins.length parts != 2 then
      {
        ok = false;
        problem = "`${qualified}` is not a qualified name. Write `<registry>/<service>`, for example `ryra/${qualified}`.";
      }
    else if !(registries ? ${registry}) then
      {
        ok = false;
        problem = "no registry named `${registry}`. Registries available here: ${have}.";
      }
    else
      {
        ok = true;
        problem = null;
        inherit registry;
        service = builtins.elemAt parts 1;
      };

  # Everything known about one enabled service WITHOUT LOOKING AT `config`.
  #
  # That restriction is the whole reason this function is shaped like it is.
  # `imports` is evaluated before the module fixpoint exists, so anything it
  # touches must be derivable from the flake alone. Facts that need `config`
  # are deliberately NOT in here: see `wire` below. Mixing the two in one
  # attrset would leave `imports = filter (s: s.backsUp) enabled` looking
  # perfectly reasonable and blowing the evaluator's stack, with laziness the
  # only thing standing between the two.
  #
  # Read from the registry's FLAKE OUTPUT, not from a file beside the module.
  # There is no manifest to disagree with the definition.
  resolve =
    qualified: opts:
    let
      ref = parse qualified;
      registry = if ref.ok then registries.${ref.registry} else null;
      svc = if ref.ok then registry.ryraServices.${ref.service} or null else null;

      # The running thing is named for the SERVICE, not for the registry that
      # defined it. `ryra-nextcloud.tailnet.ts.net` would be absurd as a URL,
      # and moving a definition between registries must not rewrite the data
      # paths under a live box.
      name = opts.name or ref.service or qualified;
    in
    {
      inherit qualified name svc ref;
      registry = ref.registry or null;
      service = ref.service or null;

      subdomain = opts.subdomain or name;
      settings = opts.settings or { };

      # Optional ownership overrides for generated datasets.
      dataset = opts.dataset or { };

      # Option namespace used to connect the service to its providers.
      optionRoot = svc.meta.optionRoot or null;
      shbModule = svc.meta.shbModule or null;
    };

  resolved = mapAttrsToList resolve services;

  # Every complaint about the enable list, gathered before anything is wired.
  problems =
    map (s: "ryra.services: ${s.ref.problem}") (builtins.filter (s: !s.ref.ok) resolved)
    ++ map (
      s:
      "ryra.services: registry `${s.registry}` has no service `${s.service}`. It offers: ${
        lib.concatStringsSep ", " (builtins.attrNames (registries.${s.registry}.ryraServices or { }))
      }."
    ) (builtins.filter (s: s.ref.ok && s.svc == null) resolved)
    ++ map (
      s: "ryra.services: `${s.qualified}` has no package or deployment module."
    ) (builtins.filter (s: s.svc != null && !(s.svc ? module) && !(s.svc ? package)) resolved)
    ++ map (
      s: "ryra.services: `${s.qualified}` has no `meta.optionRoot`, so nothing can be wired to it."
    ) (builtins.filter (s: s.svc != null && s.svc ? module && s.optionRoot == null) resolved);

  # Only sound entries reach the wiring. A broken one would otherwise produce a
  # second, uglier failure on top of the assertion that already explains it.
  enabled = builtins.filter (s: s.svc != null && s.svc ? module && s.optionRoot != null) resolved;
  packages = builtins.filter (s: s.svc != null && s.svc ? package) resolved;

  # The other half: a service seen THROUGH the evaluated config. Only legal
  # inside `config`, which is exactly where these are used, and unavailable
  # anywhere else because they are not attributes of a resolved service.
  configOf = s: getAttrFromPath s.optionRoot config;
  declaredOptionsOf = s: getAttrFromPath s.optionRoot options;

  # Asked of the module's declared OPTIONS, not repeated in metadata: a service
  # backs up if it exposes a backup requester, so that fact cannot drift out of
  # step with the module. Inspecting `options` rather than `config` is also
  # load-bearing now that the result is routed back to that same option: asking
  # config whether backup exists while defining backup.result is a module
  # fixpoint cycle.
  backsUp = s: (declaredOptionsOf s) ? backup;

  # Unlike backup, this has to be known before evaluating the service module:
  # `sslFor` may reach into another provider's config, while a service with no
  # public listener should never cause that provider to be evaluated. `needs`
  # already exists for exactly these host prerequisites, so it is the one
  # authored fact rather than a second `public = true` flag beside it.
  needsSsl = s: builtins.elem "ssl" (s.svc.meta.needs or [ ]);

  # Stateful services declare paths explicitly; not every module exposes mount.
  declaresState = s: config.ryra.services.state ? ${s.name};
  stateless = s: s.svc.meta.stateless or false;

  # Two definitions of the same underlying service both want subdomain
  # `nextcloud`, state name `nextcloud` and the sops key
  # `nextcloud/adminpass`. Catch it here: the alternative is two units quietly
  # fighting over /var/lib/nextcloud on a machine that is already serving.
  duplicates =
    let
      names = map (s: s.name) enabled;
    in
    lib.unique (lib.subtractLists (lib.unique names) names);

  needsShb = builtins.filter (s: s.shbModule != null) enabled;
  needsCertificates = builtins.filter needsSsl enabled;
  setupProblems = problems
    ++ lib.optional (needsShb != [ ] && selfhostblocks == null)
      "ryra.services: ${lib.concatStringsSep ", " (map (s: s.qualified) needsShb)} requires `selfhostblocks`. Pass the host's flake input."
    ++ lib.optional (needsCertificates != [ ] && domain == null)
      "ryra.services: ${lib.concatStringsSep ", " (map (s: s.qualified) needsCertificates)} requests SSL but `domain` is null. Pass the DNS suffix its URL uses."
    ++ lib.optional (needsCertificates != [ ] && sslFor == null)
      "ryra.services: ${lib.concatStringsSep ", " (map (s: s.qualified) needsCertificates)} requests SSL but `sslFor` is null. Pass a certificate provider.";

in
# Imports and unknown option definitions fail before NixOS assertions run.
if setupProblems != [ ] then
  throw (lib.concatStringsSep "\n" setupProblems)
else
{
  imports =
    lib.optionals (needsShb != [ ]) (
      # Load upstream contract helpers before the application modules.
      [ selfhostblocks.nixosModules.lib ]
      ++ map (s: selfhostblocks.nixosModules.${s.shbModule}) needsShb
    )
    ++ lib.optionals (backupProvider != null) [ backupProvider ]
    ++ lib.optionals (stateProvider != null) [ stateProvider ]
    ++ map (
      s:
      s.svc.module {
        inherit (s) name subdomain settings;
        inherit contracts;
        # Keep the value structurally acceptable to application modules so the
        # assertion below can give the useful error when a web service omitted
        # its domain. Local-only modules never inspect it.
        domain = if domain == null then "" else domain;
        ssl = if sslFor != null && needsSsl s then sslFor s.name else null;
      }
    ) enabled;

  options.ryra.services = {
    names = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        The unqualified name of every enabled service, including local-only
        services and command-line tools.
      '';
    };

    certificateNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        Enabled services that request SSL. A host derives certificates from
        this list, so a loopback-only service neither gets nor requires one.
      '';
    };

    state = lib.mkOption {
      default = { };
      description = ''
        Where each service keeps state that cannot be rebuilt from the flake.

        A service sets its own entry. A machine state provider may turn these
        into individual datasets; the Btrfs base instead snapshots the parent
        `/var/lib` subvolume before every switch.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            path = lib.mkOption {
              type = lib.types.str;
              description = "Directory holding the state.";
            };
            owner = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "User that must be able to write it.";
            };
            group = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Group that must be able to write it.";
            };
          };
        }
      );
    };

    backup = {
      requests = lib.mkOption {
        type = lib.types.attrsOf contracts.backup.contract.request.type;
        default = { };
        internal = true;
        description = ''
          Backup requests keyed by running service name. A backup provider
          consumes these without knowing where each service's options live.
        '';
      };

      results = lib.mkOption {
        type = lib.types.attrsOf contracts.backup.contract.result.type;
        default = { };
        internal = true;
        description = ''
          Provider results keyed by running service name. The mechanism wires
          each result back to the service that made the request.
        '';
      };

      onCalendar = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        internal = true;
        description = "Per-service backup schedule overrides.";
      };
    };

    resolved = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.unspecified);
      readOnly = true;
      internal = true;
      description = ''
        Every enabled service as data, including the option path it lives at.
        Nothing reads this yet. It exists because a generic conformance test
        binds to a provider by option path rather than by name, so keeping the
        paths addressable is what makes that test cheap to add later.
      '';
    };
  };

  config = mkMerge [
    {
      environment.systemPackages = map (s: s.svc.package pkgs) packages;
      ryra.services.names = lib.unique (map (s: s.name) (enabled ++ packages));
      ryra.services.certificateNames = map (s: s.name) (builtins.filter needsSsl enabled);
      ryra.services.resolved = map (s: {
        inherit (s)
          qualified
          name
          registry
          optionRoot
          ;
      }) enabled;

      assertions = [
        {
          assertion =
            stateProvider == null
            || builtins.all (s: declaresState s || stateless s) enabled;
          message = "ryra.services: ${
            lib.concatStringsSep ", " (
              map (s: s.qualified) (
                builtins.filter (s: !(declaresState s) && !(stateless s)) enabled
              )
            )
          } does not say where its state lives. Set `ryra.services.state.<name>` in the service module, or `meta.stateless = true` if it genuinely keeps nothing on disk. A state provider cannot protect a path it has to guess.";
        }
        {
          assertion = duplicates == [ ];
          message = "ryra.services: more than one definition claims the name(s) ${lib.concatStringsSep ", " duplicates}. Two services with one name would share a subdomain, state entry, backup repository and sops keys. Set `name` on one of them.";
        }
        {
          assertion = backupProvider != null || builtins.filter backsUp enabled == [ ];
          message = "ryra.services: a service requests backups but `backupProvider` is null. Pass a module that consumes `ryra.services.backup.requests` and provides matching `ryra.services.backup.results`.";
        }
      ];
    }

    # Provider-neutral backup bus. Services publish requests here; the selected
    # provider publishes results; those results are then returned to the exact
    # requester option that originated them.
    {
      ryra.services.backup.requests = lib.listToAttrs (
        map (
          s:
          lib.nameValuePair s.name (configOf s).backup.request
        ) (builtins.filter backsUp enabled)
      );

      ryra.services.backup.onCalendar = lib.listToAttrs (
        map (
          s:
          lib.nameValuePair s.name (s.settings.backupOnCalendar or backupOnCalendar)
        ) (builtins.filter backsUp enabled)
      );
    }

    (lib.mkIf (backupProvider != null) (
      mkMerge (
        map (
          s:
          lib.setAttrByPath (s.optionRoot ++ [ "backup" "result" ])
            config.ryra.services.backup.results.${s.name}
        ) (builtins.filter backsUp enabled)
      )
    ))
  ];
}
