# Confine one service to its own loopback ports. Grants exactly CAP_NET_BIND_SERVICE so it may
# bind its privileged port(s), and denies binding any OTHER privileged port, so a compromised
# service cannot take another service's port. Registers the guard so web.nix's assertion can
# check every port is privileged at evaluation time.
#
# SocketBindDeny takes precedence over SocketBindAllow and the default for an unmatched bind is
# allow, so the confinement is expressed as a deny of the whole privileged range [1, 1023]
# EXCEPT this unit's own ports (an allow-list would not deny the rest). Unprivileged ports stay
# bindable, which a service needs for outbound and ephemeral sockets.
#
# unit: the systemd unit that binds the ports. ports: the privileged ports it listens on.
{ lib }:
{ unit, ports }:
let
  sorted = lib.sort (a: b: a < b) ports;
  bounds = [ 1 ] ++ lib.concatMap (p: [ (p - 1) (p + 1) ]) sorted ++ [ 1023 ];
  ranges = lib.genList (i: { lo = lib.elemAt bounds (2 * i); hi = lib.elemAt bounds (2 * i + 1); })
    (builtins.length sorted + 1);
  deny = map (r: if r.lo == r.hi then toString r.lo else "${toString r.lo}-${toString r.hi}")
    (builtins.filter (r: r.lo <= r.hi) ranges);
in
{
  systemd.services.${unit}.serviceConfig = {
    AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
    CapabilityBoundingSet = lib.mkForce [ "CAP_NET_BIND_SERVICE" ];
    # A privileged port cannot be bound from inside a private user namespace: the namespace
    # does not own the host network namespace, so CAP_NET_BIND_SERVICE there does not count.
    # nixpkgs enables PrivateUsers for some of these services; binding a privileged port needs
    # it off (as most services already run). The other sandboxing stays.
    PrivateUsers = lib.mkForce false;
    SocketBindDeny = deny;
  };
  ryra.services.loopbackGuards = [ { inherit unit ports; } ];
}
