# Authelia

Optional shared sign-in backed by a private LLDAP directory. Application accounts and custom OIDC providers work independently of this service.

Setup collects your initial username, email and password in the organization's vault. Choose a stable HTTPS origin through the app's reviewed private access route or a public domain. Internal keys and app client credentials are generated on the machine and retained with the directory and sign-in databases under `/var/lib/ryra-auth`. Keep the service backup and its vault encryption password together: losing the signing or storage keys cannot be repaired by generating replacements.

The initial person belongs to `service_users`, `service_admins` and `lldap_admin`. The generated directory administrator and Authelia reader cannot sign in to ordinary apps. Setup preserves established human passwords on retry. Initial setup does not delete other people or groups.

Manage people and change passwords with the same human login in LLDAP's private UI. From Ryra, open `http://127.0.0.1:17170` through the machine's encrypted browser connection, for example `ryra browser http://127.0.0.1:17170 --remote HOST`. This address belongs to the service machine. The directory port stays on loopback and is never published. Add ordinary people to `service_users`; use `service_admins` only for app administration. Directory management additionally requires `lldap_admin`.

Backups briefly stop both authentication services, snapshot both SQLite databases and preserve every generated key and client credential. Restores keep the writers stopped while restoring the complete set, then restart and require Authelia's health check to succeed. Filesystem notifications are retained locally by default; set `settings.notifier` explicitly before enabling email password reset.
