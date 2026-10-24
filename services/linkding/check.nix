let
  root = ../..;
  nixpkgs = (builtins.getFlake "path:${toString root}").inputs.nixpkgs;
  lib = nixpkgs.lib;
  file = name: "/run/ryra-linkding-test/${name}";
  evaluate = { shared ? false, mode ? null, web ? {} }:
    (lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ (import ../../lib/services-module.nix {
        registries.ryra.ryraServices = { linkding = import ./.; nextcloud = import ../nextcloud; };
        services = { "ryra/linkding" = {
          settings = { environmentFile = file "admin"; };
          web = lib.optionalAttrs shared { externalUrl = "https://linkding.m1.home.arpa"; privateHttps = true; } // web;
          auth = lib.optionalAttrs (mode != null || shared) { mode = if mode == null then "oidc" else mode; };
        }; };
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
          clientSecrets.linkding = { clientSecretFile = file "client"; secretHashFile = file "client-hash"; };
        };
      } ];
    }).config;
  failures = c: map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
  # Loopback HTTP: no issuer to verify, no HTTPS cookie. The private app is reached through Ryra.
  native = evaluate { };
  # Shared sign-in over local HTTPS: the issuer is this machine's own CA, so Linkding must verify
  # against the system trust, and its session cookie must be Secure.
  oidc = evaluate { shared = true; };
  # Private HTTPS without shared sign-in still serves over TLS, so the cookie is still Secure.
  privateHttps = evaluate { mode = "none"; web = { externalUrl = "https://linkding.m1.home.arpa"; privateHttps = true; }; };
  authCheck = import ../../checks/auth.nix { config = oidc; inherit lib; };
in
assert lib.assertMsg (builtins.all (c: failures c == [ ]) [ native oidc privateHttps ])
  "A Linkding configuration failed NixOS assertions.";
assert lib.assertMsg (oidc.services.linkding.settings.NIX_SSL_CERT_FILE == "/etc/ssl/certs/ca-certificates.crt")
  "Shared sign-in Linkding must verify the OIDC issuer against the system CA trust.";
assert lib.assertMsg (!(native.services.linkding.settings ? NIX_SSL_CERT_FILE))
  "Loopback Linkding has no issuer to verify and needs no custom CA bundle.";
assert lib.assertMsg (oidc.services.linkding.package.drvPath != native.services.linkding.package.drvPath)
  "HTTPS Linkding must install custom Django settings for the Secure session cookie.";
assert lib.assertMsg (privateHttps.services.linkding.package.drvPath != native.services.linkding.package.drvPath)
  "Private-HTTPS Linkding must install custom Django settings for the Secure session cookie.";
{
  inherit authCheck;
  passed = [ "native" "shared-oidc-https" "private-https" "nix-ssl-cert-file" "secure-cookie-override" ];
  linkdingVersion = native.services.linkding.package.version;
}
