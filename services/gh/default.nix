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
# So `carries` names a credential each PERSON brings their own of. Ryra reads this, writes it into
# the machine's `carries` in the declaration, and every person with a login there seals their own
# to the box out of a keyring nobody else can open. Whoever deploys copies ciphertext they cannot
# read: an admin can put your GitHub sign-in in your account without ever holding it.
#
# It names the credential and never the path. Where gh keeps its own hosts file is gh's fact, and
# it lives in Ryra's integrations table, which is also the only place that can carry it: the
# phones link a compiled interface, so a credential type invented in a flake would have nothing
# to call. An entry carrying its own path would be a second answer that disagrees the day the
# tool moves its file.
{
  meta = {
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

  # The mechanism calls this with a service's own arguments -- name, subdomain, domain, ssl,
  # contracts, settings -- and a tool wants none of them, so they are taken and ignored. What
  # comes back is an ordinary NixOS module, which is where `pkgs` arrives.
  module =
    { ... }:
    { pkgs, ... }:
    {
      environment.systemPackages = [ pkgs.gh ];
    };
}
