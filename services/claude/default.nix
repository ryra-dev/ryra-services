# claude: Claude Code, signed in as whoever is using it.
#
# A tool rather than a service, for the reasons `services/gh` states at length. The interesting
# half is the same one: `carries` names a credential each PERSON brings their own of, so Ada's
# agent bills Ada and Ben's bills Ben, in one shell each, on one box.
#
# It is the reason per-person carrying exists at all. A shared Anthropic sign-in on a machine
# several people reach means whoever gets there first spends somebody else's account, and there
# is no way to tell afterwards which of them did. That is not a permissions problem to solve with
# a stricter mode on a file: it is one credential where there should have been several.
{
  meta = {
    title = "Claude";
    auth.claude = {
      label = "Claude";
      why = "Use your own Claude Code sign-in on the machines you reach.";
      connect = {
        kind = "local";
        command = [ "claude" "auth" "login" ];
        file = ".claude/.credentials.json";
        keychain = "Claude Code-credentials";
      };
      carries = { at = ".claude/.credentials.json"; what = "your own Claude sign-in"; };
    };
    summary = "Claude Code, signed in as whoever is using it";
    category = "tools";
    url = "https://claude.com/claude-code";

    optionRoot = [ ];
    stateless = true;
    needs = [ ];
    provides = [ ];
    secrets = { };
    secretAliases = { };

    carries = [ "claude" ];
  };

  module =
    { ... }:
    { pkgs, ... }:
    {
      environment.systemPackages = [ pkgs.claude-code ];

      # nixpkgs merges this list with the host's license policy. A predicate
      # replaces the host's function even when wrapped in mkDefault.
      nixpkgs.config.allowUnfreePackages = [ "claude-code" ];
    };
}
