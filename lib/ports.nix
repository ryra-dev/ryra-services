# Every loopback port a Ryra service binds so another process can reach it: the port
# nginx proxies to, and the port LLDAP serves LDAP on, and so on. Chosen here, once; a
# module reads its number from this file rather than writing a literal.
#
# All are below 1024. The kernel lets only a process holding CAP_NET_BIND_SERVICE bind a
# port below net.ipv4.ip_unprivileged_port_start (1024), so an ordinary login cannot take
# a service's port while it is stopped or restarting and receive another person's traffic.
# Each service is additionally confined to its own ports (see loopback.nix), so a
# compromised service cannot take another's either. web.nix asserts, at evaluation time,
# that every one of these and every private front-door port is below 1024.
#
# frontDoor is nginx's private "Only through Ryra" listener for the app, which a browser
# reaches through the SSH tunnel; the other roles are what nginx or a sibling service connects
# to. The whole 801-820 band is privileged AND clear of the ports browsers refuse to open
# (Chromium/Firefox/Safari each keep a restricted-ports list that would turn a front-door into a
# blank page, e.g. 601, 636; web.nix asserts front-door ports avoid that list).
{
  grafana = {
    frontDoor = 801;
    backend = 811;
  };
  linkding = {
    frontDoor = 802;
    backend = 812;
  };
  nextcloud = {
    # The backend is a php-fpm unix socket, which no login can take, so there is no port.
    frontDoor = 803;
  };
  forgejo = {
    frontDoor = 804;
    backend = 813;
  };
  authelia = {
    frontDoor = 805;
    provider = 814;
  };
  lldap = {
    ldap = 815;
    http = 816;
  };
  vexa = {
    frontDoor = 806;
    whisper = 817;
    adminApi = 818;
    api = 819;
    ui = 820;
  };
}
