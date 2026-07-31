---
name: linkding
description: Operating, backing up and exposing a ryra-managed linkding.
---

# linkding

## Enabling it needs a manual Tailscale step, and nothing tells you first

`tailscale cert` will not issue for a name until that **Tailscale Service is
approved in the admin console**. Until then the certificate unit fails:

```
500 Internal Server Error: invalid domain "linkding.cobbler-tuna.ts.net";
must be one of ["hetzner-fsn1..." "nextcloud..." "authelia..." ...]
```

This is not a linkding problem, it happens for every new service, and it is
the one step in adding a service that no amount of Nix can do for you.
**Approve the Service before switching**, not after.

## A missing certificate takes down the WHOLE web server

This is worth knowing before you find out the way we did.

`modules/ryra/tailscale.nix` orders nginx `after` the certificate units rather
than `requires`, with a comment saying that "one failing cert degrades a single
vhost instead of taking the whole web server down". **That is not what
happens.** nginx refuses to start at all when any vhost references an
`ssl_certificate` path that does not exist, so it hits its restart limit:

```
nginx.service: Start request repeated too quickly.
nginx.service: Failed with result 'start-limit-hit'.
```

and every other service on the box becomes unreachable, not just the new one.
`after` controls ordering; it does nothing about a config file pointing at a
missing file.

So the safe order for adding any service that terminates TLS is: approve the
Tailscale Service, `nixos-rebuild build`, confirm the cert unit can run, then
`switch`. If you are already broken, `nixos-rebuild switch` back to a tree
without the new service restores nginx immediately.

## Backups cover everything, because the state is one directory

linkding on the default sqlite backend keeps the database, the secret key,
favicons, previews and assets all under `/var/lib/linkding`. That is the
`mount`, that is the restic `sourceDirectories`, and restoring that directory
restores the service completely. There is no separate database repository to
remember, which is not true of Nextcloud.

Repository unit name follows restic's path-mangling:

```
restic-backups-linkding_srv_backups_linkding.service
```

Switching the backend to Postgres changes this: the data directory stops being
sufficient and a restore then needs the postgresql dump as well.

## SSO sits in front of the API too

Authelia protects this at the reverse proxy via forward auth, not through
linkding's own OIDC support. That covers every route, including ones that would
otherwise leak a bookmark title in an error page.

The cost: the browser extension and mobile clients talk to `/api/`, and they
send a token rather than an Authelia session cookie, so they get bounced to the
login page. If you want those working, add a bypass rule for `/api/` in the
vhost's `autheliaRules` and rely on linkding's own token auth for that path.

## The admin account is created once, from the secret

`LD_SUPERUSER_NAME` and `LD_SUPERUSER_PASSWORD` come from the sops secret
`linkding/admin`, delivered as an EnvironmentFile. They are read at first
start; changing the secret afterwards does not change an existing account's
password. Use linkding's own UI or the Django admin for that.
