# Nextcloud metadata and application configuration.
{
  meta = {
    title = "Nextcloud";
    description = builtins.readFile ./README.md;
    summary = "Files, calendar and contacts";
    category = "productivity";
    url = "https://nextcloud.com";

    # The option namespace used to connect backup requests.
    optionRoot = [
      "shb"
      "nextcloud"
    ];

    # Upstream application module imported by the service mechanism.
    shbModule = "nextcloud-server";

    # Blocks the host must already provide. Read by an agent before adding the
    # service, so it fails while writing the config rather than at the end of a
    # rebuild.
    needs = [
      "ssl"
      "secrets"
      "backup"
      "ldap"
      "oidc"
      "postgresql"
    ];
    provides = [ ];

    # Secrets this service requests, as sops keys. The authority is the
    # `.request` lines below, which the module system checks; this exists so
    # the keys can go into secrets.yaml BEFORE a rebuild fails on a missing
    # one.
    secrets = {
      "nextcloud-adminpass" = {
        purpose = "Nextcloud admin account password";
        generate = { format = "hex"; bytes = 32; };
      };
      "nextcloud-sso-secret" = {
        purpose = "OIDC client secret, shared with Authelia";
        generate = { format = "hex"; bytes = 32; };
      };
      "restic-nextcloud" = {
        purpose = "Encryption password for Nextcloud's file backup repository";
        owner = "nextcloud";
        restart = [ "restic-backups-nextcloud.service" ];
        generate = {
          format = "base64";
          bytes = 32;
        };
      };
    };

    # Two logical secrets that must resolve to ONE value, via `settings.key`.
    # Generating independent values for these produces a service that starts
    # cleanly, passes every health check, and cannot log anybody in.
    secretAliases = {
      "nextcloud-ldap_admin_password" = "lldap-user_password";
      "authelia-nextcloud_sso_secret" = "nextcloud-sso-secret";
    };
  };

  # One line was DROPPED rather than ported from the hand-written aspect:
  #
  #     networking.firewall.allowedTCPPorts = lib.mkForce [ 22 ];
  #
  # That is host policy ("nothing but SSH reaches the internet") that happened
  # to live in a file about one service. Removing that file opened 80 and 443
  # to the public internet, which is precisely why a registry service must not
  # be able to write it. It belongs in the host's base profile.
  module =
    {
      name,
      subdomain,
      domain,
      ssl,
      contracts,
      settings,
    }:
    { config, ... }:
    {
      shb.nextcloud = {
        enable = true;
        inherit domain subdomain ssl;
        dataDir = "/var/lib/${name}";
        defaultPhoneRegion = settings.phoneRegion or "NO";

        # Contract: nextcloud declares it needs a secret, sops provides it. The
        # mechanism does not write these, because WHICH secrets a service needs
        # is the service's own business.
        adminPass.result = config.shb.sops.secret."${name}-adminpass".result;

        # Users come from LLDAP rather than Nextcloud's own account list.
        apps.ldap = {
          enable = true;
          host = "127.0.0.1";
          port = config.shb.lldap.ldapPort;
          dcdomain = config.shb.lldap.dcdomain;
          adminName = "admin";
          adminPassword.result = config.shb.sops.secret."${name}-ldap_admin_password".result;
          userGroup = "${name}_user";
        };

        # Login is delegated to Authelia over OIDC. fallbackDefaultAuth keeps
        # the local admin login reachable, so an Authelia that fails to start
        # does not lock every account out of Nextcloud, including the one that
        # could fix it.
        apps.sso = {
          enable = true;
          endpoint = "https://${config.shb.authelia.subdomain}.${config.shb.authelia.domain}";
          clientID = name;
          fallbackDefaultAuth = true;

          secret.result = config.shb.sops.secret."${name}-sso-secret".result;
          secretForAuthelia.result = config.shb.sops.secret."authelia-${name}_sso_secret".result;
        };
      };

      # Declare state explicitly because the application exposes no mount contract.
      ryra.services.state.${name} = {
        path = "/var/lib/${name}";
        owner = "nextcloud";
        group = "nextcloud";
      };

      shb.sops.secret."${name}-adminpass".request = config.shb.nextcloud.adminPass.request;
      shb.sops.secret."${name}-sso-secret".request = config.shb.nextcloud.apps.sso.secret.request;

      # Both of these must hold the SAME value as the secret they point at:
      # Nextcloud binds to LLDAP as its admin user, and Nextcloud and Authelia
      # must agree on one OIDC client secret. `settings.key` is the alias.
      shb.sops.secret."${name}-ldap_admin_password" = {
        request = config.shb.nextcloud.apps.ldap.adminPassword.request;
        settings.key = "lldap-user_password";
      };
      shb.sops.secret."authelia-${name}_sso_secret" = {
        request = config.shb.nextcloud.apps.sso.secretForAuthelia.request;
        settings.key = "${name}-sso-secret";
      };
    };
}
