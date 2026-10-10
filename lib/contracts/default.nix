# Contracts connect service requests to provider results. Field names and
# types define compatibility; keep them consistent across consumers and providers.
{ lib }:

let
  inherit (lib) mkOption types;

  # A contract is a pair of functions, each taking defaults and returning an
  # attrset of options. Everything else is derived from them:
  #
  #   mkRequester  the consumer's view: it defaults the REQUEST (it knows what
  #               it needs) and leaves the RESULT blank for a provider to fill.
  #   mkProvider   the mirror: it defaults the RESULT (it knows what it will
  #               deliver) and leaves the REQUEST blank for a consumer to fill.
  #
  # Both sides get identical option TYPES; only the defaults differ. That
  # symmetry is the whole reason `provider.request = requester.request` is a
  # legal assignment.
  mkContract =
    { request, result }:
    {
      mkRequester = requestDefaults: {
        request = mkOption {
          description = "What this module needs from a provider.";
          default = { };
          type = types.submodule { options = request requestDefaults; };
        };

        result = mkOption {
          description = "What a provider delivered. Set by the provider.";
          type = types.submodule { options = result { }; };
        };
      };

      mkProvider =
        {
          resultCfg,
          settings ? null,
        }:
        {
          request = mkOption {
            description = "What a requester asked for. Set by the requester.";
            default = { };
            type = types.submodule { options = request { }; };
          };

          result = mkOption {
            description = "What this provider delivers.";
            default = { };
            type = types.submodule { options = result resultCfg; };
          };
        }
        // lib.optionalAttrs (settings != null) { inherit settings; };

      # Both halves with no defaults applied. Unused today; this is the shape a
      # generic conformance test binds to when we get there, and the shape a
      # docs generator would render.
      contract = {
        request = mkOption {
          description = "Request half of the contract.";
          type = types.submodule { options = request { }; };
        };
        result = mkOption {
          description = "Result half of the contract.";
          type = types.submodule { options = result { }; };
        };
      };
    };

in
{
  secret = mkContract (import ./secret.nix { inherit lib; });
  backup = mkContract (import ./backup.nix { inherit lib; });

  inherit (import ./mount.nix { inherit lib; }) mount;
}
