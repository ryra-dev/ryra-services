{
  meta = {
    title = "X";
    summary = "Search and read public posts on X (Twitter)";
    description = builtins.readFile ./README.md;
    category = "tools";
    url = "https://x.com";
    auth.x = {
      label = "X";
      why = "Search and read public posts using your X developer app.";
      organization_owned = true;
      connect = {
        kind = "token";
        page = "https://console.x.com";
        scopes = "Use the app-only Bearer Token from your developer app's Keys and tokens. Public read access; X API usage is billed to that app. Add API credits and set a spending limit in the developer console.";
        fields = [ "bearer_token" ];
      };
      environment.X_BEARER_TOKEN = "bearer_token";
    };
  };
}
