# Certificate paths and the unit that creates them. Consumers must wait for
# that unit before opening the files.
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
        description = "Unit that produces the certificate. Consumers must require it and start after it.";
        type = types.str;
      };
    };
  };
}
