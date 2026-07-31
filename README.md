# ryra-services

A registry of self-hostable services, as NixOS aspects. One folder per service;
a host enables them by qualified name.

## Standing on Self Host Blocks

[Self Host Blocks](https://github.com/ibizaman/selfhostblocks) already solved
the hard part, and this registry is a thin thing sitting on top of it rather
than an alternative to it. What we take, deliberately and without improving on
it:

**Contracts are the whole abstraction.** A service does not know who provides
its certificate, its secrets or its backups. It publishes a `.request` and
consumes a `.result`, and the host wires providers to consumers:

```nix
shb.sops.secret."nextcloud/adminpass".request = config.shb.nextcloud.adminPass.request;
shb.nextcloud.adminPass.result = config.shb.sops.secret."nextcloud/adminpass".result;
```

This is why a registry is possible at all. A service definition that reached
directly for `sops.secrets."..."` or an ACME certificate path could not be moved
between hosts; one that speaks the contract can.

**Blocks and services are different things.** A block (ssl, backup, secrets,
ldap, sso, monitoring, database) is infrastructure the host configures once. A
service is an application that consumes blocks. This registry ships *services*.
Blocks come from SHB, or from the host when SHB has none — `ryra.tailscale` in
`hetzner-nixos-uefi` is a home-grown SSL contract provider whose
`certs.<n>` deliberately has the same shape as `shb.certs.certs.selfsigned.<n>`,
so a service swaps providers by one line.

**The contract shape is small enough to reimplement.** The SSL contract is
three fields: `paths.cert`, `paths.key`, `systemdService`. That is the entire
reason a Tailscale-issued certificate can be dropped into
`shb.nextcloud.ssl`.

**Options are namespaced and enable-gated**, so importing a module you do not
use costs nothing. That is what lets the mechanism import SHB modules on the
service's behalf instead of making the host maintain an import list.

Where we depart, and why:

- **`manifest.toml`.** SHB has no equivalent, and does not need one: it is
  consumed only by Nix. A registry has to be listable and searchable by tooling
  that has no nixpkgs and no thirty seconds to evaluate one. The manifest
  duplicates facts that also appear in `service.nix`, on purpose.
- **`SKILL.md` per service.** SHB documents in a manual; the old ryra registry
  documented in dense TOML comments and had exactly one `.md` in the whole
  repo. Neither leaves a home for "a restore needs both repositories" or
  "upgrade one major at a time" — the knowledge you need at 2am, not the
  knowledge you need while writing the module.
- **Qualified names.** SHB is one upstream tree, so `shb.nextcloud` is
  unambiguous. Several registries per org is the premise here, so the
  definition is identified as `ryra/nextcloud`.

## Layout

```
flake.nix                     input-free; exports the mechanism and the registry
lib/services-module.nix       ryra.services: enable list -> aspects, certs, datasets
services/<name>/
├── manifest.toml             what tooling can know without evaluating Nix
├── service.nix               the aspect, as a function of (name, domain, ssl, ...)
├── SKILL.md                  operational knowledge: restore, upgrade traps
└── secrets.example.yaml      the sops keys this service expects
```

## Names are qualified, always

A service is `<registry>/<service>`: `ryra/nextcloud`, `acme/internal-wiki`.

There is no unqualified form in a config file. `nextcloud = { };` answers "from
which registry?" only by knowing an unwritten default rule, and a config is read
far more often than it is written, usually by someone who did not write it. The
CLI may accept `ryra add nextcloud` as shorthand; what it writes to disk is
qualified.

Resolution is purely syntactic and never falls back. An unknown namespace is an
error, not a search across the other registries — otherwise adding a registry
could silently change what an existing name means.

Qualification identifies the *definition*. It does not name the *running thing*:
the subdomain, the ZFS dataset and the sops keys are all `nextcloud`, because
`ryra-nextcloud.tailnet.ts.net` would be absurd and because moving a definition
between registries must not rewrite the data paths under a live box.

## Using it from a host

The mechanism is a function returning a module, not a module. `imports` may not
depend on `config`, so an enable list read from an option could never decide
which aspect files to pull in.

```nix
# modules/profiles/services.nix
{
  flake.modules.nixos.ryra-services =
    { config, ... }:
    {
      imports = [
        (inputs.ryra-services.nixosModules.services {
          registries = { ryra = inputs.ryra-services; };
          selfhostblocks = inputs.selfhostblocks;

          domain = "cobbler-tuna.ts.net";
          zfsPool = "rpool";
          sslFor = name: config.ryra.tailscale.certs.${name};

          services = {
            "ryra/nextcloud" = { };
          };
        })
      ];

      # One certificate per service, derived rather than listed twice.
      ryra.tailscale.certs = builtins.listToAttrs (
        map (n: { name = n; value = { }; }) config.ryra.services.names
      );
    };
}
```

Adding a service is then one line in `services`. The aspect is imported, the SHB
module it needs is imported, its certificate is requested and its dataset is
created; removing the line takes all of that with it.
