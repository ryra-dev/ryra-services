# The mechanism: turn a list of qualified service names into a NixOS config.
#
# This is a FUNCTION returning a module, not a module. That is forced by the
# module system: `imports` may not depend on `config`, so an enable list read
# from an option could never decide which aspect files to pull in. Taking the
# list as an argument sidesteps it entirely and costs one extra pair of
# parentheses at the call site.
#
# What it closes, relative to writing aspects by hand:
#
#   - the service's aspect file is imported from the registry, not the host
#   - `ryra.tailscale.certs.<n> = { }` (or whatever ssl provider) is derived
#   - the `<pool>/safe/<n>` dataset is derived, when the manifest says stateful
#   - the selfhostblocks module the service needs is imported
#
# so that adding a service is one line in the host, and removing it leaves
# nothing behind.
{
  # Attrset of registry name -> path to a registry root. The key is the
  # namespace: `{ ryra = ...; acme = ...; }` makes "ryra/nextcloud" and
  # "acme/nextcloud" both addressable, and distinct.
  registries,

  # The host's selfhostblocks flake. One revision per box, always the host's:
  # a registry pinning its own would put two option trees on one machine.
  selfhostblocks,

  # Services to run, keyed by QUALIFIED name: "ryra/nextcloud".
  #
  # There is no unqualified form here on purpose. A config file is read far
  # more often than it is written, usually by someone who did not write it, and
  # `nextcloud = { }` answers "from where?" only by knowing an unwritten
  # default rule. The CLI expands the shorthand; the file it writes does not
  # keep it.
  services,

  # The DNS suffix every service hangs off. A tailnet's MagicDNS suffix here.
  domain,

  # name -> the SHB ssl contract for that name. The host owns this because the
  # provider is a host decision: Tailscale here, ACME or self-signed elsewhere.
  # `null` means no service may request ssl.
  sslFor ? null,

  # ZFS pool to carve per-service datasets out of, or null to manage none.
  zfsPool ? null,

  # Where restic repositories live.
  backupRoot ? "/srv/backups",
}:

{ config, lib, ... }:

let
  inherit (lib) mkMerge mapAttrsToList;

  # "ryra/nextcloud" -> { registry = "ryra"; service = "nextcloud"; }
  #
  # Purely syntactic, and it never falls back: an unparseable or unknown
  # namespace is an error, not a search across the other registries. A registry
  # you add must not be able to change what an existing name means.
  parse =
    qualified:
    let
      parts = lib.splitString "/" qualified;
    in
    if builtins.length parts != 2 then
      throw "ryra.services: `${qualified}` is not a qualified service name (expected `<registry>/<service>`)"
    else if !(registries ? ${builtins.elemAt parts 0}) then
      throw "ryra.services: no registry named `${builtins.elemAt parts 0}` (have: ${lib.concatStringsSep ", " (builtins.attrNames registries)})"
    else
      {
        registry = builtins.elemAt parts 0;
        service = builtins.elemAt parts 1;
      };

  # Everything known about one enabled service, resolved once.
  resolve =
    qualified: opts:
    let
      ref = parse qualified;
      dir = "${registries.${ref.registry}}/services/${ref.service}";
      manifest = builtins.fromTOML (builtins.readFile "${dir}/manifest.toml");

      # The running thing is named for the SERVICE, not for the registry that
      # defined it. `ryra-nextcloud.tailnet.ts.net` would be absurd as a URL,
      # and moving a definition between registries must not rewrite the data
      # paths underneath a live box.
      name = opts.name or ref.service;
    in
    {
      inherit qualified name dir manifest;
      inherit (ref) registry service;
      subdomain = opts.subdomain or name;
      stateful = manifest.service.stateful or false;
      shbModule = manifest.service.shb-module or null;
      settings = opts.settings or { };
    };

  enabled = mapAttrsToList resolve services;

  # Two definitions of the same underlying service both want subdomain
  # `nextcloud`, dataset `safe/nextcloud` and the sops key `nextcloud/adminpass`.
  # Catch it here: the alternative is two units quietly fighting over
  # /var/lib/nextcloud on a live box, which is miserable to diagnose.
  duplicates =
    let
      names = map (s: s.name) enabled;
    in
    lib.subtractLists (lib.unique names) names;

in
{
  imports =
    # SHB modules are option-declaring, so they must be real imports. They are
    # all enable-gated, so importing one the host does not use is free.
    map (s: selfhostblocks.nixosModules.${s.shbModule}) (builtins.filter (s: s.shbModule != null) enabled)
    ++ map (
      s:
      import "${s.dir}/service.nix" {
        inherit (s) name subdomain settings;
        inherit domain backupRoot;
        ssl = if sslFor == null then null else sslFor s.name;
      }
    ) enabled;

  options.ryra.services.names = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    description = ''
      The unqualified name of every enabled service. The host reads this to
      issue one certificate per service, so the cert list cannot drift out of
      step with the service list.
    '';
  };

  config = mkMerge [
    {
      assertions = [
        {
          assertion = duplicates == [ ];
          message = "ryra.services: more than one definition claims the name(s) ${lib.concatStringsSep ", " (lib.unique duplicates)}. Set `name` on one of them to disambiguate.";
        }
      ];
    }

    # One dataset per stateful service, under safe/ so the pre-switch snapshot
    # hook covers it. Rebuildable state does not belong here.
    (lib.mkIf (zfsPool != null) {
      shb.zfs.pools.${zfsPool}.datasets = lib.listToAttrs (
        map (
          s:
          lib.nameValuePair "safe/${s.name}" (
            {
              enable = true;
              path = s.manifest.service.dataDir or "/var/lib/${s.name}";
            }
            // lib.optionalAttrs (s.manifest.service ? owner) {
              owner = s.manifest.service.owner;
              group = s.manifest.service.group or s.manifest.service.owner;
            }
          )
        ) (builtins.filter (s: s.stateful) enabled)
      );
    })

    # Names the host must issue certificates for. Read this rather than keeping
    # a second list in step with the enable list by hand.
    { ryra.services.names = map (s: s.name) enabled; }
  ];
}
