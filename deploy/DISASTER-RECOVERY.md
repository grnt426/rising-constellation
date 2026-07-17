# Disaster recovery — Tetrarchy Falls production

What it takes to rebuild production from nothing, where every piece of
state lives, and the exact runbook. Assumes total loss of the prod EC2
instance; anything less (bad deploy, corrupted table) uses a subset.

Last verified: 2026-07-17.

## Production inventory (us-east-1, account 553872001542)

| Piece | Identifier |
|---|---|
| EC2 instance | `i-017d81bd1155ebfb3` (t4g.large Graviton/arm64, Ubuntu 22.04, 30 GB gp3 root, `DeleteOnTermination=false`) |
| Public DNS | `ec2-98-91-16-141.compute-1.amazonaws.com` |
| Old amd64 host (cold rollback) | `i-0e47138cd400b3a5d` (stopped, volume preserved) |
| ALB | `rc-prod-alb` — `arn:...:loadbalancer/app/rc-prod-alb/04ba37753900211c` |
| Target group | `rc-prod-tg` — `arn:...:targetgroup/rc-prod-tg/c20f38802e9a18df` |
| ALB security group | `sg-010d955086edbb40a` (port 80 restricted to the CloudFront prefix list `pl-3b927c52`, rule `sgr-0ed518e05116a94f6`) |
| CloudFront | `E1S7G1Z8YADSRX` (`d1vgv10axi3fbo.cloudfront.net`), aliases `tetrarchyfalls.com` + `www`, origin = the ALB over HTTP:80 |
| ACM cert | `arn:...:certificate/a8fbaeb7-32ee-430d-8564-a8950630a40c` (tetrarchyfalls.com) |
| DNS | Route53, apex ALIAS (ALB hosted zone `Z35SXDOTRQ7X7K`) |
| Backup bucket | `rc-prod-backups-553872001542` (created by `provision-dr.ps1`) |
| Instance role | `rc-prod-instance-role` / profile `rc-prod-instance-profile` (backup-bucket write + `rc/prod/env` secret read; attached by `provision-dr.ps1`) |

## Where state lives

| State | Primary | Off-host copies |
|---|---|---|
| Code + deploy tooling | GitHub (`master` = production trunk) | every checkout |
| Database (accounts, games, everything) | Postgres 14 **on the instance** (no RDS) | nightly `pg_dump` to `s3://rc-prod-backups-553872001542/db/` (30-day retention) |
| Game snapshots (paused/running instance state) | `/var/lib/rc-snapshots` on the instance | nightly tarball to `s3://.../snapshots/` |
| Runtime secrets (`SECRET_KEY_BASE`, DB password, `RELEASE_COOKIE`, Mailjet, Discord token, ...) | `/etc/rc/secret.json` on the instance (root, 0600) | operator machine `.secrets/rc-prod-env.json` (gitignored); AWS Secrets Manager `rc/prod/env` once `provision-dr.ps1` has run |
| Edge/TLS identifiers | this file (table above) | operator machine `.secrets/*.txt` |
| User uploads | none yet (`S3_BUCKET` is a placeholder) | n/a |

The secret flow: `rc-fetch-secrets.service` renders `/etc/rc/env` from a
JSON blob before `rc.service` starts. Prod currently runs with the
`RC_SECRET_FILE=/etc/rc/secret.json` override (local file). Once
`rc/prod/env` exists in Secrets Manager and the instance role is
attached, deleting
`/etc/systemd/system/rc-fetch-secrets.service.d/override.conf` flips the
host to Secrets Manager mode — the bootstrap default for new hosts.

## Nightly backups

`rc-db-backup.timer` fires daily at 08:47 UTC and runs
`/usr/local/bin/rc-db-backup` as `rc`: `pg_dump -Fc` (verified with
`pg_restore --list`) plus a tarball of `/var/lib/rc-snapshots`, both
uploaded via the instance role. Bucket lifecycle expires objects after
30 days. Installed by `deploy/provision-dr.ps1` (current host) and
`bootstrap-host.sh` (new hosts).

Check freshness:

```
aws s3 ls s3://rc-prod-backups-553872001542/db/ --region us-east-1 | tail -3
# on-host: systemctl list-timers rc-db-backup.timer && journalctl -u rc-db-backup -n 20
```

Restore a dump (into an empty or scratch DB):

```
aws s3 cp s3://rc-prod-backups-553872001542/db/rc-db-<STAMP>.dump .
pg_restore --clean --if-exists --no-owner -d "$DATABASE_URL" rc-db-<STAMP>.dump
```

Do a quarterly restore drill against a scratch database — a backup you
have never restored is a hope, not a backup.

## Runbook: rebuild onto a new host

Prereqs: the `rc/prod/env` secret exists in Secrets Manager (or you have
`.secrets/rc-prod-env.json` to scp over), an SSH keypair, and a recent
backup in the bucket.

1. **Launch**: arm64 (Graviton) Ubuntu 22.04 instance in us-east-1,
   ≥30 GB gp3, security group allowing SSH from you and port 80 from the
   ALB SG. Attach `rc-prod-instance-profile` at launch.
2. **Bootstrap** (as root on the host):
   ```
   git clone <repo> && cd rising-constellation
   RC_HOST=<new-public-dns> RC_BACKUP_BUCKET=rc-prod-backups-553872001542 \
     ./deploy/bin/bootstrap-host.sh
   ```
   Secrets-Manager mode is the default (`RC_SECRET_ID=rc/prod/env`);
   pass `RC_SECRET_FILE=/etc/rc/secret.json` instead if you scp'd the
   JSON. This installs Postgres, nginx, systemd units, the backup timer,
   and primes `/etc/rc/env`.
3. **Restore the DB** (before first deploy — migrations then no-op):
   pull the latest dump from S3 and `pg_restore` as above. Optionally
   untar the latest `snapshots/` tarball into `/var/lib/rc-snapshots`
   (owner `rc:rc`) so paused games resume.
4. **Deploy**: from the operator machine,
   `RC_SSH_HOST=rc@<new-public-dns> ./deploy/release.sh master`
   (arm64 build — local QEMU or `--remote`; see README "Building for
   prod").
5. **Repoint traffic**: register the new instance in `rc-prod-tg`,
   deregister the dead one. CloudFront/DNS need no change — they point
   at the ALB.
6. **Verify**: `https://tetrarchyfalls.com` loads, log in, an instance
   resumes; `systemctl list-timers rc-db-backup.timer` shows the next
   backup.

## Known gaps (accepted for now)

- `S3_BUCKET`/upload storage is a placeholder and the app's
  `AWS_ACCESS_KEY_ID`/`SECRET` in the env blob are dead keys — uploads
  don't work in prod today. Replace with a real bucket (or move the app
  to the instance role) when uploads matter.
- Mailjet template IDs in the secret blob reference templates that no
  longer exist — transactional email needs re-provisioning.
- The ALB/CloudFront/ACM/Route53 layer is not scripted; identifiers
  above + `deploy/aws-setup.md` prose is what exists. Losing *those*
  (vs. the instance) means manual reprovisioning.
- If every copy of the secret blob is lost, regenerate
  `SECRET_KEY_BASE`/`GUARDIAN_SECRET_KEY` (logs everyone out, kills
  outstanding invite links), reset the DB password, re-issue the Discord
  bot token and Mailjet keys.
