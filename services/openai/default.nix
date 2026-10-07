{
  meta = {
    title = "OpenAI";
    summary = "Use your organization's OpenAI API account";
    category = "tools";
    url = "https://platform.openai.com";
    auth.openai = {
      label = "OpenAI";
      why = "Charge conversation voice to your organization's OpenAI project.";
      organization_owned = true;
      connect = {
        kind = "token";
        page = "https://platform.openai.com/api-keys";
        scopes = "Create a key in the project you want voice charged to, with Realtime API access.";
        fields = [ "api_key" ];
      };
      environment.OPENAI_API_KEY = "api_key";
    };
  };
}
