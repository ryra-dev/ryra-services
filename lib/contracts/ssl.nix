# The ssl contract: three fields, and that is genuinely all of it.
#
# `paths.cert`, `paths.key`, `systemdService`. Nothing about ACME, nothing
# about Tailscale, nothing about a CA. That smallness is what let
# `ryra.tailscale.certs.<n>` drop into `shb.nextcloud.ssl` and yield a real
# Let's Encrypt certificate without either side knowing about the other.
#
# `systemdService` is the part people forget and then debug for an hour: nginx
# must not start before the certificate exists, or it burns its restart limit
# on a missing ssl_certificate and lands in start-limit-hit.
{ lib }:

let
  inherit (lib) mkOption types;
in
{
  certs = types.submodule {
    options = {
      paths = mkOption {
        description = "Paths to the certificate and its private key.";
        type = types.submodule {
          # Freeform so a provider may carry extra material (a CA bundle, a
          # chain) without every consumer needing to know about it.
          freeformType = types.attrsOf types.str;
          options = {
            cert = mkOption {
              description = "Path to the certificate.";
              type = types.path;
            };
            key = mkOption {
              description = "Path to the private key.";
              type = types.path;
            };
          };
        };
      };

      systemdService = mkOption {
        description = ''
          Unit that produces the certificate.

          Consumers order themselves after it. `after` rather than `requires`,
          so one failing certificate degrades a single vhost instead of taking
          the whole web server down with it.
        '';
        type = types.str;
      };
    };
  };
}
