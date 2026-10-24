let
  nixpkgs = (builtins.getFlake "path:${toString ../..}").inputs.nixpkgs;
  lib = nixpkgs.lib;
  evaluate = { web ? {}, settings ? {}, environmentFile ? true }:
    (lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ (import ../../lib/services-module.nix {
        registries.ryra.ryraServices.vexa = import ./.;
        services."ryra/vexa" = {
          inherit web;
          settings = lib.optionalAttrs environmentFile { environmentFile = "/run/vexa-test/environment"; } // settings;
        };
        backupPasswordFileFor = _: "/run/vexa-test/restic";
      }) {
        config = {
          boot.isContainer = true;
          system.stateVersion = "26.05";
          security.acme.defaults.email = "admin@example.com";
        };
        # Stands in for sops-nix, which is a host concern.
        options.sops.secrets = lib.mkOption {
          default = {};
          type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
            freeformType = lib.types.attrsOf lib.types.anything;
            options.path = lib.mkOption { type = lib.types.str; default = "/run/secrets/${name}"; };
          }));
        };
      } ];
    }).config;
  failures = c: map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
  private = evaluate {};
  public = evaluate { web = { access = "public"; domain = "meet.example.com"; }; };
  custom = evaluate { web.port = 706; settings = { uiPort = 705; apiPort = 707; model = "Systran/faster-whisper-small"; }; };
  declared = evaluate { environmentFile = false; };
  script = c: builtins.readFile (lib.getExe (lib.findFirst (p: (p.name or "") == "vexa-compose") null c.environment.systemPackages));
  unit = private.systemd.services.vexa;
  backup = private.ryra.services.backup.requests.vexa;
  stack = c: builtins.fromJSON (builtins.readFile (builtins.head (builtins.match ".*--file ([^ ]+).*" (script c))));
in
assert lib.assertMsg (builtins.all (c: failures c == []) [ private public custom declared ]) "A Vexa configuration failed NixOS assertions.";
assert failures (evaluate { settings.environmentFile = "/nix/store/unsafe-environment"; }) != [];
assert builtins.length (builtins.attrNames (stack private).services) == 10;
assert builtins.all (s: builtins.all (p: lib.hasPrefix "127.0.0.1:" p) (s.ports or [])) (builtins.attrValues (stack private).services);
assert (stack private).services.gateway.ports == [ "127.0.0.1:819:8000" ];
assert (stack custom).services.gateway.ports == [ "127.0.0.1:707:8000" ];
assert (stack custom).services.terminal.ports == [ "127.0.0.1:705:3000" ];
assert (stack custom).services.whisper.environment.WHISPER__MODEL == "Systran/faster-whisper-small";
assert (stack private).services.terminal.environment.NEXTAUTH_URL == "http://127.0.0.1:806";
assert (stack public).services.terminal.environment.NEXTAUTH_URL == "https://meet.example.com";
assert builtins.all (s: lib.hasInfix "@sha256:" s.image) (builtins.attrValues (stack private).services);
assert lib.hasInfix "--env-file /run/vexa-test/environment" (script private);
assert lib.hasInfix "--env-file /run/secrets/vexa-environment" (script declared);
assert declared.sops.secrets.vexa-environment.restartUnits == [ "vexa.service" ];
assert !(private.sops.secrets ? vexa-environment);
assert private.services.nginx.virtualHosts."vexa.localhost".locations."/".proxyPass == "http://127.0.0.1:820";
assert custom.services.nginx.virtualHosts."vexa.localhost".locations."/".proxyPass == "http://127.0.0.1:705";
assert private.networking.firewall.allowedTCPPorts == [];
assert public.networking.firewall.allowedTCPPorts == [ 80 443 ];
assert private.virtualisation.docker.enable;
assert private.ryra.services.state.vexa.path == "/var/lib/vexa";
assert unit.serviceConfig.Type == "oneshot";
assert backup.sourceDirectories == [ "/var/lib/vexa/backup" "/var/lib/vexa/storage" ];
assert lib.hasInfix "pg_dump --clean --if-exists" (lib.concatStrings backup.beforeBackup);
assert lib.hasInfix "psql -v ON_ERROR_STOP=1" (lib.concatStrings backup.afterRestore);
assert private.services.restic.backups.vexa.timerConfig.OnCalendar == "hourly";
{
  passed = [ "private" "public" "custom-ports" "declared-secret" "store-secret-denial" "loopback-only" "pinned-images" "backup-contract" ];
}
