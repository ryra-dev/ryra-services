# The secret contract: "put this value in a file, owned like so, and restart
# these units when it changes."
#
# Field names and types match SHB's modules/contracts/secret.nix exactly. They
# are not ours to rename: sops-nix, SHB's hardcodedsecret and any provider we
# write later all agree on this shape, and structural typing means a rename is
# a silent incompatibility rather than a build error.
{ lib }:

let
  inherit (lib) mkOption types;
in
{
  request =
    {
      mode ? "0400",
      owner ? "root",
      group ? "root",
      restartUnits ? [ ],
    }:
    {
      mode = mkOption {
        description = "Mode of the secret file, as chmod would take it.";
        type = types.str;
        default = mode;
      };

      owner = mkOption {
        description = "Linux user owning the secret file.";
        type = types.str;
        default = owner;
      };

      group = mkOption {
        description = "Linux group owning the secret file.";
        type = types.str;
        default = group;
      };

      restartUnits = mkOption {
        description = ''
          Systemd units to restart when the secret changes.

          A secret nothing restarts on is a secret that takes effect at the
          next unrelated reboot, which is the kind of thing that makes a
          rotation look like it worked.
        '';
        type = types.listOf types.str;
        default = restartUnits;
      };
    };

  result =
    { path ? "/run/secrets/secret" }:
    {
      path = mkOption {
        description = "Path to the file holding the secret.";
        type = types.path;
        default = path;
      };
    };
}
