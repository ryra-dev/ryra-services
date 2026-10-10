{
  meta = {
    title = "Nextcloud";
    description = builtins.readFile ./README.md;
    summary = "Files, calendar and contacts";
    category = "productivity";
    url = "https://nextcloud.com";
    optionRoot = [ "ryra" "nextcloud" ];
    needs = [ "secrets" "backup" ];
    provides = [];
    web.port = 8082;
    web.authModes = [ "none" "oidc" ];
    secrets = {
      "nextcloud-adminpass" = {
        purpose = "Nextcloud admin account password";
        generate = { format = "hex"; bytes = 32; };
      };
      "restic-nextcloud" = {
        purpose = "Encryption password for Nextcloud's backup repository";
        owner = "nextcloud";
        restart = [ "restic-backups-nextcloud.service" ];
        generate = { format = "base64"; bytes = 32; };
      };
    };
    secretAliases = {};
  };

  module = { name, contracts, settings }:
    { config, lib, pkgs, ... }:
    let
      cfg = config.services.nextcloud;
      web = config.ryra.services.web.${name};
      occ = "${cfg.occ}/bin/nextcloud-occ";
      dataDir = "/var/lib/${name}";
      database = lib.escapeShellArg cfg.config.dbname;
      backupDir = "${dataDir}/.ryra-backup";
      dump = lib.escapeShellArg "${backupDir}/database.dump";
      postgres = config.services.postgresql.package;
      oidc = (config.ryra.services.auth.modes.${name} or "none") == "oidc";
      auth = config.ryra.${name}.auth;
      oidcApp = settings.oidcApp or cfg.package.packages.apps.user_oidc;
      issuerPrefix = "${lib.removeSuffix "/" auth.result.issuerUrl}/";
      phpIssuerPrefix = "'${lib.replaceStrings [ "\\" "'" ] [ "\\\\" "\\'" ] issuerPrefix}'";
    in {
      imports = lib.optionals (!(settings ? adminPasswordFile)) [ {
        sops.secrets."${name}-adminpass" = {
          mode = "0400";
          restartUnits = [ "nextcloud-setup.service" ];
        };
      } ];
      options.ryra.${name} = {
      auth = lib.mkOption {
        default = {};
        type = lib.types.submodule { options = contracts.auth.mkRequester {
          clientId = "ryra-${name}";
          redirectUris = [ "${web.url}/apps/user_oidc/code" ];
          scopes = [ "openid" "profile" "email" "groups" ];
          tokenEndpointAuthMethod = "client_secret_post";
        }; };
      };
      backup = lib.mkOption {
        default = {};
        type = lib.types.submodule {
          options = contracts.backup.mkRequester {
            user = "nextcloud";
            sourceDirectories = [ dataDir ];
            beforeBackup = [ ''
              ${occ} maintenance:mode --on
              umask 077
              ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg backupDir}
              ${postgres}/bin/pg_dump --format=custom --file=${dump} ${database}
            '' ];
            afterBackup = [ "${occ} maintenance:mode --off" ];
            beforeRestore = [ "${occ} maintenance:mode --on" ];
            afterRestore = [ ''
              ${pkgs.util-linux}/bin/runuser -u nextcloud -- \
                ${postgres}/bin/pg_restore --clean --if-exists --no-owner \
                --single-transaction --dbname=${database} ${dump}
              ${occ} maintenance:data-fingerprint
              ${occ} maintenance:mode --off
            '' ];
          };
        };
        description = "Nextcloud file and database backup request and provider result.";
      };
      };

      config = {
        ryra.services.web.${name}.healthPath = "/status.php";
        services.nextcloud = {
          enable = true;
          package = lib.mkIf (settings ? package) settings.package;
          hostName = web.hostName;
          home = dataDir;
          https = web.access == "public";
          database.createLocally = true;
          configureRedis = true;
          extraApps = lib.mkIf oidc {
            # Nextcloud blocks private addresses by default, including the configured tailnet issuer.
            user_oidc = oidcApp.overrideAttrs (old: {
              postPatch = (old.postPatch or "") + ''
                substituteInPlace lib/Helper/HttpClientHelper.php \
                  --replace-fail 'if ($this->shouldDisableSSLVerification()) {' ${lib.escapeShellArg ''
                    if (str_starts_with($url, ${phpIssuerPrefix})) {
                      $options['nextcloud']['allow_local_address'] = true;
                    }
                    if ($this->shouldDisableSSLVerification()) {
                  ''}
              '';
            });
          };
          config = {
            dbtype = "pgsql";
            adminuser = settings.adminUser or "admin";
            adminpassFile = settings.adminPasswordFile or config.sops.secrets."${name}-adminpass".path;
          };
          settings = {
            default_phone_region = settings.phoneRegion or "NO";
            trusted_domains = lib.optionals (web.access == "private") ([ "127.0.0.1" "localhost" ]
              ++ lib.optional (web.externalUrl != null) (lib.removePrefix "https://" web.externalUrl));
            "overwrite.cli.url" = web.url;
          } // lib.optionalAttrs (web.externalUrl != null) {
            overwritehost = lib.removePrefix "https://" web.externalUrl;
            overwriteprotocol = "https";
          } // lib.optionalAttrs oidc {
            user_oidc.use_pkce = true;
          } // (settings.extraSettings or {});
          poolSettings = {
            pm = "ondemand";
            "pm.max_children" = 4;
            "pm.process_idle_timeout" = "10s";
          };
        };

        systemd.services.nextcloud-oidc = lib.mkIf oidc {
          wantedBy = [ "multi-user.target" ];
          requires = [ "nextcloud-setup.service" ];
          after = [ "nextcloud-setup.service" ];
          restartTriggers = [ (builtins.toJSON auth.request) ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "nextcloud";
            LoadCredential = (config.systemd.services.phpfpm-nextcloud.serviceConfig.LoadCredential or [])
              ++ [ "oidc-client:${auth.result.clientSecretFile}" ];
          };
          script = ''
            ${occ} user_oidc:provider Ryra \
              --clientid=${lib.escapeShellArg auth.result.clientId} \
              --clientsecret-file="$CREDENTIALS_DIRECTORY/oidc-client" \
              --discoveryuri=${lib.escapeShellArg "${auth.result.issuerUrl}/.well-known/openid-configuration"} \
              --scope=${lib.escapeShellArg (lib.concatStringsSep " " auth.request.scopes)} \
              --mapping-uid=preferred_username --unique-uid=0 \
              --mapping-display-name=name --mapping-email=email
          '';
        };

        systemd.services.${lib.removeSuffix ".service" config.ryra.${name}.backup.result.backupService}.serviceConfig = {
          LoadCredential = config.systemd.services.phpfpm-nextcloud.serviceConfig.LoadCredential or [];
        };
        ryra.services.state.${name} = { path = dataDir; owner = "nextcloud"; group = "nextcloud"; };
      };
    };
}
