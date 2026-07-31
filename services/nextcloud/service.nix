# Nextcloud.
#
# What is NOT in this file is the point of the file. No restic instance, no
# repository path, no retention policy, no passphrase request, no ZFS dataset,
# no certificate request: all of that is the same for every service, so the
# mechanism writes it. Compare against hetzner-nixos-uefi's hand-written
# modules/services/nextcloud.nix, which carries about sixty lines of exactly
# that plumbing.
#
# What remains is what is true about Nextcloud specifically: it takes its users
# from LDAP, it delegates login over OIDC, and two of its secrets are aliases
# of somebody else's.
#
# One line was DROPPED rather than ported:
#
#     networking.firewall.allowedTCPPorts = lib.mkForce [ 22 ];
#
# That is host policy ("nothing but SSH reaches the internet") that happened to
# be written in the Nextcloud file. A registry service that silently mkForces
# the host firewall is a trap. It belongs in the host's base profile.
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
    # mechanism does not write these because WHICH secrets a service needs is
    # the service's own business.
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
    # local admin login reachable, so an Authelia that fails to start does not
    # lock every account out of Nextcloud, including the one that could fix it.
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
  shb.sops.secret."${name}/sso/secret".request = config.shb.nextcloud.apps.sso.secret.request;

  # Both of these must hold the SAME value as the secret they point at:
  # Nextcloud binds to LLDAP as its admin user, and Nextcloud and Authelia must
  # agree on one OIDC client secret. `settings.key` is the alias.
  shb.sops.secret."${name}/ldap_admin_password" = {
    request = config.shb.nextcloud.apps.ldap.adminPassword.request;
    settings.key = "lldap/user_password";
  };
  shb.sops.secret."authelia/${name}_sso_secret" = {
    request = config.shb.nextcloud.apps.sso.secretForAuthelia.request;
    settings.key = "${name}/sso/secret";
  };
}
