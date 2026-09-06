---
name: nextcloud
description: Operating, restoring and upgrading a ryra-managed Nextcloud.
---

# Nextcloud

## A restore needs two repositories, not one

`ryra-backup-nextcloud` covers `/var/lib/nextcloud` — **files only**.
The database lives in the cluster-wide `pg_dumpall` taken by the postgresql
service, in a different restic repository with a different passphrase. Restoring
files alone gives you a Nextcloud that starts, serves a login page, and knows
about no users or shares.

Restore order that works: stop nginx and phpfpm, restore the database dump,
restore the data directory, then `nextcloud-occ maintenance:mode --off`.
Restoring files onto a newer database schema than they were taken with is the
one ordering that silently half-works.

The file repository has the same provider-neutral helper as every service:

```
sudo ryra-backup-nextcloud snapshots
sudo ryra-backup-nextcloud backup
sudo ryra-backup-nextcloud restore <snapshot>
```

## Upgrade one major at a time

Nextcloud refuses to skip a major version, and NixOS will happily offer you a
package two majors ahead. The failure is not at build time — it is `occ upgrade`
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
