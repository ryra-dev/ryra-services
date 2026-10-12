{ config, lib }:
let
  c = config;
  requests = c.ryra.services.auth.requests;
  results = c.ryra.services.auth.results;
  web = c.ryra.services.web;
  modes = c.ryra.services.auth.modes;
  provider = c.ryra.services.auth.provider;
  runtimeFile = path: lib.hasPrefix "/" path && !(lib.hasPrefix "/nix/store/" path);
  selected = lib.filterAttrs (_: mode: mode == "oidc") modes;
  failures = map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
in
assert lib.assertMsg (failures == []) (lib.concatStringsSep "\n" failures);
assert lib.assertMsg (provider.enable && selected != {}) "Enable the shared provider and at least one OIDC app before checking authentication.";
assert lib.assertMsg (builtins.all (name:
  requests ? ${name} && results ? ${name}
  && results.${name}.issuerUrl == provider.issuerUrl
  && results.${name}.clientId == requests.${name}.clientId
  && runtimeFile requests.${name}.clientSecretFile
  && runtimeFile requests.${name}.secretHashFile
  && builtins.all (uri: lib.hasPrefix "${web.${name}.url}/" uri) requests.${name}.redirectUris
  && (web.${name}.access != "private" ||
    (web.${name}.externalUrl != null && builtins.all (listen: listen.addr == "127.0.0.1")
      c.services.nginx.virtualHosts.${web.${name}.hostName}.listen))
) (builtins.attrNames selected)) "An OIDC app has missing registration, runtime secrets, canonical callbacks or private loopback listeners.";
assert lib.assertMsg (c.services.lldap.settings.ldap_host == "127.0.0.1" && c.services.lldap.settings.http_host == "127.0.0.1") "The directory must remain on loopback.";
assert lib.assertMsg (c.systemd.services.lldap.serviceConfig.WorkingDirectory == provider.lldapStatePath) "The directory working directory must match its configured persistent storage.";
assert lib.assertMsg (!(selected ? nextcloud) ||
  (c.services.nextcloud.extraApps ? user_oidc && lib.hasInfix "--clientsecret-file=" c.systemd.services.nextcloud-oidc.script
   && requests.nextcloud.tokenEndpointAuthMethod == "client_secret_post"
   && c.services.nextcloud.settings.user_oidc.use_pkce)) "Nextcloud must install user_oidc, load its client secret from a runtime file, use PKCE and register its supported POST token authentication method.";
assert lib.assertMsg (!(selected ? linkding) ||
  (c.services.linkding.settings.LD_ENABLE_OIDC == "True"
   && !(c.services.linkding.settings ? OIDC_RP_CLIENT_SECRET)
   && builtins.elem "/run/linkding-oidc/environment" c.systemd.services.linkding.serviceConfig.EnvironmentFile)) "Linkding must enable native OIDC with a runtime environment file.";
assert lib.assertMsg (!(selected ? grafana) ||
  (c.services.grafana.settings."auth.generic_oauth".enabled
   && c.services.grafana.settings."auth.generic_oauth".use_pkce
   && c.services.grafana.settings."auth.generic_oauth".auth_style == "InParams"
   && c.services.grafana.settings."auth.generic_oauth".client_secret == "$__file{/run/credentials/grafana.service/oidc-client}"
   && builtins.elem "oidc-client:${results.grafana.clientSecretFile}" c.systemd.services.grafana.serviceConfig.LoadCredential
   && c.services.grafana.settings."auth.generic_oauth".role_attribute_strict
   && !c.services.grafana.settings."auth.generic_oauth".skip_org_role_sync
   && c.services.grafana.settings.users.auto_assign_org_role == "Viewer"
   && !c.services.grafana.settings."auth.anonymous".enabled
   && c.services.grafana.settings.server.http_addr == "127.0.0.1"
   && c.services.grafana.settings.server.root_url == "${web.grafana.url}/"
   && requests.grafana.redirectUris == [ "${web.grafana.url}/login/generic_oauth" ]
   && requests.grafana.tokenEndpointAuthMethod == "client_secret_post")) "Grafana must use native OAuth with PKCE, runtime secrets, strict role mapping, Viewer defaults and canonical loopback routing.";
{
  passed = true;
  services = builtins.attrNames selected;
  issuer = provider.issuerUrl;
  callbacks = builtins.mapAttrs (_: request: request.redirectUris) requests;
}
