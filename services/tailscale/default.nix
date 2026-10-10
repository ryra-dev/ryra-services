{
  meta = {
    title = "Tailscale";
    summary = "Connect machines to your private network";
    category = "network";
    url = "https://tailscale.com";
    auth.tailscale = {
      label = "Tailscale";
      why = "Ryra uses this credential to join machines to your private Tailscale network when you apply their configuration.";
      organization_owned = true;
      connect = {
        kind = "token";
        page = "https://login.tailscale.com/admin/settings/oauth";
        scopes = ''
          1. In Tailscale, create the device tag your machines will use. Ryra defaults to tag:ryra.
          2. Generate an OAuth client with Auth Keys: Write (auth_keys), authorized for that tag.
          3. Copy the client ID and client secret below.
        '';
        fields = [ "client_id" "client_secret" ];
      };
    };
  };
}
