# gh: the GitHub CLI, signed in as whoever is using it.
#
# THE FIRST ENTRY THAT IS A TOOL RATHER THAN A SERVICE, and it is here to show that the registry
# needed nothing added to hold one. It serves nothing, listens on no port, wants no certificate,
# no database and no backup: `needs` is empty and every contract requester below it is absent.
# What is left is a package on the machine, which is what a module is for.
#
# That matters because the alternative was a second mechanism. A machine already imports modules
# from here; inventing a separate "tools" list beside it would have been two things doing one job,
# and the one nobody maintained would have been the one somebody needed.
#
# # Why this has `carries` and no `secrets`
#
# A secret is the ORGANIZATION'S: one value, one path, one owner, the same bytes for everybody the
# access groups reach. Right for a database password and wrong for a GitHub sign-in, because when
# Ada pushes from this machine she is pushing as Ada and Ben is pushing as Ben.
#
# `carries` describes the personal credential this tool can import. Delivery is explicitly
# declared on the machine; installing the tool alone does not request anyone's sign-in.
#
{
  package = pkgs: import ../../adapters/package.nix { inherit pkgs; service = "gh"; };
  meta = {
    title = "GitHub";
    auth.github = {
      label = "GitHub";
      why = "Read and push repositories as yourself, and create deploy keys for your machines.";
      connect = {
        kind = "token";
        page = "https://github.com/settings/personal-access-tokens/new?name=Ryra&description=Repository%20access%20and%20machine%20deploy%20keys&expires_in=90&contents=write&administration=write";
        scopes = "Browser sign-in requests repository read/write access. Use a fine-grained personal access token to select specific repositories. Contents write allows pushing; Administration write allows creating deploy keys.";
        fields = [ "token" ];
      };
      driver = {
        command = [ "ryra-adapter-gh" ];
        configuration = { client_id = ""; client_secret = ""; };
        required = [ "client_id" "client_secret" ];
      };
      settings = {
        "/driver/configuration/client_id".env = "RYRA_GITHUB_CLIENT_ID";
        "/driver/configuration/client_secret".env = "RYRA_GITHUB_CLIENT_SECRET";
      };
      environment.GH_TOKEN = "token";
      carries = { at = ".config/gh/hosts.yml"; what = "your own GitHub sign-in"; };
    };
    summary = "The GitHub CLI, signed in as whoever is using it";
    category = "tools";
    url = "https://cli.github.com";

    # Required by `validate`, and empty on purpose: `optionRoot` is where the mechanism reaches
    # for `.backup` and `.mount`, and a tool that stores nothing has neither. Present rather than
    # absent, because absent means "the author forgot" and this is a decision.
    optionRoot = [ ];
    stateless = true;

    needs = [ ];
    provides = [ ];
    secrets = { };
    secretAliases = { };

    carries = [ "github" ];
  };

  # Service arguments arrive before the NixOS module arguments, including pkgs.
  module =
    { ... }:
    { pkgs, ... }:
    {
      environment.systemPackages = [ pkgs.gh ];
    };
}
