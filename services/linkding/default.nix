{
  meta = {
    title = "Linkding";
    summary = "Bookmark manager";
    category = "productivity";
    url = "https://linkding.link";
    optionRoot = [ "ryra" "linkding" ];
    needs = [ "secrets" "backup" ];
    provides = [];
    web.port = 8081;
    web.authModes = [ "none" "oidc" ];
    secrets = {
      "linkding-admin" = {
        purpose = "Linkding administrator account";
        owner = "linkding";
        restart = [ "linkding.service" ];
        setup = {
          instructions = "Choose the administrator login for this service. Ryra stores the credentials securely and prepares the required file.";
          fields = [
            { name = "LD_SUPERUSER_NAME"; label = "Username"; secret = false; }
            { name = "LD_SUPERUSER_PASSWORD"; label = "Password"; secret = true; }
          ];
        };
      };
      "restic-linkding" = {
        purpose = "Encryption password for Linkding's backup repository";
        owner = "linkding";
        restart = [ "restic-backups-linkding.service" ];
        generate = { format = "base64"; bytes = 32; };
      };
    };
    secretAliases = {};
  };

  module = { name, contracts, settings }:
    { config, lib, pkgs, ... }:
    let
      dataDir = "/var/lib/${name}";
      web = config.ryra.services.web.${name};
      oidc = (config.ryra.services.auth.modes.${name} or "none") == "oidc";
      auth = config.ryra.${name}.auth;
      oidcEnvironment = "/run/${name}-oidc/environment";
    in {
      imports = lib.optionals (!(settings ? environmentFile)) [ {
        sops.secrets."${name}-admin" = {
          owner = name;
          group = name;
          mode = "0400";
          restartUnits = [ "linkding.service" ];
        };
      } ];
      options.ryra.${name} = {
      auth = lib.mkOption {
        default = {};
        type = lib.types.submodule { options = contracts.auth.mkRequester {
          clientId = "ryra-${name}";
          redirectUris = [ "${web.url}/oidc/callback/" ];
          tokenEndpointAuthMethod = "client_secret_post";
        }; };
      };
      backup = lib.mkOption {
        default = {};
        type = lib.types.submodule {
          options = contracts.backup.mkRequester {
            user = name;
            sourceDirectories = [ dataDir ];
          };
        };
        description = "Linkding backup request and provider result.";
      };
      };

      config = {
        services.nginx.appendHttpConfig = lib.mkIf (web.access == "private") ''
          map $http_host $ryra_linkding_port {
            default "";
            "~:([0-9]{1,5})$" ":$1";
          }
        '';
        services.linkding = {
          enable = true;
          package = lib.mkIf oidc (pkgs.linkding.overrideAttrs (old: {
            postPatch = (old.postPatch or "") + ''
              cp ${./proxy-settings.py} bookmarks/settings/custom.py
            '';
          }));
          user = name;
          group = name;
          inherit dataDir;
          address = "127.0.0.1";
          port = settings.port or 9090;
          environmentFile = settings.environmentFile or config.sops.secrets."${name}-admin".path;
          settings = { LD_LOG_X_FORWARDED_FOR = "true"; }
            // lib.optionalAttrs oidc {
              LD_ENABLE_OIDC = "True";
              LD_DISABLE_LOGIN_FORM = "True";
              OIDC_RP_CLIENT_ID = auth.result.clientId;
              OIDC_OP_AUTHORIZATION_ENDPOINT = "${auth.result.issuerUrl}/api/oidc/authorization";
              OIDC_OP_TOKEN_ENDPOINT = "${auth.result.issuerUrl}/api/oidc/token";
              OIDC_OP_USER_ENDPOINT = "${auth.result.issuerUrl}/api/oidc/userinfo";
              OIDC_OP_JWKS_ENDPOINT = "${auth.result.issuerUrl}/jwks.json";
              OIDC_RP_SCOPES = lib.concatStringsSep " " auth.request.scopes;
              OIDC_USE_PKCE = "True";
              OIDC_VERIFY_SSL = "True";
              LD_CSRF_TRUSTED_ORIGINS = web.url;
            } // (settings.extraSettings or {});
        };
        systemd.services.linkding-oidc = lib.mkIf oidc {
          before = [ "linkding-setup.service" "linkding.service" "linkding-background-tasks.service" ];
          restartTriggers = [ auth.result.clientSecretFile ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            RuntimeDirectory = "${name}-oidc";
            RuntimeDirectoryMode = "0700";
            LoadCredential = [ "client:${auth.result.clientSecretFile}" ];
          };
          script = ''
            set -eu
            umask 077
            secret=$(${pkgs.coreutils}/bin/cat "$CREDENTIALS_DIRECTORY/client")
            if [[ -z "$secret" || "$secret" == *[!a-zA-Z0-9._~-]* ]]; then
              echo 'Linkding OIDC secrets must use RFC3986 unreserved characters.' >&2
              exit 1
            fi
            printf 'OIDC_RP_CLIENT_SECRET=%s\n' "$secret" > "$RUNTIME_DIRECTORY/environment.new"
            ${pkgs.coreutils}/bin/mv "$RUNTIME_DIRECTORY/environment.new" "$RUNTIME_DIRECTORY/environment"
          '';
        };
        systemd.services.linkding-setup = lib.mkIf oidc {
          requires = [ "linkding-oidc.service" ];
          after = [ "linkding-oidc.service" ];
          serviceConfig.EnvironmentFile = [ oidcEnvironment ];
        };
        systemd.services.linkding = lib.mkIf oidc {
          requires = [ "linkding-oidc.service" ];
          after = [ "linkding-oidc.service" ];
          serviceConfig.EnvironmentFile = [ oidcEnvironment ];
        };
        systemd.services.linkding-background-tasks = lib.mkIf (oidc && (config.services.linkding.settings.LD_DISABLE_BACKGROUND_TASKS or "False") != "True") {
          requires = [ "linkding-oidc.service" ];
          after = [ "linkding-oidc.service" ];
          serviceConfig.EnvironmentFile = [ oidcEnvironment ];
        };
        services.nginx.virtualHosts.${web.hostName}.locations."/" = {
          proxyPass = "http://127.0.0.1:${toString config.services.linkding.port}";
          proxyWebsockets = true;
          recommendedProxySettings = false;
          # SSH forwarding changes the browser port, which Django checks in the CSRF origin.
          extraConfig = ''
            proxy_set_header Host ${if web.externalUrl != null then lib.removePrefix "https://" web.externalUrl else if web.access == "private" then "$host$ryra_linkding_port" else web.hostName};
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto ${if web.externalUrl != null then "https" else "$scheme"};
            proxy_set_header X-Forwarded-Host ${if web.externalUrl != null then lib.removePrefix "https://" web.externalUrl else if web.access == "private" then "$host$ryra_linkding_port" else web.hostName};
          '';
        };
        ryra.services.state.${name} = { path = dataDir; owner = name; group = name; };
      };
    };
}
