{ name, contracts, settings }:
{ config, lib, pkgs, ... }:
let
  providers = builtins.filter (service: service.name == name) config.ryra.services.resolved;
  qualified = if builtins.length providers == 1 then (builtins.head providers).qualified else "";
  sites = lib.filterAttrs (_: site:
    site.access == "gateway" && site.provider == qualified) config.ryra.services.web;
  keyFor = site: builtins.hashString "sha256" "${qualified}\n${site.domain}";
  unitFor = site: "ryra-cloudflare-${builtins.substring 0 32 (keyFor site)}";
  units = map (site: "${unitFor site}.service") (lib.attrValues sites);
  cfg = config.ryra.cloudflare;
  state = "/var/lib/ryra-cloudflare";
  runtime = "/run/ryra-cloudflare";
  manifest = pkgs.writeText "ryra-cloudflare-sites.json" (builtins.toJSON {
    provider = qualified;
    sites = lib.mapAttrsToList (_: site: { inherit (site) domain port hostName; }) sites;
  });
in {
  options.ryra.cloudflare.package = lib.mkPackageOption pkgs "cloudflared" {};
  options.ryra.cloudflare.backup = lib.mkOption {
    default = {};
    type = lib.types.submodule { options = contracts.backup.mkRequester {
      user = "root";
      sourceDirectories = [ state ];
      excludePatterns = [ "${state}/lock" "${state}/.owner.*" "${state}/claims/.claim.*" ];
      beforeBackup = [ "${pkgs.systemd}/bin/systemctl stop ryra-cloudflare-setup.service" ];
      afterBackup = [ "${pkgs.systemd}/bin/systemctl start ryra-cloudflare-setup.service" ];
      beforeRestore = [ "${pkgs.systemd}/bin/systemctl stop ryra-cloudflare-setup.service" ];
      afterRestore = [ "${pkgs.systemd}/bin/systemctl start ryra-cloudflare-setup.service" ];
    }; };
  };

  config = {
    assertions = [
      {
        assertion = builtins.length providers == 1;
        message = "The Cloudflare gateway must resolve to one qualified enabled service.";
      }
      {
        assertion = builtins.length (lib.attrNames sites) <= 32;
        message = "A Cloudflare gateway supports at most 32 hostnames per machine.";
      }
      {
        assertion = lib.versionAtLeast cfg.package.version "2025.4.0";
        message = "Cloudflare gateway connections require cloudflared 2025.4.0 or newer for private token files.";
      }
      {
        assertion = builtins.all (site: site.domain != null && site.url == "https://${site.domain}" &&
          builtins.all (listener: listener.addr == "127.0.0.1" && listener.port == site.port && !listener.ssl)
            config.services.nginx.virtualHosts.${site.hostName}.listen &&
          config.services.nginx.virtualHosts.${site.hostName}.listen != []) (lib.attrValues sites);
        message = "Cloudflare gateway sites need a canonical HTTPS domain and an HTTP nginx listener restricted to their loopback port.";
      }
    ];

    ryra.services.state.${name} = { path = state; owner = "root"; group = "root"; };

    systemd.services = {
      ryra-cloudflare-setup = {
        description = "Reconcile owned Cloudflare web gateways";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ] ++ units;
        after = [ "network-online.target" ];
        before = units;
        path = [ pkgs.bash pkgs.coreutils pkgs.curl pkgs.jq pkgs.util-linux ];
        restartTriggers = [ manifest ./runtime.sh ];
        script = ''
          exec bash ${./runtime.sh} ${manifest} ${state} ${runtime}
        '';
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = "30s";
          TimeoutStartSec = "5min";
          TimeoutStopSec = "10s";
          StateDirectory = "ryra-cloudflare";
          StateDirectoryMode = "0700";
          RuntimeDirectory = "ryra-cloudflare";
          RuntimeDirectoryMode = "0700";
          RuntimeDirectoryPreserve = true;
          UMask = "0077";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
          StandardInput = "null";
        };
      };
    } // lib.mapAttrs' (_: site: lib.nameValuePair (unitFor site) {
      description = "Cloudflare gateway for ${site.domain}";
      wantedBy = [ "multi-user.target" ];
      requires = [ "ryra-cloudflare-setup.service" "nginx.service" ];
      after = [ "ryra-cloudflare-setup.service" "nginx.service" ];
      partOf = [ "ryra-cloudflare-setup.service" "nginx.service" ];
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/cloudflared tunnel --no-autoupdate run --token-file %d/tunnel";
        LoadCredential = [ "tunnel:${runtime}/${keyFor site}.token" ];
        DynamicUser = true;
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStopSec = "30s";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        CapabilityBoundingSet = "";
        UnsetEnvironment = [ "CLOUDFLARE_ACCOUNT_ID" "CLOUDFLARE_API_TOKEN" ];
        StandardInput = "null";
      };
    }) sites;
  };
}
