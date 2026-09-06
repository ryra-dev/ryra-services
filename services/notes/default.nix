# Ryra Notes: one organization-owned Markdown vault held on this machine.
#
# There is intentionally no nginx vhost, certificate or application login.
# `ryra sync serve` listens on loopback, and clients reach it through the SSH
# access Ryra already issues to each person. The central process has a locked
# `brain` system identity; nobody shares that identity to log in or send mail.
{
  meta = {
    summary = "Shared Markdown vault for Ryra and Obsidian";
    category = "productivity";
    url = "https://ryra.dev";

    optionRoot = [
      "ryra"
      "notes"
    ];

    # No SSL: the listener is loopback-only and every remote connection is an
    # SSH forward authenticated as the person making it.
    needs = [ "backup" ];
    provides = [ "notes" ];

    secrets = {
      "restic-notes" = {
        purpose = "Encryption password for the organization notes backup";
        owner = "brain";
        restart = [ "restic-backups-notes.service" ];
        generate = {
          format = "base64";
          bytes = 32;
        };
      };
    };
    secretAliases = { };
  };

  module =
    {
      name,
      contracts,
      settings,
      ...
    }:
    {
      config,
      lib,
      pkgs,
      ryraPackage ? null,
      ...
    }:

    let
      cfg = config.ryra.${name};
      serviceUser = "brain";
      serviceGroup = "brain";
      # Fixed under /var/lib so systemd's StateDirectory owns creation,
      # permissions and writable access even with ProtectSystem=strict. A
      # configurable path would need a mount contract in the other direction,
      # not just another string here.
      dataDir = "/var/lib/${name}";
      vaultDir = "${dataDir}/vault";
      ryraHome = "${dataDir}/.ryra";
      port = settings.port or 7972;
      editors = settings.editors or [ ];

      # The Ryra machine base supplies this as `_module.args.ryraPackage` from
      # its pinned published package. `settings.package` keeps the registry
      # usable from another base without making this input-free registry pin a
      # second copy of Ryra itself.
      package = settings.package or ryraPackage;
      packageVersion =
        if package == null then
          "0"
        else if package ? version && package.version != null then
          package.version
        else
          lib.getVersion package;
      executable =
        if package == null then
          "/run/current-system/sw/bin/ryra"
        else
          lib.getExe package;
    in
    {
      options.ryra.${name} = {
        mount = lib.mkOption {
          description = ''
            The Markdown vault and Ryra's kept CRDT state. Both are needed for
            a complete recovery: the Markdown is the current content, while
            the kept updates preserve merge history across clients.
          '';
          type = contracts.mount;
          readOnly = true;
          default = {
            path = dataDir;
            owner = serviceUser;
            group = serviceGroup;
          };
        };

        backup = lib.mkOption {
          description = "Backup configuration for the complete notes state.";
          default = { };
          type = lib.types.submodule {
            options = contracts.backup.mkRequester {
              user = serviceUser;
              sourceDirectories = [ dataDir ];
            };
          };
        };

        vaultPath = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = vaultDir;
          description = "Directory to open directly in Obsidian on this machine.";
        };

        port = lib.mkOption {
          type = lib.types.port;
          readOnly = true;
          default = port;
          description = "Loopback-only Ryra Notes synchronization port.";
        };
      };

      config = {
        assertions = [
          {
            assertion = package != null;
            message = ''
              ryra/notes needs the Ryra CLI package. Import it from the Ryra
              base template, or pass `settings.package` for this service.
            '';
          }
          {
            # 0.1.17 can order an attachment replacement and a subsequent
            # deletion at the same millisecond, causing the present copy to
            # win the tie and reappear. The fix advances local operations past
            # the state they observed and ships with the next CLI release.
            assertion = package == null || lib.versionAtLeast packageVersion "0.1.18";
            message = ''
              ryra/notes needs Ryra CLI 0.1.18 or newer; ${packageVersion} has
              a known attachment-deletion resurrection bug. Publish the fix
              and bump the base template's Ryra package before deploying it.
            '';
          }
          {
            assertion = builtins.all (
              editor:
              config.users.users ? ${editor}
              && config.users.users.${editor}.isNormalUser
            ) editors;
            message = ''
              ryra/notes `settings.editors` must name normal organization
              users already declared on this machine.
            '';
          }
        ];

        users.groups.${serviceGroup} = { };
        users.users = {
          ${serviceUser} = {
            isSystemUser = true;
            group = serviceGroup;
            home = dataDir;
            createHome = false;
          };
        }
        // lib.genAttrs (builtins.filter (editor: editor != serviceUser) editors) (_: {
          extraGroups = [ serviceGroup ];
        });

        systemd.services."ryra-${name}" = {
          description = "Ryra organization notes vault";
          wantedBy = [ "multi-user.target" ];
          after = [ "local-fs.target" ];

          environment = {
            HOME = dataDir;
            RYRA_HOME = ryraHome;
            USER = serviceUser;
          };

          # `serve` requires an existing canonical directory. StateDirectory
          # creates its parent with the ownership and mode below first.
          preStart = ''
            mkdir -p ${lib.escapeShellArg vaultDir} ${lib.escapeShellArg ryraHome}
          '';
          script = ''
            exec ${lib.escapeShellArg executable} sync serve \
              ${lib.escapeShellArg vaultDir} --port ${toString port}
          '';

          serviceConfig = {
            User = serviceUser;
            Group = serviceGroup;
            StateDirectory = name;
            StateDirectoryMode = "0770";
            UMask = "0007";
            Restart = "on-failure";
            RestartSec = "2s";

            # It needs its state directory and a loopback TCP socket, and no
            # machine authority beyond those two things.
            NoNewPrivileges = true;
            PrivateDevices = true;
            PrivateTmp = true;
            ProtectClock = true;
            ProtectControlGroups = true;
            ProtectHome = true;
            ProtectHostname = true;
            ProtectKernelLogs = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectSystem = "strict";
            RestrictAddressFamilies = [
              "AF_UNIX"
              "AF_INET"
              "AF_INET6"
            ];
            RestrictRealtime = true;
            LockPersonality = true;
            CapabilityBoundingSet = "";
          };
        };

        ryra.services.state.${name} = {
          inherit (cfg.mount) path owner group;
        };
      };
    };
}
