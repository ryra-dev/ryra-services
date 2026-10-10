{ config, lib, pkgs, options, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.ryra.services.auth.provider;
  runtimeFile = types.pathWith { absolute = true; inStore = false; };
  clients = config.ryra.services.auth.requests // cfg.extraClients;
  names = builtins.attrNames clients;
  indexed = lib.imap0 (index: name: { inherit name; credential = "oidc-client-${toString index}"; client = clients.${name}; }) names;
  registrations = map (entry: {
    client_id = entry.client.clientId;
    client_secret = "__RYRA_${entry.credential}__";
    public = false;
    authorization_policy = entry.client.authorizationPolicy;
    consent_mode = entry.client.consentMode;
    require_pkce = true;
    pkce_challenge_method = "S256";
    redirect_uris = entry.client.redirectUris;
    scopes = entry.client.scopes;
    response_types = [ "code" ];
    grant_types = [ "authorization_code" ];
    token_endpoint_auth_method = entry.client.tokenEndpointAuthMethod;
  } // lib.optionalAttrs (entry.client.claimsPolicy != null) { claims_policy = entry.client.claimsPolicy; }) indexed;
  fileOption = description: mkOption { type = runtimeFile; inherit description; };
  autheliaFiles = {
    jwt = cfg.secrets.jwtSecretFile;
    session = cfg.secrets.sessionSecretFile;
    storage = cfg.secrets.storageEncryptionKeyFile;
    hmac = cfg.secrets.oidcHmacSecretFile;
    signing = cfg.secrets.oidcIssuerPrivateKeyFile;
    ldap-bind = cfg.secrets.ldapBindPasswordFile;
  };
in {
  imports = [ ./auth.nix ];
  options.ryra.services.auth.provider = {
    enable = lib.mkEnableOption "shared Authelia and LLDAP authentication";
    instance = mkOption { type = types.str; default = "main"; };
    issuerUrl = mkOption { type = types.str; };
    cookieDomain = mkOption { type = types.str; };
    port = mkOption { type = types.port; default = 9091; };
    storagePath = mkOption { type = types.str; default = "/var/lib/authelia-${cfg.instance}/db.sqlite3"; };
    lldapStatePath = mkOption { type = types.str; default = "/var/lib/lldap"; };
    ldap = {
      port = mkOption { type = types.port; default = 3890; };
      httpPort = mkOption { type = types.port; default = 17170; };
      baseDn = mkOption { type = types.str; };
      bindDn = mkOption { type = types.str; };
      adminUser = mkOption { type = types.str; default = "admin"; };
      adminEmail = mkOption { type = types.str; };
      usersFilter = mkOption { type = types.str; default = "(&({username_attribute}={input})(objectClass=person))"; };
      passwordReset = mkOption { type = types.bool; default = false; };
      passwordChange = mkOption { type = types.bool; default = false; };
    };
    secrets = {
      jwtSecretFile = fileOption "Authelia password reset signing secret.";
      sessionSecretFile = fileOption "Authelia session secret.";
      storageEncryptionKeyFile = fileOption "Authelia storage encryption key.";
      oidcHmacSecretFile = fileOption "Authelia OIDC HMAC secret.";
      oidcIssuerPrivateKeyFile = fileOption "Authelia OIDC signing key.";
      ldapBindPasswordFile = fileOption "Authelia directory bind password.";
      ldapAdminPasswordFile = fileOption "LLDAP administrator password.";
      ldapJwtSecretFile = fileOption "LLDAP JWT secret.";
      ldapKeySeedEnvironmentFile = fileOption "Runtime environment file containing LLDAP_KEY_SEED.";
    };
    extraClients = mkOption {
      type = types.attrsOf (types.submodule {
        options = builtins.removeAttrs ((import ./contracts/auth.nix { inherit lib; }).request {}) [ "clientSecretFile" ];
      });
      default = {};
      description = "Additional native OIDC clients registered through the same runtime configuration.";
    };
    clientSecrets = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          clientSecretFile = fileOption "Application OIDC client secret.";
          secretHashFile = fileOption "Authelia OIDC client secret hash.";
        };
      });
      default = {};
      description = "Runtime credentials for automatically registered hosted applications.";
    };
  };
  config = lib.mkIf cfg.enable (lib.mkMerge [{
    assertions = [
      {
        assertion = builtins.match "https://[a-zA-Z0-9.-]+(:[0-9]{1,5})?" cfg.issuerUrl != null;
        message = "Ryra's OIDC issuer must be a stable HTTPS origin.";
      }
      {
        assertion = builtins.all (name: !(config.ryra.services.auth.requests ? ${name})) (builtins.attrNames cfg.extraClients);
        message = "An extra Ryra OIDC client duplicates a service registration.";
      }
      {
        assertion = let ids = map (client: client.clientId) (lib.attrValues clients);
          in builtins.all (id: id != "") ids && builtins.length ids == builtins.length (lib.unique ids);
        message = "Ryra OIDC client IDs must be nonempty and unique.";
      }
    ];
    ryra.services.auth.results = lib.mapAttrs (_: request: {
      inherit (request) clientId clientSecretFile;
      inherit (cfg) issuerUrl;
    }) config.ryra.services.auth.requests;
    services.lldap = {
      enable = true;
      environmentFile = cfg.secrets.ldapKeySeedEnvironmentFile;
      environment.LLDAP_JWT_SECRET_FILE = "%d/jwt";
      settings = {
        ldap_host = "127.0.0.1";
        http_host = "127.0.0.1";
        ldap_port = cfg.ldap.port;
        http_port = cfg.ldap.httpPort;
        http_url = "http://localhost:${toString cfg.ldap.httpPort}";
        ldap_base_dn = cfg.ldap.baseDn;
        ldap_user_dn = cfg.ldap.adminUser;
        ldap_user_email = cfg.ldap.adminEmail;
        ldap_user_pass_file = "/run/credentials/lldap.service/admin";
        force_ldap_user_pass_reset = "always";
        database_url = "sqlite://${cfg.lldapStatePath}/users.db?mode=rwc";
      };
    };
    users.groups.lldap = {};
    users.users.lldap = { isSystemUser = true; group = "lldap"; };
    systemd.tmpfiles.rules = [
      "d ${cfg.lldapStatePath} 0700 lldap lldap -"
      "d ${builtins.dirOf cfg.storagePath} 0700 ${config.services.authelia.instances.${cfg.instance}.user} ${config.services.authelia.instances.${cfg.instance}.group} -"
    ];
    systemd.services.lldap.serviceConfig = {
      DynamicUser = lib.mkForce false;
      LoadCredential = [ "jwt:${cfg.secrets.ldapJwtSecretFile}" "admin:${cfg.secrets.ldapAdminPasswordFile}" ];
      WorkingDirectory = lib.mkForce cfg.lldapStatePath;
      ReadWritePaths = [ cfg.lldapStatePath ];
      Restart = "on-failure";
      RestartSec = "5s";
    };
    systemd.services.lldap.unitConfig.RequiresMountsFor = [ cfg.lldapStatePath ];
    services.authelia.instances.${cfg.instance} = {
      enable = true;
      secrets.manual = true;
      environmentVariables = {
        AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE = "%d/jwt";
        AUTHELIA_SESSION_SECRET_FILE = "%d/session";
        AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE = "%d/storage";
        AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET_FILE = "%d/hmac";
        AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD_FILE = "%d/ldap-bind";
      };
      settingsFiles = [ (pkgs.writeText "ryra-oidc-clients.json" (lib.replaceStrings
        (map (entry: builtins.toJSON "__RYRA_${entry.credential}__") indexed)
        (map (entry: "{{ mustEnv \"CREDENTIALS_DIRECTORY\" | printf \"%s/${entry.credential}\" | secret | trim | msquote }}") indexed)
        (builtins.toJSON {
        identity_providers.oidc = lib.optionalAttrs (clients != {}) { clients = registrations; };
      }))) (pkgs.writeText "ryra-oidc-jwks.yaml" ''
        identity_providers:
          oidc:
            jwks:
              - key: {{ mustEnv "CREDENTIALS_DIRECTORY" | printf "%s/signing" | secret | mindent 10 "|" | msquote }}
      '') ];
      settings = {
        server.address = "tcp://127.0.0.1:${toString cfg.port}/";
        authentication_backend = {
          password_reset.disable = !cfg.ldap.passwordReset;
          password_change.disable = !cfg.ldap.passwordChange;
          ldap = {
            implementation = "lldap";
            address = "ldap://127.0.0.1:${toString cfg.ldap.port}";
            base_dn = cfg.ldap.baseDn;
            user = cfg.ldap.bindDn;
            users_filter = cfg.ldap.usersFilter;
          };
        };
        access_control.default_policy = lib.mkDefault "deny";
        session.cookies = [{ domain = cfg.cookieDomain; authelia_url = cfg.issuerUrl; }];
        storage.local.path = cfg.storagePath;
      };
    };
    systemd.services."authelia-${cfg.instance}" = {
      after = [ "lldap.service" ];
      requires = [ "lldap.service" ];
      environment.X_AUTHELIA_CONFIG_FILTERS = "template";
      unitConfig.RequiresMountsFor = [ (builtins.dirOf cfg.storagePath) ];
      serviceConfig.LoadCredential = lib.mapAttrsToList (name: path: "${name}:${path}") autheliaFiles
        ++ map (entry: "${entry.credential}:${entry.client.secretHashFile}") indexed;
    };
  } (lib.optionalAttrs (lib.hasAttrByPath [ "ryra" "services" "state" ] options) {
    ryra.services.state = {
    "authelia-${cfg.instance}" = {
      path = builtins.dirOf cfg.storagePath;
      owner = config.services.authelia.instances.${cfg.instance}.user;
      group = config.services.authelia.instances.${cfg.instance}.group;
    };
    lldap = { path = cfg.lldapStatePath; owner = "lldap"; group = "lldap"; };
    };
  })]);
}
