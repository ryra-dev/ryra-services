{
  package = pkgs: import ../../adapters/package.nix { inherit pkgs; service = "resend"; };
  meta = {
    title = "Resend";
    summary = "Connect your organization's email and domain management";
    category = "email";
    url = "https://resend.com";
    auth.resend = {
      label = "Resend";
      why = "Browser sign-in requests full account access for email and domain management. Connecting does not send email.";
      organization_owned = true;
      connect = {
        kind = "token";
        page = "https://resend.com/api-keys";
        scopes = "For sending only, use a Sending API key restricted to its domain. Full access is needed for management and reporting.";
        fields = [ "api_key" ];
      };
      driver.command = [ "ryra-adapter-resend" ];
      environment.RESEND_API_KEY = "api_key";
    };
  };
}
