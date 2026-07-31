# Contracts: how a service says what it needs without naming who provides it.
#
# Lifted in shape from Self Host Blocks' modules/contracts, deliberately.
# Owning this layer is what lets us iterate without waiting on upstream, and it
# is small: the whole mechanism is the function below.
#
# The one thing to understand before changing anything here: THE TYPING IS
# STRUCTURAL, NOT NOMINAL. A `.request`/`.result` pair typechecks against
# another because both sides are submodules with the same field names and
# types, not because they came from the same constructor. That is why our
# contracts drop straight into SHB's service modules, and why `ryra.tailscale`
# could provide SHB's ssl contract without importing a line of SHB. Keep the
# field lists identical to SHB's and the two worlds stay interchangeable;
# rename a field and they silently stop fitting.
#
# What we dropped from SHB's version, on purpose: every option there carries a
# parallel `<field>Text` argument feeding `defaultText`/`literalMD`, so the
# generated options manual renders `config.request.user` rather than a
# meaningless concrete value. It is about 40% of their line count and it buys
# nothing until we generate a manual. When we do, that is where it goes back.
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

  # ssl and mount are plain types rather than request/result pairs: nobody
  # negotiates, a provider simply hands over a fixed shape. SHB models them the
  # same way, and matching that is what keeps them interchangeable.
  inherit (import ./ssl.nix { inherit lib; }) certs;
  inherit (import ./mount.nix { inherit lib; }) mount;
}
