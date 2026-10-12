{ config, lib, ... }:
let
  sites = config.ryra.services.web;
  public = lib.filterAttrs (_: site: site.access == "public") sites;
  private = lib.filterAttrs (_: site: site.access != "public") sites;
  origin = site:
    let
      parts = if site.externalUrl == null then null else
        builtins.match "https://([a-zA-Z0-9.-]+)(:([1-9][0-9]{0,4}))?" site.externalUrl;
      port = if parts != null && builtins.elemAt parts 2 != null then
        lib.toInt (builtins.elemAt parts 2) else 443;
    in {
      valid = parts != null && port <= 65535;
      host = if parts == null then site.hostName else builtins.elemAt parts 0;
      inherit port;
    };
  validDomain = domain: domain != null &&
    builtins.match "[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+" domain != null &&
    builtins.stringLength domain <= 253 &&
    builtins.all (label: builtins.stringLength label <= 63) (lib.splitString "." domain) &&
    builtins.match "[0-9]+(\\.[0-9]+){3}" domain == null &&
    !builtins.any (suffix: lib.hasSuffix suffix domain) [ ".localhost" ".local" ".invalid" ".ts.net" ];
  privateHttps = lib.filterAttrs (_: site: site.access == "private" && site.privateHttps) sites;
  tlsHosts = lib.unique (map (site: (origin site).host) (lib.attrValues privateHttps));
  portOf = site: if site.privateHttps then (origin site).port else site.port;
in {
  options.ryra.services.web = lib.mkOption {
    default = {};
    type = lib.types.attrsOf (lib.types.submodule ({ name, config, ... }: {
      options = {
        access = lib.mkOption {
          type = lib.types.enum [ "private" "public" "tailnet" ];
          default = "private";
          description = "Private apps listen only on loopback for an encrypted Ryra connection. Public apps require a domain and automatic HTTPS.";
        };
        domain = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "DNS name for a public app.";
        };
        externalUrl = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = if config.access == "tailnet" && config.domain != null then
            "https://${config.domain}:${toString config.port}" else null;
          description = "Stable HTTPS origin for a private app, provided by the machine's private access route.";
        };
        privateHttps = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Obtain an HTTP-01 certificate and serve the private external URL over loopback HTTPS. Public port 80 serves challenges only.";
        };
        port = lib.mkOption {
          type = lib.types.port;
          description = "Loopback port used for private access.";
        };
        hostName = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = if config.access != "public" then "${name}.localhost" else
            if config.domain == null then "${name}.invalid" else config.domain;
          description = "Name of the app's nginx virtual host.";
        };
        url = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = if config.access != "public" then
            if config.externalUrl != null then config.externalUrl else "http://127.0.0.1:${toString config.port}"
            else "https://${config.hostName}";
          description = "App address on this machine. Loopback addresses require Ryra's encrypted machine connection.";
        };
        healthPath = lib.mkOption {
          type = lib.types.str;
          default = "/";
          description = "App path used to check that its web service answers.";
        };
      };
    }));
  };

  config = lib.mkIf (sites != {}) {
    assertions = [
      {
        assertion = builtins.all (site: site.externalUrl == null ||
          (site.access != "public" && (origin site).valid)) (lib.attrValues sites);
        message = "Ryra private external URLs must be HTTPS origins with valid ports and without paths, credentials or query strings.";
      }
      {
        assertion = builtins.all (site: !site.privateHttps ||
          (site.access == "private" && (origin site).valid && validDomain (origin site).host)) (lib.attrValues sites);
        message = "Automatic private HTTPS requires a private external URL with a valid certificate hostname.";
      }
      {
        assertion = builtins.all (host: !(builtins.elem host (map (site: site.domain) (lib.attrValues public)))) tlsHosts;
        message = "A private HTTPS certificate hostname cannot also publish a Ryra app.";
      }
      {
        assertion = builtins.all (name: ((config.ryra.services.auth.modes or {}).${name} or "none") != "oidc" ||
          sites.${name}.access == "public" || sites.${name}.externalUrl != null) (builtins.attrNames sites);
        message = "Ryra private OIDC apps require an explicit stable HTTPS external URL.";
      }
      {
        assertion = builtins.all (site: validDomain site.domain) (lib.attrValues public);
        message = "Public Ryra apps need a valid DNS name before automatic HTTPS can be configured.";
      }
      {
        assertion = let ports = map portOf (lib.attrValues private);
          in builtins.length ports == builtins.length (lib.unique ports);
        message = "Two private Ryra apps use the same port. Choose separate ports before applying.";
      }
      {
        assertion = builtins.all (site: portOf site != 80 &&
          (portOf site != 443 || (site.privateHttps && public == {}))) (lib.attrValues private);
        message = "Private Ryra app ports cannot overlap public HTTP or HTTPS listeners.";
      }
      {
        assertion = let domains = map (site: site.domain) (lib.attrValues public);
          in builtins.length domains == builtins.length (lib.unique domains);
        message = "Two public Ryra apps use the same domain. Choose a separate address for each app.";
      }
    ];

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      virtualHosts = lib.listToAttrs (lib.mapAttrsToList (_: site: lib.nameValuePair site.hostName (
        if site.access != "public" then {
          listen = [ { addr = "127.0.0.1"; port = portOf site; ssl = site.privateHttps; } ];
        } // lib.optionalAttrs site.privateHttps {
          serverName = (origin site).host;
          onlySSL = true;
          useACMEHost = (origin site).host;
        } else {
          enableACME = true;
          forceSSL = true;
        }
      )) sites) // lib.listToAttrs (map (host: lib.nameValuePair "ryra-acme-${host}" {
        serverName = host;
        enableACME = true;
        listen = [ { addr = "0.0.0.0"; port = 80; } ]
          ++ lib.optional config.networking.enableIPv6 { addr = "[::]"; port = 80; };
        locations."/".return = "404";
      }) tlsHosts);
    };

    networking.hosts."127.0.0.1" = tlsHosts;
    security.acme.acceptTerms = lib.mkIf (public != {} || privateHttps != {}) true;
    networking.firewall.allowedTCPPorts = lib.optionals (public != {} || privateHttps != {}) [ 80 ]
      ++ lib.optionals (public != {}) [ 443 ];

    environment.etc."ryra/apps.json".text = builtins.toJSON (lib.mapAttrs (_: site: {
      inherit (site) access url;
    }) sites);
  };
}
