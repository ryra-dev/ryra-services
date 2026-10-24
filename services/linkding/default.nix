{
  meta = {
    title = "Linkding";
    summary = "Bookmark manager";
    category = "productivity";
    url = "https://linkding.link";
    optionRoot = [ "ryra" "linkding" ];
    needs = [ "secrets" "backup" ];
    provides = [];
    web.port = (import ../../lib/ports.nix).linkding.frontDoor;
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
        owner = "root";
        restart = [ "restic-backups-linkding.service" ];
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
      dataDir = "/var/lib/${name}";
      web = config.ryra.services.web.${name};
      oidc = (config.ryra.services.auth.modes.${name} or "none") == "oidc";
      auth = config.ryra.${name}.auth;
      oidcEnvironment = "/run/${name}-oidc/environment";
      cfg = config.services.linkding;
      httpsUrl = lib.hasPrefix "https://" web.url;
      # Linkding imports one custom settings file (prod.py: `from .custom import *`) and exposes no
      # env var for the session cookie, so the Secure flag goes here, beside the proxy scheme header.
      customSettings = pkgs.writeText "linkding-custom-settings.py" (
        builtins.readFile ./proxy-settings.py
        + lib.optionalString httpsUrl "SESSION_COOKIE_SECURE = True\n"
      );
      backup = pkgs.writeShellApplication {
        name = "ryra-linkding-backup";
        runtimeInputs = [ pkgs.systemd pkgs.coreutils pkgs.sqlite pkgs.curl ];
        runtimeEnv = {
          LINKDING_DATA = dataDir;
          LINKDING_PORT = toString cfg.port;
          LINKDING_USER = cfg.user;
          LINKDING_GROUP = cfg.group;
          LINKDING_TASKS_UNIT = if (cfg.settings.LD_DISABLE_BACKGROUND_TASKS or "False") == "True" then "" else "linkding-background-tasks.service";
        };
        text = builtins.readFile ./backup.sh;
      };
    in {
      imports = [
        # uWSGI, built with libcap, resets its capabilities at startup and loses the
        # CAP_NET_BIND_SERVICE systemd grants it, so it cannot bind its privileged loopback
        # port. nixpkgs hardcodes uWSGI's ini and ExecStart with no option to pass
        # `cap = net_bind_service`, so the flag is wrapped onto the binary. The overlay lives in
        # a module that does not consume `pkgs`, or defining nixpkgs.overlays here would recurse.
        # uWSGI is used only by this service, and the flag is a no-op for a process not granted
        # the capability.
        ({ ... }: {
          nixpkgs.overlays = [
            (final: prev: {
              # overrideAttrs (not symlinkJoin) so `.override`, which the linkding package calls
              # to build its python plugin, and `meta` survive.
              uwsgi = prev.uwsgi.overrideAttrs (o: {
                nativeBuildInputs = (o.nativeBuildInputs or [ ]) ++ [ final.makeWrapper ];
                postFixup = (o.postFixup or "") + ''
                  wrapProgram $out/bin/uwsgi --append-flags '--cap net_bind_service'
                '';
              });
            })
          ];
        })
      ] ++ lib.optionals (!(settings ? environmentFile)) [ {
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
            user = "root";
            sourceDirectories = [ dataDir ];
            excludePatterns = [ "${dataDir}/db.sqlite3*" "${dataDir}/tasks.sqlite3*" "${dataDir}/.ryra-backup/.new.*" ];
            beforeBackup = [ "${backup}/bin/ryra-linkding-backup prepare" ];
            afterBackup = [ "${backup}/bin/ryra-linkding-backup finish" ];
            beforeRestore = [ "${backup}/bin/ryra-linkding-backup before-restore" ];
            afterRestore = [ "${backup}/bin/ryra-linkding-backup after-restore" ];
          };
        };
        description = "Linkding backup request and provider result.";
      };
      };

      config = lib.mkMerge [ (guard { unit = "linkding"; ports = [ cfg.port ]; }) {
        assertions = [{
          assertion = !oidc || builtins.all (endpoint: endpoint != null)
            [ auth.result.authorizationEndpoint auth.result.tokenEndpoint auth.result.userinfoEndpoint auth.result.jwksUri ];
          message = "Linkding's OIDC provider must supply authorization, token, userinfo and JWKS endpoints.";
        } {
          assertion = cfg.database.type == "sqlite" && cfg.dataDir == dataDir
            && (cfg.settings.LD_DB_ENGINE or "sqlite") == "sqlite"
            && (cfg.settings._NIXOS_LINKDING_DATA_DIR or dataDir) == dataDir;
          message = "Linkding automatic backups require the managed SQLite databases and data directory.";
        }];
        services.nginx.appendHttpConfig = lib.mkIf (web.access == "private") ''
          map $http_host $ryra_linkding_port {
            default "";
            "~:([0-9]{1,5})$" ":$1";
          }
        '';
        services.linkding = {
          enable = true;
          package = lib.mkIf (oidc || httpsUrl) (pkgs.linkding.overrideAttrs (old: {
            postPatch = (old.postPatch or "") + ''
              cp ${customSettings} bookmarks/settings/custom.py
            '';
          }));
          user = name;
          group = name;
          inherit dataDir;
          address = "127.0.0.1";
          port = settings.port or ports.linkding.backend;
          environmentFile = settings.environmentFile or config.sops.secrets."${name}-admin".path;
          settings = { LD_LOG_X_FORWARDED_FOR = "true"; }
            // lib.optionalAttrs oidc {
              LD_ENABLE_OIDC = "True";
              LD_DISABLE_LOGIN_FORM = "True";
              OIDC_RP_CLIENT_ID = auth.result.clientId;
              OIDC_OP_AUTHORIZATION_ENDPOINT = auth.result.authorizationEndpoint;
              OIDC_OP_TOKEN_ENDPOINT = auth.result.tokenEndpoint;
              OIDC_OP_USER_ENDPOINT = auth.result.userinfoEndpoint;
              OIDC_OP_JWKS_ENDPOINT = auth.result.jwksUri;
              OIDC_RP_SCOPES = lib.concatStringsSep " " auth.request.scopes;
              OIDC_USE_PKCE = "True";
              OIDC_VERIFY_SSL = "True";
              # Verify the OIDC issuer against the machine's system CA trust, not mozilla-django-oidc's
              # bundled certifi, which cannot know this machine's own local-HTTPS CA.
              NIX_SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
              LD_CSRF_TRUSTED_ORIGINS = web.url;
            } // (settings.extraSettings or {});
        };
        systemd.services.linkding-oidc = lib.mkIf oidc {
          requires = lib.optional (auth.result.credentialService != null) auth.result.credentialService;
          after = lib.optional (auth.result.credentialService != null) auth.result.credentialService;
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
      } ];
    };
}
