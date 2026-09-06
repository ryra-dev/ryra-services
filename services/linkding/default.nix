# Linkding bookmark manager, using the native NixOS service and Ryra contracts.
{
  meta = {
    summary = "Bookmark manager";
    category = "productivity";
    url = "https://linkding.link";

    optionRoot = [
      "ryra"
      "linkding"
    ];

    needs = [
      "ssl"
      "secrets"
      "backup"
      "nginx"
    ];
    provides = [ ];

    # FLAT, and prefixed with the service rather than separated by a slash.
    #
    # A `/` is how sops-nix spells a path INTO a yaml document, so a key written `linkding/admin`
    # is looked for as a nested `linkding:` then `admin:`. The files Ryra renders are flat: a
    # record's name becomes one yaml key, slash and all. So the slashed spelling produced a deploy
    # that reported success and a machine that failed activation hunting a key that was there,
    # spelled differently.
    #
    # Prefixing sidesteps the question rather than answering it, and costs nothing: record names
    # are unique per vault already.
    secrets = {
      "linkding-admin" = "Env file holding LD_SUPERUSER_NAME and LD_SUPERUSER_PASSWORD";
      "restic-linkding" = {
        purpose = "Encryption password for linkding's backup repository";
        owner = "linkding";
        restart = [ "restic-backups-linkding.service" ];
        generate = {
          format = "base64";
          bytes = 32;
        };
      };
    };
    secretAliases = { };
  };

  module =
    {
      name,
      subdomain,
      domain,
      ssl,
      contracts,
      settings,
    }:
    { config, lib, ... }:

    let
      cfg = config.ryra.${name};
      dataDir = "/var/lib/${name}";

      # SSO is enforced at the reverse proxy by Authelia rather than inside the
      # app. linkding does speak OIDC, but forward auth is provider-agnostic
      # and puts the login in front of every route including the ones that
      # would otherwise leak a bookmark title in a 404. The tradeoff is in
      # SKILL.md: it also sits in front of the REST API, so browser extensions
      # and mobile clients need a bypass rule.
      ssoEnabled = settings.sso or true;
      autheliaEndpoint = "https://${config.shb.authelia.subdomain}.${config.shb.authelia.domain}";
    in
    {
      options.ryra.${name} = {
        # State that cannot be rebuilt from the flake. With the default sqlite
        # backend this is ALL of it: the database, the secret key, favicons,
        # previews and assets are one directory, which is why backing this up
        # is backing up linkding.
        mount = lib.mkOption {
          description = "Where linkding keeps state that cannot be rebuilt.";
          type = contracts.mount;
          readOnly = true;
          default = {
            path = dataDir;
            owner = name;
            group = name;
          };
        };

        # The requester half of the backup contract: what to back up and as
        # whom. It says nothing about restic, repositories, schedules or
        # retention, because it must not: the mechanism picks a provider and
        # this file works unchanged if that provider is ever something else.
        backup = lib.mkOption {
          description = "Backup configuration.";
          default = { };
          type = lib.types.submodule {
            options = contracts.backup.mkRequester {
              user = name;
              sourceDirectories = [ dataDir ];
            };
          };
        };

        # Never a bare path. The requester carries the ownership the file must
        # end up with and the units to restart when it changes, so a rotation
        # takes effect rather than waiting for an unrelated reboot.
        adminCredentials = lib.mkOption {
          description = ''
            File holding LD_SUPERUSER_NAME and LD_SUPERUSER_PASSWORD, in
            EnvironmentFile format.
          '';
          type = lib.types.submodule {
            options = contracts.secret.mkRequester {
              mode = "0400";
              owner = name;
              group = name;
              restartUnits = [ "${name}.service" ];
            };
          };
        };
      };

      config = {
        services.linkding = {
          enable = true;
          user = name;
          group = name;
          inherit dataDir;

          # Loopback only. The certificate belongs to nginx; an app that
          # terminates its own TLS is an app that has to be told about
          # certificate renewal.
          address = "127.0.0.1";
          port = settings.port or 9090;

          environmentFile = cfg.adminCredentials.result.path;

          settings = {
            LD_LOG_X_FORWARDED_FOR = "true";
          }
          // (settings.extraSettings or { });
        };

        # Reverse proxy through the nginx block, which also mounts the Authelia
        # forward-auth endpoint when one is given.
        shb.nginx.vhosts = [
          {
            inherit subdomain domain ssl;
            upstream = "http://127.0.0.1:${toString config.services.linkding.port}";
            authEndpoint = if ssoEnabled then autheliaEndpoint else null;
          }
        ];

        # This service does implement the mount contract, so its state
        # declaration is derived from it rather than written twice.
        ryra.services.state.${name} = {
          inherit (cfg.mount) path owner group;
        };

        # The secret this service needs. WHICH secrets a service wants is its
        # own business; where they come from is not, which is why this names a
        # sops key and not a file.
        shb.sops.secret."${name}-admin".request = cfg.adminCredentials.request;
        ryra.${name}.adminCredentials.result = config.shb.sops.secret."${name}-admin".result;
      };
    };
}
