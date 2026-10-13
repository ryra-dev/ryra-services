let
  nixpkgs = (builtins.getFlake "path:${toString ../..}").inputs.nixpkgs;
  lib = nixpkgs.lib;
  evaluate = { web ? {}, settings ? {} }:
    (lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ (import ../../lib/services-module.nix {
        registries.ryra.ryraServices.forgejo = import ./.;
        services."ryra/forgejo" = {
          inherit web;
          settings = { adminPasswordFile = "/run/forgejo-admin"; } // settings;
        };
        backupPasswordFileFor = _: "/run/forgejo-restic";
      }) {
        boot.isContainer = true;
        system.stateVersion = "26.05";
        security.acme.defaults.email = "admin@example.com";
      } ];
    }).config;
  failures = c: map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
  private = evaluate {};
  public = evaluate { web = { access = "public"; domain = "git.example.com"; }; };
  custom = evaluate { web.port = 8184; settings = { port = 3101; adminUser = "owner"; }; };
  backup = private.ryra.services.backup.requests.forgejo;
in
assert lib.assertMsg (builtins.all (c: failures c == []) [ private public custom ]) "A Forgejo configuration failed NixOS assertions.";
assert private.services.forgejo.settings.server.HTTP_ADDR == "127.0.0.1";
assert private.services.forgejo.settings.server.ROOT_URL == "http://127.0.0.1:8084/";
assert private.services.forgejo.settings.server.DISABLE_SSH;
assert private.services.forgejo.settings.service.DISABLE_REGISTRATION;
assert private.services.forgejo.settings.service.REQUIRE_SIGNIN_VIEW;
assert private.services.forgejo.settings.security.INSTALL_LOCK;
assert !private.services.forgejo.settings.session.COOKIE_SECURE;
assert private.networking.firewall.allowedTCPPorts == [];
assert public.services.forgejo.settings.server.ROOT_URL == "https://git.example.com/";
assert public.services.forgejo.settings.session.COOKIE_SECURE;
assert public.networking.firewall.allowedTCPPorts == [ 80 443 ];
assert custom.services.nginx.virtualHosts."forgejo.localhost".locations."/".proxyPass == "http://127.0.0.1:3101";
assert custom.services.forgejo.settings.server.ROOT_URL == "http://127.0.0.1:8184/";
assert lib.hasInfix (lib.escapeShellArg "SELECT count(*) FROM user WHERE lower_name = lower('owner');") custom.systemd.services.forgejo.preStart;
assert builtins.elem "admin:/run/forgejo-admin" private.systemd.services.forgejo.serviceConfig.LoadCredential;
assert failures (evaluate { settings.adminPasswordFile = "/nix/store/unsafe-password"; }) != [];
assert backup.sourceDirectories == [ "/var/lib/forgejo" ];
assert backup.excludePatterns == [];
assert lib.hasInfix "stop forgejo.service" (lib.concatStrings backup.beforeBackup);
assert lib.hasInfix "/api/healthz" (lib.concatStrings backup.afterBackup);
assert lib.hasInfix "forgejo.db-wal" (lib.concatStrings backup.beforeRestore);
assert private.services.restic.backups.forgejo.timerConfig.OnCalendar == "hourly";
{
  passed = [ "private" "public" "custom-ports" "native-login" "runtime-credential" "store-secret-denial" "backup-contract" ];
  forgejoVersion = private.services.forgejo.package.version;
}
