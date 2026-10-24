{ config, lib, pkgs, ... }:
let
  sites = config.ryra.services.web;
  public = lib.filterAttrs (_: site: site.access == "public") sites;
  addressed = lib.filterAttrs (_: site: builtins.elem site.access [ "public" "gateway" ]) sites;
  gateways = lib.listToAttrs (map (site: lib.nameValuePair site.hostName site)
    (lib.attrValues (lib.filterAttrs (_: site: site.access == "gateway") sites)));
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
  # Private apps are served over HTTPS from the machine's own CA (lib/local-https.nix), not ACME, so
  # only public apps use the direct-HTTPS certificate machinery.
  directHttps = public;
  automatic = lib.filterAttrs (_: site: site.certificate.mode == "automatic") directHttps;
  dns = lib.filterAttrs (_: site: site.certificate.mode == "dns") directHttps;
  supplied = lib.filterAttrs (_: site: site.certificate.mode == "supplied") directHttps;
  tlsHosts = lib.unique (map (site: (origin site).host) (lib.attrValues privateHttps));
  # Private apps use the machine's own CA, so they need no ACME HTTP-01 challenge host.
  challengeHosts = [ ];
  certificateHost = site: if site.access == "public" then site.hostName else (origin site).host;
  certificateDirectory = site: "/var/lib/ryra/certificates/${certificateHost site}";
  certificateCheck = pkgs.writeShellApplication {
    name = "ryra-check-certificates";
    runtimeInputs = [ pkgs.openssl pkgs.coreutils ];
    text = ''
      if [[ "''${1:-}" == --help ]]; then
        echo 'Validate supplied certificates on this machine. Run as the nginx service user before reloading nginx.'
        ${lib.concatMapStringsSep "\n" (site: "echo " + lib.escapeShellArg
          "${certificateHost site}: ${site.certificate.certificateFile} and ${site.certificate.keyFile}") (lib.attrValues supplied)}
        exit 0
      fi
      if (( $# != 0 )); then
        echo 'Usage: ryra-check-certificates [--help]' >&2
        exit 1
      fi
      ${lib.concatMapStringsSep "\n" (site: "${pkgs.bash}/bin/bash ${./certificate-check.sh} " +
        lib.escapeShellArgs [ (certificateHost site) site.certificate.certificateFile site.certificate.keyFile ]
      ) (lib.attrValues supplied)}
      echo 'Supplied certificate files passed validation.'
    '';
  };
  certificateConfig = site: if site.certificate.mode == "supplied" then {
    sslCertificate = site.certificate.certificateFile;
    sslCertificateKey = site.certificate.keyFile;
  } else { useACMEHost = certificateHost site; };
  # NixOS interpolates certificate paths into nginx directives without quoting.
  runtimeFile = path: path != null && builtins.match "/[a-zA-Z0-9/._+@-]+" path != null &&
    path != "/nix/store" && !lib.hasPrefix "/nix/store/" path &&
    builtins.all (part: !(builtins.elem part [ "" "." ".." ])) (builtins.tail (lib.splitString "/" path));
  validCertificate = certificate:
    (if certificate.mode == "dns" then
      certificate.dnsProvider != null && builtins.match "[a-zA-Z0-9_-]+" certificate.dnsProvider != null &&
      runtimeFile certificate.credentialsFile
    else certificate.dnsProvider == null && certificate.credentialsFile == null) &&
    (if certificate.mode == "supplied" then
      runtimeFile certificate.certificateFile && runtimeFile certificate.keyFile
    else certificate.certificateFile == null && certificate.keyFile == null);
  portOf = site: if site.privateHttps then (origin site).port else site.port;
  # Every loopback port that carries another person's traffic must be one an ordinary login
  # cannot bind, so it cannot take the port while the service restarts and receive that
  # traffic. The kernel reserves ports below this for CAP_NET_BIND_SERVICE.
  unprivilegedPortStart = 1024;
  guards = config.ryra.services.loopbackGuards;
  guardPorts = lib.concatMap (g: g.ports) guards;
  # Local-HTTPS private apps all share one loopback front door, 127.0.0.1:443, told apart by SNI,
  # so 443 counts once here however many there are. Any other private route (Tailscale, a gateway
  # origin) keeps its own port, and those must still be distinct from each other and from 443.
  frontDoorPorts = lib.optional (privateHttps != { }) 443
    ++ map portOf (lib.attrValues (lib.filterAttrs (_: site: !site.privateHttps) private));
  loopbackPorts = frontDoorPorts ++ guardPorts;
  # Ports a browser refuses to open (ERR_UNSAFE_PORT and the like), restricted to the privileged
  # range. A front-door port is reached by a browser through the tunnel, so one of these would be
  # a blank page rather than the app. Chromium, Firefox and Safari keep near-identical lists; this
  # is their shared privileged-range subset.
  browserUnsafePorts = [
    1 7 9 11 13 15 17 19 20 21 22 23 25 37 42 43 53 69 77 79 87 95 101 102 103 104 109 110 111
    113 115 117 119 123 135 137 139 143 161 179 389 427 465 512 513 514 515 526 530 531 532 540
    548 554 556 563 587 601 636 989 990 993 995
  ];
in {
  options.ryra.services.loopbackGuards = lib.mkOption {
    default = [];
    internal = true;
    type = lib.types.listOf (lib.types.submodule {
      options = {
        unit = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "systemd unit confined to these ports, or null when a container runtime binds them (privilege alone keeps a login out).";
        };
        ports = lib.mkOption { type = lib.types.listOf lib.types.port; description = "Loopback ports it listens on."; };
      };
    });
    description = ''
      Loopback listeners a service binds for another process to reach, each confined to its
      own ports by lib/loopback.nix. Asserted below to be privileged.
    '';
  };

  options.ryra.services.web = lib.mkOption {
    default = {};
    type = lib.types.attrsOf (lib.types.submodule ({ name, config, ... }: {
      options = {
        access = lib.mkOption {
          type = lib.types.enum [ "private" "public" "tailnet" "tailnet_service" "gateway" ];
          default = "private";
          description = "Private apps listen on loopback for an encrypted Ryra connection. Public apps serve HTTPS directly; gateway apps use a configured web gateway.";
        };
        provider = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Qualified enabled web gateway service, for example ryra/cloudflare. Only used with gateway access.";
        };
        domain = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "DNS name for a public or gateway app, Tailscale machine or named Tailscale service.";
        };
        hostTags = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Required host identity tags for named Tailscale services, provisioned by Ryra before deployment.";
        };
        audience = lib.mkOption {
          type = lib.types.enum [ "machine_users" "tailnet_members" ];
          default = "machine_users";
          description = "Named Tailscale service audience applied by Ryra to the tailnet policy.";
        };
        externalUrl = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = if config.access == "tailnet" && config.domain != null then
            "https://${config.domain}:${toString config.port}" else
            if builtins.elem config.access [ "tailnet_service" "gateway" ] && config.domain != null then
              "https://${config.domain}" else null;
          description = "Stable HTTPS origin provided by the machine's private access route or web gateway.";
        };
        privateHttps = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Serve the private external URL over loopback HTTPS. Automatic certificates use public port 80 for HTTP-01 challenges only.";
        };
        certificate = lib.mkOption {
          default = {};
          description = "Advanced certificate settings for direct public or private HTTPS. Tailscale and gateways manage their own certificates.";
          type = lib.types.submodule { options = {
            mode = lib.mkOption {
              type = lib.types.enum [ "automatic" "dns" "supplied" ];
              default = "automatic";
              description = "Automatic uses HTTP-01 for direct HTTPS; dns uses ACME DNS-01; supplied uses existing runtime PEM files.";
            };
            dnsProvider = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Lego DNS provider code, used only in dns mode.";
            };
            credentialsFile = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Absolute runtime environment file with the DNS provider's credentials, outside the Nix store. Used only in dns mode.";
            };
            certificateFile = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = if config.certificate.mode == "supplied" then "${certificateDirectory config}/fullchain.pem" else null;
              description = "PEM full-chain file on this machine, leaf first. Supplied mode defaults to /var/lib/ryra/certificates/<hostname>/fullchain.pem. Place it before deployment; nginx validates it on start and reload. Paths must be outside the Nix store and readable by nginx.";
            };
            keyFile = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = if config.certificate.mode == "supplied" then "${certificateDirectory config}/key.pem" else null;
              description = "Matching unencrypted PEM private key on this machine. Supplied mode defaults to /var/lib/ryra/certificates/<hostname>/key.pem. Use root:nginx ownership and mode 0640 with the default nginx group. Never put keys in Nix or git.";
            };
          }; };
        };
        port = lib.mkOption {
          type = lib.types.port;
          description = "Loopback port used for private access.";
        };
        hostName = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = if !(builtins.elem config.access [ "public" "gateway" ]) then "${name}.localhost" else
            if config.domain == null then "${name}.invalid" else config.domain;
          description = "Name of the app's nginx virtual host.";
        };
        url = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = if builtins.elem config.access [ "public" "gateway" ] then
            "https://${if config.domain == null then "${name}.invalid" else config.domain}"
            else if config.externalUrl != null then config.externalUrl else "http://127.0.0.1:${toString config.port}";
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

  # NixOS includes proxy headers inside each location, overriding server-level headers.
  options.services.nginx.virtualHosts = lib.mkOption {
    apply = lib.mapAttrs (host: vhost: if !(gateways ? ${host}) then vhost else vhost // {
      locations = lib.mapAttrs (_: location:
        if location.proxyPass == null || !location.recommendedProxySettings then location else location // {
          recommendedProxySettings = false;
          extraConfig = location.extraConfig + "\n" + ''
            proxy_set_header Host ${host};
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto https;
            proxy_set_header X-Forwarded-Host ${host};
            proxy_set_header X-Forwarded-Server $hostname;
          '';
        }
      ) vhost.locations;
    });
  };

  config = lib.mkIf (sites != {}) {
    assertions = [
      {
        assertion = builtins.all (site: site.externalUrl == null ||
          (site.access != "public" && (origin site).valid &&
            (site.access != "gateway" || site.externalUrl == site.url))) (lib.attrValues sites);
        message = "Ryra private external URLs must be HTTPS origins with valid ports and without paths, credentials or query strings.";
      }
      {
        assertion = builtins.all (site: !site.privateHttps ||
          (site.access == "private" && (origin site).valid && validDomain (origin site).host)) (lib.attrValues sites);
        message = "Private HTTPS requires a private external URL with a valid certificate hostname.";
      }
      {
        assertion = builtins.all (host: !(builtins.elem host (map (site: site.domain) (lib.attrValues public)))) tlsHosts;
        message = "A private HTTPS certificate hostname cannot also publish a Ryra app.";
      }
      {
        assertion = builtins.all (name: ((config.ryra.services.auth.modes or {}).${name} or "none") != "oidc" ||
          builtins.elem sites.${name}.access [ "public" "gateway" ] || sites.${name}.externalUrl != null) (builtins.attrNames sites);
        message = "Ryra private OIDC apps require an explicit stable HTTPS external URL.";
      }
      {
        assertion = builtins.all (site: validDomain site.domain) (lib.attrValues addressed);
        message = "Public and gateway Ryra apps require a valid DNS name.";
      }
      {
        assertion = builtins.all (site: if site.access == "gateway" then
          site.provider != null && builtins.match "[^/]+/[^/]+" site.provider != null &&
          site.externalUrl == site.url &&
          builtins.any (entry: entry.qualified == site.provider &&
            builtins.elem "web-gateway" (entry.provides or [])) (config.ryra.services.resolved or [])
          else site.provider == null) (lib.attrValues sites);
        message = "Ryra gateway access requires a qualified enabled service providing web-gateway. Other access modes cannot select a gateway provider.";
      }
      {
        assertion = builtins.length frontDoorPorts == builtins.length (lib.unique frontDoorPorts);
        message = "Two private Ryra apps use the same port. Choose separate ports before applying.";
      }
      {
        assertion = builtins.all (site: portOf site != 80 &&
          (portOf site != 443 || (site.privateHttps && public == {}))) (lib.attrValues private);
        message = "Private Ryra app ports cannot overlap public HTTP or HTTPS listeners.";
      }
      {
        assertion = let domains = map (site: site.domain) (lib.attrValues addressed);
          in builtins.length domains == builtins.length (lib.unique domains);
        message = "Two public or gateway Ryra apps use the same domain. Choose a separate address for each app.";
      }
      {
        assertion = builtins.all (site: site.certificate.mode == "automatic" ||
          site.access == "public" || (site.access == "private" && site.privateHttps)) (lib.attrValues sites);
        message = "Advanced Ryra certificates require direct public or private HTTPS. Tailscale and web gateways manage their own certificates.";
      }
      {
        assertion = builtins.all (site: builtins.all (other:
          certificateHost site != certificateHost other || site.certificate == other.certificate
        ) (lib.attrValues directHttps)) (lib.attrValues directHttps);
        message = "Ryra apps sharing a certificate hostname must use the same certificate settings.";
      }
      {
        assertion = builtins.all (port: port < unprivilegedPortStart) frontDoorPorts;
        message = "A private Ryra app's loopback listen port must be below ${toString unprivilegedPortStart} so an ordinary login cannot take it while nginx restarts. Choose a privileged port for its address.";
      }
      {
        assertion = builtins.all (port: port < unprivilegedPortStart) guardPorts;
        message = "A Ryra service's backend loopback port must be below ${toString unprivilegedPortStart} so an ordinary login cannot take it while the service restarts. The port is chosen in lib/ports.nix.";
      }
      {
        assertion = builtins.length loopbackPorts == builtins.length (lib.unique loopbackPorts);
        message = "Two Ryra loopback listeners share a port. Each front-door and backend port in lib/ports.nix must be distinct.";
      }
      {
        assertion = builtins.all (port: !(builtins.elem port browserUnsafePorts)) frontDoorPorts;
        message = "A private Ryra app's front-door port is one browsers refuse to open, so the app would load as a blank page through the tunnel. Choose a port outside the browser restricted-ports list in lib/ports.nix.";
      }
      {
        assertion = builtins.all (g: (config.systemd.services.${g.unit}.serviceConfig.SocketBindDeny or [ ]) != [ ])
          (builtins.filter (g: g.unit != null) guards);
        message = "A Ryra service binds a loopback port without a bind restriction. Apply lib/loopback.nix so a compromised service cannot take another's port.";
      }
      {
        assertion = (config.boot.kernel.sysctl."net.ipv4.ip_unprivileged_port_start" or unprivilegedPortStart) >= unprivilegedPortStart;
        message = "net.ipv4.ip_unprivileged_port_start must stay at ${toString unprivilegedPortStart} or above, or an ordinary login could bind a Ryra service's port.";
      }
    ] ++ lib.mapAttrsToList (name: site: {
      assertion = validCertificate site.certificate;
      message = "Ryra app `${name}` requires only dnsProvider and credentialsFile in dns certificate mode, only certificateFile and keyFile in supplied mode, and no extra fields in automatic mode. Files must use absolute runtime paths without whitespace, dot segments or Nix store paths.";
    }) sites;

    services.nginx = {
      serverNamesHashBucketSize = lib.mkDefault 128;
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      virtualHosts = lib.listToAttrs (lib.mapAttrsToList (_: site: lib.nameValuePair site.hostName (
        if site.access != "public" then {
          listen = [ { addr = "127.0.0.1"; port = portOf site; ssl = site.privateHttps; } ];
          extraConfig = lib.optionalString (site.access == "gateway") ''
            absolute_redirect off;
            if ($http_x_forwarded_proto = "http") {
              return 308 ${site.url}$request_uri;
            }
          '';
        } // lib.optionalAttrs site.privateHttps {
          serverName = (origin site).host;
          onlySSL = true;
          # The machine's own leaf, issued by lib/local-https.nix. One leaf carries every private
          # name on this machine, so all the loopback 443 vhosts present the same files by SNI.
          sslCertificate = "/var/lib/ryra/local-https/leaf.pem";
          sslCertificateKey = "/var/lib/ryra/local-https/key.pem";
        }
        else if site.certificate.mode == "automatic" then {
          enableACME = true;
          forceSSL = true;
        } else { onlySSL = true; } // certificateConfig site
      )) sites) // lib.listToAttrs (map (host: lib.nameValuePair "ryra-acme-${host}" {
        serverName = host;
        enableACME = true;
        listen = [ { addr = "0.0.0.0"; port = 80; } ]
          ++ lib.optional config.networking.enableIPv6 { addr = "[::]"; port = 80; };
        locations."/".return = "404";
      }) challengeHosts);
    };

    networking.hosts."127.0.0.1" = tlsHosts;
    # Keep the privileged-port boundary where the assertions above assume it. Pinned, so a
    # machine that lowers it to expose a Ryra port fails evaluation rather than quietly opening one.
    boot.kernel.sysctl."net.ipv4.ip_unprivileged_port_start" = lib.mkDefault unprivilegedPortStart;
    environment.systemPackages = lib.optional (supplied != {}) certificateCheck;
    systemd.tmpfiles.rules = lib.optionals (supplied != {}) ([
      "d /var/lib/ryra/certificates 0750 root ${config.services.nginx.group} -"
    ] ++ map (directory: "d ${directory} 0750 root ${config.services.nginx.group} -")
      (lib.unique (map certificateDirectory (lib.attrValues supplied))));
    services.nginx.preStart = lib.mkIf (supplied != {}) (lib.mkBefore "${lib.getExe certificateCheck}");
    systemd.services.nginx.serviceConfig.ExecReload = lib.mkIf (supplied != {})
      (lib.mkBefore [ (lib.getExe certificateCheck) ]);
    security.acme.acceptTerms = lib.mkIf (automatic != {} || dns != {}) true;
    security.acme.certs = lib.listToAttrs (map (site: lib.nameValuePair (certificateHost site) {
      inherit (site.certificate) dnsProvider;
      environmentFile = site.certificate.credentialsFile;
      webroot = null;
      group = config.services.nginx.group;
    }) (lib.attrValues dns));
    networking.firewall.allowedTCPPorts = lib.optionals (automatic != {}) [ 80 ]
      ++ lib.optionals (public != {}) [ 443 ];

    environment.etc."ryra/apps.json".text = builtins.toJSON (lib.mapAttrs (_: site: {
      inherit (site) access url;
    }) sites);
  };
}
