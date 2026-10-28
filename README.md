# ryra-services

Services for Ryra, including external accounts and applications you can deploy.
Deployable services use names like `ryra/nextcloud`.

Service definitions and operational notes live in [services/](services/).
For Gmail access through a saved connection, see the [Google guide](services/google/README.md).

## Authentication

An entry's optional `meta.auth` declares its login choices alongside its other
metadata. The flake's `index` exposes everything as JSON without building a NixOS
system. It derives `deployable` from the presence of `module`; external services
need no module or `optionRoot`. Google and Microsoft demonstrate OAuth definitions.
An entry with `package` can be installed on a machine without signing in. The
service module adds that package alongside any deployment module. Personal
credential delivery and shared service bindings are separate declaration choices.

```nix
{
  meta = {
    title = "My app";
    summary = "Read my documents";
    auth.my-app = {
      label = "My app";
      why = "Read my documents";
      connect = {
        kind = "token";
        page = "https://app.example/account/keys";
        scopes = "Documents: read";
        fields = [ "token" ];
      };
      environment.MY_APP_TOKEN = "token";
    };
  };
}
```

Authentication IDs are unique across the index. Additional repositories have a
namespace: `acme`'s `my-app` becomes `acme.my-app`. `connect.kind` supports `oauth2`
(authorization code with PKCE and refresh), `token` (API keys or bearer tokens),
and `local` (an executable login command and captured credential file).
OAuth profiles declare endpoints, an authenticated identity read and permission
choices. Use `settings` for publisher registration values; user credentials never
belong in metadata or the Nix store. Optional `driver` executables implement other
authentication protocols through typed login and refresh requests. The
[Bun/TypeScript SDK](adapters/README.md) provides Zod schemas and examples.

`lib.withServices { inherit pkgs; package = ryra; index = myRegistry.index; }`
packages one index for both `ryra catalog services` and `ryra integrations`.
The equivalent without a wrapper is `RYRA_SERVICE_INDEX=/path/to/index.json`.
The desktop Services page and `ryra catalog --org ORG` read the same organization
repository list. Add repositories without replacing the existing ones:

```sh
ryra catalog --org ORG --add-source acme=github:acme/services
ryra catalog --org ORG --add-source partner=git+https://forge.example/partner/services.git
```

All configured repositories are used together, alongside the default
`github:ryra-dev/ryra-services`. Their namespaces keep identically named services
and accounts separate. Fetched metadata is cached at its Git revision;
`ryra catalog --org ORG --refresh` updates it. There is no separate connection catalog.

Each repository publishes `service-index.json` at the root of its flake. Generate
it from the Nix definitions with `nix eval --json .#index > service-index.json` and
commit it with them. This repository uses `bash scripts/service-index.sh` to
generate it and `bash scripts/service-index.sh --check` to check it. Consumers read
the generated metadata without Nix, including on Windows. Local folders need no
additional tool; remote Git repositories use Git and its configured credentials.
GitHub references, Git URLs and their `ref`, `rev` and `dir` selections are supported.
Never put user credentials in the published index. Nix still builds packages and
deploys NixOS modules; connecting a metadata-only OAuth or token integration does
not require either.

Connections with environment bindings support Ryra's reviewed
`--connection SERVICE=CONNECTION_ID` binding, private systemd credentials and
persistent refresh state. The service
runs `ryra integrations run ID --credentials "$RYRA_CONNECTION_CREDENTIALS"
--state "$RYRA_CONNECTION_STATE" -- COMMAND`. Executable authentication adapters
use that same storage and restart path, keeping opaque refresh state out of the
consumer's environment. They own protocol validation, account identity and grant
checks. Token connections can declare an optional `verify` request: a fixed HTTPS
`url`, `headers` using `{credential_field}` placeholders, and JSON pointers in
`present` or exact values in `require`. An optional `form` sends a POST for token
exchanges; otherwise the request is a GET. Use a harmless authenticated operation
that needs no extra permissions beyond the connection's purpose. Ryra runs it
before saving, records the result with those credentials, and offers verification
again for saved connections. Requests time out after 15 seconds and do not follow
redirects. No check means "Credentials saved", not verified access. These checks
do not refresh credentials or prove that a deployed service is healthy.

## Required credentials

Declare requirements once in a service's `meta.secrets`. Keep values out of this
repository. Ryra uses these declarations to prompt for credentials, show missing
or malformed values, and prepare encrypted machine delivery.

For a single internal secret, use `purpose` and optionally
`generate = { format = "hex"; bytes = 32; };`. For an environment file, expose
labelled fields instead of asking users to write its syntax:

```nix
secrets."app-admin" = {
  purpose = "Administrator account";
  setup = {
    instructions = "Choose the administrator login.";
    # Optional: url = "https://provider.example/account/api-keys";
    fields = [
      { name = "APP_USER"; label = "Username"; secret = false; }
      { name = "APP_PASSWORD"; label = "Password"; secret = true; }
    ];
  };
};
```

Fields are required, single-line values. They are safely quoted into one systemd
EnvironmentFile credential. Do not combine named fields with `generate`, which
creates a single random value. `setup` can also contain instructions and a
provider URL without fields for an ordinary API key. Format checks do not verify
remote API permissions or expiry. Use `owner` and `restart` where the consuming
service needs them; existing secret aliases still share the same stored value.

Linkding demonstrates the form; Nextcloud declares generation for its initial
administrator password. This metadata needs a Ryra client
that supports credential forms; it does not change the services' runtime paths.

## Web apps

Linkding and Nextcloud use native NixOS modules and nginx. Installing either app
also configures its required database, private credentials and backups. Each app
keeps its own login. Installing it does not sign every machine user into that account.

Apps are private by default. Their loopback addresses in `/etc/ryra/apps.json`
are reachable through an encrypted Ryra machine connection. Public access is an
explicit configuration choice: give the app a DNS name and nginx requests and
renews its ACME certificate. Direct HTTPS terminates TLS on the machine. DNS must
point to it without a proxy; Cloudflare DNS-only works. Ryra coordinates the
declared ports on supported cloud firewalls and NixOS. HTTPS needs TCP 443;
HTTP-01 certificates also need TCP 80, while DNS-01 or supplied certificates do
not. Public HTTPS does not remove the app's login.

Ryra stages these choices in `modules/ryra/web.json`, alongside `services.json`:

```json
{ "ryra/linkding": { "access": "public", "domain": "bookmarks.example.com" } }
```

Private access can specify a different port with
`{ "access": "private", "port": 8083 }`. Duplicate app addresses are refused.
The file is part of the organization configuration and its Git export. Credentials
remain in the vault and encrypted machine secrets, never in this file.

Gateway access uses `{ "access": "gateway", "provider": "ryra/cloudflare",
"domain": "bookmarks.example.com" }`. The enabled provider owns DNS, the outbound
tunnel and edge HTTPS. Cloudflare terminates TLS and can read HTTP traffic, so
choose this only if you want that tradeoff. Direct HTTPS needs no tunnel or
proxy. App ports behind a gateway remain on loopback. Other registries can provide
`web-gateway` and declare `serviceConnections` without app-specific client code.
Cloudflare needs a connected account with Tunnel Edit and zone-scoped DNS Edit,
Zone Read, SSL and Certificates Read, and Zone Settings Read. Automatic edge TLS
supports an active full zone's apex or one subdomain label. Before removing the
provider or its credential, deploy removal of its gateway routes so owned DNS and
tunnels can be deleted. The shared backup system includes gateway ownership state.
Backup and restore briefly stop its connectors; restore that state before
recreating the same host's routes.

Certificates are automatic. For your own certificate, set
`"ryra/linkding".web.certificate.mode = "supplied";` in
`modules/ryra/settings.nix` (Configuration in the desktop). On the service machine,
place `fullchain.pem` (leaf first, then intermediates) and `key.pem` in
`/var/lib/ryra/certificates/<hostname>/` before applying. You can use `ryra files`
to reach that machine. With the default nginx user/group, use root:nginx ownership,
0750 for the directory and 0640 for the files. Create the directory with those
permissions if this is the first deployment. To keep files elsewhere, set
`certificateFile` and `keyFile` to their absolute runtime paths. Nginx cannot read
home directories in its service sandbox. Never put private keys in Nix or git.

Nginx validates supplied files before starting or reloading. For replacement,
put both new files in place, run `sudo -u nginx ryra-check-certificates`, then
`sudo systemctl reload nginx` if it succeeds. `ryra-check-certificates --help`
lists the configured paths. Validation checks the hostname, dates and matching
unencrypted key; it does not establish browser trust. Renew supplied certificates
yourself. Cloudflare Origin CA certificates need Cloudflare in front of them.

For automatic DNS validation without opening port 80, set `web.certificate` to
`{ mode = "dns"; dnsProvider = "cloudflare"; credentialsFile = "/run/secrets/acme-dns"; }`.
The provider credentials stay outside Nix and git. These advanced settings apply
to direct HTTPS; gateways and Tailscale manage their own certificates.
