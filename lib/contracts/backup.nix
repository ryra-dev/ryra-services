# The backup contract: "these directories, as this user, are worth keeping."
#
# The requester knows WHAT to back up and never knows where it goes. The
# provider knows the repository, the schedule and the retention, and never
# knows what the files mean. That split is why the mechanism can wire restic to
# every service in the registry without any service mentioning restic.
#
# Field names and types match SHB's modules/contracts/backup.nix.
{ lib }:

let
  inherit (lib) mkOption types;
in
{
  request =
    {
      user ? "",
      sourceDirectories ? [ "/var/lib/example" ],
      excludePatterns ? [ ],
      beforeBackup ? [ ],
      afterBackup ? [ ],
    }:
    {
      user = mkOption {
        description = "User needed to access the files to back up.";
        type = types.str;
        default = user;
      };

      sourceDirectories = mkOption {
        description = "Directories to back up.";
        type = types.nonEmptyListOf types.str;
        default = sourceDirectories;
      };

      excludePatterns = mkOption {
        description = "Patterns to exclude.";
        type = types.listOf types.str;
        default = excludePatterns;
      };

      hooks = {
        beforeBackup = mkOption {
          description = ''
            Commands to run before the backup.

            Where a service needs quiescing: dumping a database, or stopping a
            writer so the snapshot is not torn.
          '';
          type = types.listOf types.str;
          default = beforeBackup;
        };

        afterBackup = mkOption {
          description = "Commands to run after the backup.";
          type = types.listOf types.str;
          default = afterBackup;
        };
      };
    };

  result =
    {
      backupService ? "backup.service",
      restoreScript ? "restore",
    }:
    {
      backupService = mkOption {
        description = "Systemd service that performs the backup.";
        type = types.str;
        default = backupService;
      };

      restoreScript = mkOption {
        description = ''
          Executable that lists and restores snapshots.

          By convention it takes `snapshots`, `backup`, `restore <snapshot>`
          and `exec <args>`. Keeping that CLI identical across providers is
          what lets a restore runbook survive swapping restic for something
          else.
        '';
        type = types.str;
        default = restoreScript;
      };
    };
}
