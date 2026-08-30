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
    summary = "Claude Code, signed in as whoever is using it";
    category = "tools";
    url = "https://claude.com/claude-code";

    optionRoot = [ ];
    needs = [ ];
    provides = [ ];
    secrets = { };
    secretAliases = { };

    carries = [ "claude" ];
  };

  module =
    { ... }:
    { pkgs, lib, ... }:
    {
      environment.systemPackages = [ pkgs.claude-code ];

      # claude-code is UNFREE, so a host that has not said so refuses to build it. Found by
      # trying: the module evaluates, the package resolves, `nix eval` on the whole NixOS system
      # lists it happily, and the rebuild then stops with a licence error naming a package the
      # person adding this entry never typed.
      #
      # Permitted for THIS package by name rather than by setting `allowUnfree`, which would let
      # every future unfree thing onto the machine on the strength of somebody once wanting an
      # agent. An entry may speak for its own dependency and for nothing else.
      #
      # `lib.mkDefault` so a host that has already made its own decision keeps it: this is the
      # entry saying "I need this", not overruling an operator who said otherwise.
      nixpkgs.config.allowUnfreePredicate = lib.mkDefault (
        pkg: builtins.elem (lib.getName pkg) [ "claude-code" ]
      );
    };
}
