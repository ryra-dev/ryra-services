{
  meta = {
    title = "Linkding";
    summary = "Bookmark manager";
    category = "productivity";
    url = "https://linkding.link";
    optionRoot = [ "ryra" "linkding" ];
    needs = [ "secrets" "backup" ];
    provides = [];
    web.port = 8081;
    secrets = {
      "linkding-admin" = {
        purpose = "Linkding administrator account";
        owner = "linkding";
        restart = [ "linkding.service" ];
        setup = {
          instructions = "Choose the administrator login for this service. Ryra stores the credentials securely and prepares the required file.";
          fields = [
            { name = "LD_SUPERUSER_NAME"; label = "Username"; secret = false; }
            { name = "LD_SUPERUSER_PASSWORD"; label = "Password"; secret = true; }
          ];
        };
      };
      "restic-linkding" = {
        purpose = "Encryption password for Linkding's backup repository";
        owner = "linkding";
        restart = [ "restic-backups-linkding.service" ];
        generate = { format = "base64"; bytes = 32; };
      };
    };
    secretAliases = {};
  };

  module = { name, contracts, settings }:
    { config, lib, ... }:
    let
      dataDir = "/var/lib/${name}";
      web = config.ryra.services.web.${name};
    in {
      options.ryra.${name}.backup = lib.mkOption {
        default = {};
        type = lib.types.submodule {
          options = contracts.backup.mkRequester {
            user = name;
            sourceDirectories = [ dataDir ];
          };
        };
        description = "Linkding backup request and provider result.";
      };

      config = {
        services.nginx.appendHttpConfig = lib.mkIf (web.access == "private") ''
          map $http_host $ryra_linkding_port {
            default "";
            "~:([0-9]{1,5})$" ":$1";
          }
        '';
        services.linkding = {
          enable = true;
          user = name;
          group = name;
          inherit dataDir;
          address = "127.0.0.1";
          port = settings.port or 9090;
          environmentFile = config.sops.secrets."${name}-admin".path;
          settings = { LD_LOG_X_FORWARDED_FOR = "true"; } // (settings.extraSettings or {});
        };
        services.nginx.virtualHosts.${web.hostName}.locations."/" = {
          proxyPass = "http://127.0.0.1:${toString config.services.linkding.port}";
          proxyWebsockets = true;
          recommendedProxySettings = false;
          # SSH forwarding changes the browser port, which Django checks in the CSRF origin.
          extraConfig = ''
            proxy_set_header Host ${if web.access == "private" then "$host$ryra_linkding_port" else web.hostName};
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-Forwarded-Host ${if web.access == "private" then "$host$ryra_linkding_port" else web.hostName};
          '';
        };
        sops.secrets."${name}-admin" = {
          owner = name;
          group = name;
          mode = "0400";
          restartUnits = [ "linkding.service" ];
        };
        ryra.services.state.${name} = { path = dataDir; owner = name; group = name; };
      };
    };
}
