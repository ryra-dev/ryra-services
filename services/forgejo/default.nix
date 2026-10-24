{
  meta = {
    title = "Forgejo";
    summary = "Git repositories, issues and pull requests";
    description = builtins.readFile ./README.md;
    category = "tools";
    url = "https://forgejo.org";
    optionRoot = [ "ryra" "forgejo" ];
    needs = [ "secrets" "backup" ];
    provides = [];
    web.port = (import ../../lib/ports.nix).forgejo.frontDoor;
    web.authModes = [ "none" "oidc" ];
    secrets = {
      "forgejo-adminpass" = {
        purpose = "Forgejo initial administrator password";
        owner = "forgejo";
        restart = [ "forgejo.service" ];
        generate = { format = "hex"; bytes = 32; };
      };
      "restic-forgejo" = {
        purpose = "Encryption password for Forgejo's backup repository";
        restart = [ "restic-backups-forgejo.service" ];
        generate = { format = "base64"; bytes = 32; };
      };
    };
    secretAliases = {};
  };

  module = { name, contracts, settings }:
    { config, lib, pkgs, ... }:
    let
      ports = import ../../lib/ports.nix;
      guard = import ../../lib/loopback.nix { inherit lib; };
      cfg = config.services.forgejo;
      dataDir = "/var/lib/${name}";
      web = config.ryra.services.web.${name};
      oidc = (config.ryra.services.auth.modes.${name} or "none") == "oidc";
      auth = config.ryra.${name}.auth;
      adminUser = settings.adminUser or "ryra-admin";
      adminPasswordFile = settings.adminPasswordFile or config.sops.secrets."${name}-adminpass".path;
      adminQuery = "SELECT count(*) FROM user WHERE lower_name = lower('${lib.replaceStrings [ "'" ] [ "''" ] adminUser}');";
      stop = "${pkgs.systemd}/bin/systemctl stop forgejo.service";
      start = ''
        ${pkgs.systemd}/bin/systemctl start forgejo.service
        ${pkgs.curl}/bin/curl --fail --silent --show-error --retry 30 --retry-connrefused --retry-delay 1 --max-time 5 \
          http://127.0.0.1:${toString cfg.settings.server.HTTP_PORT}/api/healthz
      '';
    in {
      imports = lib.optionals (!(settings ? adminPasswordFile)) [{
        sops.secrets."${name}-adminpass" = {
          owner = "forgejo";
          group = "forgejo";
          mode = "0400";
          restartUnits = [ "forgejo.service" ];
        };
      }];
      options.ryra.${name} = {
        auth = lib.mkOption {
          default = {};
          type = lib.types.submodule { options = contracts.auth.mkRequester {
            clientId = "ryra-${name}";
            redirectUris = [ "${web.url}/user/oauth2/Ryra/callback" ];
            scopes = [ "openid" "profile" "email" "groups" ];
            tokenEndpointAuthMethod = "client_secret_basic";
          }; };
        };
        backup = lib.mkOption {
          default = {};
          type = lib.types.submodule { options = contracts.backup.mkRequester {
            user = "root";
            sourceDirectories = [ dataDir ];
            beforeBackup = [ stop ];
            afterBackup = [ start ];
            beforeRestore = [ ''
              ${stop}
              ${pkgs.coreutils}/bin/rm -f ${lib.escapeShellArgs [ "${cfg.database.path}-wal" "${cfg.database.path}-shm" "${cfg.database.path}-journal" ]}
            '' ];
            afterRestore = [ ''
              ${pkgs.coreutils}/bin/chown -R ${lib.escapeShellArg "${cfg.user}:${cfg.group}"} ${lib.escapeShellArg dataDir}
              ${start}
            '' ];
          }; };
        };
      };
      config = lib.mkMerge [ (guard { unit = "forgejo"; ports = [ cfg.settings.server.HTTP_PORT ]; }) {
        assertions = [
          {
            assertion = lib.hasPrefix "/" adminPasswordFile && !lib.hasPrefix "/nix/store/" adminPasswordFile;
            message = "Forgejo's administrator password requires a runtime file outside the Nix store.";
          }
          {
            assertion = cfg.database.type == "sqlite3" && cfg.stateDir == dataDir
              && cfg.database.path == "${dataDir}/data/forgejo.db"
              && cfg.repositoryRoot == "${dataDir}/repositories" && cfg.customDir == "${dataDir}/custom";
            message = "Forgejo automatic backups require the managed SQLite database and state directories.";
          }
        ];
        ryra.services.web.${name}.healthPath = "/api/healthz";
        ryra.services.state.${name} = { path = dataDir; owner = "forgejo"; group = "forgejo"; };
        services.forgejo = {
          enable = true;
          stateDir = dataDir;
          database.type = "sqlite3";
          settings = {
            server = {
              HTTP_ADDR = "127.0.0.1";
              HTTP_PORT = settings.port or ports.forgejo.backend;
              ROOT_URL = "${web.url}/";
              DISABLE_SSH = true;
            };
            service = {
              DISABLE_REGISTRATION = !oidc;
              ALLOW_ONLY_EXTERNAL_REGISTRATION = oidc;
              SHOW_REGISTRATION_BUTTON = false;
              REQUIRE_SIGNIN_VIEW = true;
            };
            openid = { ENABLE_OPENID_SIGNIN = false; ENABLE_OPENID_SIGNUP = false; };
            oauth2_client = {
              ENABLE_AUTO_REGISTRATION = oidc;
              ACCOUNT_LINKING = "login";
              USERNAME = "nickname";
            };
            repository.DEFAULT_PRIVATE = "private";
            session.COOKIE_SECURE = lib.hasPrefix "https://" web.url;
          };
        };
        services.nginx.virtualHosts.${web.hostName} = {
          extraConfig = "client_max_body_size 512m;";
          locations."/" = {
            proxyPass = "http://127.0.0.1:${toString cfg.settings.server.HTTP_PORT}";
            extraConfig = "proxy_request_buffering off;";
          };
        };
        systemd.services.forgejo = {
          serviceConfig.RestartSec = "5s";
          serviceConfig.LoadCredential = [ "admin:${adminPasswordFile}" ]
            ++ lib.optional oidc "oidc-client:${auth.result.clientSecretFile}";
          requires = lib.optionals oidc (lib.optional (auth.result.credentialService != null) auth.result.credentialService);
          after = lib.optionals oidc (lib.optional (auth.result.credentialService != null) auth.result.credentialService);
          preStart = lib.mkAfter ''
            count=$(${pkgs.sqlite}/bin/sqlite3 -readonly ${lib.escapeShellArg cfg.database.path} ${lib.escapeShellArg adminQuery})
            if [ "$count" = 0 ]; then
              ${lib.getExe cfg.package} admin user create \
                --username ${lib.escapeShellArg adminUser} \
                --email ${lib.escapeShellArg (settings.adminEmail or "admin@localhost")} \
                --password "$(${pkgs.coreutils}/bin/cat "$CREDENTIALS_DIRECTORY/admin")" \
                --admin --must-change-password=false
            fi
            ${if oidc then ''
              source_id=$(${pkgs.sqlite}/bin/sqlite3 -readonly ${lib.escapeShellArg cfg.database.path} "SELECT id FROM login_source WHERE name = 'Ryra' AND type = 6;")
              if [ -n "$source_id" ]; then
                # Updating an active source performs discovery, tying every restart to issuer availability.
                ${pkgs.sqlite}/bin/sqlite3 ${lib.escapeShellArg cfg.database.path} "UPDATE login_source SET is_active = 0 WHERE name = 'Ryra' AND type = 6;"
                command=(update-oauth --id "$source_id")
              else
                ${pkgs.curl}/bin/curl --fail --silent --show-error --output /dev/null \
                  --retry 60 --retry-all-errors --retry-delay 1 --retry-max-time 60 --max-time 5 \
                  ${lib.escapeShellArg "${lib.removeSuffix "/" auth.result.issuerUrl}/.well-known/openid-configuration"}
                command=(add-oauth)
              fi
              ${lib.getExe cfg.package} admin auth "''${command[@]}" \
                --name Ryra --provider openidConnect \
                --key ${lib.escapeShellArg auth.result.clientId} \
                --secret "$(${pkgs.coreutils}/bin/cat "$CREDENTIALS_DIRECTORY/oidc-client")" \
                --auto-discover-url ${lib.escapeShellArg "${lib.removeSuffix "/" auth.result.issuerUrl}/.well-known/openid-configuration"} \
                --scopes ${lib.escapeShellArg (lib.concatStringsSep " " auth.request.scopes)}
              ${pkgs.sqlite}/bin/sqlite3 ${lib.escapeShellArg cfg.database.path} "UPDATE login_source SET is_active = 1 WHERE name = 'Ryra' AND type = 6;"
            '' else ''
              ${pkgs.sqlite}/bin/sqlite3 ${lib.escapeShellArg cfg.database.path} "UPDATE login_source SET is_active = 0 WHERE name = 'Ryra' AND type = 6;"
            ''}
          '';
        };
      } ];
    };
}
