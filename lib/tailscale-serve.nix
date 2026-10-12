{ config, lib, pkgs, ... }:
let
  sites = lib.filterAttrs (_: site: site.access == "tailnet") config.ryra.services.web;
  validDomain = domain: domain != null && builtins.stringLength domain <= 253 &&
    builtins.match "[a-z0-9]([a-z0-9-]*[a-z0-9])?\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?\\.ts\\.net" domain != null;
in {
  config = lib.mkIf (sites != {}) {
    assertions = [
      {
        assertion = config.services.tailscale.enable;
        message = "Private Tailscale apps require this machine to be connected to Tailscale.";
      }
      {
        assertion = builtins.all (site: validDomain site.domain && !site.privateHttps &&
          site.externalUrl == "https://${site.domain}:${toString site.port}") (lib.attrValues sites);
        message = "Tailscale apps need this machine's full .ts.net name and a private port. Tailscale manages their HTTPS certificates.";
      }
    ];
    networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts =
      map (site: site.port) (lib.attrValues sites);
    systemd.services = lib.mapAttrs' (name: site: lib.nameValuePair "ryra-serve-${name}" {
      description = "Private Tailscale access for ${name}";
      wantedBy = [ "multi-user.target" ];
      wants = [ "tailscaled-autoconnect.service" ];
      after = [ "tailscaled.service" "tailscaled-autoconnect.service" "nginx.service" ];
      requires = [ "tailscaled.service" "nginx.service" ];
      path = [ config.services.tailscale.package pkgs.jq ];
      script = ''
        set -eu
        actual=$(tailscale status --json | jq -er '.Self.DNSName | rtrimstr(".")')
        if [ "$actual" != ${lib.escapeShellArg site.domain} ]; then
          echo "The declared Tailscale name does not match this machine. Review its private app address." >&2
          exit 1
        fi
        if ! tailscale status --json | jq -e --arg domain "$actual" '(.CertDomains // []) | index($domain) != null' >/dev/null; then
          echo "Enable HTTPS certificates in your Tailscale DNS settings, then retry private app setup." >&2
          exit 1
        fi
        tailscale serve status --json | jq -e --arg port ${lib.escapeShellArg (toString site.port)} '
          [.. | objects | .TCP? // empty | has($port)] | any | not
        ' >/dev/null || {
          echo "This private app port is already used by another Tailscale Serve route." >&2
          exit 1
        }
        exec tailscale serve --bg=false --https=${toString site.port} http://127.0.0.1:${toString site.port}
      '';
      serviceConfig = {
        Restart = "always";
        RestartSec = "5s";
        TimeoutStopSec = "15s";
        StandardInput = "null";
        UMask = "0077";
      };
    }) sites;
  };
}
