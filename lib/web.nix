{ config, lib, ... }:
let
  sites = config.ryra.services.web;
  public = lib.filterAttrs (_: site: site.access == "public") sites;
  private = lib.filterAttrs (_: site: site.access == "private") sites;
in {
  options.ryra.services.web = lib.mkOption {
    default = {};
    type = lib.types.attrsOf (lib.types.submodule ({ name, config, ... }: {
      options = {
        access = lib.mkOption {
          type = lib.types.enum [ "private" "public" ];
          default = "private";
          description = "Private apps listen only on loopback for an encrypted Ryra connection. Public apps require a domain and automatic HTTPS.";
        };
        domain = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "DNS name for a public app.";
        };
        port = lib.mkOption {
          type = lib.types.port;
          description = "Loopback port used for private access.";
        };
        hostName = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = if config.access == "private" then "${name}.localhost" else
            if config.domain == null then "${name}.invalid" else config.domain;
          description = "Name of the app's nginx virtual host.";
        };
        url = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = if config.access == "private" then "http://127.0.0.1:${toString config.port}"
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
        assertion = builtins.all (site: site.domain != null &&
          builtins.match "[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+" site.domain != null &&
          builtins.stringLength site.domain <= 253 &&
          builtins.all (label: builtins.stringLength label <= 63) (lib.splitString "." site.domain) &&
          builtins.match "[0-9]+(\\.[0-9]+){3}" site.domain == null &&
          !builtins.any (suffix: lib.hasSuffix suffix site.domain) [ ".localhost" ".local" ".invalid" ".ts.net" ])
          (lib.attrValues public);
        message = "Public Ryra apps need a valid DNS name before automatic HTTPS can be configured.";
      }
      {
        assertion = let ports = map (site: site.port) (lib.attrValues private);
          in builtins.length ports == builtins.length (lib.unique ports);
        message = "Two private Ryra apps use the same port. Choose separate ports before applying.";
      }
      {
        assertion = builtins.all (site: !(builtins.elem site.port [ 80 443 ])) (lib.attrValues private);
        message = "Ports 80 and 443 are reserved for public HTTPS. Choose a different private Ryra app port.";
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
        if site.access == "private" then {
          listen = [ { addr = "127.0.0.1"; port = site.port; } ];
        } else {
          enableACME = true;
          forceSSL = true;
        }
      )) sites);
    };

    security.acme.acceptTerms = lib.mkIf (public != {}) true;
    networking.firewall.allowedTCPPorts = lib.mkIf (public != {}) [ 80 443 ];

    environment.etc."ryra/apps.json".text = builtins.toJSON (lib.mapAttrs (_: site: {
      inherit (site) access url;
    }) sites);
  };
}
