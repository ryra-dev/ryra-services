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
The desktop Services page and `ryra catalog services --org ORG` read the same
organization repository list. Add a repository from Services → Repositories, or
save a complete list with `ryra catalog services --org ORG --save-sources --source
acme=github:acme/services`. The default is `github:ryra-dev/ryra-services`.
Fetched metadata is cached at its resolved revision; `--refresh` updates it.
There is no separate connection catalog.

Connections with environment bindings support Ryra's reviewed
`--connection SERVICE=CONNECTION_ID` binding, private systemd credentials and
persistent refresh state. The service
runs `ryra integrations run ID --credentials "$RYRA_CONNECTION_CREDENTIALS"
--state "$RYRA_CONNECTION_STATE" -- COMMAND`. Executable authentication adapters
use that same storage and restart path, keeping opaque refresh state out of the
consumer's environment. They own protocol validation, account identity and grant
checks. Plain API keys have no automatic verification or refresh.

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
administrator password and OIDC client secret. This metadata needs a Ryra client
that supports credential forms; it does not change the services' runtime paths.
