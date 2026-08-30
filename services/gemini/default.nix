# gemini: Google's agent, signed in as whoever is using it.
#
# The same shape as `services/claude` and `services/codex`.
{
  meta = {
    summary = "Google's agent, signed in as whoever is using it";
    category = "tools";
    url = "https://github.com/google-gemini/gemini-cli";

    optionRoot = [ ];
    needs = [ ];
    provides = [ ];
    secrets = { };
    secretAliases = { };

    carries = [ "gemini" ];
  };

  module =
    { ... }:
    { pkgs, ... }:
    {
      environment.systemPackages = [ pkgs.gemini-cli ];
    };
}
