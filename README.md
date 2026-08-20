# Sentry Self-Hosted — ilmiy.uz Deployment

Production deployment of self-hosted Sentry, managed as a Git repository.

Access: **http://&lt;server-ip&gt;:9000** — internal network, plaintext HTTP, no TLS.
Container stack binds: **0.0.0.0:9000** (all interfaces)

> This is a deliberate choice. The deployment and the projects reporting to it
> all live on an internal network. See §5 for the security boundary this
> assumes, and §10 for what to change if the host ever becomes public.

---

## 1. Version

| Item | Value |
|---|---|
| Sentry self-hosted release | **26.8.0** |
| Upstream | https://github.com/getsentry/self-hosted |
| Pinned commit | `73fe2f2` (`release: 26.8.0`) |
| Channel | stable release tag — **not** `master`, `nightly`, `beta`, or an RC |

All service images are pinned to `26.8.0` in upstream's `.env` (`SENTRY_IMAGE`,
`SNUBA_IMAGE`, `RELAY_IMAGE`, `SYMBOLICATOR_IMAGE`, `TASKBROKER_IMAGE`,
`VROOM_IMAGE`, `UPTIME_CHECKER_IMAGE`, `LAUNCHPAD_IMAGE`).

Check what is actually deployed:

```bash
git describe --tags
```

**Never deploy `latest`.** Every upgrade goes through an explicit tag — see §9.

---

## 2. Repository strategy

This is a **standalone deployment repository with upstream as a second remote**,
not a fork of `getsentry/self-hosted`.

```
origin    -> our private GitHub repo   (deployment config, this README)
upstream  -> getsentry/self-hosted     (read-only, fetch only)
```

Why not a fork:

- `getsentry/self-hosted` carries a large history and gets force-pushes. A fork
  inherits all of it, so `git log` on our deployment is unreadable.
- A fork's GitHub UI constantly offers PRs against upstream, which is noise for
  a deployment repo.
- The one real advantage of a fork — easy merging of new upstream tags — we keep
  anyway, because `upstream` is configured as a remote here. `git merge 26.9.0`
  works identically.

Result: `git log` shows only our config decisions, while upstream history stays
one `git fetch upstream` away.

Verify the remotes:

```bash
git remote -v
```

If `upstream` is missing on a fresh clone:

```bash
git remote add upstream https://github.com/getsentry/self-hosted.git
git fetch upstream --tags
```

---

## 3. Server requirements

| | Upstream minimum | Our server |
|---|---|---|
| OS | Linux, x86_64 | Ubuntu 22.04.5 LTS, x86_64 |
| CPU | 4 cores (hard fail below) | 8 vCPU |
| RAM | 14000 MB hard floor, 16 GB recommended | 32 GB |
| Disk | 20 GB | ~195 GB (~181 GB free) |
| Docker | >= 19.03.6 | installed |
| Docker Compose | >= 2.32.2 | plugin installed |
| Bash | >= 4.4.0 | 5.x |
| CPU flag | SSE 4.2 (ClickHouse) | verify with preflight |

The hard floors live in `install/_min-requirements.sh`; `install.sh` aborts if
they are not met. With `COMPOSE_PROFILES=errors-only` the floors drop to 2 cores
and 7000 MB.

### OS-level settings

Do **not** change these blindly. Check the current value first, change only if
below the requirement.

**`vm.max_map_count`** — ClickHouse and Kafka memory-map many files.

```bash
sysctl vm.max_map_count          # check first
```

Modern Ubuntu ships `1048576`, which is already far above the `262144` that
ClickHouse wants. If, and only if, it reads lower and ClickHouse fails to start:

```bash
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-sentry.conf
sudo sysctl --system
```

**Swap** — not a Sentry requirement. But Kafka and ClickHouse spike during the
initial migration, and on a box with no swap that spike becomes an OOM kill
mid-migration, which is far messier to recover from than a few slow seconds.
With 32 GB RAM this is optional; 2–4 GB of swap is cheap insurance.

```bash
free -h                          # check first
```

`deploy/preflight.sh` reports both values without changing anything.

---

## 4. Directory layout

```
/home/devops/sentry
├── deploy/                  <- ours, version controlled
│   ├── env.base             <- non-secret config (retention, bind, profiles)
│   ├── bootstrap.sh         <- generates .env.custom from env.base + secrets
│   ├── preflight.sh         <- read-only pre-install host check
│   ├── verify.sh            <- read-only post-install health check
│   └── backup.sh            <- Postgres + config backup
├── README.md                <- this file (ours)
├── UPSTREAM_README.md       <- upstream's original README, kept for reference
├── .gitignore               <- upstream's + our additions
├── .env.custom              <- GENERATED, GITIGNORED, CONTAINS SECRETS
└── ...                      <- everything else is upstream 26.8.0, unmodified
```

---

## 5. What we changed vs upstream

Upstream files are left untouched, which is what keeps upgrades cheap. Our
configuration is a thin layer on top.

| File | Status | Why |
|---|---|---|
| `deploy/env.base` | **added** | Our non-secret config. Source of truth for retention and bind address. |
| `deploy/bootstrap.sh` | **added** | Renders `.env.custom` from `env.base` + generated secrets. |
| `deploy/preflight.sh` | **added** | Pre-install host verification. |
| `deploy/verify.sh` | **added** | Post-install verification. |
| `deploy/backup.sh` | **added** | Backup helper. |
| `README.md` | **replaced** | Upstream's moved to `UPSTREAM_README.md` so upgrade merges do not conflict on it. |
| `.gitignore` | **appended** | Added `.venv/`, `backups/`, `*.sql`, `*.tar.gz`, `.env.custom.*`. Upstream already ignores `.env.custom`, `sentry/config.yml`, `sentry/sentry.conf.py`, `relay/credentials.json`, `.idea`. |
| `.env` | **not touched** | Overridden via `.env.custom` instead. Editing `.env` would conflict on every upgrade. |
| `docker-compose.yml` | **not touched** | Same reason. |

### Configuration values we set

Both live in `deploy/env.base`:

| Key | Upstream default | Ours | Reason |
|---|---|---|---|
| `SENTRY_EVENT_RETENTION_DAYS` | `90` | `30` | Requested retention window. |
| `SENTRY_BIND` | `9000` | `0.0.0.0:9000` | Reachable at `http://<server-ip>:9000` from the internal network. Explicit form instead of upstream's bare `9000` so the intent is stated rather than implied. |

`install/_lib.sh` reads `.env.custom` first and merges it over `.env`, so only
the keys we actually change need to be listed.

> **Retention caveat:** set retention **before the first install**. Snuba derives
> ClickHouse TTLs from `SENTRY_EVENT_RETENTION_DAYS` at bootstrap. Lowering it
> later affects new data and the nightly `sentry cleanup` job, but does not
> retroactively shrink existing ClickHouse partitions.

---

## 6. Secrets — what must never reach Git

**Never commit these. They are all in `.gitignore`; verify before every push.**

| Path | Contains |
|---|---|
| `.env.custom` | `LAUNCHPAD_RPC_SHARED_SECRET`, any future SMTP password |
| `sentry/config.yml` | `system.secret-key` (generated by `install/generate-secret-key.sh`) |
| `sentry/sentry.conf.py` | DB credentials, local overrides |
| `relay/credentials.json` | Relay keypair — **private key** |
| `symbolicator/config.yml` | generated local config |
| `geoip/GeoIP.conf` | MaxMind license key |
| `sentry/backup.json` | full data export |
| `*.tar.gz`, `*.sql`, `backups/` | Postgres dumps and backup archives |

Rule: **`deploy/env.base` is version controlled, therefore no secret ever goes
in it.** Secrets belong in `.env.custom`, which `bootstrap.sh` generates and Git
ignores.

Check before pushing:

```bash
git status --short
git ls-files | grep -E '\.env\.custom|config\.yml|sentry\.conf\.py|credentials\.json'
```

The second command must print **nothing**.

Optional local guard:

```bash
cat > .git/hooks/pre-commit <<'EOF'
#!/usr/bin/env bash
blocked=$(git diff --cached --name-only | grep -E '^\.env\.custom|^sentry/config\.yml|^sentry/sentry\.conf\.py|^relay/credentials\.json|\.sql$|\.tar\.gz$' || true)
if [[ -n "$blocked" ]]; then
  echo "BLOCKED: attempt to commit secret-bearing files:"; echo "$blocked"; exit 1
fi
EOF
chmod +x .git/hooks/pre-commit
```

---

## 7. Installation

Run as a non-root user that is in the `docker` group. `install.sh` refuses to be
helpful if the Docker socket is unreachable.

```bash
# 1. Clone
git clone <our-repo-url> /home/devops/sentry
cd /home/devops/sentry

# 2. Confirm the pinned version
git describe --tags          # expect: 26.8.0

# 3. Pre-install host check (read-only, changes nothing)
./deploy/preflight.sh

# 4. Render .env.custom from env.base + generated secrets
./deploy/bootstrap.sh

# 5. Confirm the config that will be applied
grep -E '^(SENTRY_EVENT_RETENTION_DAYS|SENTRY_BIND|COMPOSE_PROFILES)=' .env.custom

# 6. Install. Takes 20-40 minutes: pulls ~20 images, runs DB migrations,
#    bootstraps Kafka topics and ClickHouse tables.
./install.sh

# 7. Start
docker compose up -d

# 8. Verify
./deploy/verify.sh
```

`install.sh` prompts near the end to create the first admin user. If you skip it:

```bash
docker compose run --rm web createuser --superuser
```

---

## 8. Operations

### Status

```bash
docker compose ps
./deploy/verify.sh
curl -I http://127.0.0.1:9000          # from the server itself
curl -I http://<server-ip>:9000        # from another host on the network
```

### Start / stop / restart

```bash
docker compose up -d                    # start
docker compose stop                     # stop, keep containers and data
docker compose restart                  # restart all
docker compose restart web              # restart one service
docker compose down                     # stop and remove containers (data volumes survive)
```

> **Never run `docker compose down -v`.** The `-v` flag deletes volumes, which
> destroys Postgres, ClickHouse, and Kafka data permanently. There is no undo.

### Logs

```bash
docker compose logs -f                       # everything, follow
docker compose logs --tail=200 web           # one service
docker compose logs --tail=200 snuba-api clickhouse kafka
docker compose logs --since=30m web | grep -i error
```

### Troubleshooting an unhealthy container

Do **not** reflexively restart it — a restart hides the cause and the container
comes back unhealthy a minute later.

```bash
docker compose ps                            # 1. which service, what status
docker compose logs --tail=200 <service>     # 2. read the actual error
docker inspect --format '{{json .State.Health}}' \
  $(docker compose ps -q <service>) | jq     # 3. what the healthcheck ran
docker stats --no-stream                     # 4. OOM? check memory
```

Common causes: Kafka not ready yet (wait, the healthcheck retries 10×),
ClickHouse blocked by a low `vm.max_map_count`, or the host out of memory.

### Backup

```bash
./deploy/backup.sh                                   # -> /var/backups/sentry/
SENTRY_BACKUP_DIR=/mnt/backup ./deploy/backup.sh     # custom destination
```

What it covers: Postgres (projects, users, orgs, issue metadata, settings) plus
the config layer including secrets.

What it does **not** cover: raw event bodies in ClickHouse. Restoring only this
backup gives you a working Sentry with your projects and DSNs intact, but not
the historical event data. A full event backup means snapshotting the
`sentry-clickhouse` Docker volume with the stack stopped.

Upstream also provides a logical export:

```bash
./sentry-admin.sh export global /sentry-admin/backup.json
```

Backup archives contain secrets. Store them off-box and encrypted. Never inside
this repository.

---

## 9. Upgrade procedure

**Never auto-upgrade production. Always target an exact tag.**

Sentry supports upgrading at most one release train at a time; skipping many
versions can break migrations. Read the release notes before starting.

```bash
cd /home/devops/sentry

# 1. Current version
git describe --tags

# 2. Backup FIRST -- this is the rollback path
./deploy/backup.sh

# 3. Fetch upstream tags
git fetch upstream --tags

# 4. Pick the new stable tag. Skip anything marked prerelease, rc, beta, nightly.
git tag -l --sort=-v:refname | head -10
#    Confirm on https://github.com/getsentry/self-hosted/releases

# 5. Review what actually changes before merging
git log --oneline 26.8.0..<NEW_TAG>
git diff 26.8.0..<NEW_TAG> -- .env docker-compose.yml install/
#    Watch for: new required env vars, changed service names, removed volumes.
#    If .env gained a key we care about, add it to deploy/env.base.

# 6. Stop the stack
docker compose down

# 7. Merge the new tag onto our branch
git merge <NEW_TAG>
#    Conflicts should be rare -- we do not edit upstream files.
#    README.md will not conflict: upstream's lives in UPSTREAM_README.md.

# 8. Re-render .env.custom (picks up env.base changes, keeps existing secrets)
./deploy/bootstrap.sh

# 9. Run the installer -- it handles image pulls and DB migrations
./install.sh

# 10. Start
docker compose up -d

# 11. Verify
./deploy/verify.sh

# 12. Record the upgrade
git tag -a deployed-<NEW_TAG>-$(date -u +%Y%m%d) -m "Deployed <NEW_TAG>"
git push origin main --tags
```

### Rollback

```bash
docker compose down
git checkout <PREVIOUS_TAG>          # or: git reset --hard <commit before merge>
./deploy/bootstrap.sh
./install.sh
docker compose up -d
```

Database migrations are generally **not** reversible. If the new version already
migrated the schema, rolling back the code is not enough — restore the Postgres
dump from step 2. This is why the backup comes before anything else.

---

## 10. Network exposure and the security boundary

This deployment runs **plaintext HTTP on all interfaces**, by design, because it
sits on an internal network and the projects reporting to it use internal IPs.

### What that assumes

Everything below travels unencrypted and is readable by anything on the network
path:

- login credentials and session cookies
- DSN keys and auth tokens
- event payloads — stack traces, request data, and whatever user data your
  projects attach to them

That is an acceptable trade **only** while port 9000 stays inside the trusted
network. The whole security model rests on that one condition.

### Keep the boundary intact

```bash
sudo ufw status                      # confirm 9000 is not open at the perimeter
ss -lntp | grep 9000                 # confirm what is actually bound
```

Rules of thumb:

- Do not port-forward or NAT 9000 to a public address.
- Do not put the host on a public interface without revisiting this section.
- `deploy/verify.sh` prints the reminder and the internal URL on every run.

### Set the URL prefix

After the first install, point Sentry at the address people actually use.
Without this, links in notification emails and any SSO redirect go to the wrong
host.

```bash
# sentry/config.yml
system.url-prefix: 'http://<server-ip>:9000'
```

```bash
docker compose restart web
```

Prefer a stable internal DNS name over a raw IP if you have one — it survives
the server changing address.

### If this ever needs to face the internet

The change is small, and the order matters:

1. `deploy/env.base` → `SENTRY_BIND=127.0.0.1:9000`, then
   `./deploy/bootstrap.sh && docker compose up -d`.
2. Point DNS at the host; open 80 and 443, keep 9000 closed.
3. Install nginx on the host, proxy to `http://127.0.0.1:9000`.
4. Issue a certificate with certbot (`--nginx`); confirm auto-renewal.
5. Update `system.url-prefix` to the `https://` address, restart `web`.
6. Forward `X-Forwarded-For` and `X-Forwarded-Proto`, or Sentry attributes every
   event to the proxy.
7. Raise `client_max_body_size` — nginx's 1 MB default rejects large source maps
   and minidumps. 100 MB is a reasonable start.

## 11. Reference

- Self-hosted docs: https://develop.sentry.dev/self-hosted/
- Releases: https://github.com/getsentry/self-hosted/releases
- Upstream README: `UPSTREAM_README.md` in this repo
