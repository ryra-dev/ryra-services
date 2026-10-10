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

Set the recipe's `settings.package` explicitly, go one major, let it settle, then
go again.

## Access and accounts

The default address is `http://127.0.0.1:8082` on the service machine, reached
through Ryra's encrypted connection. Public access uses a declared domain with
automatic HTTPS. PostgreSQL, Redis and PHP are configured by the native NixOS
module. Nextcloud keeps its own users and login; no separate identity service
is required. The initial `admin` password is the `nextcloud-adminpass` vault
secret. Manage additional accounts and subsequent passwords inside Nextcloud.
