# Services declare paths and hooks; providers choose storage and scheduling.
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
      beforeRestore ? [ ],
      afterRestore ? [ ],
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

      beforeBackup = mkOption {
        description = "Commands to run before the backup.";
        type = types.listOf types.str;
        default = beforeBackup;
      };

      afterBackup = mkOption {
        description = "Commands to run after the backup.";
        type = types.listOf types.str;
        default = afterBackup;
      };

      beforeRestore = mkOption {
        description = "Commands to run before restoring a backup.";
        type = types.listOf types.str;
        default = beforeRestore;
      };

      afterRestore = mkOption {
        description = "Commands to run after a successful restore.";
        type = types.listOf types.str;
        default = afterRestore;
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
