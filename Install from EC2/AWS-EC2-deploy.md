# CloudPi AWS EC2 — Manual Deployment Runbook (No Local Access Keys)

This guide deploys CloudPi entirely through the **AWS Console and SSH commands on the EC2 itself** — no local AWS access keys, no Python scripts, no boto3 needed on your machine.

> Use this guide when you cannot obtain AWS programmatic access keys but do have AWS Console login and SSH access to the EC2.

---

## Prerequisites

- AWS Console login (IAM user with console access — no access keys required)
- SSH client on your local machine
- Python 3 on your local machine (for generating secret values in Part 2)
- Docker Hub credentials for the `cloudpi1` account
- The `cloudpi-secrets.json` file filled in with your values (see Part 2)

---

## Part 1 — AWS Console: Create IAM Role for EC2

The EC2 instance needs its own IAM role so it can read secrets from AWS Secrets Manager — no access keys needed on the instance, it uses the role automatically.

### 1.1 Create the IAM Role

1. Go to **AWS Console → IAM → Roles → Create role**
2. Trusted entity type: **AWS service**
3. Use case: **EC2** → click Next
4. Search for and attach: **SecretsManagerReadWrite**
5. Role name: `cloudpi-ec2-role`
6. Click **Create role**

---

## Part 2 — Prepare Your Secrets

> **STOP — Request Required Files Before Continuing**
> Contact your CloudPi support person to securely obtain `cloudpi-secrets.json`, the `.env` sample file, and the Docker Hub Personal Access Token (`docker-pat.txt`). Do not proceed until you have all three.

### 2.1 Fill in cloudpi-secrets.json

Create `cloudpi-secrets.json` on your local machine with your values:

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
  "CRYPTO_SECRET":               "32-char-hex-string",
  "ENCRYPTION_KEY":              "base64-fernet-key=",
  "CREDENTIAL_ENCRYPTION_KEY":   "base64-fernet-key=",
  "HMAC_SECRET_KEY":             "64-char-hex-string",
  "PAR_SECRET_KEY":              "base64-fernet-key=",
  "WORKSPACE_ID":                "uuid-v4",
  "CLIENT_NAME":                 "YourCompanyName",
  "CLIENT_CODE":                 "ABC",
  "CLIENT_DOMAIN":               "YOUR_EC2_PUBLIC_IP",
  "REACT_APP_ORIGIN_URL":        "http://localhost:3000",
  "CLIENT_EMAIL":                "admin@yourcompany.com",
  "CLIENT_CONTACT_NAME":         "Your Name",
  "CLIENT_CONTACT_NUMBER":       "",
  "FISCAL_YEAR":                 "JAN-DEC"
}
```

**Generating secret values** (run these on any machine with Python 3):

```bash
# Install cryptography package first (needed for Fernet key generation only)
pip3 install cryptography

# SECRET_KEY / HMAC_SECRET_KEY (64-char hex)
python3 -c "import secrets; print(secrets.token_hex(32))"

# REDIS_PASSWORD (32-char hex)
python3 -c "import secrets; print(secrets.token_hex(16))"

# CRYPTO_SECRET (32 hex chars)
python3 -c "import secrets; print(secrets.token_hex(16))"

# ENCRYPTION_KEY / CREDENTIAL_ENCRYPTION_KEY / PAR_SECRET_KEY (Fernet keys)
python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"

# WORKSPACE_ID (UUID)
python3 -c "import uuid; print(uuid.uuid4())"
```

### 2.2 Create Secret in AWS Secrets Manager (via Console)

1. Go to **AWS Console → Secrets Manager → Store a new secret**
2. Secret type: **Other type of secret**
3. Key/value pairs: switch to **Plaintext** tab and paste the entire JSON from `cloudpi-secrets.json`
4. Click Next
5. Secret name: `cloudpi-secrets`
6. Click Next → Next → **Store**

> You will update `CLIENT_DOMAIN` in the secret later once you know the EC2 IP (Part 3.4).

---

## Part 3 — AWS Console: Launch EC2 Instance

### 3.1 Launch the instance

1. Go to **AWS Console → EC2 → Launch Instance**
2. Name: `cloudpi`
3. AMI: **Ubuntu Server 22.04 LTS (64-bit x86)**
4. Instance type: **t3.large**
5. Key pair: Create new or select existing → save the `.pem` file as `cloudpi-key.pem`
6. Network settings:
   - Click **Edit**
   - Create or select a security group
   - Add inbound rules:
     | Type | Port | Source |
     |------|------|--------|
     | SSH | 22 | My IP (or 0.0.0.0/0) |
     | HTTP | 80 | 0.0.0.0/0 |
     | HTTPS | 443 | 0.0.0.0/0 |
7. Storage: change to **30 GB, gp3**
8. Advanced details → **IAM instance profile**: select `cloudpi-ec2-role`
9. Advanced details → **User data**: paste the block below (creates the `cloudpiadmin` OS user automatically on first boot)

```bash
#!/bin/bash
set -e
adduser --disabled-password --gecos "" cloudpiadmin
usermod -aG sudo cloudpiadmin
mkdir -p /home/cloudpiadmin/.ssh
cp /home/ubuntu/.ssh/authorized_keys /home/cloudpiadmin/.ssh/authorized_keys
chown -R cloudpiadmin:cloudpiadmin /home/cloudpiadmin/.ssh
chmod 700 /home/cloudpiadmin/.ssh
chmod 600 /home/cloudpiadmin/.ssh/authorized_keys
echo "cloudpiadmin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/cloudpiadmin
touch /var/log/cloudpi-bootstrap-done
```

10. Click **Launch instance**

### 3.2 Allocate and attach an Elastic IP

1. Go to **EC2 → Network & Security → Elastic IPs → Allocate Elastic IP address** → Allocate
2. Select the new Elastic IP → **Actions → Associate Elastic IP address**
3. Select your `cloudpi` instance → Associate
4. Note the public IP — this is your `<PUBLIC_IP>`

### 3.3 Set SSH key permissions (local machine)

```bash
chmod 400 /path/to/cloudpi-key.pem
```

### 3.4 Update CLIENT_DOMAIN in Secrets Manager

Now that you have the public IP, update the secret:

1. Go to **AWS Console → Secrets Manager → cloudpi-secrets → Retrieve secret value → Edit**
2. Change `CLIENT_DOMAIN` from `YOUR_EC2_PUBLIC_IP` to the actual IP
3. Click **Save**

---

## Part 4 — SSH into EC2 and Install Docker

Wait 2–3 minutes for the instance to finish booting, then SSH in:

```bash
ssh -i /path/to/cloudpi-key.pem cloudpiadmin@<PUBLIC_IP>
```

> If `cloudpiadmin` doesn't work yet (user-data still running), SSH as `ubuntu` first and wait:
> ```bash
> ssh -i /path/to/cloudpi-key.pem ubuntu@<PUBLIC_IP>
> # Wait until this file exists:
> ls /var/log/cloudpi-bootstrap-done
> # Then switch to cloudpiadmin
> ```

### 4.1 Install Docker Engine

Run these on the EC2 as `cloudpiadmin`:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) \
  signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker cloudpiadmin
```

Log out and back in for the group change to take effect:

```bash
exit
ssh -i /path/to/cloudpi-key.pem cloudpiadmin@<PUBLIC_IP>
```

Verify:

```bash
docker --version
docker compose version
```

---

## Part 5 — Create CloudPi Directory Structure on EC2

```bash
mkdir -p /home/cloudpiadmin/cloudpi/certs
```

---

## Part 6 — Upload CloudPi Application Files to EC2

Choose one of the three options below depending on where your application files are:

### Option A — Fresh install: clone from GitHub (recommended)

On the EC2:

```bash
sudo apt-get install -y git
cd /home/cloudpiadmin
git clone https://github.com/YOUR_ORG/cloudpi.git cloudpi-repo
cp -r cloudpi-repo/* /home/cloudpiadmin/cloudpi/
```

> Replace the GitHub URL with the actual CloudPi repo URL provided by your support contact.
> If the repo is private, you will be prompted for GitHub credentials. Use a GitHub Personal Access Token as the password.

### Option B — Upload a local `cloudpi-files` folder from your machine

From your **local machine**, rsync the folder to EC2:

```bash
rsync -avz -e "ssh -i /path/to/cloudpi-key.pem" \
    /path/to/cloudpi-files/ \
    cloudpiadmin@<PUBLIC_IP>:/home/cloudpiadmin/cloudpi/
```

### Option C — Migrate from an Azure instance

From your **local machine**:

```bash
rsync -avz -e "ssh -i /path/to/azure-key.pem" \
    azureuser@<AZURE_IP>:/home/azureuser/cloudpi/ \
    /tmp/cloudpi-files/

rsync -avz -e "ssh -i /path/to/cloudpi-key.pem" \
    /tmp/cloudpi-files/ \
    cloudpiadmin@<PUBLIC_IP>:/home/cloudpiadmin/cloudpi/
```

After any option, fix ownership on the EC2:

```bash
sudo chown -R cloudpiadmin:cloudpiadmin /home/cloudpiadmin/cloudpi
```

---

## Part 7 — Upload docker-compose.yml to EC2

Run this from your **local machine** in the repo folder. This overwrites any docker-compose.yml that may have been copied in Part 6, ensuring the correct version is used:

```bash
scp -i /path/to/cloudpi-key.pem docker-compose.yml.txt \
    cloudpiadmin@<PUBLIC_IP>:/home/cloudpiadmin/cloudpi/docker-compose.yml
```

> To use a different release version, edit the image tags in `docker-compose.yml.txt` before uploading, replacing `Cloudpi_db_v1.1.042` and `Cloudpi_v1.1.042` with your target version (e.g. `Cloudpi_db_v1.1.044` and `Cloudpi_v1.1.044`).

---

## Part 8 — Upload .env File to EC2

Edit the `.env` file in this repo folder on your local machine — set `HOST` and `SUBDOMAIN` to your EC2 public IP:

```
HOST=<PUBLIC_IP>
HTTPS=true
SUBDOMAIN=<PUBLIC_IP>
CERT_PATH=/home/certs/cert.pem
KEY_PATH=/home/certs/privkey.pem
CA_BUNDLE_PATH=/home/certs/ca_bundle.pem
```

> **SUBDOMAIN** must be set to the IP/domain. Without it, the app entrypoint fetches the public IP via an external URL and its output contaminates the value.

> **CERT_PATH** must point to `cert.pem`, not `fullchain.pem`. The entrypoint builds `fullchain.pem` by concatenating `CERT_PATH` + `CA_BUNDLE_PATH` — pointing `CERT_PATH` at `fullchain.pem` causes a self-referential delete loop.

Then upload it:

```bash
scp -i /path/to/cloudpi-key.pem .env \
    cloudpiadmin@<PUBLIC_IP>:/home/cloudpiadmin/cloudpi/.env
```

---

## Part 9 — Generate TLS Certificates on EC2

Replace `<PUBLIC_IP>` with your actual EC2 public IP:

```bash
PUBLIC_IP=<PUBLIC_IP>

sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /home/cloudpiadmin/cloudpi/certs/privkey.pem \
    -out    /home/cloudpiadmin/cloudpi/certs/cert.pem \
    -subj   "/CN=${PUBLIC_IP}"

sudo cp /home/cloudpiadmin/cloudpi/certs/cert.pem \
        /home/cloudpiadmin/cloudpi/certs/ca_bundle.pem

sudo chown -R 1000:1000 /home/cloudpiadmin/cloudpi/certs
sudo chmod 644 /home/cloudpiadmin/cloudpi/certs/cert.pem
sudo chmod 640 /home/cloudpiadmin/cloudpi/certs/privkey.pem
sudo chmod 644 /home/cloudpiadmin/cloudpi/certs/ca_bundle.pem
```

---

## Part 10 — Upload and Install the Secrets Fetch Script on EC2

Run this from your **local machine** in the repo folder:

```bash
scp -i /path/to/cloudpi-key.pem cloudpi-fetch-secrets.sh.txt \
    cloudpiadmin@<PUBLIC_IP>:/home/cloudpiadmin/cloudpi-fetch-secrets.sh
```

Then on the EC2, install it to the correct location:

```bash
sudo cp /home/cloudpiadmin/cloudpi-fetch-secrets.sh /usr/local/bin/cloudpi-fetch-secrets.sh
sudo chmod 755 /usr/local/bin/cloudpi-fetch-secrets.sh
sudo chown root:root /usr/local/bin/cloudpi-fetch-secrets.sh
```

Install the AWS CLI v2 (needed by the fetch script — must be v2 so it installs to `/usr/local/bin/aws`):

```bash
sudo apt-get install -y unzip curl
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
aws --version
```

Test the fetch script manually:

```bash
sudo /usr/local/bin/cloudpi-fetch-secrets.sh
```

Expected output: `Secrets fetched successfully.`

---

## Part 11 — Docker Hub Login

Log in as cloudpiadmin so the Docker daemon can pull private images:

```bash
docker login -u cloudpi1
# Enter the Docker Hub Personal Access Token when prompted (not the account password)
```

---

## Part 12 — Fix Ownership

Run this before installing the systemd services, so containers start with correct permissions:

```bash
sudo chown -R cloudpiadmin:cloudpiadmin /home/cloudpiadmin/cloudpi
sudo chown -R 1000:1000 /home/cloudpiadmin/cloudpi/certs
```

### Required ownership reference

| Path | Owner | Group | Mode | Notes |
|------|-------|-------|------|-------|
| `/home/cloudpiadmin/cloudpi/` | `cloudpiadmin` | `cloudpiadmin` | `755` | Must not be owned by root |
| `/home/cloudpiadmin/cloudpi/docker-compose.yml` | `cloudpiadmin` | `cloudpiadmin` | `644` | |
| `/home/cloudpiadmin/cloudpi/.env` | `cloudpiadmin` | `cloudpiadmin` | `644` | |
| `/home/cloudpiadmin/cloudpi/certs/` | `1000` | `1000` | `755` | Container runs as UID 1000 |
| `/home/cloudpiadmin/cloudpi/certs/cert.pem` | `1000` | `1000` | `644` | |
| `/home/cloudpiadmin/cloudpi/certs/privkey.pem` | `1000` | `1000` | `640` | |
| `/home/cloudpiadmin/cloudpi/certs/ca_bundle.pem` | `1000` | `1000` | `644` | |
| `/home/cloudpiadmin/.docker/config.json` | `cloudpiadmin` | `cloudpiadmin` | `600` | Docker Hub credentials |
| `/usr/local/bin/cloudpi-fetch-secrets.sh` | `root` | `root` | `755` | Must be executable by root |

---

## Part 13 — Install Systemd Services

Upload `setup_docker_compose_service.py.txt` from this repo to the EC2, then run it.

**From your local machine:**

```bash
scp -i /path/to/cloudpi-key.pem setup_docker_compose_service.py.txt \
    cloudpiadmin@<PUBLIC_IP>:/home/cloudpiadmin/setup_docker_compose_service.py
```

**On the EC2:**

```bash
sudo python3 /home/cloudpiadmin/setup_docker_compose_service.py
```

This installs and starts two systemd units:
- `cloudpi-fetch-secrets` — fetches secrets from Secrets Manager into tmpfs on boot
- `cloudpi-docker-compose` — starts DB + App containers

---

## Part 14 — Verify Containers Are Running

```bash
sudo docker ps
```

Wait 2–3 minutes for the database to initialize, then check the app:

```bash
sudo docker logs cloudpi-app --tail 50
```

---

## Part 15 — Create MySQL User

Once `cloudpi-db` shows as healthy (`sudo docker ps`), run:

```bash
DB_ROOT_PWD=$(cat /run/secrets-tmp/db_root_password)

sudo docker exec -e "MYSQL_PWD=${DB_ROOT_PWD}" cloudpi-db mysql -u root << 'EOSQL'
CREATE USER IF NOT EXISTS 'masteradmin'@'%' IDENTIFIED BY 'REPLACE_WITH_DB_PASSWORD';
GRANT ALL PRIVILEGES ON pidb.* TO 'masteradmin'@'%';
GRANT PROCESS, SHOW_ROUTINE, SYSTEM_USER ON *.* TO 'masteradmin'@'%';
FLUSH PRIVILEGES;
EOSQL
```

> Replace `REPLACE_WITH_DB_PASSWORD` with the `DB_PASSWORD` value from your secrets file.

Or use the fetched secret directly:

```bash
DB_ROOT_PWD=$(cat /run/secrets-tmp/db_root_password)
DB_PWD=$(cat /run/secrets-tmp/db_password)

sudo docker exec -e "MYSQL_PWD=${DB_ROOT_PWD}" cloudpi-db mysql -u root -e "
  CREATE USER IF NOT EXISTS 'masteradmin'@'%' IDENTIFIED BY '${DB_PWD}';
  GRANT ALL PRIVILEGES ON pidb.* TO 'masteradmin'@'%';
  GRANT PROCESS, SHOW_ROUTINE, SYSTEM_USER ON *.* TO 'masteradmin'@'%';
  FLUSH PRIVILEGES;
"
```

> `SYSTEM_USER` is required so the migration system can restore backups containing stored functions/procedures created by root.

---

## Part 16 — Verify Login

```bash
curl -sk https://<PUBLIC_IP>/CPiN/v1/user/login \
  -X POST -H 'Content-Type: application/json' \
  -d '{"email":"admin@cloudpi.ai","password":"admin123"}'
```

Expected: HTTP 200 with a JWT token in the response.

---

## Part 17 — Post-Install: Reset Admin Password

To reset the default admin password on the EC2:

```bash
# Generate bcrypt hash inside the container
sudo docker exec cloudpi-app node -e \
  "const bcrypt = require('bcrypt'); bcrypt.hash('your_new_password', 10).then(h => console.log(h));"
```

Copy the output hash, then update it in MySQL:

```bash
DB_PWD=$(cat /run/secrets-tmp/db_password)

sudo docker exec -e "MYSQL_PWD=${DB_PWD}" cloudpi-db \
  mysql -u masteradmin pidb -e \
  "UPDATE user SET password='PASTE_BCRYPT_HASH_HERE' WHERE email='admin@cloudpi.ai';"
```

---

## Part 18 — Post-Install: Update CLIENT_DOMAIN in Database

If `CLIENT_DOMAIN` in the database needs to match the EC2 IP:

```bash
DB_PWD=$(cat /run/secrets-tmp/db_password)

sudo docker exec -e "MYSQL_PWD=${DB_PWD}" cloudpi-db \
  mysql -u masteradmin pidb -e \
  "UPDATE client SET domain='<PUBLIC_IP>' WHERE id=1;"
```

---

## Troubleshooting

### Permission denied writing files in /home/cloudpiadmin/cloudpi/

Files placed with `sudo` are owned by root. Check:

```bash
stat /home/cloudpiadmin/cloudpi
# Look for: Uid: ( 0/ root)  — that means root owns it
```

Fix:

```bash
sudo chown -R cloudpiadmin:cloudpiadmin /home/cloudpiadmin/cloudpi
sudo chown -R 1000:1000 /home/cloudpiadmin/cloudpi/certs
```

### sudo asks for a password for cloudpiadmin

The user-data bootstrap sets up NOPASSWD automatically. If you're on an EC2 where this didn't run, SSH as `ubuntu` and run:

```bash
echo "cloudpiadmin ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/cloudpiadmin
```

Alternatively, use **AWS Console → EC2 → Connect → Session Manager** to run privileged commands as root without any SSH or password.

### Docker images fail to pull ("access denied" or "connection refused")

```bash
# Re-login to Docker Hub
docker login -u cloudpi1
```

If the EC2 cannot reach Docker Hub at all, check outbound port 443 in the EC2 security group and network ACLs.

### Migration fails: "Unknown column 'v.schedule_instance_id'"

```bash
DB_PWD=$(cat /run/secrets-tmp/db_password)
sudo docker exec -e "MYSQL_PWD=${DB_PWD}" cloudpi-db mysql -u masteradmin pidb -e "
  UPDATE schema_version SET success=0 WHERE id=19;
  UPDATE schema_version SET success=0 WHERE id=29;
"
```

Then clear lockout and restart:

```bash
sudo docker exec cloudpi-app rm /app/backups/.migration_lockout
sudo docker restart cloudpi-app
```

### Migration fails: "Access denied; you need SYSTEM_USER privilege"

```bash
DB_ROOT_PWD=$(cat /run/secrets-tmp/db_root_password)
sudo docker exec -e "MYSQL_PWD=${DB_ROOT_PWD}" cloudpi-db \
  mysql -u root -e \
  "GRANT SYSTEM_USER ON *.* TO 'masteradmin'@'%'; FLUSH PRIVILEGES;"
```

### Migration fails: "Table 'pidb.cost_tags' doesn't exist"

```bash
DB_PWD=$(cat /run/secrets-tmp/db_password)
sudo docker exec -e "MYSQL_PWD=${DB_PWD}" cloudpi-db mysql -u masteradmin pidb -e "
CREATE TABLE IF NOT EXISTS cost_tags (
    project_id INT DEFAULT NULL,
    key_name   VARCHAR(255) NOT NULL,
    tag_value  VARCHAR(500) DEFAULT NULL,
    INDEX idx_cost_tags_project_key (project_id, key_name),
    INDEX idx_cost_tags_key (key_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
"
```

Then clear lockout and restart the app:

```bash
sudo docker exec cloudpi-app rm /app/backups/.migration_lockout
sudo docker restart cloudpi-app
```

### Backup restore fails silently ("mysql restore command failed")

Check that `masteradmin` has `SYSTEM_USER` privilege — this is the most common cause. Run the SYSTEM_USER grant above (see "Access denied; you need SYSTEM_USER privilege"), then restart the app.

### Login returns 404

In v1.1.042+, the API moved from `/v1/` to `/CPiN/v1/`. Use:
```
POST https://<IP>/CPiN/v1/user/login
```

### cloudpi-fetch-secrets fails on boot

Check logs:
```bash
journalctl -xeu cloudpi-fetch-secrets
```

Common cause: EC2 IAM role not attached, or secret name mismatch. Verify in AWS Console that the instance has `cloudpi-ec2-role` and that the secret is named exactly `cloudpi-secrets` in Secrets Manager.

---

## Part 19 — Upgrading to a New Release

### 19.1 Update image tags in docker-compose.yml

On the EC2, edit the file and update both image tags to the new version:

```bash
sudo nano /home/cloudpiadmin/cloudpi/docker-compose.yml
# Update Cloudpi_db_v1.1.042 → Cloudpi_db_v1.1.044
# Update Cloudpi_v1.1.042 → Cloudpi_v1.1.044
```

Or from your local machine, edit `docker-compose.yml.txt` and re-upload:

```bash
scp -i /path/to/cloudpi-key.pem docker-compose.yml.txt \
    cloudpiadmin@<PUBLIC_IP>:/home/cloudpiadmin/cloudpi/docker-compose.yml
```

### 19.2 Pull new images and restart

```bash
cd /home/cloudpiadmin/cloudpi
docker compose pull
sudo systemctl restart cloudpi-docker-compose
```

### 19.3 Monitor migration

```bash
sudo docker logs -f cloudpi-app
```

If migration fails and the container enters lockout:

1. Identify the failure in logs
2. Fix the root cause in MySQL (see Troubleshooting section)
3. Clear lockout: `sudo docker exec cloudpi-app rm /app/backups/.migration_lockout`
4. Restart: `sudo docker restart cloudpi-app`

---

## Appendix A — If AWS Secrets Manager Is Not Available

If the EC2 cannot reach Secrets Manager (e.g. no internet, no IAM role), you can write secrets directly to the tmpfs location instead of using the fetch script.

**Skip Part 1 (IAM role), Part 2.2 (Secrets Manager), Part 3.4 (update CLIENT_DOMAIN in Secrets Manager), Part 10 (fetch-secrets install), and Part 13 (systemd install). Instead, run the steps below to write secrets directly and install only the docker-compose service:**

```bash
sudo mkdir -p /run/secrets-tmp
sudo mount -t tmpfs -o size=2m,mode=0700 tmpfs /run/secrets-tmp
sudo chgrp cloudpiadmin /run/secrets-tmp
sudo chmod 750 /run/secrets-tmp

# Write cloudpi.secrets — paste your full cloudpi-secrets.json values as KEY=VALUE lines
sudo tee /run/secrets-tmp/cloudpi.secrets << 'EOF'
DB_PASSWORD=your_db_password
DB_ROOT_PASSWORD=your_db_root_password
DB_NAME=pidb
DB_HOST=cloudpi-db
DB_USER=masteradmin
MYSQL_PASSWORD=your_db_password
MYSQL_ROOT_PASSWORD=your_db_root_password
MYSQL_DATABASE=pidb
MYSQL_USER=masteradmin
SECRET_KEY=your_secret_key
REDIS_PASSWORD=your_redis_password
CRYPTO_SECRET=your_crypto_secret
ENCRYPTION_KEY=your_fernet_key=
CREDENTIAL_ENCRYPTION_KEY=your_fernet_key=
HMAC_SECRET_KEY=your_hmac_key
PAR_SECRET_KEY=your_par_key=
WORKSPACE_ID=your-uuid
CLIENT_NAME=YourCompanyName
CLIENT_CODE=ABC
CLIENT_DOMAIN=YOUR_EC2_PUBLIC_IP
REACT_APP_ORIGIN_URL=http://localhost:3000
CLIENT_EMAIL=admin@yourcompany.com
CLIENT_CONTACT_NAME=Your Name
CLIENT_CONTACT_NUMBER=
FISCAL_YEAR=JAN-DEC
EOF

# Write individual password files
sudo bash -c "echo -n 'your_db_password' > /run/secrets-tmp/db_password"
sudo bash -c "echo -n 'your_db_root_password' > /run/secrets-tmp/db_root_password"

sudo chmod 640 /run/secrets-tmp/cloudpi.secrets /run/secrets-tmp/db_password /run/secrets-tmp/db_root_password
sudo chown cloudpiadmin:cloudpiadmin /run/secrets-tmp/cloudpi.secrets /run/secrets-tmp/db_password /run/secrets-tmp/db_root_password
```

Then install only the docker-compose systemd service (skip fetch-secrets):

```bash
sudo tee /etc/systemd/system/cloudpi-docker-compose.service << 'EOF'
[Unit]
Description=CloudPi Docker Compose Application
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/home/cloudpiadmin/cloudpi
User=cloudpiadmin
ExecStartPre=-/usr/bin/docker compose pull --quiet
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable cloudpi-docker-compose
sudo systemctl start cloudpi-docker-compose
```

> **Note:** The tmpfs mount and its contents are lost on every reboot. After rebooting, you must re-run the **entire block above** — from `sudo mkdir -p /run/secrets-tmp` through the final `sudo chown` — before starting the containers. If you only re-run the `tee` commands without remounting, secrets will be written to regular disk instead of tmpfs.

---

## Appendix B — Useful Commands on EC2

```bash
# Check container status
sudo docker ps

# App logs (live)
sudo docker logs -f cloudpi-app

# DB shell
sudo docker exec -it cloudpi-db mysql -u masteradmin -p

# Restart app only
sudo docker restart cloudpi-app

# Restart via systemd (re-fetches secrets and restarts containers)
sudo systemctl restart cloudpi-fetch-secrets
sudo systemctl restart cloudpi-docker-compose

# Fix ownership if files end up owned by root
sudo chown -R cloudpiadmin:cloudpiadmin /home/cloudpiadmin/cloudpi
sudo chown -R 1000:1000 /home/cloudpiadmin/cloudpi/certs

# Test login
curl -sk https://<PUBLIC_IP>/CPiN/v1/user/login \
  -X POST -H 'Content-Type: application/json' \
  -d '{"email":"admin@cloudpi.ai","password":"admin123"}'

# Check migration state
DB_PWD=$(cat /run/secrets-tmp/db_password)
sudo docker exec -e "MYSQL_PWD=${DB_PWD}" cloudpi-db mysql -u masteradmin pidb -e \
  "SELECT version_number, success FROM schema_version ORDER BY id DESC LIMIT 10;"

# Clear migration lockout
sudo docker exec cloudpi-app rm /app/backups/.migration_lockout

# Grant cloudpiadmin passwordless sudo (run as ubuntu if needed)
echo "cloudpiadmin ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/cloudpiadmin
```

---

## Appendix C — Key File Locations on EC2

| File | Purpose |
|------|---------|
| `/home/cloudpiadmin/cloudpi/docker-compose.yml` | Container definitions |
| `/home/cloudpiadmin/cloudpi/.env` | App environment: HOST, HTTPS, cert paths |
| `/home/cloudpiadmin/cloudpi/certs/` | TLS certificates (owned UID 1000) |
| `/home/cloudpiadmin/.docker/config.json` | Docker Hub credentials |
| `/run/secrets-tmp/cloudpi.secrets` | Runtime secrets (tmpfs, cleared on reboot) |
| `/run/secrets-tmp/db_password` | DB password for container |
| `/run/secrets-tmp/db_root_password` | DB root password for container |
| `/usr/local/bin/cloudpi-fetch-secrets.sh` | Secrets fetch script |
| `/etc/systemd/system/cloudpi-fetch-secrets.service` | Systemd: fetch secrets on boot |
| `/etc/systemd/system/cloudpi-docker-compose.service` | Systemd: start containers |
| `/var/log/cloud-init-output.log` | EC2 user-data bootstrap log (AWS default) |
| `/var/log/cloudpi-bootstrap-done` | Marker file: created when user-data bootstrap completes |
