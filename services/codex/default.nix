# codex: OpenAI's agent, signed in as whoever is using it.
#
# The same shape as `services/claude`, and deliberately a separate entry rather than one "agents"
# entry with a list. Each vendor keeps its own credential in its own file, and a machine that
# wants Codex and not Claude should install Codex and not Claude: an entry per tool is what lets
# a design say that without a flag.
{
  meta = {
    title = "Codex";
    auth.codex = {
      label = "Codex";
      why = "Use your own Codex sign-in on the machines you reach.";
      connect = {
        kind = "local";
        command = [ "codex" "login" ];
        file = ".codex/auth.json";
      };
      carries = { at = ".codex/auth.json"; what = "your own Codex sign-in"; };
    };
    summary = "OpenAI's agent, signed in as whoever is using it";
    category = "tools";
    url = "https://developers.openai.com/codex/cli";

    optionRoot = [ ];
    stateless = true;
    needs = [ ];
    provides = [ ];
    secrets = { };
    secretAliases = { };

    carries = [ "codex" ];
  };

  module =
    { ... }:
    { pkgs, ... }:
    {
      environment.systemPackages = [ pkgs.codex ];
    };
}
