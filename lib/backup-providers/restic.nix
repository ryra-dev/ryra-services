# Restic implementation of the provider-neutral backup bus declared by
# services-module.nix.
#
# This is ours, but deliberately thin: NixOS already owns the Restic systemd
# service and wrapper. This module translates Ryra's backup contract into those
# native options, adds the stable restore CLI promised by the contract, and
# nothing more.
{
  # name -> {
  #   path = <any repository Restic accepts>;
  #   environmentFile ? <file with repository credentials>;
  #   credentialService ? <unit that prepares/renews that file>;
  # }
  #
  # Ryra's deployment layer resolves this from the organization's default
  # storage target. The Restic password is deliberately separate: storage
  # credentials open the bucket, while this password decrypts its contents.
  repositoryFor,

  # null means this module declares `sops.secrets.restic-<name>` itself. A host
  # with another vault provider can supply `name: "/run/..."` and this module
  # will not mention sops at all.
  passwordFileFor ? null,

  onCalendar ? "hourly",
  retention ? {
    keep_within = "1d";
    keep_hourly = 24;
    keep_daily = 7;
    keep_weekly = 4;
    keep_monthly = 6;
  },
}:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  requests = config.ryra.services.backup.requests;
  unitName = name: "restic-backups-${name}";
  restoreName = name: "ryra-backup-${name}";
  resolved = name: repositoryFor name;

  passwordFile =
    name:
    if passwordFileFor == null then
      config.sops.secrets."restic-${name}".path
    else
      passwordFileFor name;

  pruneOpts = lib.mapAttrsToList (
    name: value: "--${builtins.replaceStrings [ "_" ] [ "-" ] name} ${toString value}"
  ) retention;

  restoreScript =
    name:
    pkgs.writeShellApplication {
      name = restoreName name;
      runtimeInputs = [
        pkgs.jq
        pkgs.systemd
      ];
      text = ''
        usage() {
          echo "usage: ${restoreName name} snapshots | backup | restore <snapshot> | exec <restic arguments>" >&2
          exit 2
        }

        command="''${1:-}"
        case "$command" in
          snapshots)
            shift
            restic-${name} snapshots --json "$@" | jq -r '.[].id'
            ;;
          backup)
            shift
            test "$#" -eq 0 || usage
            systemctl start --wait ${unitName name}.service
            ;;
          restore)
            test "$#" -eq 2 || usage
            ${lib.concatStringsSep "\n" requests.${name}.beforeRestore}
            restic-${name} restore "$2" --target /
            ${lib.concatStringsSep "\n" requests.${name}.afterRestore}
            ;;
          exec)
            shift
            test "$#" -gt 0 || usage
            exec restic-${name} "$@"
            ;;
          *)
            usage
            ;;
        esac
      '';
    };
in
{
  imports = lib.optionals (passwordFileFor == null) [
    # Kept as a conditional import rather than `mkIf`: when a host supplies a
    # different password file provider, the `sops.secrets` option genuinely
    # need not exist.
    ({ config, lib, ... }: {
      sops.secrets = lib.mapAttrs' (
        name: request:
        lib.nameValuePair "restic-${name}" {
          owner = request.user;
          group = "root";
          mode = "0400";
          restartUnits = [ "${unitName name}.service" ];
        }
      ) config.ryra.services.backup.requests;
    })
  ];

  config = lib.mkMerge [
    {
      # NixOS supplies the timer, oneshot service, repository initialization
      # and credential-aware `restic-<name>` wrapper.
      services.restic.backups = lib.mapAttrs (
        name: request:
        let
          repo = resolved name;
        in
        {
          inherit (request) user;
          repository = repo.path;
          environmentFile = repo.environmentFile or null;
          paths = request.sourceDirectories;
          exclude = request.excludePatterns;
          passwordFile = passwordFile name;
          initialize = true;
          createWrapper = true;
          timerConfig = {
            OnCalendar = config.ryra.services.backup.onCalendar.${name} or onCalendar;
            RandomizedDelaySec = "5m";
            Persistent = true;
          };
          inherit pruneOpts;
          backupPrepareCommand = lib.concatStringsSep "\n" ([ "set -e" ] ++ request.beforeBackup);
          backupCleanupCommand = lib.concatStringsSep "\n" ([ "set -e" ] ++ request.afterBackup);
        }
      ) requests;

      # A local path still needs creating. This preserves the former
      # `/srv/backups/<service>` behavior, although an organization storage
      # target is the production default: a directory on the same disk is not
      # disaster recovery.
      systemd.tmpfiles.rules = lib.flatten (
        lib.mapAttrsToList (
          name: request:
          let
            path = (resolved name).path;
          in
          lib.optionals (lib.hasPrefix "/" path) [
            "d '${path}' 0750 ${request.user} root - -"
          ]
        ) requests
      );

      environment.systemPackages = lib.mapAttrsToList (name: _: restoreScript name) requests;

      ryra.services.backup.results = lib.mapAttrs (
        name: _: {
          backupService = "${unitName name}.service";
          restoreScript = restoreName name;
        }
      ) requests;
    }

    # A short-lived organization storage lease may need a unit to materialize
    # or renew its environment file before Restic starts.
    {
      systemd.services = lib.mapAttrs' (
        name: _:
        let
          service = (resolved name).credentialService or null;
        in
        lib.nameValuePair (unitName name) (lib.mkIf (service != null) {
          after = [ service ];
          requires = [ service ];
        })
      ) requests;
    }
  ];
}
