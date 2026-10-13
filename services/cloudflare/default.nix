{
  package = pkgs: import ../../adapters/package.nix { inherit pkgs; service = "cloudflare"; };
  module = import ./module.nix;
  meta = {
    title = "Cloudflare";
    summary = "Publish sites and manage DNS, tunnels and HTTPS";
    category = "network";
    url = "https://cloudflare.com";
    optionRoot = [ "ryra" "cloudflare" ];
    needs = [ "secrets" "backup" ];
    secrets.restic-cloudflare = {
      purpose = "Encryption password for gateway ownership backups";
      restart = [ "restic-backups-cloudflare.service" ];
      generate = { format = "base64"; bytes = 32; };
    };
    provides = [ "web-gateway" ];
    serviceConnections = { "ryra-cloudflare-setup" = "cloudflare"; };
    auth.cloudflare = {
      label = "Cloudflare";
      why = "Publish websites and connect applications through your organization's Cloudflare account.";
      organization_owned = true;
      connect = {
        kind = "token";
        page = "https://dash.cloudflare.com/?to=/:account/api-tokens";
        scopes = ''
          For web gateways, supply your Account ID and an API token with Account: Cloudflare Tunnel Edit for that account, plus Zone: DNS Edit, Zone Read, SSL and Certificates Read, and Zone Settings Read for only the intended zones. Gateways require active full zones with Universal SSL enabled and HTTPS enabled, using the zone apex or one subdomain label. Application authentication stays with the app or Authelia.
          For other Cloudflare actions, grant only the permissions they need, such as Pages Edit or SSL and Certificates Edit.
        '';
        fields = [ "account_id" "api_token" ];
      };
      driver = {
        command = [ "ryra-adapter-cloudflare" ];
        configuration = { client_id = ""; scopes = ""; };
        required = [ "client_id" "scopes" ];
      };
      settings = {
        "/driver/configuration/client_id".env = "RYRA_CLOUDFLARE_OAUTH_CLIENT_ID";
        "/driver/configuration/scopes".env = "RYRA_CLOUDFLARE_OAUTH_SCOPES";
      };
      environment = { CLOUDFLARE_ACCOUNT_ID = "account_id"; CLOUDFLARE_API_TOKEN = "api_token"; };
    };
  };
}
