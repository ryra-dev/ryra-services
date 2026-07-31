{
  description = "ryra-services — a registry of self-hostable services as NixOS aspects";

  # Deliberately input-free.
  #
  # A registry describes services; it does not pin the world they run in. The
  # HOST owns nixpkgs and selfhostblocks, and hands its selfhostblocks in via
  # `ryra.services.selfhostblocks`. Two revisions of SHB on one box is not a
  # thing that can be made to work, so there is exactly one, and it is the
  # host's.
  #
  # This also keeps `nix flake lock` on a consumer meaningful: updating the
  # registry input moves the service definitions and nothing else.
  outputs = _: {
    # The mechanism: `ryra.services.*`, which turns an enable list into
    # imported aspects, certificates and datasets.
    nixosModules.services = import ./lib/services-module.nix;

    # The registry itself, for tooling that wants to enumerate without
    # evaluating a NixOS configuration.
    ryraRegistry = {
      name = "ryra";
      path = ./.;
    };
  };
}
