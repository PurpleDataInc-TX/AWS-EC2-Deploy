# CloudPi AWS EC2 Deployment Runbook

Complete procedure to bring up a new CloudPi environment on AWS EC2 from scratch.

> **Primary method:** Use `deploy_interactive.sh` — it automates every step from EC2 provisioning through first-boot verification in a single guided session. Manual steps are documented in the appendices as reference/fallback only.

---

## Prerequisites

- AWS account with admin access
- Python 3.x on your local machine
- SSH client
- Docker Hub credentials for the `cloudpi1` account

---

## Part 1 — AWS Account Setup (one-time per account)

### 1.1 Create an EC2 Key Pair

The deployment connects to the instance over SSH, so create the key pair first and keep the private key safe.

1. Sign in to AWS Console → **EC2** → **Network & Security** → **Key Pairs** → **Create key pair**
2. Name: `cloudpi-key` (or any name — you reference it during deployment, script step 5)
3. Key pair type: **RSA**
4. Private key file format: **.pem**
5. Click **Create key pair** — your browser downloads `cloudpi-key.pem`

Move the downloaded key into your SSH folder and restrict its permissions (SSH refuses private keys that are readable by others):

```bash
mkdir -p ~/.ssh
mv ~/Downloads/cloudpi-key.pem ~/.ssh/
chmod 400 ~/.ssh/cloudpi-key.pem
```

> **Region must match.** Create the key pair in the same region you deploy into (default `us-east-1`). A key pair only exists in the region it was created in — if the regions differ, provisioning fails with `InvalidKeyPair.NotFound`.

> During deployment, script step 5 detects `~/.ssh/cloudpi-key.pem` automatically. You can also point it at a different `.pem`, import an existing key, or create a new pair from there.

### 1.2 Create an IAM User for deployments

1. Sign in to AWS Console → IAM → Users → **Create user**
2. Username: `cloudpiadmin` (or any name)
3. Attach policy: **AdministratorAccess** (or at minimum: EC2FullAccess + IAMFullAccess + SecretsManagerFullAccess)
4. Click through to **Create user**

### 1.3 Create an Access Key

1. IAM → Users → click your user → **Security credentials** tab
2. Under **Access keys** → **Create access key**
3. Use case: **Command Line Interface (CLI)**
4. Copy and save:
   - **Access Key ID** (e.g. `AKIAXXXXXXXXXXXXXXXXX`)
   - **Secret Access Key** (shown once only)

### 1.4 Install Python dependencies locally

```bash
pip3 install boto3 cryptography
```

### 1.5 Configure AWS credentials in your shell session

```bash
export AWS_ACCESS_KEY_ID=AKIAXXXXXXXXXXXXXXXXX
export AWS_SECRET_ACCESS_KEY=your_secret_key_here
export AWS_DEFAULT_REGION=us-east-1
```

Verify access:
```bash
python3 -c "import boto3; print(boto3.client('sts').get_caller_identity())"
```

---

## Part 2 — Prepare Secrets File

> **⚠ STOP — Request Required Files Before Continuing**
> Before proceeding, contact your CloudPi support person to securely obtain the required **secrets and env sample files** and the **Docker Hub Personal Access Token (`docker-pat.txt`)** to proceed with the installation. These files are **not included in this repository** and contain credentials and settings that must be customized for your organisation. Do not proceed with the deployment until you have received and reviewed all three files.

### 2.1 Edit cloudpi-secrets.json

Fill in the **root** `cloudpi-secrets.json` (in the repository root, next to `deploy_interactive.sh`) with your values. This is the single source of truth — the deployment reads and uploads this file to AWS Secrets Manager (script steps 4, 7, and 9). Do **not** keep a separate copy inside `cloudpi-files/`; secrets are delivered to the instance only through Secrets Manager, never as a file in the app bundle.

```json
{
  "DB_PASSWORD":                 "your_db_password",
  "DB_ROOT_PASSWORD":            "your_db_root_password",
  "DB_NAME":                     "pidb",
  "DB_HOST":                     "cloudpi-db",
  "DB_USER":                     "masteradmin",
  "MYSQL_PASSWORD":              "your_db_password",
  "MYSQL_ROOT_PASSWORD":         "your_db_root_password",
  "MYSQL_DATABASE":              "pidb",
  "MYSQL_USER":                  "masteradmin",
  "SECRET_KEY":                  "64-char-hex-string",
  "REDIS_PASSWORD":              "32-char-hex-string",
  "CRYPTO_SECRET":               "32-char-hex-string (exactly 32 hex chars)",
  "ENCRYPTION_KEY":              "base64-fernet-key=",
  "CREDENTIAL_ENCRYPTION_KEY":   "base64-fernet-key=",
  "HMAC_SECRET_KEY":             "64-char-hex-string",
  "PAR_SECRET_KEY":              "base64-fernet-key=",
  "WORKSPACE_ID":                "uuid-v4",
  "CLIENT_NAME":                 "YourCompanyName",
  "CLIENT_CODE":                 "ABC",
  "CLIENT_DOMAIN":               "your.domain.or.ip",
  "REACT_APP_ORIGIN_URL":        "http://localhost:3000",
  "CLIENT_EMAIL":                "admin@yourcompany.com",
  "CLIENT_CONTACT_NAME":         "Your Name",
  "CLIENT_CONTACT_NUMBER":       "",
  "FISCAL_YEAR":                 "JAN-DEC"
}
```

**Generating secret values:**
```bash
# SECRET_KEY / HMAC_SECRET_KEY (64-char hex)
python3 -c "import secrets; print(secrets.token_hex(32))"

# REDIS_PASSWORD (32-char hex)
python3 -c "import secrets; print(secrets.token_hex(16))"

# CRYPTO_SECRET (exactly 32 hex chars = 16 bytes)
python3 -c "import secrets; print(secrets.token_hex(16))"

# ENCRYPTION_KEY / CREDENTIAL_ENCRYPTION_KEY / PAR_SECRET_KEY (Fernet keys)
python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"

# WORKSPACE_ID (UUID)
python3 -c "import uuid; print(uuid.uuid4())"
```

> **CLIENT_DOMAIN**: You can leave this as a placeholder — the deployment script will prompt you to update it once the EC2 IP is known (Step 7 of the script).

---

## Part 3 — Run the Deployment Script

`deploy_interactive.sh` is the single command that runs the entire deployment. It is re-runnable: completed steps are recorded in `.deploy_state` and skipped unless you choose to re-run them.

```bash
cd /path/to/cloudpi-deploy-aws-py
bash deploy_interactive.sh
```

The script walks through these steps in order:

| Step | What it does |
|------|-------------|
| 1 | Checks local prerequisites (`python3`, `ssh`, `openssl`, `curl`) |
| 2 | Prompts for AWS credentials if not set; asks the **Automation & Recommendations** question. Enabling it grants the instance role extra write/remediation permissions (see [Automation & Recommendations](#automation--recommendations)) |
| 3 | Installs `boto3` + `cryptography` locally |
| 4 | Creates or regenerates `cloudpi-secrets.json` (preserves `CLIENT_*` values) |
| 5 | SSH key pair: uses the default `~/.ssh/cloudpi-key.pem`, a custom name/path, or `none`. Verifies the key exists in AWS and matches your local `.pem` — offering to **import** your `.pem` or **create** a new pair if it's missing |
| 6 | Provisions EC2 (IAM role, security group, t3.large, 30 GB gp3); AWS allocates and associates an Elastic IP — permanent, persists through reboots and stop/start — or accepts an existing IP. Applies the read-only **or** automation IAM policy per the step-2 choice |
| 7 | Updates `CLIENT_DOMAIN` in secrets to the real EC2 IP |
| 8 | Waits for EC2 user-data bootstrap to complete (polls via SSH as `cloudpiadmin`) |
| 9 | Uploads all secrets to AWS Secrets Manager |
| 10a | Asks: (1) fresh install — git clone from GitHub, (2) migration — rsync from an existing server, (3) upload local `cloudpi-files` folder to EC2 |
| 10b | Clones repo, rsyncs from an existing server, or rsyncs from local `cloudpi-files/` → `/home/cloudpiadmin/cloudpi/`; sets `cloudpiadmin` ownership |
| 10c | Options: (1) generate full `docker-compose.yml` from template, (2) update image tags only in existing file (replaces `latest` or any tag with the chosen version), (3) skip |
| 10d | Generates `.env` with `HOST`, `HTTPS`, `SUBDOMAIN`, cert paths and uploads it |
| 10e | TLS certificate — choose **(1) self-signed** for the EC2 IP (default) or **(2) Let's Encrypt** for a domain (trusted cert via `certbot --standalone`; also sets `HOST`/`SUBDOMAIN`/`CLIENT_DOMAIN` to the domain and installs an auto-renewal deploy hook) |
| 10f | Installs `/usr/local/bin/cloudpi-fetch-secrets.sh` |
| 10g | Logs in to Docker Hub (`cloudpi1`) and copies credentials to `cloudpiadmin` |
| 10h | Installs the systemd units (`setup_docker_compose_service.py`), pre-creates `/var/log/pico` (writable by the container's UID 1000), then starts `cloudpi-fetch-secrets` and `cloudpi-docker-compose` |
| 10i | **Reconciles the DB password with the secrets.** The prebuilt `cloudpi-db` image ships a pre-initialized datadir whose `masteradmin` password does not match Secrets Manager; this step probes the app's login and, only if it fails, resets the password via a throwaway `--skip-grant-tables` container. Idempotent (see [DB password / baked-in datadir](#db-password--baked-in-datadir)) |
| 11a | Waits for `cloudpi-db` and `cloudpi-app` to report **healthy**. **Self-healing:** on timeout it inspects the app log and auto-applies the matching fix (log-dir permissions, DB-password reconcile, or secrets re-fetch), then retries — up to 3 repair rounds |
| 11b | Creates/verifies the MySQL `masteradmin` user with required grants |
| 11c | Tests the login endpoint (`/CPiN/v1/user/login`) |
| 12 | Optional: reset admin password, update `CLIENT_DOMAIN` in DB |

### SSH user: always `cloudpiadmin`

All SSH operations in the script connect as `cloudpiadmin`, not `ubuntu`. The EC2 user-data bootstrap creates the `cloudpiadmin` OS user and grants it `sudo` access. Never SSH as `ubuntu` for CloudPi operations.

```bash
# Correct
ssh -i ~/.ssh/cloudpi-key.pem cloudpiadmin@<PUBLIC_IP>

# Wrong — do not use
ssh -i ~/.ssh/cloudpi-key.pem ubuntu@<PUBLIC_IP>
```

### Automation & Recommendations

Step 2 asks whether to enable **Automation & Recommendations** (matches the third checkbox in the CloudPi console onboarding). Your choice controls the IAM permissions attached to the EC2 instance role in step 6:

| Choice | IAM policy | Permissions |
|--------|-----------|-------------|
| **No** (default) | read-only | billing / inventory / CUR-S3 read + Secrets Manager access |
| **Yes** | read-only **+** automation | the above **plus** write/remediation actions |

When enabled, the instance role also gets the `AutomationRemediation` statement (mirrored from `terraform/automation/cloudpi-aws-automation.tf`): start/stop/modify/terminate EC2 & RDS instances, delete volumes/snapshots, release addresses, manage tags, and update Auto Scaling groups.

The choice is threaded through as the `TF_SCRIPT` environment variable; `deploy_aws_ec2.py` reads it (or `AUTOMATION=1`) and appends the write statement. Re-running step 6 with a different choice cleanly adds or removes the automation permissions — the inline policy is overwritten each run, so no stale grants are left behind.

> ⚠ **The automation policy includes destructive actions** (`ec2:TerminateInstances`, `ec2:DeleteVolume`, `ec2:DeleteSnapshot`). Only enable it if CloudPi's remediation features require them, and confirm the action list against your organisation's policy first.

---

## Part 4 — Permissions Reference

### Why permissions matter

Files placed in `/home/cloudpiadmin/cloudpi/` using `sudo` commands are owned by `root` by default. When VS Code Remote SSH or the `cloudpiadmin` user tries to write to them, it fails with `EACCES: permission denied` — even though `cloudpiadmin` owns the home directory.

The deployment script handles this automatically: every `sudo mv` is followed by `sudo chown cloudpiadmin:cloudpiadmin`. The table below documents the required ownership for each path.

### Required ownership per path

| Path | Owner | Group | Mode | Notes |
|------|-------|-------|------|-------|
| `/home/cloudpiadmin/cloudpi/` | `cloudpiadmin` | `cloudpiadmin` | `755` | Directory must not be owned by root |
| `/home/cloudpiadmin/cloudpi/docker-compose.yml` | `cloudpiadmin` | `cloudpiadmin` | `644` | Set by script step 10c |
| `/home/cloudpiadmin/cloudpi/.env` | `cloudpiadmin` | `cloudpiadmin` | `644` | Set by script step 10d |
| `/home/cloudpiadmin/cloudpi/certs/` | `1000` | `1000` | `755` | Container runs as UID 1000 |
| `/home/cloudpiadmin/cloudpi/certs/cert.pem` | `1000` | `1000` | `644` | |
| `/home/cloudpiadmin/cloudpi/certs/privkey.pem` | `1000` | `1000` | `640` | |
| `/home/cloudpiadmin/cloudpi/certs/ca_bundle.pem` | `1000` | `1000` | `644` | |
| `/home/cloudpiadmin/.docker/config.json` | `cloudpiadmin` | `cloudpiadmin` | `600` | Docker Hub credentials |
| `/usr/local/bin/cloudpi-fetch-secrets.sh` | `root` | `root` | `755` | Needs to be executable |

### Fix permissions if they get wrong

If any file in the `cloudpi` directory ends up owned by root (e.g. after a manual `sudo mv` or `sudo rsync`), run this on the EC2 instance:

```bash
sudo chown -R cloudpiadmin:cloudpiadmin /home/cloudpiadmin/cloudpi
```

Then restore cert ownership for the container:

```bash
sudo chown -R 1000:1000 /home/cloudpiadmin/cloudpi/certs
```

### `cloudpiadmin` sudo and passwords

`cloudpiadmin` requires a password for `sudo` by default. To grant passwordless sudo (needed for seamless deployment), SSH as `ubuntu` (the default EC2 admin user) and run:

```bash
echo "cloudpiadmin ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/cloudpiadmin
```

Alternatively, use **AWS Console → EC2 → Connect → Session Manager** (runs as root) to run any privileged command without a password.

---

## Part 5 — What the Script Configures (Detail)

This section documents exactly what each script step writes to EC2. Use this as reference when debugging or making manual changes.

### .env file (script step 10d) A sample file provided

Written to `/home/cloudpiadmin/cloudpi/.env`, owned by `cloudpiadmin`:

```bash
HOST=<PUBLIC_IP>
HTTPS=true
SUBDOMAIN=<PUBLIC_IP>
CERT_PATH=/home/certs/cert.pem
KEY_PATH=/home/certs/privkey.pem
CA_BUNDLE_PATH=/home/certs/ca_bundle.pem
```

> **SUBDOMAIN** must be set to the IP/domain. Without it, the app entrypoint fetches the public IP via an external URL and its output contaminates the value.

> **CERT_PATH** must point to `cert.pem`, not `fullchain.pem`. The entrypoint builds `fullchain.pem` by concatenating `CERT_PATH` + `CA_BUNDLE_PATH` — pointing `CERT_PATH` at `fullchain.pem` causes a self-referential delete loop.

### docker-compose.yml (script step 10c)

See **Appendix A** for the full file. Key points:
- The script prompts for the target release version (e.g. `v1.1.048`) and sets both image tags
- Secrets are read from `/run/secrets-tmp/` (tmpfs, populated by the fetch script on boot)
- The app reads `.env` via `env_file`

### TLS certificates (script step 10e)

Step 10e offers two certificate options:

**Option 1 — Self-signed (default).** For IP-based access. Valid 365 days; browsers show an "untrusted" warning. Equivalent to:

```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /home/cloudpiadmin/cloudpi/certs/privkey.pem \
    -out    /home/cloudpiadmin/cloudpi/certs/cert.pem \
    -subj   "/CN=<PUBLIC_IP>"
sudo cp /home/cloudpiadmin/cloudpi/certs/cert.pem \
        /home/cloudpiadmin/cloudpi/certs/ca_bundle.pem
sudo chown -R 1000:1000 /home/cloudpiadmin/cloudpi/certs
sudo chmod 644 /home/cloudpiadmin/cloudpi/certs/cert.pem
sudo chmod 640 /home/cloudpiadmin/cloudpi/certs/privkey.pem
sudo chmod 644 /home/cloudpiadmin/cloudpi/certs/ca_bundle.pem
```

**Option 2 — Let's Encrypt (trusted cert for a domain).** Requires a domain whose **A record points to the EC2 Elastic IP**. The step prompts for the domain + a renewal-notice email, then:

1. Runs `certbot certonly --standalone -d <domain>` (uses port 80 for the ACME HTTP-01 challenge — free at this point since the app starts in step 10h; the security group already allows 80).
2. Installs the issued cert into `certs/` with the app's expected mapping: `cert.pem` = leaf, `ca_bundle.pem` = LE `chain.pem`, `privkey.pem` = LE `privkey.pem`.
3. Sets `HOST`/`SUBDOMAIN` in `.env` and `CLIENT_DOMAIN` in Secrets Manager (and the local secrets file) to the domain, so the app serves on the name the cert was issued for.
4. Installs a certbot **deploy hook** (`/etc/letsencrypt/renewal-hooks/deploy/cloudpi-cert.sh`) that re-copies the renewed cert into `certs/` and restarts the app — so the 90-day auto-renewal is fully handled.

```bash
# Manual equivalent (what step 10e automates)
sudo certbot certonly --standalone --agree-tos -m you@example.com -d cloudpi.example.com
LE=/etc/letsencrypt/live/cloudpi.example.com
sudo cp "$LE/cert.pem"    /home/cloudpiadmin/cloudpi/certs/cert.pem
sudo cp "$LE/chain.pem"   /home/cloudpiadmin/cloudpi/certs/ca_bundle.pem
sudo cp "$LE/privkey.pem" /home/cloudpiadmin/cloudpi/certs/privkey.pem
sudo chown -R 1000:1000 /home/cloudpiadmin/cloudpi/certs
```

> The domain's A record must resolve to the Elastic IP **before** running this step, or Let's Encrypt's HTTP validation fails. The script does a best-effort `dig` check and warns on mismatch.

### Secrets fetch script (script step 10f)

Installed as `/usr/local/bin/cloudpi-fetch-secrets.sh` (owned root, mode 755). Run by the `cloudpi-fetch-secrets` systemd unit on every boot before the Docker Compose service starts. It pulls from AWS Secrets Manager using the EC2 instance's IAM role (no credentials needed on the instance).

### MySQL user (script step 11b)

```sql
CREATE USER IF NOT EXISTS 'masteradmin'@'%' IDENTIFIED BY '<db_password>';
GRANT ALL PRIVILEGES ON pidb.* TO 'masteradmin'@'%';
GRANT PROCESS, SHOW_ROUTINE, SYSTEM_USER ON *.* TO 'masteradmin'@'%';
FLUSH PRIVILEGES;
```

> `SYSTEM_USER` is required so the migration system can restore backups containing stored functions/procedures created by root.

---

## Part 6 — Post-Install Steps

### 6.1 Reset the default admin password

The script (step 12) offers to do this interactively. To do it manually:

```bash
# Generate bcrypt hash inside the container
sudo docker exec cloudpi-app node -e \
  "const bcrypt = require('bcrypt'); bcrypt.hash('your_new_password', 10).then(h => console.log(h));"

# Update in MySQL
_db_pwd=$(aws secretsmanager get-secret-value --region us-east-1 \
  --secret-id cloudpi-secrets --query SecretString --output text \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['MYSQL_PASSWORD'])")

sudo docker exec -e "MYSQL_PWD=${_db_pwd}" cloudpi-db \
  mysql -u masteradmin pidb -e \
  "UPDATE user SET password='<bcrypt_hash>' WHERE email='admin@cloudpi.ai';"
```

### 6.2 Update CLIENT_DOMAIN in the database

```bash
_db_pwd=$(aws secretsmanager get-secret-value --region us-east-1 \
  --secret-id cloudpi-secrets --query SecretString --output text \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['MYSQL_PASSWORD'])")

sudo docker exec -e "MYSQL_PWD=${_db_pwd}" cloudpi-db \
  mysql -u masteradmin pidb -e "UPDATE client SET domain='your.domain.or.ip' WHERE id=1;"
```

### 6.3 Verify login

```bash
curl -sk https://<PUBLIC_IP>/CPiN/v1/user/login \
  -X POST -H 'Content-Type: application/json' \
  -d '{"email":"admin@cloudpi.ai","password":"admin123"}'
```

Expected response: HTTP 200 with a JWT token.

---

## Part 7 — Upgrading to a New Release

### 7.1 Update image tags in docker-compose.yml

**Recommended:** Re-run `deploy_interactive.sh`, re-run step 10c, and choose **option 2 — update image tags only**. Enter the new version (e.g. `v1.1.048`). The script replaces both image tags in the existing file without touching anything else.

Or manually with nano:
```bash
sudo nano /home/cloudpiadmin/cloudpi/docker-compose.yml
# Update both image tags to the new version, e.g. Cloudpi_v1.1.048
```

### 7.2 Pull new images and restart

```bash
cd /home/cloudpiadmin/cloudpi
sudo -u cloudpi1 docker compose pull
sudo systemctl restart cloudpi-docker-compose
```

### 7.3 Monitor migration

```bash
sudo docker logs -f cloudpi-app
```

If migration fails and the container enters lockout:

1. Identify the failure in logs
2. Fix the root cause in MySQL (see Troubleshooting below)
3. Clear lockout: `sudo docker exec cloudpi-app rm /app/backups/.migration_lockout`
4. Restart: `sudo docker restart cloudpi-app`

---

## Troubleshooting

### Provisioning fails: `InvalidKeyPair.NotFound`

The key pair named in step 5 does not exist in AWS in the deploy region. Either create it in the AWS console (see [1.1 Create an EC2 Key Pair](#11-create-an-ec2-key-pair)) in the **same region** you deploy into, or let script step 5 **import** your local `.pem` / **create** a new pair when it prompts. Confirm it exists:

```bash
aws ec2 describe-key-pairs --key-names cloudpi-key --region us-east-1
```

### Provisioning fails: `UnauthorizedOperation` on `ec2:DescribeKeyPairs`

The deploying IAM user lacks `ec2:DescribeKeyPairs`. The script warns and continues (the later `RunInstances` still validates the key), but to enable the pre-flight check, add the permission:

```bash
aws iam put-user-policy --user-name <your-iam-user> \
  --policy-name EC2DescribeKeyPairs \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"ec2:DescribeKeyPairs","Resource":"*"}]}'
```

### DB password / baked-in datadir

**Symptom:** `cloudpi-app` never becomes healthy; its log loops on `Waiting for MySQL database to be ready...` then `MySQL connection failed` / `Access denied for user 'masteradmin'`. Meanwhile `cloudpi-db` reports **healthy** (its `mysqladmin ping` doesn't authenticate).

**Cause:** The prebuilt `cloudpi-db` image ships a **pre-initialized MySQL datadir**. Because `/var/lib/mysql` is already populated, MySQL **ignores** the `MYSQL_*` env vars on first boot, so `masteradmin@'%'` keeps the password baked into the image — not the one in your secrets.

**Fix:** Script **step 10i** does this automatically (and step 11a's self-repair will trigger it). To do it manually — reset the password to match your secrets via a throwaway `--skip-grant-tables` container:

```bash
cd /home/cloudpiadmin/cloudpi
DB_PW=$(/usr/local/bin/aws secretsmanager get-secret-value --region us-east-1 \
  --secret-id cloudpi-secrets --query SecretString --output text \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['MYSQL_PASSWORD'])")
VOL=$(sudo docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/mysql"}}{{.Name}}{{end}}{{end}}' cloudpi-db)
IMG=$(sudo docker inspect -f '{{.Config.Image}}' cloudpi-db)

sudo docker compose stop db
sudo docker run --rm -d --name mysql-reset -v "$VOL":/var/lib/mysql \
  --user mysql --entrypoint mysqld "$IMG" --skip-grant-tables --skip-networking
sleep 8
sudo docker exec mysql-reset mysql -e "FLUSH PRIVILEGES;
  ALTER USER IF EXISTS 'masteradmin'@'%'         IDENTIFIED BY '${DB_PW}';
  ALTER USER IF EXISTS 'masteradmin'@'localhost' IDENTIFIED BY '${DB_PW}';
  FLUSH PRIVILEGES;"
sudo docker stop mysql-reset
sudo docker compose up -d
```

> ⚠ Do **not** run `docker compose down -v` to "fix" this — the `-v` deletes the volume and re-copies the same baked datadir, undoing any reset. The DB password reset survives a normal `down`/`up` because the named volume is preserved.

### App crash-loops: `PermissionError: /var/log/pico/app.log`

**Cause:** The app (Flask, UID 1000 in-container) writes its log to `/var/log/pico`, bind-mounted from the host. If the host directory is missing or owned by root, UID 1000 can't write and Flask crash-loops.

**Fix:** Script **step 10h** creates it automatically. To fix manually on the instance:

```bash
sudo mkdir -p /var/log/pico
sudo chown -R 1000:syslog /var/log/pico   # if the 'syslog' group is missing, use 1000:1000
sudo chmod 2750 /var/log/pico
cd /home/cloudpiadmin/cloudpi && sudo docker compose restart app
```

### Permission denied writing files in /home/cloudpiadmin/cloudpi/

**Symptom:** VS Code Remote SSH shows `EACCES: permission denied` when saving files. Or `cloudpiadmin` can't write files to the `cloudpi` directory.

**Cause:** The directory (or files inside it) are owned by `root`, typically because they were placed there with a `sudo` command without fixing ownership afterwards.

**Check:**
```bash
stat /home/cloudpiadmin/cloudpi
# Look for: Uid: ( 0/ root)
```

**Fix:**
```bash
sudo chown -R cloudpiadmin:cloudpiadmin /home/cloudpiadmin/cloudpi
# Restore cert ownership for the container after:
sudo chown -R 1000:1000 /home/cloudpiadmin/cloudpi/certs
```

### sudo asks for a password for cloudpiadmin

`cloudpiadmin` is not configured for passwordless sudo by default. SSH as `ubuntu` and run:

```bash
echo "cloudpiadmin ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/cloudpiadmin
```

Or use **AWS Console → EC2 → Connect → Session Manager** to run privileged commands as root without any password.

### Migration fails: "Unknown column 'v.schedule_instance_id'"

Migration `V1_171` expects `vm_optimization_config` to have a `schedule_instance_id` column (added by v1.58), but the table was recreated from its v1.46 state (with only `schedule_id`). Fix: mark the intermediate migrations as needing re-run.

```sql
UPDATE schema_version SET success=0 WHERE id=19;  -- v1.48 (adds additional_config)
UPDATE schema_version SET success=0 WHERE id=29;  -- v1.58 (renames to schedule_instance_id)
```

Then clear lockout and restart.

### Migration fails: "Access denied; you need SYSTEM_USER privilege"

The backup restore fails because stored functions in the dump require `SYSTEM_USER` to drop. Grant it:

```sql
GRANT SYSTEM_USER ON *.* TO 'masteradmin'@'%';
FLUSH PRIVILEGES;
```

### Migration fails: "Table 'pidb.cost_tags' doesn't exist"

The `cost_tags` materialized table was lost during a failed restore. Recreate it:

```sql
CREATE TABLE IF NOT EXISTS cost_tags (
    project_id INT DEFAULT NULL,
    key_name   VARCHAR(255) NOT NULL,
    tag_value  VARCHAR(500) DEFAULT NULL,
    INDEX idx_cost_tags_project_key (project_id, key_name),
    INDEX idx_cost_tags_key (key_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

Then clear lockout and restart.

### Backup restore fails silently

Check that `cloudpiadmin` has `SYSTEM_USER` privilege (see above). This is the most common cause of "mysql restore command failed" errors.

### Login returns 404

In v1.1.042+, the API moved from `/v1/` to `/CPiN/v1/`. Use:
```
POST https://<IP>/CPiN/v1/user/login
```

### Docker images fail to pull ("access denied")

Log in to Docker Hub with credentials for the `cloudpi1` account:
```bash
sudo docker login -u cloudpi1
```

---

## Appendix A — docker-compose.yml

```yaml
version: "3.8"

secrets:
  cloudpi_secrets:
    file: /run/secrets-tmp/cloudpi.secrets
  db_password:
    file: /run/secrets-tmp/db_password
  db_root_password:
    file: /run/secrets-tmp/db_root_password

services:
  db:
    image: cloudpi1/cloudpi:Cloudpi_db_v1.1.048
    container_name: cloudpi-db
    restart: unless-stopped
    environment:
      MYSQL_DATABASE: pidb
      MYSQL_USER: masteradmin
    secrets:
      - db_password
      - db_root_password
    volumes:
      - cloudpi_db_data:/var/lib/mysql
    networks:
      - cloudpi_network
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root",
             "--password=$$MYSQL_ROOT_PASSWORD"]
      interval: 10s
      timeout: 5s
      retries: 5

  app:
    image: cloudpi1/cloudpi:Cloudpi_v1.1.048
    container_name: cloudpi-app
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    env_file:
      - .env
    secrets:
      - cloudpi_secrets
    volumes:
      - ./certs:/home/certs
      - cloudpi_backups:/app/backups
    ports:
      - "80:80"
      - "443:443"
    networks:
      - cloudpi_network
    healthcheck:
      test: ["CMD", "curl", "-fsk", "https://localhost/"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s

volumes:
  cloudpi_db_data:
  cloudpi_backups:

networks:
  cloudpi_network:
    driver: bridge
```

---

## Appendix B — Key File Locations on EC2

| File | Purpose |
|------|---------|
| `/home/cloudpiadmin/cloudpi/docker-compose.yml` | Container definitions (owned by `cloudpiadmin`) |
| `/home/cloudpiadmin/cloudpi/.env` | App environment: HOST, HTTPS, cert paths (owned by `cloudpiadmin`) |
| `/home/cloudpiadmin/cloudpi/certs/` | TLS certificates (owned by UID 1000 for container access) |
| `/home/cloudpiadmin/.docker/config.json` | Docker Hub credentials (owned by `cloudpiadmin`) |
| `/run/secrets-tmp/cloudpi.secrets` | Runtime secrets (tmpfs, cleared on reboot) |
| `/run/secrets-tmp/db_password` | DB password file for container |
| `/run/secrets-tmp/db_root_password` | DB root password file for container |
| `/usr/local/bin/cloudpi-fetch-secrets.sh` | Secrets fetch script (owned root, mode 755) |
| `/etc/systemd/system/cloudpi-fetch-secrets.service` | Systemd unit: fetch secrets on boot |
| `/etc/systemd/system/cloudpi-docker-compose.service` | Systemd unit: start containers |
| `/var/log/pico/` | App JSON logs (bind-mounted into the container; owned UID `1000`, mode `2750`) |
| `/var/log/cloudpi-bootstrap.log` | EC2 user-data bootstrap log |
| `/var/log/cloudpi-bootstrap-done` | Marker file created when bootstrap completes |

---

## Appendix C — Useful Commands

```bash
# Container status
sudo docker ps

# App logs (live)
sudo docker logs -f cloudpi-app

# DB shell
sudo docker exec -it cloudpi-db mysql -u masteradmin -p

# Restart app only
sudo docker restart cloudpi-app

# Restart via systemd (also re-fetches secrets)
sudo systemctl restart cloudpi-fetch-secrets
sudo systemctl restart cloudpi-docker-compose

# Check migration state
sudo docker exec cloudpi-db mysql -u masteradmin -p pidb -e \
  "SELECT version_number, success FROM schema_version ORDER BY id DESC LIMIT 10;"

# Clear migration lockout
sudo docker exec cloudpi-app rm /app/backups/.migration_lockout

# Test login (replace IP)
curl -sk https://<PUBLIC_IP>/CPiN/v1/user/login \
  -X POST -H 'Content-Type: application/json' \
  -d '{"email":"admin@cloudpi.ai","password":"admin123"}'

# Fix ownership if cloudpi directory ends up owned by root
sudo chown -R cloudpiadmin:cloudpiadmin /home/cloudpiadmin/cloudpi
sudo chown -R 1000:1000 /home/cloudpiadmin/cloudpi/certs

# Grant cloudpiadmin passwordless sudo (run as ubuntu)
echo "cloudpiadmin ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/cloudpiadmin
```
