{
  meta = {
    title = "Authelia";
    summary = "Optional shared sign-in and user directory";
    description = builtins.readFile ./README.md;
    category = "productivity";
    url = "https://www.authelia.com";
    optionRoot = [ "ryra" "authelia" ];
    needs = [ "secrets" "backup" ];
    provides = [];
    web.port = (import ../../lib/ports.nix).authelia.frontDoor;
    secrets = {
      "authelia-admin" = {
        purpose = "Initial shared sign-in account";
        restart = [ "ryra-auth-bootstrap.service" ];
        setup = {
          instructions = "Choose your shared sign-in account. This same account manages users through Ryra's private directory connection. Existing passwords are preserved when setup runs again.";
          fields = [
            { name = "INITIAL_USERNAME"; label = "Username"; secret = false; }
            { name = "INITIAL_EMAIL"; label = "Email"; secret = false; }
            { name = "INITIAL_PASSWORD"; label = "Password"; secret = true; }
          ];
        };
      };
      "restic-authelia" = {
        purpose = "Encryption password for the shared sign-in backup repository";
        restart = [ "restic-backups-authelia.service" ];
        generate = { format = "base64"; bytes = 32; };
      };
    };
    secretAliases = {};
  };
  module = { name, contracts, settings }:
    { config, lib, pkgs, ... }:
    let
      state = "/var/lib/ryra-auth";
      web = config.ryra.services.web.${name};
      provider = config.ryra.services.auth.provider;
      instance = settings.instance or "main";
      authelia = config.services.authelia.instances.${instance};
      authUnit = "authelia-${instance}.service";
      baseDn = settings.baseDn or "dc=ryra,dc=internal";
      keys = "${state}/keys/current";
      names = lib.unique (builtins.attrNames (lib.filterAttrs (_: mode: mode == "oidc") config.ryra.services.auth.modes)
        ++ builtins.attrNames provider.extraClients);
      issuerHost = builtins.match "https://([^:]+)(:[0-9]+)?" web.url;
      initialAccountFile = settings.initialAccountFile or config.sops.secrets."${name}-admin".path;
      tools = [ pkgs.coreutils pkgs.openssl pkgs.authelia pkgs.gnused pkgs.gnugrep ];
      backup = pkgs.writeShellApplication {
        name = "ryra-auth-backup";
        runtimeInputs = [ pkgs.coreutils pkgs.systemd pkgs.sqlite pkgs.curl pkgs.jq ];
        text = ''
          export AUTH_STATE=${lib.escapeShellArg state}
          export AUTH_UNIT=${lib.escapeShellArg authUnit}
          export AUTH_PORT=${toString provider.port}
          export AUTH_USER=${lib.escapeShellArg authelia.user}
          export AUTH_GROUP=${lib.escapeShellArg authelia.group}
        '' + builtins.readFile ./backup.sh;
      };
    in {
      imports = [ ../../lib/auth-provider.nix ] ++ lib.optionals (!(settings ? initialAccountFile)) [{
        sops.secrets."${name}-admin" = {
          mode = "0400";
          restartUnits = [ "ryra-auth-bootstrap.service" ];
        };
      }];
      options.ryra.${name}.backup = lib.mkOption {
        default = {};
        type = lib.types.submodule { options = contracts.backup.mkRequester {
          user = "root";
          sourceDirectories = [ state ];
          excludePatterns = [ "${state}/lldap/users.db*" "${state}/authelia/db.sqlite3*" "${state}/.ryra-backup/.new.*" "${state}/keys/.new.*" "${state}/clients/.new.*" ];
          beforeBackup = [ "${backup}/bin/ryra-auth-backup prepare" ];
          afterBackup = [ "${backup}/bin/ryra-auth-backup finish" ];
          beforeRestore = [ "${backup}/bin/ryra-auth-backup before-restore" ];
          afterRestore = [ "${backup}/bin/ryra-auth-backup after-restore" ];
        }; };
      };
      config = {
        assertions = [
          { assertion = issuerHost != null;
            message = "Shared sign-in setup needs an explicit canonical HTTPS origin. Configure private HTTPS access or a reviewed public domain before applying."; }
          { assertion = lib.hasPrefix "/" initialAccountFile && !(lib.hasPrefix "/nix/store/" initialAccountFile);
            message = "The initial Authelia account requires a runtime EnvironmentFile outside the Nix store."; }
          { assertion = builtins.all (client: builtins.match "[a-zA-Z0-9][a-zA-Z0-9_-]*" client != null) names;
            message = "Managed OIDC clients require simple service names for persistent credential paths."; }
        ];
        ryra.services.web.${name}.healthPath = "/api/health";
        ryra.services.state = {
          "${name}-keys" = { path = "${state}/keys"; owner = "root"; group = "root"; };
          "${name}-clients" = { path = "${state}/clients"; owner = "root"; group = "root"; };
        };
        ryra.services.auth.provider = {
          enable = true;
          credentialService = "ryra-auth-credentials.service";
          inherit instance;
          issuerUrl = web.url;
          cookieDomain = if issuerHost == null then "invalid" else builtins.head issuerHost;
          storagePath = "${state}/authelia/db.sqlite3";
          lldapStatePath = "${state}/lldap";
          ldap = {
            inherit baseDn;
            bindDn = "uid=authelia,ou=people,${baseDn}";
            adminUser = "directory-admin";
            adminEmail = "directory-admin@localhost.invalid";
            usersFilter = "(&({username_attribute}={input})(objectClass=person)(memberOf=cn=service_users,ou=groups,${baseDn})(!(uid=directory-admin))(!(uid=authelia)))";
          };
          secrets = {
            jwtSecretFile = "${keys}/jwt";
            sessionSecretFile = "${keys}/session";
            storageEncryptionKeyFile = "${keys}/storage";
            oidcHmacSecretFile = "${keys}/hmac";
            oidcIssuerPrivateKeyFile = "${keys}/signing";
            ldapBindPasswordFile = "${keys}/ldap-bind";
            ldapAdminPasswordFile = "${keys}/ldap-admin";
            ldapJwtSecretFile = "${keys}/ldap-jwt";
            ldapKeySeedEnvironmentFile = "${keys}/lldap.env";
          };
          clientSecrets = lib.genAttrs names (client: {
            clientSecretFile = lib.mkDefault "${state}/clients/${client}/secret";
            secretHashFile = lib.mkDefault "${state}/clients/${client}/hash";
          });
        };
        services.authelia.instances.${instance}.settings = {
          notifier = settings.notifier or { filesystem.filename = "${state}/authelia/notifications.txt"; };
          access_control.rules = lib.mkDefault [{
            domain = provider.cookieDomain;
            policy = "one_factor";
            subject = [ "group:service_users" ];
          }];
        };
        services.nginx.virtualHosts.${web.hostName}.locations."/" = {
          proxyPass = "http://127.0.0.1:${toString provider.port}";
          proxyWebsockets = true;
          recommendedProxySettings = false;
          extraConfig = ''
            proxy_set_header Host ${lib.removePrefix "https://" web.url};
            proxy_set_header X-Forwarded-Host ${lib.removePrefix "https://" web.url};
            proxy_set_header X-Forwarded-Proto https;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          '';
        };
        systemd.tmpfiles.rules = [ "d ${state} 0711 root root -" ];
        systemd.services.ryra-auth-credentials = {
          wantedBy = [ "multi-user.target" ];
          before = [ "lldap.service" authUnit "ryra-auth-bootstrap.service" ];
          restartTriggers = [ (builtins.toJSON names) ];
          unitConfig.RequiresMountsFor = [ state "${state}/keys" "${state}/clients" ];
          serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; };
          environment.AUTH_STATE = state;
          path = tools;
          script = ''
            exec ${pkgs.bash}/bin/bash ${./generate-credentials.sh} ${lib.escapeShellArgs names}
          '';
        };
        systemd.services.lldap = {
          requires = [ "ryra-auth-credentials.service" ];
          after = [ "ryra-auth-credentials.service" ];
        };
        systemd.services.ryra-auth-bootstrap = {
          wantedBy = [ "multi-user.target" ];
          requires = [ "lldap.service" ];
          after = [ "lldap.service" ];
          before = [ authUnit ];
          path = [ pkgs.coreutils pkgs.jq pkgs.curl pkgs.sqlite pkgs.openldap ];
          environment = {
            LLDAP_URL = "http://127.0.0.1:${toString provider.ldap.httpPort}";
            LLDAP_ADDRESS = "ldap://127.0.0.1:${toString provider.ldap.port}";
            LLDAP_BASE_DN = baseDn;
            LLDAP_DATABASE = "${state}/lldap/users.db";
          };
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            UMask = "0077";
            RuntimeDirectory = "ryra-auth-bootstrap";
            RuntimeDirectoryMode = "0700";
            EnvironmentFile = initialAccountFile;
            LoadCredential = [ "admin:${keys}/ldap-admin" "bind:${keys}/ldap-bind" ];
            ExecStart = "${pkgs.bash}/bin/bash ${./bootstrap-directory.sh}";
          };
        };
        systemd.services."authelia-${instance}" = {
          requires = [ "ryra-auth-bootstrap.service" ];
          after = [ "ryra-auth-bootstrap.service" ];
          serviceConfig.ReadWritePaths = [ (builtins.dirOf provider.storagePath) ];
        };
      };
    };
}
