# Nextcloud: the service, its secrets and its backup in one file.
#
# Ported from hetzner-nixos-uefi's modules/services/nextcloud.nix. Three things
# changed, all of them the same change: what was hardcoded to one box is now an
# argument. `domain` was "cobbler-tuna.ts.net" in four places, `ssl` reached
# directly into `config.ryra.tailscale.certs`, and the restic repository was an
# absolute path under /srv/backups.
#
# One thing was DROPPED rather than parameterised:
#
#     networking.firewall.allowedTCPPorts = lib.mkForce [ 22 ];
#
# That is host policy — "nothing but SSH is reachable from the internet" — which
# happened to be written in the Nextcloud file. It is true of the whole box, not
# of this service, and a registry service that quietly rewrites the host
# firewall is a trap. It belongs in the host's base profile.
{
  name,
  subdomain,
  domain,
  ssl,
  backupRoot,
  settings,
}:

{ config, lib, ... }:

{
  shb.nextcloud = {
    enable = true;
    inherit domain subdomain;
    dataDir = "/var/lib/${name}";
    defaultPhoneRegion = settings.phoneRegion or "NO";

    # Real certificate for this service's own DNS name. SHB asserts SSL is
    # required for SSO, so this is not optional once sso is on.
    inherit ssl;

    # Contract: nextcloud declares it needs a secret, sops provides it.
    adminPass.result = config.shb.sops.secret."${name}/adminpass".result;

    # Users come from LLDAP rather than Nextcloud's own account list.
    apps.ldap = {
      enable = true;
      host = "127.0.0.1";
      port = config.shb.lldap.ldapPort;
      dcdomain = config.shb.lldap.dcdomain;
      adminName = "admin";
      adminPassword.result = config.shb.sops.secret."${name}/ldap_admin_password".result;
      userGroup = "${name}_user";
    };

    # Login is delegated to Authelia over OIDC. fallbackDefaultAuth keeps the
    # local admin login reachable, so a broken Authelia does not lock everyone
    # out of Nextcloud.
    apps.sso = {
      enable = true;
      endpoint = "https://${config.shb.authelia.subdomain}.${config.shb.authelia.domain}";
      clientID = name;
      fallbackDefaultAuth = true;

      secret.result = config.shb.sops.secret."${name}/sso/secret".result;
      secretForAuthelia.result = config.shb.sops.secret."authelia/${name}_sso_secret".result;
    };
  };
  shb.sops.secret."${name}/adminpass".request = config.shb.nextcloud.adminPass.request;

  # Both of these must hold the same value as the secret they point at:
  # Nextcloud binds to LLDAP as its admin user, and Nextcloud and Authelia must
  # agree on the shared OIDC client secret.
  shb.sops.secret."${name}/ldap_admin_password" = {
    request = config.shb.nextcloud.apps.ldap.adminPassword.request;
    settings.key = "lldap/user_password";
  };
  shb.sops.secret."${name}/sso/secret".request = config.shb.nextcloud.apps.sso.secret.request;
  shb.sops.secret."authelia/${name}_sso_secret" = {
    request = config.shb.nextcloud.apps.sso.secretForAuthelia.request;
    settings.key = "${name}/sso/secret";
  };

  # Backup of the data directory. shb.nextcloud.backup is a requester: it
  # already knows what to back up and as which user, so restic only supplies
  # the repository and schedule.
  #
  # This covers FILES ONLY. The database is backed up by the postgresql
  # service. Both are needed to restore; see SKILL.md.
  shb.restic.instances.${name} = {
    request = config.shb.nextcloud.backup.request;

    settings = {
      enable = true;
      passphrase.result = config.shb.sops.secret."restic/${name}".result;

      repository = {
        path = "${backupRoot}/${name}";
        timerConfig = {
          OnCalendar = settings.backupOnCalendar or "hourly";
          RandomizedDelaySec = "5m";
        };
      };

      retention = {
        keep_within = "1d";
        keep_hourly = 24;
        keep_daily = 7;
        keep_weekly = 4;
        keep_monthly = 6;
      };
    };
  };
  shb.sops.secret."restic/${name}".request =
    config.shb.restic.instances.${name}.settings.passphrase.request;
}
