# CloudPi · On-EC2 Interactive Deploy (v2)

This guide covers `deploy_interactive_2.sh` — a variant of the original
`deploy_interactive.sh` designed to be run **directly on the EC2 instance**
instead of from your local PC.

Use this version when you do **not** have an AWS access key on your local
machine and want to deploy entirely from inside EC2.

---

## What's different vs `deploy_interactive.sh`

| Concern | `deploy_interactive.sh` (local PC) | `deploy_interactive_2.sh` (on EC2) |
|---|---|---|
| AWS auth | `AWS_ACCESS_KEY_ID` / secret from env or prompt | EC2 **IAM instance role** (IMDSv2) — no keys |
| EC2 provisioning | Step 6 runs `deploy_aws_ec2.py` | Skipped — EC2 already exists |
| SSH key pair | Step 5 creates/imports a key pair | Skipped — no SSH needed |
| File transport | SCP/SSH from local PC to EC2 | Local file ops on EC2 |
| Bootstrap wait | Polls `/var/log/cloudpi-bootstrap-done` over SSH | Not needed — you're already past bootstrap |
| Region | Prompted | Auto-detected from IMDSv2 placement |
| Host address | Captured from `deploy_aws_ec2.py` output (required) | **Optional** — tries IMDSv2 public-ipv4 → private IP → `hostname -I` → `localhost` |
| State file | `.deploy_state` | `.deploy_state_2` (independent) |

The script keeps the same re-runnable, step-tracking model: every completed
step is written to `.deploy_state_2` and is skipped on subsequent runs (with
a confirmation prompt to re-run).

---

## Prerequisites on the EC2 instance

1. **An EC2 instance you can log in to.** Use any of:
   - EC2 Instance Connect (browser, no key needed)
   - AWS Systems Manager Session Manager (browser, no key needed)
   - An existing SSH key that's already on the box

2. **The instance must have an IAM role attached** that allows:
   - `secretsmanager:GetSecretValue`, `secretsmanager:DescribeSecret`
   - `secretsmanager:CreateSecret`, `secretsmanager:PutSecretValue`,
     `secretsmanager:UpdateSecret`, `secretsmanager:TagResource`
   - On the resource `cloudpi-secrets` (and version suffixes).

   The role `cloudpi-ec2-role` created by `deploy_aws_ec2.py` already grants
   exactly this — no extra setup is needed if you provisioned with that.

3. **Bootstrap completed** (cloud-init/userdata finished). A telltale is:
   ```bash
   ls /var/log/cloudpi-bootstrap-done    # file exists when bootstrap is done
   ```

4. **Installed by the bootstrap** and required by the script:
   - `python3`, `pip3`, `openssl`, `curl`, `rsync`
   - `docker` + the `docker compose` plugin
   - `/usr/local/bin/aws` (AWS CLI v2)
   - `sudo` (if you're not running as root)

   The script checks these at step 1 and aborts with a clear message if any
   are missing.

---

## Files this flow needs

All of these live in the deployment folder you copy onto EC2:

| File | Purpose |
|---|---|
| `deploy_interactive_2.sh` | The on-EC2 driver (this README documents it) |
| `setup_aws_secrets.py` | Uploads / fetches secrets in AWS Secrets Manager |
| `setup_docker_compose_service.py` | Installs the two systemd units |
| `cloudpi-fetch-secrets.sh` | Reference template for the systemd fetch service (the script regenerates this at install time and writes to `/usr/local/bin/`) |
| `docker-compose.yml` | Reference template (the script generates a fresh one) |
| `cloudpi-secrets.json` | Local input/output of secret values (gitignored in real use) |
| `docker-pat.txt` | Optional — Docker Hub PAT (`DOCKER_PAT=...`) for unattended login |

The `.txt` versions in the repo are backup copies; the script needs the
plain-named versions.

---

## Getting the files onto the EC2 instance

If you can't SSH from your laptop, use any of these alternatives:

- **EC2 Instance Connect / SSM Session Manager**, then `git clone`:
  ```bash
  cd ~
  git clone https://github.com/venkatnichesoft/venkat-cloudpi-aws-deploy.git
  cd venkat-cloudpi-aws-deploy
  ```

- **S3 staging** — upload the folder to a private bucket from anywhere, then on EC2:
  ```bash
  aws s3 cp s3://<your-bucket>/venkat-cloudpi-aws-deploy/ . --recursive
  ```

- **Paste-and-write** the few files directly into the terminal session
  (works in Instance Connect / Session Manager).

Once on the box:
```bash
chmod +x deploy_interactive_2.sh setup_aws_secrets.py setup_docker_compose_service.py
```

---

## Running the deploy

```bash
sudo -i              # or run the script with sudo each time
./deploy_interactive_2.sh
```

On startup the script prints a status overview. Pick option **1** to resume —
already-completed steps are skipped unless you explicitly say "yes, re-run".

### The 16 steps — read this before each one runs

Each step below tells you **exactly what it does, what it touches, and what
you'll be prompted for** so you know what's about to happen before pressing
Enter. Steps marked with a `STEP_X` key write that key to `.deploy_state_2`
and skip themselves on the next run (you'll see `⚠ Already completed: …` and
be asked `Re-run this step? [y/N]`).

---

#### Step 1 — Prerequisites check  *(always runs, read-only)*

**What it does:** Verifies the EC2 box has `python3`, `pip3`, `openssl`,
`curl`, `rsync`, `docker`, the `docker compose` plugin, the AWS CLI, and
`sudo` (if you aren't root).
**Touches:** Nothing — just runs `command -v` checks.
**Prompts:** None.
**Aborts if:** Any tool is missing — the bootstrap script (cloud-init) is
supposed to install all of them.

---

#### Step 2 — IAM instance role & region  *(always runs, read-only)*

**What it does:** Reads the availability-zone from IMDSv2 to figure out the
AWS region, then calls `sts:GetCallerIdentity` to confirm the instance role
works.
**Touches:** Sets `REGION` / `AWS_DEFAULT_REGION` in this shell only.
**Prompts:** Region (only as a fallback if IMDSv2 is unreachable); a
confirmation prompt if STS fails.
**Notes:** No access keys are used. The role attached to the instance must
allow `secretsmanager:Get/Put/Create/Describe/Update/TagResource` on
`cloudpi-secrets*`.

---

#### Step 3 — Python dependencies  *(STEP_3)*

**What it does:** `pip3 install --quiet boto3 cryptography`. `boto3` is for
talking to AWS Secrets Manager; `cryptography` is used to generate/validate
the Fernet keys in step 4.
**Touches:** System or user-local Python site-packages depending on how the
script is invoked.
**Prompts:** None.

---

#### Step 4 — Build / repair `cloudpi-secrets.json`  *(STEP_4)*

**What it does:** Either uses your existing `cloudpi-secrets.json` as-is, or
regenerates a fresh one (random DB password, random Fernet/HMAC keys, random
`SECRET_KEY` etc.) — `CLIENT_*` values are always preserved. Then it
validates the three Fernet keys (`PAR_SECRET_KEY`, `ENCRYPTION_KEY`,
`CREDENTIAL_ENCRYPTION_KEY`); if any are malformed, you're asked whether to
regenerate them.
**Touches:** `./cloudpi-secrets.json` on disk.
**Prompts:** Use existing vs. regenerate (default: existing); client name
& email if missing; Fernet key regen confirmation if any are invalid.
**Why this matters:** Bad Fernet keys cause the Flask backend to crash-loop,
which only surfaces as an HTTP 503 on login much later — catching it here
saves a lot of debugging.

---

#### Step 5 — Detect host address  *(optional)*

**What it does:** Looks up a sensible default address (used as
`CLIENT_DOMAIN`, the `.env` `HOST` value, the TLS cert CN, and the URL the
login-test step curls). Order: cached value → IMDSv2 `public-ipv4` →
IMDSv2 `local-ipv4` → `hostname -I` → user prompt → `localhost` fallback.
**Touches:** `.deploy_state_2` (caches the chosen value as `PUBLIC_IP`).
**Prompts:** A single line: `Host address [<detected>]:` — press Enter to
accept, type a different IP/hostname, or type `-` (or leave blank when
nothing was detected) to skip and use `localhost`.

---

#### Step 6 — Update `CLIENT_DOMAIN` in secrets  *(STEP_6)*

**What it does:** Sets `CLIENT_DOMAIN` inside `cloudpi-secrets.json` to the
host address (or whatever you type). This value is what the running app uses
for redirects, CORS, and outbound links.
**Touches:** `./cloudpi-secrets.json`.
**Prompts:** New `CLIENT_DOMAIN` (default = host address from step 5).

---

#### Step 7 — Upload secrets to AWS Secrets Manager  *(STEP_7)*

**What it does:** Calls `setup_aws_secrets.py upload` to push the contents
of `cloudpi-secrets.json` into the `cloudpi-secrets` secret in AWS Secrets
Manager. If the secret already exists, it's updated; otherwise it's created
with the `Project=CloudPi` tag.
**Touches:** AWS Secrets Manager (`cloudpi-secrets`).
**Prompts:** None.
**Permission needed:** `secretsmanager:CreateSecret` / `PutSecretValue` /
`UpdateSecret` / `TagResource` / `DescribeSecret` (all granted by the
`cloudpi-ec2-role` policy).

---

#### Step 8 — Place files in `/home/cloudpiadmin/cloudpi`  *(STEP_8)*

**What it does:** Makes sure `/home/cloudpiadmin/cloudpi/certs` exists,
owned by `cloudpiadmin`, then offers four ways to populate it:
1. **Fresh install** — `git clone` the repo into `…/cloudpi/repo` and copy
   files up (no-clobber).
2. **Local folder on EC2** — `rsync` from a directory you specify (skips
   `.git`, `.DS_Store`, `*.bak`, `__pycache__`, `*.pyc`).
3. **Migration from another server** — `rsync` over SSH from a source host
   you specify (you provide IP, username, and the path to an SSH key
   *on this EC2 box*).
4. **Skip** — keep the existing contents.
**Touches:** `/home/cloudpiadmin/cloudpi/` and `certs` ownership (`certs`
ends up owned by UID 1000 because that's what the container expects).
**Prompts:** Install type; depending on choice: local folder path, or
source host/user/key path.

---

#### Step 9 — Generate / patch `docker-compose.yml`  *(STEP_9)*

**What it does:** Either generates a fresh `docker-compose.yml` from the
embedded template (db + app services, named-volume MySQL data, secrets bind
mount from `/run/secrets-tmp/`, healthchecks, ports 80/443), or updates the
image tags in an existing file to a new release version, or leaves it
alone.
**Touches:** `/home/cloudpiadmin/cloudpi/docker-compose.yml`.
**Prompts:** Action (1=generate / 2=update tags / 3=skip);
target release version (default `v1.1.044`).

---

#### Step 10 — Generate `.env`  *(STEP_10)*

**What it does:** Writes a short `.env` file with `HOST`, `SUBDOMAIN`,
`HTTPS=true`, and the in-container paths to the TLS cert / key /
ca-bundle. Both the db and app containers read this via `env_file:`.
**Touches:** `/home/cloudpiadmin/cloudpi/.env`.
**Prompts:** None.

---

#### Step 11 — Self-signed TLS certificates  *(STEP_11)*

**What it does:** Runs `openssl req -x509 -nodes -days 365 -newkey rsa:2048`
to create `cert.pem` + `privkey.pem`, then copies `cert.pem` to
`ca_bundle.pem`. Chowns the directory to UID 1000 (container user) and sets
file modes 644/640/644.
**Touches:** `/home/cloudpiadmin/cloudpi/certs/{cert.pem,privkey.pem,ca_bundle.pem}`.
**Prompts:** None.
**Aborts if:** openssl fails or the expected files aren't present after.

---

#### Step 12 — Systemd services *(STEP_12A / 12B / 12C — sub-steps)*

Three sub-steps, each independently re-runnable:

**12A — Install secrets-fetch script.** Writes
`/usr/local/bin/cloudpi-fetch-secrets.sh` with the detected `REGION` baked
in. This script mounts a 2 MiB tmpfs at `/run/secrets-tmp`, pulls the
`cloudpi-secrets` blob from Secrets Manager, and writes
`cloudpi.secrets` + `db_password` + `db_root_password` into it.

**12B — Docker Hub login** (for the private `cloudpi1/cloudpi:*` images).
Reads `DOCKER_PAT=…` from `docker-pat.txt` if present, otherwise prompts.
**Aborts if** the PAT is rejected, with a clear message — no silent failure.

**12C — Install systemd units.** Runs `setup_docker_compose_service.py`,
which writes `cloudpi-fetch-secrets.service` and
`cloudpi-docker-compose.service`, enables them, then starts them in order
(fetch first, then compose). Failures are surfaced with the last 20 lines
of `journalctl`.

**Touches:** `/usr/local/bin/cloudpi-fetch-secrets.sh`,
`/etc/systemd/system/cloudpi-*.service`,
`/home/cloudpiadmin/.docker/config.json`.
**Prompts:** Docker Hub PAT (only if `docker-pat.txt` is missing/empty).

---

#### Step 13 — Wait for containers `healthy`  *(STEP_13)*

**What it does:** Polls `docker ps --filter health=healthy` every 10s for
up to ~10 minutes (60 attempts) until **both** `cloudpi-db` and
`cloudpi-app` report healthy. Every 3rd attempt prints a diagnostic block
(tmpfs contents, fetch-secrets status, container statuses, last 5 lines of
the app log).
**Touches:** Nothing (read-only polling).
**Prompts:** None.

---

#### Step 13b — Verify secrets chain  *(STEP_13B)*

**What it does:** Visible end-to-end proof that what
`cloudpi-fetch-secrets.sh` wrote on the host actually reaches the running
app. Prints three sections:

1. **Host: `/run/secrets-tmp/`** — `ls -la` of the three files
   (`cloudpi.secrets`, `db_password`, `db_root_password`).
2. **Container `cloudpi-app`: `/run/secrets/`** — what the Docker secrets
   bind-mount looks like inside the app (the standard Docker path —
   different from the host on purpose).
3. **Container `cloudpi-app`: secret env-var names** — `env` filtered to
   names starting with `DB_`, `MYSQL_`, `SECRET_KEY`, `CLIENT_`, `REDIS_`,
   `CRYPTO_`, `ENCRYPTION_`, `CREDENTIAL_`, `HMAC_`, `PAR_`, `WORKSPACE_`,
   `FISCAL_`, `REACT_`. **Values are redacted** (replaced with `<set>`).

Then runs two pass/fail checks:
- `$MYSQL_PASSWORD` is non-empty inside the app container → confirms the
  `env_file` channel works. If missing, the step warns and asks whether to
  continue (defaults to no).
- `/run/secrets/cloudpi_secrets` is a non-empty file inside the app
  container → confirms the Compose `secrets:` bind-mount channel works.

**Touches:** Nothing — read-only inspection.
**Prompts:** "Continue anyway?" only if `$MYSQL_PASSWORD` is missing inside
the container.
**Why this matters:** If either delivery channel is broken, login would
fail at step 15 with a confusing HTTP 5xx. Catching it here points the
finger at the secrets pipeline directly, not at the app.

---

#### Step 14 — MySQL app user & privileges  *(STEP_14)*

**What it does:** Pulls the secrets from Secrets Manager again, finds a
working MySQL admin login by trying `root` then `masteradmin` against the
db container, then ensures the `DB_USER` exists with the right password
and grants `ALL PRIVILEGES ON pidb.*` plus `PROCESS, SHOW_ROUTINE,
SYSTEM_USER` (the last one is needed for the migration system to restore
stored routines from backups).
**Touches:** MySQL inside the `cloudpi-db` container.
**Prompts:** None.

---

#### Step 15 — Verify login endpoint  *(STEP_15)*

**What it does:** Curls `https://<host-address>/CPiN/v1/user/login` with
the default `admin@cloudpi.ai / admin123` credentials, retrying up to 15
times × 10s (≈2.5 min) to ride out the Flask warmup. Passes if it gets
HTTP 200.
**Touches:** Nothing (read-only health check).
**Prompts:** None.

---

#### Step 16 — Post-install (optional)  *(always asks; no state marker)*

Two optional actions, each gated on a yes/no prompt:

1. **Reset the `admin@cloudpi.ai` password** — bcrypts a new password using
   the app's own `bcrypt` module inside the container, then `UPDATE user
   SET password=… WHERE email=admin@cloudpi.ai` via the working admin
   login.
2. **Update `CLIENT_DOMAIN` in the database** — runs `UPDATE client SET
   domain=… WHERE id=1`. Use this if the deployed `CLIENT_DOMAIN` in the
   `client` table needs to differ from what was uploaded to Secrets
   Manager.

**Touches:** MySQL inside `cloudpi-db`.
**Prompts:** Yes/no for each action; new password (hidden) or new domain.

---

> **Re-runnability summary:** Every step that writes a marker
> (`STEP_3, 4, 6, 7, 8, 9, 10, 11, 12A, 12B, 12C, 13, 13B, 14, 15`) is
> skipped on the next run with `⚠ Already completed: <label>` and a
> confirmation prompt — press Enter to skip and continue to the next
> pending step. Steps 1, 2, 5, and 16 always run because they are either
> read-only sanity checks (1, 2), idempotent detection (5), or explicitly
> always-ask (16). The overview row for "Containers + secrets chain" uses
> `STEP_13B` as its proxy (so the green check only lights up when both
> halves passed).

---

## Resetting state

To redo from scratch (the AWS resources are untouched — only local
bookkeeping is cleared):

```bash
./deploy_interactive_2.sh
# Choose option 2 — "Reset deployment state and start fresh"
```

Or simply:
```bash
rm .deploy_state_2
```

---

## What happens when there is no public IP

Step 5 never blocks the deploy. The script tries, in order:

1. The value cached in `.deploy_state_2` from a previous run.
2. IMDSv2 `public-ipv4`.
3. IMDSv2 `local-ipv4` (private IP — useful when the instance is behind an ALB/NAT).
4. The first non-loopback address from `hostname -I`.
5. An interactive prompt where you can:
   - Press **Enter** to accept the detected default.
   - Type a different IP/hostname.
   - Type `-` (or just press Enter when nothing was detected) to skip — the
     script falls back to `localhost`.

Whichever value is chosen is then used as the default for `CLIENT_DOMAIN`,
the `.env` `HOST`/`SUBDOMAIN`, the self-signed TLS cert CN, and the URL the
login-verification step (15) curls. If you used `localhost`, step 15 still
works because the curl runs on the same EC2 instance as the container.

You can override later by re-running the script and choosing to re-do step
5 (or step 6 for `CLIENT_DOMAIN` alone).

---

## Troubleshooting

| Symptom | Where to look |
|---|---|
| `STS check failed` at step 2 | The instance has no IAM role, or the role lacks `sts:GetCallerIdentity`. Attach `cloudpi-ec2-role`. |
| `Secrets upload failed` at step 7 | IAM role missing Secrets Manager Put/Create. See `deploy_aws_ec2.py` policy. |
| `cloudpi-fetch-secrets failed` | `sudo journalctl -u cloudpi-fetch-secrets --no-pager -n 50` — usually IAM perms or wrong region. |
| Containers never become healthy | `sudo docker logs cloudpi-app` and `sudo docker logs cloudpi-db`. If the DB volume was initialised with stale passwords, `cd /home/cloudpiadmin/cloudpi && sudo docker compose down -v && sudo docker compose up -d`, then re-run step 14. |
| Login returns non-200 | Wait through the ~2-minute warmup; check `sudo docker logs cloudpi-app` for migration errors. |

---

## What was added in this v2 flow

- `deploy_interactive_2.sh` — the on-EC2 driver.
- Restored the helper scripts the driver calls (they previously existed only
  as `.txt` backups): `setup_aws_secrets.py`,
  `setup_docker_compose_service.py`, `cloudpi-fetch-secrets.sh`, and a
  reference `docker-compose.yml`.
- This `README3.md`.

The original local-PC flow (`deploy_interactive.sh`) is unchanged.
