---
name: linkding
description: Operating and backing up a Ryra-managed Linkding.
---

# Linkding

The default address is `http://127.0.0.1:8081` on the service machine. Reach it
through Ryra's encrypted machine connection. Public access uses a declared domain
with automatic HTTPS. The backend remains on loopback port 9090.

Linkding handles browser logins and API tokens itself. The initial administrator
credentials come from the `linkding-admin` vault secret, delivered as an
EnvironmentFile containing `LD_SUPERUSER_NAME` and `LD_SUPERUSER_PASSWORD`.
Manage users and subsequent password changes inside Linkding.

With the default SQLite backend, bookmarks, database, keys, previews and assets
live under `/var/lib/linkding`. Its backup restores that directory together:

```sh
sudo ryra-backup-linkding snapshots
sudo ryra-backup-linkding backup
sudo ryra-backup-linkding restore <snapshot>
```

Changing to an external database requires adding that database to the backup and
restore hooks. Copying the app's directory alone then stops being sufficient.
