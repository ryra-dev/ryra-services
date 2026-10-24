{
  meta = {
    title = "Vexa";
    summary = "Meeting bots, local Whisper transcription and audio recordings";
    description = builtins.readFile ./README.md;
    category = "productivity";
    url = "https://github.com/Vexa-ai/vexa";
    optionRoot = [ "ryra" "vexa" ];
    needs = [ "secrets" "backup" ];
    provides = [ "meeting-transcription" ];
    web.port = (import ../../lib/ports.nix).vexa.frontDoor;
    secrets = {
      "vexa-environment" = {
        purpose = "Vexa database, internal API, session and recording-storage credentials";
        restart = [ "vexa.service" ];
        setup = {
          instructions = "Use independent random values for these internal service credentials.";
          fields = map (name: { inherit name; label = name; secret = true; }) [
            "DB_PASSWORD" "ADMIN_TOKEN" "INTERNAL_API_SECRET" "NEXTAUTH_SECRET"
            "MINIO_ACCESS_KEY" "MINIO_SECRET_KEY"
          ];
        };
      };
      "restic-vexa" = {
        purpose = "Vexa backup encryption password";
        owner = "root";
        restart = [ "restic-backups-vexa.service" ];
        generate = { format = "hex"; bytes = 32; };
      };
    };
    secretAliases = { };
  };

  module = { name, contracts, settings }: { config, lib, pkgs, ... }:
    let
      ports = import ../../lib/ports.nix;
      web = config.ryra.services.web.${name};
      environmentFile = settings.environmentFile or config.sops.secrets."${name}-environment".path;
      dataDir = "/var/lib/${name}";
      network = "${name}-meetings";
      apiPort = settings.apiPort or ports.vexa.api;
      uiPort = settings.uiPort or ports.vexa.ui;
      model = settings.model or "Systran/faster-whisper-base";
      secret = key: "$" + "{${key}:?${key} is required}";
      botImage = "vexaai/vexa-bot@sha256:423c487aadb81514c71c9786758a3a730acbf5495e9593930da50c7442f158c1";
      database = {
        DB_HOST = "postgres";
        DB_PORT = "5432";
        DB_NAME = "vexa";
        DB_USER = "vexa";
        DB_PASSWORD = secret "DB_PASSWORD";
      };
      internal = {
        INTERNAL_API_SECRET = secret "INTERNAL_API_SECRET";
      };
      transcription = {
        TRANSCRIPTION_SERVICE_URL = "http://whisper:8000";
        TRANSCRIPTION_SERVICE_TOKEN = "";
        TRANSCRIPTION_MODEL = model;
      };
      healthy = command: {
        test = [ "CMD-SHELL" command ];
        interval = "10s";
        timeout = "5s";
        retries = 12;
        start_period = "30s";
      };
      httpHealth = port: healthy "python -c 'import urllib.request; urllib.request.urlopen(\"http://127.0.0.1:${toString port}/health\", timeout=3)'";
      depends = names: lib.genAttrs names (_: { condition = "service_healthy"; });
      services = {
        postgres = {
          image = "postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24";
          environment = {
            POSTGRES_DB = "vexa";
            POSTGRES_USER = "vexa";
            POSTGRES_PASSWORD = database.DB_PASSWORD;
            TZ = "UTC";
          };
          command = [ "postgres" "-c" "idle_in_transaction_session_timeout=60000" ];
          volumes = [ "${dataDir}/postgres:/var/lib/postgresql/data" ];
          healthcheck = healthy "pg_isready -U vexa -d vexa";
          mem_limit = "512m";
        };
        redis = {
          image = "valkey/valkey:8-alpine@sha256:081c2f5cb575efc901aa80ff9cdbd1ec6a301682fd35e1ebb4b0990a4a4a8507";
          command = [ "valkey-server" "--appendonly" "yes" "--maxmemory" "128mb" "--maxmemory-policy" "noeviction" ];
          volumes = [ "${dataDir}/redis:/data" ];
          healthcheck = healthy "valkey-cli ping | grep -q PONG";
          mem_limit = "256m";
        };
        storage = {
          image = "versity/versitygw:v1.8.0@sha256:30292fc2eeacc67a36993b01f7a7a5e3361a19cced0e80c1d71cfa2a4b0a2499";
          environment = {
            ROOT_ACCESS_KEY = secret "MINIO_ACCESS_KEY";
            ROOT_SECRET_KEY = secret "MINIO_SECRET_KEY";
          };
          entrypoint = [ "/bin/sh" "-ec" ];
          command = [ "mkdir -p /storage/data /storage/iam; exec versitygw --port :9000 --health /health --iam-dir /storage/iam --quiet posix /storage/data" ];
          volumes = [ "${dataDir}/storage:/storage" ];
          healthcheck = healthy "wget -q -O /dev/null http://127.0.0.1:9000/health";
          mem_limit = "256m";
        };
        storage-init = {
          image = services.storage.image;
          environment = {
            ADMIN_ACCESS_KEY = secret "MINIO_ACCESS_KEY";
            ADMIN_SECRET_KEY = secret "MINIO_SECRET_KEY";
          };
          entrypoint = [ "/bin/sh" "-ec" ];
          command = [ ''
            result=$$(versitygw admin --endpoint-url http://storage:9000 create-bucket --bucket vexa --owner "$$ADMIN_ACCESS_KEY" 2>&1) || {
              case "$$result" in
                *BucketAlreadyOwnedByYou*) exit 0 ;;
                *) printf '%s\n' "$$result" >&2; exit 1 ;;
              esac
            }
          '' ];
          depends_on = depends [ "storage" ];
          restart = "no";
          mem_limit = "128m";
        };
        whisper = {
          image = "fedirz/faster-whisper-server@sha256:760e5e43d427dc6cfbbc4731934b908b7de9c7e6d5309c6a1f0c8c923a5b6030";
          environment = {
            WHISPER__MODEL = model;
            WHISPER__INFERENCE_DEVICE = "cpu";
            WHISPER__COMPUTE_TYPE = "int8";
            WHISPER__CPU_THREADS = "2";
            WHISPER__NUM_WORKERS = "1";
            WHISPER__TTL = "-1";
            HF_HUB_DISABLE_TELEMETRY = "1";
            GRADIO_ANALYTICS_ENABLED = "false";
          };
          volumes = [ "${dataDir}/models:/root/.cache/huggingface" ];
          ports = [ "127.0.0.1:${toString ports.vexa.whisper}:8000" ];
          healthcheck = healthy "/root/faster-whisper-server/.venv/bin/python -c 'import urllib.request; urllib.request.urlopen(\"http://127.0.0.1:8000/health\", timeout=3)'";
          mem_limit = "1536m";
          cpus = "1.5";
        };
        admin-api = {
          image = "vexaai/v012-admin-api@sha256:4c702354384eafe3a933cd537a106b7c15067cfd368a5f6da1a6e675e7e03e04";
          environment = database // internal // { ADMIN_API_TOKEN = secret "ADMIN_TOKEN"; };
          depends_on = depends [ "postgres" ];
          ports = [ "127.0.0.1:${toString ports.vexa.adminApi}:8001" ];
          healthcheck = httpHealth 8001;
          mem_limit = "384m";
        };
        runtime = {
          image = "vexaai/v012-runtime@sha256:a1f6448fbb380b9433364e8b572ec25a12aa4f274bf403f1d83a89cbf5812f2d";
          environment = internal // {
            REDIS_URL = "redis://redis:6379/0";
            DOCKER_NETWORK = network;
            BROWSER_IMAGE = botImage;
          };
          volumes = [ "/var/run/docker.sock:/var/run/docker.sock" ];
          depends_on = depends [ "redis" ];
          healthcheck = httpHealth 8090;
          mem_limit = "384m";
        };
        meeting-api = {
          image = "vexaai/v012-meeting-api@sha256:4e9c201f656788755458fd6f2b9fbf3bfe0722d5b17d4cebd82b874b5aee98e1";
          environment = database // internal // transcription // {
            REDIS_URL = "redis://redis:6379/0";
            RUNTIME_API_URL = "http://runtime:8090";
            MEETING_API_URL = "http://meeting-api:8080";
            ADMIN_API_URL = "http://admin-api:8001";
            ADMIN_TOKEN = secret "ADMIN_TOKEN";
            DEFAULT_BOT_NAME = "Ryra meeting notes";
            RECORDING_ENABLED = "true";
            TRANSCRIBE_ENABLED = "true";
            MINIO_ENDPOINT = "storage:9000";
            MINIO_ACCESS_KEY = secret "MINIO_ACCESS_KEY";
            MINIO_SECRET_KEY = secret "MINIO_SECRET_KEY";
            MINIO_BUCKET = "vexa";
            MINIO_SECURE = "false";
          };
          depends_on = (depends [ "postgres" "redis" "runtime" "admin-api" "whisper" ]) // {
            storage-init.condition = "service_completed_successfully";
          };
          healthcheck = httpHealth 8080;
          mem_limit = "512m";
        };
        gateway = {
          image = "vexaai/v012-gateway@sha256:2e76319812f28adbb6bc328ac0a7484d3826924a9d38a9dd9599dd190fbb0f19";
          environment = internal // {
            ADMIN_API_URL = "http://admin-api:8001";
            MEETING_API_URL = "http://meeting-api:8080";
            AGENT_API_URL = "";
            REDIS_URL = "redis://redis:6379/0";
          };
          depends_on = depends [ "admin-api" "meeting-api" ];
          ports = [ "127.0.0.1:${toString apiPort}:8000" ];
          healthcheck = httpHealth 8000;
          mem_limit = "384m";
        };
        terminal = {
          image = "vexaai/v012-terminal@sha256:8293350ff70008674032de67c682091eb8b87110412d2a4a1f3c4ed10cb1b09f";
          environment = transcription // {
            NODE_ENV = "production";
            GATEWAY_URL = "http://gateway:8000";
            VEXA_API_URL = "http://gateway:8000";
            VEXA_ADMIN_API_URL = "http://admin-api:8001";
            VEXA_ADMIN_API_KEY = secret "ADMIN_TOKEN";
            VEXA_INTERNAL_API_SECRET = secret "INTERNAL_API_SECRET";
            NEXTAUTH_SECRET = secret "NEXTAUTH_SECRET";
            NEXTAUTH_URL = web.url;
          };
          depends_on = depends [ "gateway" ];
          ports = [ "127.0.0.1:${toString uiPort}:3000" ];
          healthcheck = healthy "node -e 'require(\"http\").get(\"http://localhost:3000/\",r=>process.exit(r.statusCode<500?0:1)).on(\"error\",()=>process.exit(1))'";
          mem_limit = "512m";
        };
      };
      composeFile = pkgs.writeText "${name}-compose.json" (builtins.toJSON {
        services = lib.mapAttrs (_: service: {
          restart = "unless-stopped";
          init = true;
          networks = [ "meetings" ];
          logging = { driver = "json-file"; options = { max-size = "10m"; max-file = "3"; }; };
        } // service) services;
        networks.meetings.name = network;
      });
      compose = "${pkgs.docker}/bin/docker compose --project-name ${name} --env-file ${environmentFile} --file ${composeFile}";
    in {
      imports = lib.optionals (!(settings ? environmentFile)) [{
        sops.secrets."${name}-environment" = {
          mode = "0400";
          restartUnits = [ "${name}.service" ];
        };
      }];
      options.ryra.${name} = {
        backup = lib.mkOption {
          default = { };
          type = lib.types.submodule {
            options = contracts.backup.mkRequester {
              user = "root";
              sourceDirectories = [ "${dataDir}/backup" "${dataDir}/storage" ];
              beforeBackup = [ ''
                ${compose} exec -T postgres pg_dump --clean --if-exists -U vexa -d vexa > ${dataDir}/backup/postgres.sql.tmp
                mv ${dataDir}/backup/postgres.sql.tmp ${dataDir}/backup/postgres.sql
              '' ];
              # The services create their schema on first start; the dump replaces it.
              afterRestore = [ ''
                ${pkgs.systemd}/bin/systemctl start ${name}.service
                ${compose} exec -T postgres psql -v ON_ERROR_STOP=1 -U vexa -d vexa < ${dataDir}/backup/postgres.sql
                ${pkgs.systemd}/bin/systemctl restart ${name}.service
              '' ];
            };
          };
          description = "Database dump and recording objects; models are downloadable cache.";
        };
      };
      config = {
        assertions = [{
          assertion = lib.hasPrefix "/" environmentFile && !lib.hasPrefix "/nix/store/" environmentFile;
          message = "Vexa's credentials require a runtime file outside the Nix store.";
        }];
        ryra.services.web.${name}.healthPath = "/";
        services.nginx.virtualHosts.${web.hostName}.locations."/" = {
          proxyPass = "http://127.0.0.1:${toString uiPort}";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_buffering off;
            proxy_read_timeout 3600s;
          '';
        };
        virtualisation.docker.enable = true;
        virtualisation.docker.daemon.settings.log-driver = "journald";
        # Docker (running as root) publishes these on loopback, so they are privileged and no
        # login can take one. There is no systemd unit to confine; registering them anyway puts
        # them under the same evaluation-time privilege assertion as every other Ryra port.
        ryra.services.loopbackGuards = [ { ports = [ apiPort uiPort ports.vexa.whisper ports.vexa.adminApi ]; } ];
        ryra.services.state.${name} = { path = dataDir; owner = "root"; group = "root"; };
        environment.systemPackages = [ (pkgs.writeShellScriptBin "${name}-compose" ''
          exec ${compose} "$@"
        '') ];
        systemd.services.${name} = {
          description = "Vexa meeting transcription";
          wantedBy = [ "multi-user.target" ];
          requires = [ "docker.service" ];
          after = [ "docker.service" "network-online.target" ];
          wants = [ "network-online.target" ];
          unitConfig.RequiresMountsFor = [ dataDir ];
          path = [ pkgs.docker pkgs.coreutils ];
          preStart = ''
            install -d -m 0700 ${dataDir} ${dataDir}/backup
            ${compose} pull --quiet
            docker pull --quiet ${botImage}
          '';
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${compose} up --detach --wait --wait-timeout 300";
            ExecStop = "${compose} down --timeout 30";
            TimeoutStartSec = "20min";
            TimeoutStopSec = "2min";
            Restart = "on-failure";
            RestartSec = "15s";
            UMask = "0077";
          };
        };
      };
    };
}
