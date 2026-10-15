Vexa sends meeting bots into video calls, transcribes them with a local Whisper model and keeps the audio recordings. It runs as a Docker Compose stack of nine long-running containers and a one-shot bucket initialiser (PostgreSQL, Valkey, an S3-compatible recording store, Whisper, the API services and the web UI), started by `vexa.service`. Nothing is sent to a hosted transcription service. Images are pinned by digest and pulled when the service starts.

Plan for about 4 GB of memory and a few GB of disk for the Whisper model and recordings. `settings.model` selects the Whisper model (default `Systran/faster-whisper-base`).

The web UI uses the Ryra web contract: private by default on port 8086, with optional public HTTPS or Tailscale access. Vexa's own login is the only one, so set `web.externalUrl` or public HTTPS before exposing it. The REST API listens on loopback port 18056 (`settings.apiPort`); the UI backend on 13000 (`settings.uiPort`). Neither is public.

The `vexa-environment` secret holds the internal credentials as an environment file: `DB_PASSWORD`, `ADMIN_TOKEN`, `INTERNAL_API_SECRET`, `NEXTAUTH_SECRET`, `MINIO_ACCESS_KEY` and `MINIO_SECRET_KEY`. Use independent random values. `ADMIN_TOKEN` is the key for Vexa's admin API; create users and their API tokens with it. `settings.environmentFile` supplies a runtime file instead of the declared secret.

Bots need Docker, so the module enables it and gives the runtime container the Docker socket. Anyone able to start a meeting bot can therefore start containers on this machine; treat the admin token accordingly.

Hourly encrypted backups capture a PostgreSQL dump and the recording store; Whisper models are a re-downloadable cache. Use `sudo ryra-backup-vexa backup`, `snapshots` and `restore SNAPSHOT`. Restore starts the stack, loads the dump over the fresh schema and restarts. `vexa-compose` runs `docker compose` against the stack, for example `sudo vexa-compose ps`.

Syncing a Google Calendar into Vexa is not part of this service.
