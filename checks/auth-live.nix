{
  issuerUrl,
  nextcloudUrl,
  linkdingUrl,
  cookieDomain,
  credentialDirectory ? "/run/ryra-auth-test",
  credentialsReadyUnit ? null,
  directoryBootstrapUnit ? null,
}:
{ lib, ... }:
let
  file = name: "${credentialDirectory}/${name}";
  gatedUnits = [ "lldap" "authelia-main" "nextcloud-setup" "nextcloud-oidc" "linkding-setup" "linkding-oidc" ];
in {
  imports = [ (import ../lib/services-module.nix {
    registries.ryra.ryraServices = {
      nextcloud = import ../services/nextcloud;
      linkding = import ../services/linkding;
    };
    services = {
      "ryra/nextcloud" = {
        web.externalUrl = nextcloudUrl;
        settings.adminPasswordFile = file "nextcloud-adminpass";
        auth.consentMode = "implicit";
        auth.authorizationPolicy = "service_users";
      };
      "ryra/linkding" = {
        web.externalUrl = linkdingUrl;
        settings.environmentFile = file "linkding-admin.env";
        auth.consentMode = "implicit";
        auth.authorizationPolicy = "service_users";
      };
    };
    backupRoot = "/var/lib/ryra-auth-test-backups";
    backupPasswordFileFor = name: file "restic-${name}";
  }) ];

  assertions = [{
    assertion = lib.hasPrefix "/" credentialDirectory && !(lib.hasPrefix "/nix/store/" credentialDirectory);
    message = "The Ryra auth live test requires a runtime credential directory outside the Nix store.";
  }];
  ryra.services.auth.provider = {
    enable = true;
    inherit issuerUrl cookieDomain;
    instance = "main";
    ldap = {
      baseDn = "dc=ryra-test,dc=invalid";
      bindDn = "uid=authelia,ou=people,dc=ryra-test,dc=invalid";
      adminUser = "directory-admin";
      adminEmail = "directory-admin@ryra-test.invalid";
      usersFilter = "(&({username_attribute}={input})(objectClass=person)(!(uid=authelia))(!(uid=directory-admin)))";
    };
    secrets = {
      jwtSecretFile = file "authelia-jwt";
      sessionSecretFile = file "authelia-session";
      storageEncryptionKeyFile = file "authelia-storage";
      oidcHmacSecretFile = file "authelia-hmac";
      oidcIssuerPrivateKeyFile = file "authelia-signing.pem";
      ldapBindPasswordFile = file "lldap-bind";
      ldapAdminPasswordFile = file "lldap-admin";
      ldapJwtSecretFile = file "lldap-jwt";
      ldapKeySeedEnvironmentFile = file "lldap.env";
    };
    clientSecrets = lib.genAttrs [ "nextcloud" "linkding" ] (name: {
      clientSecretFile = file "${name}-oidc";
      secretHashFile = file "${name}-oidc-hash";
    });
  };
  services.authelia.instances.main.settings = {
    access_control.rules = [{ domain = cookieDomain; policy = "one_factor"; }];
    identity_providers.oidc.authorization_policies.service_users = {
      default_policy = "deny";
      rules = [{ policy = "one_factor"; subject = "group:service_users"; }];
    };
    notifier.filesystem.filename = "/var/lib/authelia-main/test-notifications.txt";
  };
  systemd.services = lib.mkMerge [
    (lib.genAttrs gatedUnits (_: {
      after = lib.optional (credentialsReadyUnit != null) credentialsReadyUnit;
      requires = lib.optional (credentialsReadyUnit != null) credentialsReadyUnit;
    }))
    { authelia-main = {
      after = lib.optional (directoryBootstrapUnit != null) directoryBootstrapUnit;
      requires = lib.optional (directoryBootstrapUnit != null) directoryBootstrapUnit;
    }; }
  ];
}
