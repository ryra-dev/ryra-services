let
  root = ../..;
  nixpkgs = (builtins.getFlake "path:${toString root}").inputs.nixpkgs;
  lib = nixpkgs.lib;
  file = name: "/run/ryra-grafana-test/${name}";
  evaluate = { shared ? false, mode ? null, settings ? {}, web ? {}, external ? null, others ? {} }:
    (lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ (import ../../lib/services-module.nix {
        registries.ryra.ryraServices = { grafana = import ./.; nextcloud = import ../nextcloud; };
        services = { "ryra/grafana" = {
          settings = { adminPasswordFile = file "admin"; secretKeyFile = file "key"; } // settings;
          web = lib.optionalAttrs shared { externalUrl = "https://grafana.test.invalid"; } // web;
          auth = lib.optionalAttrs (mode != null || shared) { mode = if mode == null then "oidc" else mode; }
            // { inherit external; };
        }; } // others;
        backupPasswordFileFor = _: file "restic";
      }) {
        boot.isContainer = true;
        system.stateVersion = "26.05";
        ryra.services.auth.provider = lib.mkIf shared {
          enable = true;
          issuerUrl = "https://auth.test.invalid";
          cookieDomain = "test.invalid";
          ldap = { baseDn = "dc=test,dc=invalid"; bindDn = "uid=authelia,ou=people,dc=test,dc=invalid"; adminEmail = "admin@test.invalid"; };
          secrets = lib.genAttrs [ "jwtSecretFile" "sessionSecretFile" "storageEncryptionKeyFile" "oidcHmacSecretFile" "oidcIssuerPrivateKeyFile" "ldapBindPasswordFile" "ldapAdminPasswordFile" "ldapJwtSecretFile" "ldapKeySeedEnvironmentFile" ] file;
          clientSecrets.grafana = { clientSecretFile = file "client"; secretHashFile = file "client-hash"; };
        };
      } ];
    }).config;
  failures = c: map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
  native = evaluate {};
  oidc = evaluate { shared = true; };
  optOut = evaluate { shared = true; mode = "none"; };
  custom = evaluate { mode = "none"; settings.extraSettings."auth.generic_oauth" = { enabled = true; client_secret = "$__file{/run/custom-secret}"; }; };
  roles = evaluate { shared = true; settings = { allowedGroups = [ "grafana-users" ]; roleAttributePath = "contains(groups, 'grafana-admins') && 'GrafanaAdmin' || 'Viewer'"; allowAssignGrafanaAdmin = true; }; };
  customerOptions = {
    mode = "oidc";
    web.externalUrl = "https://grafana.customer.test";
    external = {
      issuerUrl = "https://identity.customer.test/realms/company/";
      clientId = "customer-grafana";
      clientSecretFile = file "customer-client";
      authorizationEndpoint = "https://identity.customer.test/authorize";
      tokenEndpoint = "https://identity.customer.test/token";
      userinfoEndpoint = "https://identity.customer.test/userinfo";
      jwksUri = "https://identity.customer.test/keys";
    };
  };
  customer = evaluate customerOptions;
  mixed = evaluate {
    shared = true;
    others."ryra/nextcloud" = {
      settings.adminPasswordFile = file "nextcloud-admin";
      web.externalUrl = "https://files.customer.test";
      auth = {
        mode = "oidc";
        external = {
          issuerUrl = "https://identity.customer.test/realms/files/";
          clientId = "external-nextcloud";
          clientSecretFile = file "external-nextcloud";
        };
      };
    };
  };
  authCheck = import ../../checks/auth.nix { config = oidc; inherit lib; };
in
assert lib.assertMsg (builtins.all (c: failures c == []) [ native oidc optOut custom roles customer mixed ]) "An authentication configuration failed NixOS assertions.";
assert builtins.attrNames mixed.ryra.services.auth.requests == [ "grafana" ];
assert mixed.ryra.grafana.auth.result.issuerUrl == "https://auth.test.invalid";
assert mixed.ryra.nextcloud.auth.result.issuerUrl == "https://identity.customer.test/realms/files/";
assert lib.hasInfix "https://identity.customer.test/realms/files/.well-known/openid-configuration" mixed.systemd.services.nextcloud-oidc.script;
assert builtins.stringLength mixed.systemd.services.nextcloud-oidc.serviceConfig.ExecStart > 0;
assert !(builtins.elem "ryra-auth-credentials.service" mixed.systemd.services.nextcloud-oidc.requires);
assert builtins.all (c: builtins.stringLength c.systemd.services.grafana.serviceConfig.ExecStart > 0) [ native oidc optOut custom roles ];
assert native.ryra.services.auth.requests == {};
assert !native.services.grafana.settings.auth.disable_login_form;
assert native.services.grafana.settings."auth.basic".enabled;
assert !optOut.services.grafana.settings."auth.generic_oauth".enabled;
assert optOut.ryra.services.auth.requests == {};
assert custom.services.grafana.settings."auth.generic_oauth".client_secret == "$__file{/run/custom-secret}";
assert oidc.services.grafana.settings."auth.generic_oauth".role_attribute_path == "('Viewer')";
assert !oidc.services.grafana.settings."auth.generic_oauth".allow_assign_grafana_admin;
assert roles.services.grafana.settings."auth.generic_oauth".allow_assign_grafana_admin;
assert roles.services.grafana.settings."auth.generic_oauth".role_attribute_path == "(contains(groups, 'grafana-admins') && 'GrafanaAdmin' || 'Viewer')";
assert roles.services.grafana.settings."auth.generic_oauth".allowed_groups == "grafana-users";
assert !customer.ryra.services.auth.provider.enable && !customer.services.lldap.enable;
assert customer.services.authelia.instances == {};
assert customer.ryra.services.auth.requests == {};
assert customer.services.grafana.settings."auth.generic_oauth".auth_url == "https://identity.customer.test/authorize";
assert customer.systemd.services.grafana.serviceConfig.LoadCredential == [
  "admin:${file "admin"}" "key:${file "key"}" "oidc-client:${file "customer-client"}"
];
assert !builtins.elem "ryra-auth-credentials.service" customer.systemd.services.grafana.requires;
assert builtins.all (issuerUrl: failures (evaluate (customerOptions // {
  external = customerOptions.external // { inherit issuerUrl; };
})) != []) [ "http://identity.customer.test" "https://identity.customer.test/realm?query" "https://identity.customer.test/realm#fragment" ];
assert failures (evaluate { settings.extraSettings."auth.anonymous".enabled = true; }) != [];
assert failures (evaluate { settings.secretKeyFile = "/nix/store/unsafe-key"; }) != [];
assert failures (evaluate { shared = true; web.externalUrl = null; }) != [];
assert native.ryra.services.backup.requests.grafana.user == "root";
assert lib.hasInfix ".backup" (lib.concatStringsSep "\n" native.ryra.services.backup.requests.grafana.beforeBackup);
assert lib.hasInfix "integrity_check" (lib.concatStringsSep "\n" native.ryra.services.backup.requests.grafana.afterRestore);
assert native.services.restic.backups.grafana.timerConfig.OnCalendar == "hourly";
{
  inherit authCheck;
  passed = [ "native" "shared-oidc" "shared-opt-out" "custom-auth" "customer-provider" "mixed-providers" "explicit-roles" "anonymous-denial" "store-secret-denial" "canonical-origin-required" "backup-hooks" ];
  grafanaVersion = native.services.grafana.package.version;
}
