Forgejo hosts Git repositories, issues and pull requests. It uses SQLite and the Ryra web contract: private access by default, with optional public HTTPS or Tailscale access. Clone and push over HTTP(S); SSH and public registration are disabled.

The initial administrator is `ryra-admin`, with a generated password in `forgejo-adminpass`. Sign in and change that password, then create other accounts from Forgejo's administration page. `settings.adminUser` and `settings.adminEmail` select the initial account; Forgejo reserves the username `admin`. `settings.adminPasswordFile` can supply a runtime password file. Restarting or applying again preserves an existing account and its password.

Native accounts are the default. Optionally set `auth.mode = "oidc"` to reuse the machine's Authelia and LLDAP sign-in, as with Nextcloud and Grafana. This registers the client and supplies its runtime credentials; it does not install a shared provider. Configure a stable HTTPS URL with `web.externalUrl` or public HTTPS first. An external OIDC provider can instead be supplied through `auth.external`. Shared users get ordinary Forgejo accounts on first sign-in; linking an existing account requires signing into it. The native administrator remains available. Git clients use Forgejo access tokens generated after signing in.

Returning to `auth.mode = "none"` disables shared sign-in while preserving its accounts and links for re-enabling. Shared-only accounts cannot sign in while it is disabled. Keep the same issuer for existing accounts; replacing the identity provider requires migrating its account mappings.

Native login remains available if Forgejo restarts while the issuer is offline. With Forgejo 15, the first shared sign-in after the issuer returns can fail while discovery refreshes; retry sign-in.

The private web port is 8085 and the loopback backend port is 3001. Set `web.port` or `settings.port` if needed. For Git from another machine, use a reachable HTTPS address or forward the private port through SSH. A Ryra browser connection only carries browser traffic.

Hourly encrypted backups briefly stop Forgejo and capture `/var/lib/forgejo`, including repositories, SQLite, attachments and generated encryption keys. The service restarts even if a backup fails. Use `sudo ryra-backup-forgejo backup`, `snapshots`, and `restore SNAPSHOT`. Restore to an empty state directory with the same Forgejo version first; restoring over existing files does not remove newer repositories. Keep the declaration and backup password with your recovery materials.
