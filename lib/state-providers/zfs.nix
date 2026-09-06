# Optional compatibility provider for hosts that already keep service state in
# ZFS. The low-memory Ryra base uses Btrfs and does not import this module; its
# `/var/lib` subvolume is snapshotted by the machine template instead.
{ zfsPool }:

{ config, lib, ... }:

{
  config.shb.zfs.pools.${zfsPool}.datasets = lib.mapAttrs (
    _: state:
    {
      enable = true;
      inherit (state) path;
    }
    // lib.optionalAttrs (state.owner != null) { inherit (state) owner; }
    // lib.optionalAttrs (state.group != null) { inherit (state) group; }
  ) (lib.mapAttrs' (name: value: lib.nameValuePair "safe/${name}" value) config.ryra.services.state);
}
