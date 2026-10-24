# Each machine is its own certificate authority for its own names.
#
# A private app is served over HTTPS on loopback under `<app>.<machine>.home.arpa`. This module
# issues the CA that signs those names and nothing else, and the single leaf nginx presents for all
# of them by SNI. The CA key never leaves the machine and is readable by root only; the machine
# issues and renews its own leaf on a timer, so without Ryra everything keeps serving.
#
# The suffix is not declared separately. It is the parent every private name shares, read off the
# names themselves and asserted to be one, so there is no second place it could disagree with the
# names core emitted. The CA's name constraint permits only that suffix and excludes every IP
# address, so a device that trusts this CA trusts it for this machine's names alone. Android does
# not enforce that constraint, which is why Ryra's own check (ryra-core's `machine_tls`) also
# verifies the host; the constraint is still correct and is enforced everywhere else.
{ config, lib, pkgs, ... }:
let
  dir = "/var/lib/ryra/local-https";
  web = config.ryra.services.web;
  private = lib.filterAttrs (_: site: site.access == "private" && site.privateHttps) web;
  hostOf =
    site:
    let
      match = builtins.match "https://([a-zA-Z0-9.-]+).*" (if site.externalUrl == null then "" else site.externalUrl);
    in
    if match == null then null else builtins.head match;
  hosts = lib.unique (builtins.filter (host: host != null) (map hostOf (lib.attrValues private)));
  parentOf = host: lib.concatStringsSep "." (builtins.tail (lib.splitString "." host));
  suffixes = lib.unique (map parentOf hosts);
  suffix = if suffixes == [ ] then null else builtins.head suffixes;
  caCnf = pkgs.writeText "ryra-local-ca.cnf" ''
    [req]
    distinguished_name = dn
    prompt = no
    x509_extensions = v3
    [dn]
    CN = Ryra machine CA ${toString suffix}
    [v3]
    basicConstraints = critical,CA:TRUE,pathlen:0
    keyUsage = critical,keyCertSign,cRLSign
    subjectKeyIdentifier = hash
    nameConstraints = critical,permitted;DNS:${toString suffix},excluded;IP:0.0.0.0/0.0.0.0,excluded;IP:::/::
  '';
  leafExt = pkgs.writeText "ryra-local-leaf.ext" ''
    basicConstraints = critical,CA:FALSE
    keyUsage = critical,digitalSignature,keyEncipherment
    extendedKeyUsage = serverAuth
    subjectAltName = ${lib.concatMapStringsSep "," (host: "DNS:${host}") hosts}
  '';
  nginxGroup = config.services.nginx.group;
  # The CA is made once and kept; the leaf is reissued every run so its names follow the app set and
  # its validity stays fresh. New files are written aside and moved into place, so nginx never reads
  # a half-written certificate.
  issue = pkgs.writeShellApplication {
    name = "ryra-local-https-issue";
    runtimeInputs = [ pkgs.openssl pkgs.coreutils ];
    text = ''
      umask 077
      mkdir -p ${dir}
      openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out ${dir}/key.pem.new
      openssl req -new -key ${dir}/key.pem.new -subj "/CN=${toString (if hosts == [ ] then "" else builtins.head hosts)}" \
        -out ${dir}/leaf.csr
      openssl x509 -req -in ${dir}/leaf.csr -CA ${dir}/ca.pem -CAkey ${dir}/ca.key \
        -set_serial "0x$(openssl rand -hex 16)" -days 90 -extfile ${leafExt} -out ${dir}/leaf.pem.new
      mv ${dir}/key.pem.new ${dir}/key.pem
      mv ${dir}/leaf.pem.new ${dir}/leaf.pem
      rm -f ${dir}/leaf.csr
      chmod 0644 ${dir}/leaf.pem
      chown root:${nginxGroup} ${dir}/key.pem
      chmod 0640 ${dir}/key.pem
    '';
  };
  # The machine's own CA and the system bundle are made in activation, not a unit: activation runs
  # at boot and at every switch, before any service, so there is no ordering to get wrong, and a
  # change to Nix's bundle refreshes it. Nix's bundle is written first and unconditionally, so a
  # failed CA generation leaves the machine at exactly today's trust rather than none.
  makeCaAndBundle = pkgs.writeShellApplication {
    name = "ryra-local-https-ca";
    runtimeInputs = [ pkgs.openssl pkgs.coreutils ];
    text = ''
      umask 077
      install -d -m 0755 ${dir}
      if [ ! -s ${dir}/ca.pem ] || [ ! -s ${dir}/ca.key ]; then
        if openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out ${dir}/ca.key.new \
          && openssl req -x509 -new -key ${dir}/ca.key.new -config ${caCnf} -days 3650 \
               -set_serial "0x$(openssl rand -hex 16)" -out ${dir}/ca.pem.new; then
          chmod 0600 ${dir}/ca.key.new
          chmod 0644 ${dir}/ca.pem.new
          mv ${dir}/ca.key.new ${dir}/ca.key
          mv ${dir}/ca.pem.new ${dir}/ca.pem
        else
          echo "ryra-local-https: CA generation failed; system bundle stays at Nix's trust" >&2
          rm -f ${dir}/ca.key.new ${dir}/ca.pem.new
        fi
      fi
      cat ${config.security.pki.caBundle} > ${dir}/system-bundle.crt.new
      if [ -s ${dir}/ca.pem ]; then
        cat ${dir}/ca.pem >> ${dir}/system-bundle.crt.new
      fi
      chmod 0644 ${dir}/system-bundle.crt.new
      mv ${dir}/system-bundle.crt.new ${dir}/system-bundle.crt
    '';
  };
in
{
  config = lib.mkIf (private != { }) {
    assertions = [
      {
        assertion = suffix != null && builtins.length suffixes == 1;
        message = "Every local-HTTPS private app must share one machine suffix like <machine>.home.arpa.";
      }
      {
        assertion = suffix == null || lib.hasSuffix ".home.arpa" suffix;
        message = "A machine's local-HTTPS suffix must be under home.arpa.";
      }
    ];

    system.activationScripts.ryra-local-https.text = "${makeCaAndBundle}/bin/ryra-local-https-ca";

    # The three system trust paths point at the bundle activation writes, so every TLS client finds
    # the machine's own CA with no setting of its own. mkForce beats security.pki, the way NixOS
    # points resolv.conf at a file under /run.
    environment.etc."ssl/certs/ca-certificates.crt".source = lib.mkForce "${dir}/system-bundle.crt";
    environment.etc."ssl/certs/ca-bundle.crt".source = lib.mkForce "${dir}/system-bundle.crt";
    environment.etc."pki/tls/certs/ca-bundle.crt".source = lib.mkForce "${dir}/system-bundle.crt";

    systemd.services.ryra-local-https = {
      description = "Ryra machine leaf certificate for local HTTPS";
      wantedBy = [ "multi-user.target" ];
      before = [ "nginx.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = lib.getExe issue;
    };

    systemd.services.ryra-local-https-renew = {
      description = "Ryra local HTTPS leaf renewal";
      serviceConfig = {
        Type = "oneshot";
      };
      # Reload rather than restart, and with a signal rather than `systemctl reload`, so a renewal
      # started before nginx settles cannot deadlock on it.
      script = ''
        ${lib.getExe issue}
        ${pkgs.systemd}/bin/systemctl kill -s HUP nginx.service || true
      '';
    };

    systemd.timers.ryra-local-https-renew = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
      };
    };
  };
}
