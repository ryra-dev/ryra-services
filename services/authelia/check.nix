let
  root = ../..;
  nixpkgs = (builtins.getFlake "path:${toString root}").inputs.nixpkgs;
  lib = nixpkgs.lib;
  evaluate = { origin ? "https://auth.example.ts.net:8443", accountFile ? "/run/initial-account", app ? false }:
    (lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ (import ../../lib/services-module.nix {
        registries.ryra.ryraServices = {
          authelia = import ./.;
          grafana = import ../grafana;
        };
        services = {
          "ryra/authelia" = {
            settings.initialAccountFile = accountFile;
            web.externalUrl = origin;
          };
        } // lib.optionalAttrs app {
          "ryra/grafana" = {
            auth.mode = "oidc";
            settings = { adminPasswordFile = "/run/grafana-admin"; secretKeyFile = "/run/grafana-key"; };
            web.externalUrl = "https://grafana.example.ts.net";
          };
        };
        backupPasswordFileFor = _: "/run/restic-password";
      }) {
        boot.isContainer = true;
        system.stateVersion = "26.05";
      } ];
    }).config;
  failures = config: map (a: a.message) (builtins.filter (a: !a.assertion) config.assertions);
  native = evaluate {};
  shared = evaluate { app = true; };
  provider = shared.ryra.services.auth.provider;
  backup = shared.ryra.services.backup.requests.authelia;
in
assert lib.assertMsg (failures native == []) "Managed Authelia configuration failed NixOS assertions.";
assert native.services.authelia.instances.main.settingsFiles == [];
assert !(native.services.authelia.instances.main.environmentVariables ? AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET_FILE);
assert lib.assertMsg (failures shared == []) "Managed Authelia with Grafana failed NixOS assertions.";
assert failures (evaluate { origin = null; }) != [];
assert failures (evaluate { accountFile = "/nix/store/initial-account"; }) != [];
assert provider.issuerUrl == "https://auth.example.ts.net:8443";
assert provider.cookieDomain == "auth.example.ts.net";
assert lib.hasInfix "proxy_set_header Host auth.example.ts.net:8443;"
  shared.services.nginx.virtualHosts."authelia.localhost".locations."/".extraConfig;
assert shared.services.authelia.instances.main.settings.access_control.rules == [{
  domain = "auth.example.ts.net";
  policy = "one_factor";
  subject = [ "group:service_users" ];
}];
assert provider.clientSecrets.grafana.clientSecretFile == "/var/lib/ryra-auth/clients/grafana/secret";
assert shared.ryra.services.auth.requests.grafana.clientSecretFile == provider.clientSecrets.grafana.clientSecretFile;
assert shared.systemd.services.ryra-auth-bootstrap.serviceConfig.EnvironmentFile == "/run/initial-account";
assert builtins.elem "ryra-auth-credentials.service" shared.systemd.services.lldap.requires;
assert builtins.elem "ryra-auth-bootstrap.service" shared.systemd.services.authelia-main.requires;
assert builtins.elem "/var/lib/ryra-auth/authelia" shared.systemd.services.authelia-main.serviceConfig.ReadWritePaths;
assert shared.services.lldap.settings.http_host == "127.0.0.1";
assert shared.services.lldap.settings.ldap_host == "127.0.0.1";
assert lib.hasInfix "!(uid=directory-admin)" provider.ldap.usersFilter;
assert lib.hasInfix "!(uid=authelia)" provider.ldap.usersFilter;
assert backup.user == "root" && backup.sourceDirectories == [ "/var/lib/ryra-auth" ];
assert backup.beforeBackup != [] && backup.afterBackup != [] && backup.beforeRestore != [] && backup.afterRestore != [];
{
  passed = [ "managed-provider" "shared-app" "canonical-origin-required" "runtime-account-file-required" "persistent-client-paths" "startup-ordering" "directory-isolation" "complete-backup-hooks" ];
  inherit (shared.systemd.services.ryra-auth-credentials) script;
  backupCommand = builtins.head backup.beforeBackup;
}
