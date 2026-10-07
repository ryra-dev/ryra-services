{ pkgs, service, src ? ../services + "/${service}" }:
let
  zod = pkgs.fetchurl {
    url = "https://registry.npmjs.org/zod/-/zod-4.1.12.tgz";
    hash = "sha256-LvnXp9gisFnJvSH4fKpP3EgiDUNzU2eJhN+UL7Z7Q/o=";
  };
  kit = pkgs.runCommand "ryra-adapter-kit" { } ''
    mkdir -p "$out/src" "$out/node_modules/zod"
    cp ${./src/index.ts} "$out/src/index.ts"
    cp ${./src/http.ts} "$out/src/http.ts"
    cp ${./src/auth.ts} "$out/src/auth.ts"
    cp ${./package.json} "$out/package.json"
    tar -xzf ${zod} --strip-components=1 -C "$out/node_modules/zod"
  '';
  source = pkgs.runCommand "ryra-adapter-${service}-source" { } ''
    mkdir -p "$out/services/${service}" "$out/node_modules/@ryra"
    ln -s ${kit} "$out/adapters"
    ln -s ${kit} "$out/node_modules/@ryra/adapter"
    cp -R ${src}/. "$out/services/${service}/"
  '';
in
assert pkgs.lib.assertMsg (builtins.match "[a-z0-9_-]+" service != null) "Adapter names use lowercase letters, digits, underscores or hyphens";
pkgs.writeShellApplication {
  name = "ryra-adapter-${service}";
  text = ''exec ${pkgs.bun}/bin/bun --no-install ${source}/services/${service}/adapter.ts "$@"'';
}
