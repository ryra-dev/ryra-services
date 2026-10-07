{
  meta = {
    title = "Tailscale";
    summary = "Connect machines and private services to your tailnet";
    category = "network";
    url = "https://tailscale.com";
    auth.tailscale = {
      label = "Tailscale";
      why = "Enrol machines and publish private services on your organization's tailnet.";
      organization_owned = true;
      connect = {
        kind = "token";
        page = "https://login.tailscale.com/admin/settings/oauth";
        scopes = "auth_keys, services, devices:core";
        fields = [ "client_id" "client_secret" ];
      };
    };
  };
}
