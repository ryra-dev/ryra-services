{
  meta = {
    title = "Tailscale";
    summary = "Connect machines to your private network";
    category = "network";
    url = "https://tailscale.com";
    auth.tailscale = {
      label = "Tailscale";
      why = "Ryra uses this credential to enroll machines and apply reviewed private service addresses and access rules. The management credential stays in your organization's vault.";
      organization_owned = true;
      connect = {
        kind = "token";
        page = "https://console.tailscale.com/admin/settings/trust-credentials";
        scopes = ''
          1. In Tailscale, create the device tag your machines will use. Ryra defaults to tag:ryra.
          2. Generate an OAuth client with Auth Keys: Write (auth_keys), authorized for that tag.
          3. For automatic app addresses, also grant Services, Policy File and Networking Settings: Write, and Devices Core: Read.
          4. Save the client ID and client secret below. Machines enroll without a separate sign-in.
        '';
        fields = [ "client_id" "client_secret" ];
      };
    };
  };
}
