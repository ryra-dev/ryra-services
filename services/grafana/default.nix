{
  meta = {
    title = "Grafana";
    summary = "Dashboards and observability";
    description = builtins.readFile ./README.md;
    category = "productivity";
    url = "https://grafana.com";
    optionRoot = [ "ryra" "grafana" ];
    needs = [ "secrets" "backup" ];
    provides = [];
    web.port = (import ../../lib/ports.nix).grafana.frontDoor;
    web.authModes = [ "none" "oidc" ];
    secrets = {
      "grafana-adminpass" = {
        purpose = "Grafana initial administrator password";
        owner = "grafana";
        restart = [ "grafana.service" ];
        generate = { format = "hex"; bytes = 32; };
      };
      "grafana-secret-key" = {
        purpose = "Grafana database encryption key, retain with backups";
        owner = "grafana";
        restart = [ "grafana.service" ];
        generate = { format = "hex"; bytes = 32; };
      };
      "restic-grafana" = {
        purpose = "Encryption password for Grafana's backup repository";
        restart = [ "restic-backups-grafana.service" ];
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
      cfg = config.services.grafana;
      dataDir = "/var/lib/${name}";
      database = "${dataDir}/data/grafana.db";
      snapshot = "${dataDir}/.ryra-backup/database.sqlite";
      web = config.ryra.services.web.${name};
      oidc = (config.ryra.services.auth.modes.${name} or "none") == "oidc";
      auth = config.ryra.${name}.auth;
      systemctl = "${pkgs.systemd}/bin/systemctl";
      sqlite = "${pkgs.sqlite}/bin/sqlite3";
      extra = settings.extraSettings or {};
      startGrafana = ''
        ${systemctl} start grafana.service
        healthy=false
        for _ in {1..30}; do
          if ${pkgs.curl}/bin/curl --fail --silent --connect-timeout 2 --max-time 5 \
            http://127.0.0.1:${toString cfg.settings.server.http_port}/api/health | ${pkgs.jq}/bin/jq -e '.database == "ok"' >/dev/null; then
            healthy=true
            break
          fi
          ${pkgs.coreutils}/bin/sleep 1
        done
        if ! $healthy; then
          echo 'Grafana did not become healthy after backup or restore.' >&2
          exit 1
        fi
      '';
      runtimeFile = file: lib.hasPrefix "/" file && !(lib.hasPrefix "/nix/store/" file);
      checkDatabase = file: ''
        test "$(${sqlite} ${lib.escapeShellArg file} 'PRAGMA integrity_check;')" = ok
        test "$(${sqlite} ${lib.escapeShellArg file} "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('user','dashboard','data_source');")" = 3
      '';
    in {
      imports = lib.optionals (!(settings ? adminPasswordFile)) [{
        sops.secrets."${name}-adminpass" = { owner = "grafana"; group = "grafana"; mode = "0400"; restartUnits = [ "grafana.service" ]; };
      }] ++ lib.optionals (!(settings ? secretKeyFile)) [{
        sops.secrets."${name}-secret-key" = { owner = "grafana"; group = "grafana"; mode = "0400"; restartUnits = [ "grafana.service" ]; };
      }];
      options.ryra.${name} = {
        auth = lib.mkOption {
          default = {};
          type = lib.types.submodule { options = contracts.auth.mkRequester {
            clientId = "ryra-${name}";
            redirectUris = [ "${web.url}/login/generic_oauth" ];
            scopes = [ "openid" "profile" "email" "groups" ];
            tokenEndpointAuthMethod = "client_secret_post";
          }; };
        };
        backup = lib.mkOption {
          default = {};
          type = lib.types.submodule { options = contracts.backup.mkRequester {
            user = "root";
            sourceDirectories = [ dataDir ];
            excludePatterns = [ database "${database}-wal" "${database}-shm" "${database}-journal" "${dataDir}/conf" ];
            beforeBackup = [ ''
              ${systemctl} stop grafana.service
              umask 077
              ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg "${dataDir}/.ryra-backup"}
              ${sqlite} ${lib.escapeShellArg database} ${lib.escapeShellArg ".backup '${snapshot}'"}
              ${checkDatabase snapshot}
            '' ];
            afterBackup = [ startGrafana ];
            beforeRestore = [ ''
              ${systemctl} stop grafana.service
              ${pkgs.coreutils}/bin/rm -f ${lib.escapeShellArg snapshot}
            '' ];
            afterRestore = [ ''
              ${checkDatabase snapshot}
              ${pkgs.coreutils}/bin/install -o grafana -g grafana -m 0600 ${lib.escapeShellArg snapshot} ${lib.escapeShellArg "${database}.restore"}
              ${pkgs.coreutils}/bin/rm -f ${lib.escapeShellArg "${database}-wal"} ${lib.escapeShellArg "${database}-shm"}
              ${pkgs.coreutils}/bin/mv ${lib.escapeShellArg "${database}.restore"} ${lib.escapeShellArg database}
              ${startGrafana}
            '' ];
          }; };
        };
      };
      config = lib.mkMerge [ (guard { unit = "grafana"; ports = [ cfg.settings.server.http_port ]; }) {
        assertions = [
          { assertion = !oidc || builtins.all (endpoint: endpoint != null)
              [ auth.result.authorizationEndpoint auth.result.tokenEndpoint auth.result.userinfoEndpoint ];
            message = "Grafana's OIDC provider must supply authorization, token and userinfo endpoints."; }
          { assertion = runtimeFile (settings.adminPasswordFile or config.sops.secrets."${name}-adminpass".path)
              && runtimeFile (settings.secretKeyFile or config.sops.secrets."${name}-secret-key".path);
            message = "Grafana passwords and encryption keys require runtime files outside the Nix store."; }
          { assertion = cfg.settings.database.type == "sqlite3" && cfg.settings.database.path == database
              && cfg.dataDir == dataDir && cfg.settings.paths.data == "${dataDir}/data"
              && (lib.hasPrefix "${dataDir}/" cfg.settings.paths.plugins || lib.hasPrefix "/nix/store/" cfg.settings.paths.plugins);
            message = "Grafana automatic backups require the managed SQLite database and data directory."; }
          { assertion = !cfg.settings."auth.anonymous".enabled && cfg.settings.server.http_addr == "127.0.0.1"
              && cfg.settings.server.root_url == "${web.url}/";
            message = "Grafana requires authenticated access, a loopback backend and the web contract's canonical origin."; }
          { assertion = !oidc || !(extra ? "auth.generic_oauth");
            message = "Configure shared Grafana OIDC through roleAttributePath, allowedGroups and allowAssignGrafanaAdmin, or select auth.mode = none for custom authentication."; }
          { assertion = cfg.settings.security.admin_password == "$__file{/run/credentials/grafana.service/admin}"
              && cfg.settings.security.secret_key == "$__file{/run/credentials/grafana.service/key}";
            message = "Grafana administrator and encryption secrets must use the managed runtime credentials."; }
          { assertion = !oidc || (cfg.settings.auth.disable_login_form && !cfg.settings."auth.basic".enabled
              && cfg.settings.users.auto_assign_org_role == "Viewer");
            message = "Shared Grafana OIDC requires OAuth login and a Viewer default."; }
        ];
        ryra.services.web.${name}.healthPath = "/api/health";
        ryra.services.state.${name} = { path = dataDir; owner = "grafana"; group = "grafana"; };
        services.grafana = {
          enable = true;
          inherit dataDir;
          openFirewall = false;
          settings = lib.recursiveUpdate {
            server = { http_addr = "127.0.0.1"; http_port = settings.port or ports.grafana.backend; root_url = "${web.url}/"; };
            database = { type = "sqlite3"; path = database; };
            paths.data = "${dataDir}/data";
            security = {
              admin_user = settings.adminUser or "admin";
              admin_password = "$__file{/run/credentials/grafana.service/admin}";
              secret_key = "$__file{/run/credentials/grafana.service/key}";
              cookie_secure = lib.hasPrefix "https://" web.url;
            };
            users = { allow_sign_up = false; auto_assign_org_role = "Viewer"; };
            "auth.anonymous".enabled = false;
            auth.disable_login_form = oidc;
            "auth.basic".enabled = !oidc;
            "auth.generic_oauth" = { enabled = oidc; } // lib.optionalAttrs oidc {
              name = "Ryra";
              allow_sign_up = true;
              client_id = auth.result.clientId;
              client_secret = "$__file{/run/credentials/grafana.service/oidc-client}";
              scopes = lib.concatStringsSep " " auth.request.scopes;
              auth_url = auth.result.authorizationEndpoint;
              token_url = auth.result.tokenEndpoint;
              api_url = auth.result.userinfoEndpoint;
              use_pkce = true;
              auth_style = "InParams";
              login_attribute_path = "preferred_username";
              groups_attribute_path = "groups";
              allowed_groups = lib.concatStringsSep " " (settings.allowedGroups or []);
              # INI unquotes bare string literals before JMESPath sees them.
              role_attribute_path = "(${settings.roleAttributePath or "'Viewer'"})";
              role_attribute_strict = true;
              allow_assign_grafana_admin = settings.allowAssignGrafanaAdmin or false;
              skip_org_role_sync = false;
            };
          } extra;
        };
        services.nginx.virtualHosts.${web.hostName}.locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.settings.server.http_port}";
          proxyWebsockets = true;
        };
        systemd.services.grafana.serviceConfig.LoadCredential = [
          "admin:${settings.adminPasswordFile or config.sops.secrets."${name}-adminpass".path}"
          "key:${settings.secretKeyFile or config.sops.secrets."${name}-secret-key".path}"
        ] ++ lib.optional oidc "oidc-client:${auth.result.clientSecretFile}";
        systemd.services.grafana.requires = lib.optionals oidc
          (lib.optional (auth.result.credentialService != null) auth.result.credentialService);
        systemd.services.grafana.after = lib.optionals oidc
          (lib.optional (auth.result.credentialService != null) auth.result.credentialService);
      } ];
    };
}
