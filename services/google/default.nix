let
  registration = {
    "/connect/profile/client_id" = {
      env = "RYRA_GOOGLE_CLIENT_ID";
      file = { env = "RYRA_GOOGLE_CLIENT_FILE"; config = "ryra/publisher/google-desktop.json"; pointer = "/installed/client_id"; };
    };
    "/connect/profile/client_secret" = {
      env = "RYRA_GOOGLE_CLIENT_SECRET";
      file = { env = "RYRA_GOOGLE_CLIENT_FILE"; config = "ryra/publisher/google-desktop.json"; pointer = "/installed/client_secret"; };
    };
  };
  profile = {
    authorize = "https://accounts.google.com/o/oauth2/v2/auth";
    token = "https://oauth2.googleapis.com/token";
    client_id = "";
    client_secret = null;
    identity = {
      url = "https://openidconnect.googleapis.com/v1/userinfo";
      subject = "/sub";
      label = [ "/email" ];
      require."/email_verified" = true;
    };
    scope_aliases."https://www.googleapis.com/auth/userinfo.email" = "email";
  };
in
{
  package = pkgs: import ../../adapters/package.nix { inherit pkgs; service = "google"; };
  meta = {
    title = "Google Workspace";
    summary = "Gmail, Calendar, Drive and a company directory";
    category = "productivity";
    url = "https://workspace.google.com";
    adapters = {
      google-files = {
        label = "Google Drive";
        command = [ "ryra-adapter-google" ];
        connection = "google";
        files = {
          start = "root";
          permission = { id = "drive"; choices = [ "selected-files" "read" "write" ]; };
          hint = "Browse Drive with this account's granted access. Google Docs, Sheets and Slides are exported as Word, Excel and PowerPoint files.";
        };
      };
      google-directory = {
        label = "Google Workspace directory";
        command = [ "ryra-adapter-google" ];
        connection = "google-directory";
        directory = true;
      };
    };
    auth = {
      google = {
        label = "Google Workspace";
        why = "Connect your Gmail, Calendar and Drive with the access you choose.";
        settings = registration;
        environment = { GOOGLE_ACCESS_TOKEN = "access_token"; GOOGLE_ACCOUNT_EMAIL = "account"; };
        connect = {
          kind = "oauth2";
          profile = profile // {
            parameters = { access_type = "offline"; prompt = "consent select_account"; include_granted_scopes = "false"; };
            scopes = [ "openid" "email" ];
            permissions = [
              {
                id = "drive"; label = "Google Drive"; default = "selected-files";
                choices = [
                  { id = "off"; label = "No access"; scopes = [ ]; }
                  { id = "selected-files"; label = "Selected files"; scopes = [ "https://www.googleapis.com/auth/drive.file" ]; parameters = { trigger_onepick = "true"; allow_multiple = "true"; }; }
                  { id = "read"; label = "Read files"; scopes = [ "https://www.googleapis.com/auth/drive.readonly" ]; }
                  { id = "write"; label = "Read and change files"; scopes = [ "https://www.googleapis.com/auth/drive" ]; }
                ];
              }
              {
                id = "gmail"; label = "Gmail"; default = "read";
                choices = [
                  { id = "off"; label = "No access"; scopes = [ ]; }
                  { id = "read"; label = "Read mail"; scopes = [ "https://www.googleapis.com/auth/gmail.readonly" ]; }
                  { id = "write"; label = "Read, manage and send mail"; scopes = [ "https://www.googleapis.com/auth/gmail.modify" ]; }
                ];
              }
              {
                id = "calendar"; label = "Google Calendar"; default = "off";
                choices = [
                  { id = "off"; label = "No access"; scopes = [ ]; }
                  { id = "read"; label = "Read events"; scopes = [ "https://www.googleapis.com/auth/calendar.events.readonly" ]; }
                  { id = "write"; label = "Read and change events"; scopes = [ "https://www.googleapis.com/auth/calendar.events" ]; }
                ];
              }
            ];
          };
        };
      };
      google-directory = {
        label = "Google Workspace directory";
        why = "Review people before inviting them to an organization";
        settings = registration;
        environment = { GOOGLE_ACCESS_TOKEN = "access_token"; GOOGLE_ACCOUNT_EMAIL = "account"; };
        connect = {
          kind = "oauth2";
          profile = profile // {
            parameters = { access_type = "online"; prompt = "consent select_account"; include_granted_scopes = "false"; };
            scopes = [ "openid" "email" "https://www.googleapis.com/auth/admin.directory.user.readonly" ];
            persistent = false;
          };
        };
      };
    };
  };
}
