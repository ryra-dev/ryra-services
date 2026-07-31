# The mechanism: turn a list of qualified service names into a NixOS config.
#
# THE POINT OF THIS FILE. Self Host Blocks has no matching engine, on purpose:
# every contract connection there is two manual assignments, and its own docs
# own that as a design choice. That is correct for a library and miserable for
# a registry. Roughly sixty of the hundred lines in a hand-written service
# aspect are the same plumbing every time: request a certificate, request a
# restic repository, request the passphrase for that repository, carve a
# dataset for the data directory. This file writes all of it, so a service
# definition contains only what is true about that service.
#
# This is a FUNCTION returning a module, not a module. Forced by the module
# system: `imports` may not depend on `config`, so an enable list read from an
# option could never decide which files to pull in.
#
# Written for agents first. Every failure below is an eval-time assertion that
# says what to do about it, because the alternative is an agent discovering the
# problem as two systemd units fighting over a directory on a live box.
{
  # Registry name -> path to a registry root. The key is the namespace:
  # `{ ryra = ...; acme = ...; }` makes "ryra/nextcloud" and "acme/nextcloud"
  # both addressable, and distinct.
  registries,

  # The host's selfhostblocks flake, or null.
  #
  # We own the contracts; SHB still owns most service IMPLEMENTATIONS, and a
  # registry entry is allowed to be a thin wiring of one. Our contracts are
  # structurally identical to SHB's, so they typecheck straight into its
  # modules. When an entry stops needing SHB it drops `shb-module` from its
  # manifest and nothing at the host changes.
  selfhostblocks ? null,

  # Services to run, keyed by QUALIFIED name: "ryra/nextcloud".
  #
  # No unqualified form here on purpose. A config is read far more often than
  # written, usually by someone (or something) that did not write it, and
  # `nextcloud = { }` answers "from where?" only by knowing an unwritten rule.
  services,

  # The DNS suffix every service hangs off: a tailnet's MagicDNS suffix.
  domain,

  # name -> the ssl contract for that name. The host owns this because the
  # provider is a host decision: Tailscale here, ACME elsewhere.
  sslFor ? null,

  # ZFS pool to carve per-service datasets out of, or null to manage none.
  zfsPool ? null,

  # Where restic repositories live, and how often they run. Defaulted once
  # here rather than copy-pasted into every service definition.
  backupRoot ? "/srv/backups",
  backupOnCalendar ? "hourly",
  backupRetention ? {
    keep_within = "1d";
    keep_hourly = 24;
    keep_daily = 7;
    keep_weekly = 4;
    keep_monthly = 6;
  },
}:

{ config, lib, ... }:

let
  inherit (lib) mkMerge mapAttrsToList getAttrFromPath;

  contracts = import ./contracts { inherit lib; };

  # "ryra/nextcloud" -> { registry = "ryra"; service = "nextcloud"; }
  #
  # Purely syntactic, and it never falls back. An unknown namespace is an
  # error, not a search across the other registries: adding a registry must not
  # be able to change what an existing name already means.
  parse =
    qualified:
    let
      parts = lib.splitString "/" qualified;
      have = lib.concatStringsSep ", " (builtins.attrNames registries);
    in
    if builtins.length parts != 2 then
      throw "ryra.services: `${qualified}` is not a qualified name. Write `<registry>/<service>`, for example `ryra/${qualified}`."
    else if !(registries ? ${builtins.elemAt parts 0}) then
      throw "ryra.services: no registry named `${builtins.elemAt parts 0}`. Registries available here: ${have}."
    else
      {
        registry = builtins.elemAt parts 0;
        service = builtins.elemAt parts 1;
      };

  # Everything known about one enabled service, resolved once.
  #
  # Read from the registry's FLAKE OUTPUT, not from a file beside the module.
  # There is no manifest to disagree with the definition, and anything the
  # module can answer for itself is asked of the module rather than declared
  # twice.
  resolve =
    qualified: opts:
    let
      ref = parse qualified;
      registry = registries.${ref.registry};
      svc =
        registry.ryraServices.${ref.service} or (throw
          "ryra.services: registry `${ref.registry}` has no service `${ref.service}`. It offers: ${
            lib.concatStringsSep ", " (builtins.attrNames (registry.ryraServices or { }))
          }.");

      # The running thing is named for the SERVICE, not for the registry that
      # defined it. `ryra-nextcloud.tailnet.ts.net` would be absurd as a URL,
      # and moving a definition between registries must not rewrite the data
      # paths under a live box.
      name = opts.name or ref.service;
    in
    rec {
      inherit qualified name;
      inherit (ref) registry service;
      inherit (svc) meta module;

      subdomain = opts.subdomain or name;
      settings = opts.settings or { };

      # Where the service's options live. NOT derivable: selfhostblocks'
      # nextcloud-server.nix declares shb.nextcloud, and the mechanism must
      # reach <optionRoot>.backup and <optionRoot>.mount to wire anything.
      optionRoot = meta.optionRoot;
      options = getAttrFromPath optionRoot config;

      shbModule = meta.shbModule or null;

      # Asked of the module, not declared in metadata. A service backs up if it
      # exposes a backup requester; it is stateful if it says where its state
      # lives. Neither fact can drift out of step with the module, because
      # neither is written down twice.
      backsUp = options ? backup;
      stateful = options ? mount;
    };

  enabled = mapAttrsToList resolve services;

  # Two definitions of the same underlying service both want subdomain
  # `nextcloud`, dataset `safe/nextcloud` and the sops key
  # `nextcloud/adminpass`. Catch it here: the alternative is two units quietly
  # fighting over /var/lib/nextcloud on a machine that is already serving.
  duplicates =
    let
      names = map (s: s.name) enabled;
    in
    lib.unique (lib.subtractLists (lib.unique names) names);

  needsShb = builtins.filter (s: s.shbModule != null) enabled;

in
{
  imports =
    lib.optionals (needsShb != [ ]) (
      # Injects `shb` as a module arg. Without it every `shb.contracts.*`
      # reference in an SHB service module is an undefined variable, so this is
      # not optional the moment any entry names an shb-module.
      [ selfhostblocks.nixosModules.lib ]
      ++ map (s: selfhostblocks.nixosModules.${s.shbModule}) needsShb
    )
    ++ map (
      s:
      s.module {
        inherit (s) name subdomain settings;
        inherit domain contracts;
        ssl = if sslFor == null then null else sslFor s.name;
      }
    ) enabled;

  options.ryra.services = {
    names = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = ''
        The unqualified name of every enabled service. The host reads this to
        issue one certificate per service, so the certificate list cannot drift
        out of step with the service list.
      '';
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
      ryra.services.names = map (s: s.name) enabled;
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
          assertion = duplicates == [ ];
          message = "ryra.services: more than one definition claims the name(s) ${lib.concatStringsSep ", " duplicates}. Two services with one name would share a subdomain, a dataset and a set of sops keys. Set `name` on one of them.";
        }
        {
          assertion = needsShb == [ ] || selfhostblocks != null;
          message = "ryra.services: ${(builtins.head needsShb).qualified} is implemented by the selfhostblocks module `${(builtins.head needsShb).shbModule}`, but no `selfhostblocks` was passed to the mechanism. Pass the host's flake input.";
        }
        {
          assertion = sslFor != null || enabled == [ ];
          message = "ryra.services: services are enabled but `sslFor` is null, so none of them can be given a certificate. Pass a provider, for example `sslFor = name: config.ryra.tailscale.certs.\${name};`.";
        }
      ];
    }

    # Backup. The requester already knows what to back up and as which user, so
    # a provider only supplies a repository and a schedule: that is the entire
    # reason no service definition in this registry mentions restic.
    {
      shb.restic.instances = lib.listToAttrs (
        map (
          s:
          lib.nameValuePair s.name {
            request = s.options.backup.request;
            settings = {
              enable = true;
              passphrase.result = config.shb.sops.secret."restic/${s.name}".result;
              repository = {
                path = "${backupRoot}/${s.name}";
                timerConfig = {
                  OnCalendar = s.settings.backupOnCalendar or backupOnCalendar;
                  RandomizedDelaySec = "5m";
                };
              };
              retention = backupRetention;
            };
          }
        ) (builtins.filter (s: s.backsUp) enabled)
      );

      shb.sops.secret = lib.listToAttrs (
        map (
          s:
          lib.nameValuePair "restic/${s.name}" {
            request = config.shb.restic.instances.${s.name}.settings.passphrase.request;
          }
        ) (builtins.filter (s: s.backsUp) enabled)
      );
    }

    # One dataset per stateful service, read from the service's own `mount`
    # output rather than from a path repeated in the manifest. Under safe/ so
    # the pre-switch snapshot covers it; rebuildable state does not belong
    # here.
    (lib.mkIf (zfsPool != null) {
      shb.zfs.pools.${zfsPool}.datasets = lib.listToAttrs (
        map (
          s:
          lib.nameValuePair "safe/${s.name}" (
            {
              enable = true;
              inherit (s.options.mount) path;
            }
            // lib.optionalAttrs (s.options.mount ? owner) {
              inherit (s.options.mount) owner;
              group = s.options.mount.group or s.options.mount.owner;
            }
          )
        ) (builtins.filter (s: s.stateful) enabled)
      );
    })
  ];
}
