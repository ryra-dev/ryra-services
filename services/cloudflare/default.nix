{
  package = pkgs: import ../../adapters/package.nix { inherit pkgs; service = "cloudflare"; };
  meta = {
    title = "Cloudflare";
    summary = "Publish sites and manage DNS, tunnels and HTTPS";
    category = "network";
    url = "https://cloudflare.com";
    auth.cloudflare = {
      label = "Cloudflare";
      why = "Publish websites and connect applications through your organization's Cloudflare account.";
      organization_owned = true;
      connect = {
        kind = "token";
        page = "https://dash.cloudflare.com/?to=/:account/api-tokens";
        scopes = "Use an account API token and your Account ID. Choose only the permissions needed: Pages Edit, DNS Edit with Zone Read, Tunnel Edit, or SSL and Certificates Edit, scoped to the intended account and zones.";
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
