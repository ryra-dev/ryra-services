{ lib, ... }:
let contracts = import ./contracts { inherit lib; };
in {
  options.ryra.services.auth = {
    requests = lib.mkOption {
      type = lib.types.attrsOf contracts.auth.contract.request.type;
      default = {};
      internal = true;
    };
    results = lib.mkOption {
      type = lib.types.attrsOf contracts.auth.contract.result.type;
      default = {};
      internal = true;
    };
    modes = lib.mkOption {
      type = lib.types.attrsOf (lib.types.enum [ "none" "oidc" ]);
      default = {};
      internal = true;
    };
  };
}
