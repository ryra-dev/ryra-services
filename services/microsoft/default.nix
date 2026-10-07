let
  clients = builtins.fromJSON (builtins.readFile ./registration.json);
  profile = tenant: {
    authorize = "https://login.microsoftonline.com/${tenant}/oauth2/v2.0/authorize";
    token = "https://login.microsoftonline.com/${tenant}/oauth2/v2.0/token";
    callback = "localhost";
    parameters.prompt = "select_account";
    implicit_scopes = [ "openid" "profile" "email" ];
  };
  identity = {
    url = "https://graph.microsoft.com/v1.0/me?$select=id,mail,userPrincipalName";
    subject = "/id";
    label = [ "/mail" "/userPrincipalName" ];
  };
  environment = { MICROSOFT_ACCESS_TOKEN = "access_token"; MICROSOFT_ACCOUNT_EMAIL = "account"; };
  aliases = {
    "https://graph.microsoft.com/User.Read" = "User.Read";
    "https://graph.microsoft.com/Mail.Read" = "Mail.Read";
    "https://graph.microsoft.com/Mail.ReadWrite" = "Mail.ReadWrite";
    "https://graph.microsoft.com/Mail.Send" = "Mail.Send";
  };
in
{
  package = pkgs: import ../../adapters/package.nix { inherit pkgs; service = "microsoft"; };
  meta = {
    title = "Microsoft 365";
    summary = "Outlook, SharePoint and a company directory";
    category = "productivity";
    url = "https://www.microsoft.com/microsoft-365";
    adapters = {
      microsoft-files = {
        label = "SharePoint files";
        command = [ "ryra-adapter-microsoft" ];
        connection = "microsoft-files";
        files = { start = "site"; hint = "Choose a SharePoint site your administrator has granted to Ryra."; };
      };
      microsoft-directory = {
        label = "Microsoft 365 directory";
        command = [ "ryra-adapter-microsoft" ];
        connection = "microsoft-directory";
        directory = true;
      };
    };
    auth = {
      microsoft-mail = {
        label = "Outlook mail";
        why = "Connect your Microsoft mailbox with read access or explicit permission to manage and send mail.";
        inherit environment;
        settings."/connect/profile/client_id".env = "RYRA_MICROSOFT_MAIL_CLIENT_ID";
        connect = {
          kind = "oauth2";
          profile = profile "common" // {
            client_id = clients.RYRA_MICROSOFT_MAIL_CLIENT_ID;
            inherit identity;
            scopes = [ "offline_access" "https://graph.microsoft.com/User.Read" ];
            scope_aliases = aliases;
            implicit_scopes = [ "openid" "profile" "email" "Mail.Read" ];
            omitted_scopes = [ "offline_access" ];
            permissions = [ {
              id = "mail"; label = "Outlook mail"; default = "read";
              choices = [
                { id = "read"; label = "Read mail"; scopes = [ "https://graph.microsoft.com/Mail.Read" ]; }
                { id = "write"; label = "Read, manage and send mail"; scopes = [ "https://graph.microsoft.com/Mail.ReadWrite" "https://graph.microsoft.com/Mail.Send" ]; }
              ];
            } ];
          };
        };
      };
      microsoft-files = {
        label = "SharePoint files";
        why = "Use SharePoint sites explicitly granted to this application.";
        inherit environment;
        settings."/connect/profile/client_id".env = "RYRA_MICROSOFT_FILES_CLIENT_ID";
        connect = {
          kind = "oauth2";
          profile = profile "organizations" // {
            client_id = clients.RYRA_MICROSOFT_FILES_CLIENT_ID;
            identity = { url = "https://graph.microsoft.com/oidc/userinfo"; subject = "/sub"; label = [ "/email" "/name" ]; };
            scopes = [ "openid" "profile" "email" "offline_access" "https://graph.microsoft.com/Sites.Selected" ];
            scope_aliases."https://graph.microsoft.com/Sites.Selected" = "Sites.Selected";
            omitted_scopes = [ "offline_access" ];
          };
        };
      };
      microsoft-directory = {
        label = "Microsoft 365 directory";
        why = "Review people before inviting them to an organization";
        inherit environment;
        settings."/connect/profile/client_id".env = "RYRA_MICROSOFT_DIRECTORY_CLIENT_ID";
        connect = {
          kind = "oauth2";
          profile = profile "organizations" // {
            client_id = clients.RYRA_MICROSOFT_DIRECTORY_CLIENT_ID;
            inherit identity;
            scopes = [ "https://graph.microsoft.com/User.Read" "https://graph.microsoft.com/User.ReadBasic.All" ];
            scope_aliases = aliases // { "https://graph.microsoft.com/User.ReadBasic.All" = "User.ReadBasic.All"; };
            persistent = false;
          };
        };
      };
    };
  };
}
