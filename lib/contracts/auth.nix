{ lib }:
let
  inherit (lib) mkOption types;
  runtimeFile = types.pathWith { absolute = true; inStore = false; };
in {
  request = defaults: {
    clientId = mkOption { type = types.str; default = defaults.clientId or ""; };
    clientSecretFile = mkOption { type = runtimeFile; };
    secretHashFile = mkOption { type = runtimeFile; };
    redirectUris = mkOption { type = types.listOf types.str; default = defaults.redirectUris or []; };
    scopes = mkOption { type = types.listOf types.str; default = defaults.scopes or [ "openid" "profile" "email" ]; };
    tokenEndpointAuthMethod = mkOption {
      type = types.enum [ "client_secret_basic" "client_secret_post" ];
      default = defaults.tokenEndpointAuthMethod or "client_secret_basic";
    };
    authorizationPolicy = mkOption { type = types.str; default = "one_factor"; };
    claimsPolicy = mkOption { type = types.nullOr types.str; default = null; };
    consentMode = mkOption { type = types.enum [ "auto" "explicit" "implicit" ]; default = "auto"; };
  };
  result = defaults: {
    issuerUrl = mkOption { type = types.str; default = defaults.issuerUrl or ""; };
    clientId = mkOption { type = types.str; default = defaults.clientId or ""; };
    clientSecretFile = mkOption { type = runtimeFile; };
  };
}
