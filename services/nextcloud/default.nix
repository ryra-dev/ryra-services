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
    in {
      options.ryra.${name}.backup = lib.mkOption {
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

      config = {
        ryra.services.web.${name}.healthPath = "/status.php";
        services.nextcloud = {
          enable = true;
          package = settings.package or pkgs.nextcloud32;
          hostName = web.hostName;
          home = dataDir;
          https = web.access == "public";
          database.createLocally = true;
          configureRedis = true;
          config = {
            dbtype = "pgsql";
            adminuser = settings.adminUser or "admin";
            adminpassFile = config.sops.secrets."${name}-adminpass".path;
          };
          settings = {
            default_phone_region = settings.phoneRegion or "NO";
            trusted_domains = lib.optionals (web.access == "private") [ "127.0.0.1" "localhost" ];
            "overwrite.cli.url" = web.url;
          } // (settings.extraSettings or {});
          poolSettings = {
            pm = "ondemand";
            "pm.max_children" = 4;
            "pm.process_idle_timeout" = "10s";
          };
        };

        sops.secrets."${name}-adminpass" = {
          mode = "0400";
          restartUnits = [ "nextcloud-setup.service" ];
        };
        systemd.services.${lib.removeSuffix ".service" config.ryra.${name}.backup.result.backupService}.serviceConfig = {
          LoadCredential = config.systemd.services.phpfpm-nextcloud.serviceConfig.LoadCredential or [];
        };
        ryra.services.state.${name} = { path = dataDir; owner = "nextcloud"; group = "nextcloud"; };
      };
    };
}
