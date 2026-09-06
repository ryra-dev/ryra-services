# Ryra Notes

One organization-owned Markdown vault, held by `ryra-notes.service` as the
locked `brain` system user. It listens only on `127.0.0.1:7972`; do not expose
that port or put a second application login in front of it. A person's existing
Ryra SSH certificate is the authentication boundary.

The service requires Ryra CLI 0.1.18 or newer. Version 0.1.17 can resurrect an
attachment deleted in the same millisecond as a replacement; the module refuses
that version instead of deploying a known data-consistency bug.

## Use it from another machine

Keep a local folder in step through the person's own SSH account:

```sh
ryra sync exchange ~/Company --remote erlend@brain --watch
```

Open `~/Company` as the Obsidian vault. Obsidian edits ordinary Markdown and
Ryra reconciles those edits with the other clients. The remote destination is
the person's account (`erlend@` above), never the shared `brain` identity.

On the brain machine itself, an account named in `settings.editors` may open
`/var/lib/notes/vault` directly in Obsidian. Prefer a synced local folder on a
laptop when possible: it keeps the server headless and gives the person an
offline copy without sharing Unix identities.

## What must survive

`/var/lib/notes` contains both:

- `vault/`: the Markdown and attachments people see;
- `.ryra/`: the persisted Yjs updates and attachment ledger used to merge
  concurrent edits correctly after a restart.

Back up the parent, not only `vault/`. Markdown alone recovers the current
words, but drops the merge history that keeps restarted clients from treating
old edits as new ones.

## Check and restore

```sh
systemctl status ryra-notes.service
sudo ryra-backup-notes snapshots
```

To restore the complete state, stop the writer first:

```sh
sudo systemctl stop ryra-notes.service
sudo ryra-backup-notes restore SNAPSHOT_ID
sudo chown -R brain:brain /var/lib/notes
sudo systemctl start ryra-notes.service
```

Restoring only one Markdown file is safe without replacing `.ryra`: copy it
into the vault and let the running server absorb it on the next sync.
