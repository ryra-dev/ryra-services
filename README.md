# ryra-services

NixOS services for Ryra, enabled by names like `ryra/nextcloud`.

Service definitions and operational notes live in [services/](services/).

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
