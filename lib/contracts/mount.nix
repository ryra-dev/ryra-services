# The mount contract: where a service keeps state it cannot rebuild.
#
# This is an OUTPUT, not a request. The service declares the one path that
# matters and the host decides what to do with it: a ZFS dataset, a bind mount,
# nothing at all. The mechanism reads it to create the dataset, which is why no
# manifest needs to repeat the path and risk drifting from the module.
{ lib }:

let
  inherit (lib) mkOption types;
in
{
  mount = types.submodule {
    freeformType = types.attrsOf types.str;
    options = {
      path = mkOption {
        description = "Path holding state that cannot be rebuilt from the flake.";
        type = types.str;
      };
    };
  };
}
