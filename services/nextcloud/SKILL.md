---
name: nextcloud
description: Operating, restoring and upgrading a Ryra-managed Nextcloud.
---

# Nextcloud

## Back up files and the database together

`ryra-backup-nextcloud backup` enables maintenance mode, dumps Nextcloud's
PostgreSQL database into its private state directory, and snapshots that directory.
It disables maintenance mode when the backup finishes.

Restore with the same Nextcloud version that created the snapshot. The helper
restores the files and database, updates the data fingerprint, then leaves
maintenance mode. A failed restore leaves maintenance mode enabled so an
incomplete recovery cannot accept writes. Fix the reported failure and retry.

```
sudo ryra-backup-nextcloud snapshots
sudo ryra-backup-nextcloud backup
sudo ryra-backup-nextcloud restore <snapshot>
```

## Upgrade one major at a time

Nextcloud refuses to skip a major version, and NixOS will happily offer you a
package two majors ahead. The failure is not at build time: it is `occ upgrade`
refusing at activation, after the switch has already moved everything else.

Pin `services.nextcloud.package` explicitly, go one major, let it settle, then
go again.

## The two aliased secrets

`nextcloud-ldap_admin_password` and `authelia-nextcloud_sso_secret` are declared
with `settings.key` pointing at `lldap-user_password` and `nextcloud-sso-secret`
respectively. They are not independent values: Nextcloud binds to LLDAP as its
admin user, and Nextcloud and Authelia must agree on one OIDC client secret.

Generating fresh values for them instead of aliasing produces a service that
starts cleanly, passes every health check, and cannot log anybody in. If SSO
breaks after a secrets rotation, check the alias before checking anything else.

## fallbackDefaultAuth is a deliberate escape hatch

`apps.sso.fallbackDefaultAuth = true` keeps Nextcloud's own admin login
reachable. Without it, an Authelia that fails to start locks every account out
of Nextcloud, including the one that could fix it. Leave it on.
