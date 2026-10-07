# gemini: Google's agent, signed in as whoever is using it.
#
# The same shape as `services/claude` and `services/codex`.
{
  meta = {
    title = "Gemini";
    auth.gemini-api = {
      label = "Gemini API";
      why = "Use your project's Gemini API key in AI tools.";
      organization_owned = true;
      connect = {
        kind = "token";
        page = "https://aistudio.google.com/api-keys";
        scopes = "Create a Gemini API key in the project you want to use.";
        fields = [ "api_key" ];
      };
      environment = { GEMINI_API_KEY = "api_key"; GOOGLE_API_KEY = "api_key"; };
    };
    summary = "Google's agent, signed in as whoever is using it";
    category = "tools";
    url = "https://github.com/google-gemini/gemini-cli";

    optionRoot = [ ];
    stateless = true;
    needs = [ ];
    provides = [ ];
    secrets = { };
    secretAliases = { };

    carries = [ ];
  };

  module =
    { ... }:
    { pkgs, ... }:
    {
      environment.systemPackages = [ pkgs.gemini-cli ];
    };
}
