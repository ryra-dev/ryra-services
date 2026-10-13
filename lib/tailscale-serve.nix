{ config, lib, pkgs, ... }:
let
  sites = lib.filterAttrs (_: site: builtins.elem site.access [ "tailnet" "tailnet_service" ]) config.ryra.services.web;
  namedSites = lib.filterAttrs (_: site: site.access == "tailnet_service") sites;
  machineSites = lib.filterAttrs (_: site: site.access == "tailnet") sites;
  validDomain = domain: domain != null && builtins.stringLength domain <= 253 &&
    builtins.all (label: builtins.stringLength label <= 63) (lib.splitString "." domain) &&
    builtins.match "[a-z0-9]([a-z0-9-]*[a-z0-9])?\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?\\.ts\\.net" domain != null;
  serviceName = site: "svc:${builtins.head (lib.splitString "." (if site.domain == null then "" else site.domain))}";
in {
  config = lib.mkIf (sites != {}) {
    assertions = [
      {
        assertion = config.services.tailscale.enable;
        message = "Private Tailscale apps require this machine to be connected to Tailscale.";
      }
      {
        assertion = builtins.all (site: validDomain site.domain && !site.privateHttps &&
          site.externalUrl == "https://${site.domain}:${toString site.port}") (lib.attrValues machineSites);
        message = "Tailscale apps need this machine's full .ts.net name and a private port. Tailscale manages their HTTPS certificates.";
      }
      {
        assertion = builtins.all (site: validDomain site.domain && !site.privateHttps &&
          site.externalUrl == "https://${site.domain}") (lib.attrValues namedSites);
        message = "Named Tailscale services need a service-name.tailnet-name.ts.net domain and HTTPS on port 443. Tailscale manages their certificates.";
      }
      {
        assertion = builtins.all (site: site.hostTags != [] && builtins.all
          (tag: builtins.match "tag:[a-zA-Z][a-zA-Z0-9-]*" tag != null) site.hostTags) (lib.attrValues namedSites);
        message = "Named Tailscale services require host identity tags such as tag:ryra, provisioned before deployment.";
      }
      {
        assertion = let names = map serviceName (lib.attrValues namedSites);
          in builtins.length names == builtins.length (lib.unique names);
        message = "Two Ryra apps declare the same named Tailscale service. Choose a separate service name for each app.";
      }
    ];
    networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts =
      map (site: site.port) (lib.attrValues machineSites);
    systemd.services = lib.mapAttrs' (name: site:
      let
        named = site.access == "tailnet_service";
        service = lib.escapeShellArg (serviceName site);
        domain = if site.domain == null then "" else site.domain;
        suffix = lib.concatStringsSep "." (builtins.tail (lib.splitString "." domain));
        backend = "http://127.0.0.1:${toString site.port}";
        expected = builtins.toJSON {
          TCP."443".HTTPS = true;
          Web."${domain}:443".Handlers."/".Proxy = backend;
        };
        # The pinned client replaces the advertisement list without a compare-and-swap.
        lock = ''
          set -euo pipefail
          exec 9>/run/lock/ryra-tailscale-serve.lock
          ${pkgs.util-linux}/bin/flock 9
        '';
        checkService = ''
          routes=$(tailscale serve status --json)
          if ! jq -e --arg service ${service} --argjson expected ${lib.escapeShellArg expected} '
            .Services[$service] == null or .Services[$service] == $expected
          ' <<< "$routes" >/dev/null; then
            echo "The named Tailscale service already has a different Serve configuration. Review it before applying Ryra changes." >&2
            exit 1
          fi
        '';
      in lib.nameValuePair "ryra-serve-${name}" {
      description = "Private Tailscale access for ${name}";
      wantedBy = [ "multi-user.target" ] ++ lib.optionals named [ "tailscaled.service" "nginx.service" ];
      wants = [ "tailscaled-autoconnect.service" ];
      after = [ "tailscaled.service" "tailscaled-autoconnect.service" "nginx.service" ];
      requires = [ "tailscaled.service" "nginx.service" ];
      partOf = lib.optionals named [ "tailscaled.service" "nginx.service" ];
      path = [ config.services.tailscale.package pkgs.jq ];
      script = lib.optionalString named lock + ''
        set -euo pipefail
        status=$(tailscale status --json)
        if ! jq -e '.BackendState == "Running"' <<< "$status" >/dev/null; then
          echo "Tailscale must be enrolled and Running before Ryra can serve private apps." >&2
          exit 1
        fi
        actual=$(jq -er '.Self.DNSName | rtrimstr(".")' <<< "$status")
      '' + (if named then ''
        if ! jq -e --arg suffix ${lib.escapeShellArg suffix} '
          .CurrentTailnet.MagicDNSSuffix == $suffix
        ' <<< "$status" >/dev/null; then
          echo "The declared service domain does not match this machine's Tailscale DNS suffix." >&2
          exit 1
        fi
        if ! jq -e --argjson tags ${lib.escapeShellArg (builtins.toJSON site.hostTags)} '
          (.Self.Tags // []) as $actual | ($actual | length) > 0 and ($tags - $actual | length) == 0
        ' <<< "$status" >/dev/null; then
          echo "This Tailscale host must have all declared hostTags before it can advertise the service." >&2
          exit 1
        fi
      '' else ''
        if [ "$actual" != ${lib.escapeShellArg domain} ]; then
          echo "The declared Tailscale name does not match this machine. Review its private app address." >&2
          exit 1
        fi
      '') + ''
        if ! jq -e --arg domain "$actual" '(.CertDomains // []) | index($domain) != null' <<< "$status" >/dev/null; then
          echo "Enable HTTPS certificates in your Tailscale DNS settings, then retry private app setup." >&2
          exit 1
        fi
      '' + (if named then checkService + ''
        tailscale serve --service=${service} --https=443 ${backend}
        # The pinned client's setup command discards advertisement errors.
        tailscale serve advertise ${service}
      '' else ''
        tailscale serve status --json | jq -e --arg port ${lib.escapeShellArg (toString site.port)} '
          del(.Services) | [.. | objects | .TCP? // empty | has($port)] | any | not
        ' >/dev/null || {
          echo "This private app port is already used by another Tailscale Serve route." >&2
          exit 1
        }
        exec tailscale serve --bg=false --https=${toString site.port} http://127.0.0.1:${toString site.port}
      '');
      postStop = lib.optionalString named (lock + checkService + ''
        tailscale serve drain ${service}
        if jq -e --arg service ${service} '.Services[$service] != null' <<< "$routes" >/dev/null; then
          tailscale serve clear ${service}
        fi
      '');
      serviceConfig = {
        Restart = if named then "on-failure" else "always";
        RestartSec = "5s";
        TimeoutStartSec = "60s";
        TimeoutStopSec = "15s";
        StandardInput = "null";
        UMask = "0077";
      } // lib.optionalAttrs named {
        Type = "oneshot";
        RemainAfterExit = true;
      };
    }) sites;
  };
}
