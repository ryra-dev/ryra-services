let
  nixpkgs = (builtins.getFlake "path:${toString ../..}").inputs.nixpkgs;
  lib = nixpkgs.lib;
  file = name: "/run/ryra-forgejo-test/${name}";
  evaluate = { web ? {}, settings ? {}, shared ? false, managed ? false, mode ? "none", external ? null }:
    (lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ (import ../../lib/services-module.nix {
        registries.ryra.ryraServices = { forgejo = import ./.; authelia = import ../authelia; };
        services = { "ryra/forgejo" = {
          web = lib.optionalAttrs shared { externalUrl = "https://forgejo.test.invalid"; } // web;
          settings = { adminPasswordFile = "/run/forgejo-admin"; } // settings;
          auth = { inherit mode; } // lib.optionalAttrs (external != null) { inherit external; };
        }; } // lib.optionalAttrs managed { "ryra/authelia" = {
          web.externalUrl = "https://auth.test.invalid";
          settings.initialAccountFile = file "authelia-admin";
        }; };
        backupPasswordFileFor = _: "/run/forgejo-restic";
      }) {
        boot.isContainer = true;
        system.stateVersion = "26.05";
        security.acme.defaults.email = "admin@example.com";
        ryra.services.auth.provider = lib.mkIf (shared && !managed) {
          enable = true;
          issuerUrl = "https://auth.test.invalid";
          cookieDomain = "test.invalid";
          credentialService = "ryra-auth-credentials.service";
          ldap = { baseDn = "dc=test,dc=invalid"; bindDn = "uid=authelia,ou=people,dc=test,dc=invalid"; adminEmail = "admin@test.invalid"; };
          secrets = lib.genAttrs [ "jwtSecretFile" "sessionSecretFile" "storageEncryptionKeyFile" "oidcHmacSecretFile" "oidcIssuerPrivateKeyFile" "ldapBindPasswordFile" "ldapAdminPasswordFile" "ldapJwtSecretFile" "ldapKeySeedEnvironmentFile" ] file;
          clientSecrets.forgejo = { clientSecretFile = file "client"; secretHashFile = file "client-hash"; };
        };
      } ];
    }).config;
  failures = c: map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
  private = evaluate {};
  public = evaluate { web = { access = "public"; domain = "git.example.com"; }; };
  custom = evaluate { web.port = 704; settings = { port = 703; adminUser = "owner"; }; };
  oidc = evaluate { shared = true; mode = "oidc"; };
  managed = evaluate { shared = true; managed = true; mode = "oidc"; };
  optOut = evaluate { shared = true; };
  external = evaluate {
    mode = "oidc";
    web.externalUrl = "https://forgejo.customer.test";
    external = {
      issuerUrl = "https://identity.customer.test";
      clientId = "customer-forgejo";
      clientSecretFile = file "external-client";
    };
  };
  backup = private.ryra.services.backup.requests.forgejo;
in
assert lib.assertMsg (builtins.all (c: failures c == []) [ private public custom oidc managed optOut external ]) "A Forgejo configuration failed NixOS assertions.";
assert private.services.forgejo.settings.server.HTTP_ADDR == "127.0.0.1";
assert private.services.forgejo.settings.server.ROOT_URL == "http://127.0.0.1:804/";
assert private.services.forgejo.settings.server.DISABLE_SSH;
assert private.services.forgejo.settings.service.DISABLE_REGISTRATION;
assert private.services.forgejo.settings.service.REQUIRE_SIGNIN_VIEW;
assert private.services.forgejo.settings.security.INSTALL_LOCK;
assert !private.services.forgejo.settings.session.COOKIE_SECURE;
assert private.networking.firewall.allowedTCPPorts == [];
assert public.services.forgejo.settings.server.ROOT_URL == "https://git.example.com/";
assert public.services.forgejo.settings.session.COOKIE_SECURE;
assert public.networking.firewall.allowedTCPPorts == [ 80 443 ];
assert custom.services.nginx.virtualHosts."forgejo.localhost".locations."/".proxyPass == "http://127.0.0.1:703";
assert custom.services.forgejo.settings.server.ROOT_URL == "http://127.0.0.1:704/";
assert lib.hasInfix (lib.escapeShellArg "SELECT count(*) FROM user WHERE lower_name = lower('owner');") custom.systemd.services.forgejo.preStart;
assert builtins.elem "admin:/run/forgejo-admin" private.systemd.services.forgejo.serviceConfig.LoadCredential;
assert failures (evaluate { settings.adminPasswordFile = "/nix/store/unsafe-password"; }) != [];
assert backup.sourceDirectories == [ "/var/lib/forgejo" ];
assert backup.excludePatterns == [];
assert lib.hasInfix "stop forgejo.service" (lib.concatStrings backup.beforeBackup);
assert lib.hasInfix "/api/healthz" (lib.concatStrings backup.afterBackup);
assert lib.hasInfix "forgejo.db-wal" (lib.concatStrings backup.beforeRestore);
assert private.services.restic.backups.forgejo.timerConfig.OnCalendar == "hourly";
assert !private.services.lldap.enable && private.services.authelia.instances == {};
assert private.ryra.services.auth.requests == {} && optOut.ryra.services.auth.requests == {};
assert !optOut.services.forgejo.settings.oauth2_client.ENABLE_AUTO_REGISTRATION;
assert lib.hasInfix "SET is_active = 0" optOut.systemd.services.forgejo.preStart;
assert oidc.ryra.services.auth.requests.forgejo.redirectUris == [ "https://forgejo.test.invalid/user/oauth2/Ryra/callback" ];
assert oidc.ryra.services.auth.requests.forgejo.tokenEndpointAuthMethod == "client_secret_basic";
assert !oidc.services.forgejo.settings.service.DISABLE_REGISTRATION;
assert oidc.services.forgejo.settings.service.ALLOW_ONLY_EXTERNAL_REGISTRATION;
assert oidc.services.forgejo.settings.oauth2_client.ENABLE_AUTO_REGISTRATION;
assert oidc.services.forgejo.settings.oauth2_client.ACCOUNT_LINKING == "login";
assert builtins.elem "oidc-client:${file "client"}" oidc.systemd.services.forgejo.serviceConfig.LoadCredential;
assert builtins.elem "ryra-auth-credentials.service" oidc.systemd.services.forgejo.requires;
assert oidc.systemd.services.forgejo.serviceConfig.RestartSec == "5s";
assert managed.ryra.services.web.forgejo.port != managed.ryra.services.web.authelia.port;
assert failures (evaluate { shared = true; mode = "oidc"; web.externalUrl = null; }) != [];
assert !external.services.lldap.enable && external.services.authelia.instances == {};
assert external.ryra.services.auth.requests == {};
assert builtins.elem "oidc-client:${file "external-client"}" external.systemd.services.forgejo.serviceConfig.LoadCredential;
assert !builtins.elem "ryra-auth-credentials.service" external.systemd.services.forgejo.requires;
{
  authCheck = import ../../checks/auth.nix { config = oidc; inherit lib; };
  passed = [ "private" "public" "custom-ports" "native-login" "runtime-credential" "store-secret-denial" "backup-contract" "shared-oidc" "managed-authelia" "shared-opt-out" "external-oidc" "canonical-origin-required" ];
  forgejoVersion = private.services.forgejo.package.version;
}
