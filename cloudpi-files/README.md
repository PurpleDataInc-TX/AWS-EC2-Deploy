# CloudPi

CloudPi is a cloud cost governance and management platform designed for deployment on cloud virtual machines. This repository contains the deployment configuration and setup scripts for running CloudPi using Docker containers on **AWS EC2**.

**Note:** This repository contains the paid, proprietary version of CloudPi. Use is restricted to customers or those with explicit permission from PurpleData Inc.

## Features

- **Containerized Architecture:** Two-tier Docker application with separate app and database containers
- **HTTPS Support:** Self-signed or Let's Encrypt (Certbot) SSL certificate provisioning
- **AWS Secrets Manager Integration:** Secure secrets management using the EC2 instance IAM role and tmpfs (RAM-only storage)
- **Systemd Integration:** Auto-start on boot with systemd service management
- **Health Checks:** Built-in container health monitoring for both app and database services
- **Auto-renewal:** Automated SSL certificate renewal with post-renewal hooks

## Repository Structure

- `docker-compose.yml`: Container orchestration configuration with app and database services
- `.env`: Environment configuration (HOST, HTTPS, SSL paths, client settings)
- `setup-certbot.sh`: Optional standalone Let's Encrypt certificate setup
- `cp_upgrade.sh`: Helper for upgrading to a new image tag
- `setup-syslog.sh` / `verify-syslog.sh` / `host-config/`: Host rsyslog integration for the app's JSON logs
- `change-password.sh`: Reset the admin/DB password from the fetched secrets
- `certs/`: Directory for SSL certificates (created during deployment)

## Requirements

- **Operating System:** Ubuntu/Debian Linux (the deploy provisions Ubuntu 22.04)
- **Docker:** Docker Engine with the Compose plugin
- **Cloud Platform:** AWS EC2 with:
  - An IAM instance role granting AWS Secrets Manager access
  - A Security Group with ports 80 and 443 (and 22 for SSH) open
  - An Elastic IP (allocated by the deploy)
- **AWS Resources:**
  - AWS Secrets Manager secret (`cloudpi-secrets`) for secrets storage
  - IAM role with `secretsmanager:GetSecretValue` (read) on that secret
- **Domain (optional):** A registered domain/subdomain if you want a trusted Let's Encrypt certificate

## Deployment

The recommended path is the guided installer in the parent repository, which automates provisioning through first-boot verification:

```bash
bash deploy_interactive.sh
```

See the top-level **`README.md`** (AWS EC2 Deployment Runbook) for the full step-by-step guide. At a high level the deploy:

1. Provisions the EC2 instance, IAM role, Security Group, and Elastic IP (`deploy_aws_ec2.py`).
2. Uploads secrets to AWS Secrets Manager (`setup_aws_secrets.py`).
3. Copies this `cloudpi-files/` bundle to `/home/cloudpiadmin/cloudpi/` on the instance.
4. Generates `.env`, TLS certificates, and the secrets-fetch script.
5. Installs the systemd units (`setup_docker_compose_service.py`) that fetch secrets and start the stack on boot.

### Environment variables (`.env`)

The deploy sets the following automatically; they can also be edited manually:

```bash
# Host / protocol
HOST=<public-ip-or-domain>
SUBDOMAIN=<public-ip-or-domain>
HTTPS=true

# SSL certificate paths (must match the files created during deployment)
CERT_PATH=/home/certs/cert.pem
KEY_PATH=/home/certs/privkey.pem
CA_BUNDLE_PATH=/home/certs/ca_bundle.pem

# Client configuration
CLIENT_NAME=Your Client Name
CLIENT_CODE=your-code
CLIENT_DOMAIN=yourdomain.com
CLIENT_EMAIL=contact@yourdomain.com
CLIENT_CONTACT_NAME=Contact Name
CLIENT_CONTACT_NUMBER=+1 234-567-8900
FISCAL_YEAR=JAN-DEC

# Service configuration
WORKERS=4
```

> `CERT_PATH` must point at `cert.pem` (the leaf), not `fullchain.pem`. The app entrypoint builds the full chain by concatenating `CERT_PATH` + `CA_BUNDLE_PATH`.

### DNS + Let's Encrypt (optional)

For a trusted certificate, create a DNS **A record** pointing your subdomain to the instance's Elastic IP, then choose the Let's Encrypt option during deployment (or run `setup-certbot.sh`). Port 80 must be open in the Security Group for HTTP-01 validation.

## Container Architecture

### Services

- **cloudpi-app**: Main application container
  - Image: `cloudpi1/cloudpi:latest-app`
  - Ports: 80 (HTTP), 443 (HTTPS)
  - Volumes: Redis data, SSL certificates
  - Health check: HTTP endpoints

- **cloudpi-db**: MySQL database container
  - Image: `cloudpi1/cloudpi:latest-db`
  - Volumes: MySQL data persistence
  - Health check: mysqladmin ping

### Volumes

- `mysql_data`: Persistent MySQL database storage
- `redis_data`: Redis cache storage
- `./certs:/home/certs`: SSL certificate mount

### Networks

- `cloudpi-network`: Bridge network (172.28.0.0/16)

## Secrets Management

Secrets are stored in **AWS Secrets Manager** and delivered to the instance without ever being written to disk:

- The EC2 instance's IAM role authenticates to Secrets Manager (no credentials on the instance).
- On boot, the `cloudpi-fetch-secrets` systemd unit pulls the secret into tmpfs (`/run/secrets-tmp/`, RAM-only) before the app starts.
- `docker-compose.yml` reads them via `env_file: /run/secrets-tmp/cloudpi.secrets`.

## SSL Certificate Management

### Auto-Renewal

When Let's Encrypt is used, certificates are renewed by Certbot's systemd timer. The renewal deploy hook at `/etc/letsencrypt/renewal-hooks/deploy/cloudpi-cert.sh` will:
1. Copy renewed certificates to the `certs/` directory
2. Set proper ownership (UID 1000)
3. Restart the CloudPi app container

### Manual Renewal

```bash
sudo certbot renew
```

## Systemd Service Management

```bash
# Start / stop / restart containers
sudo systemctl start   cloudpi-docker-compose
sudo systemctl stop    cloudpi-docker-compose
sudo systemctl restart cloudpi-docker-compose

# Re-fetch secrets from AWS Secrets Manager
sudo systemctl restart cloudpi-fetch-secrets

# View status / logs
sudo systemctl status cloudpi-docker-compose
journalctl -u cloudpi-docker-compose -f
```

## Security Features

- **Security Groups:** Firewall rules restricting inbound access to 22/80/443
- **IAM instance role:** No credentials stored in code or configuration — the instance authenticates to AWS via its role
- **No new privileges:** Containers run with `no-new-privileges:true`
- **Capability dropping:** Minimal Linux capabilities (CAP_DROP ALL)
- **Resource limits:** CPU and memory limits enforced
- **Secrets in tmpfs:** RAM-only storage, never written to disk
- **Secure file permissions:** Certificates and secrets have restricted access

## Troubleshooting

### Containers won't start

```bash
docker compose logs
journalctl -u cloudpi-docker-compose -f
```

### SSL certificate errors

```bash
ls -la certs/
sudo ./setup-certbot.sh   # re-run cert setup
```

### Database connection issues

```bash
docker exec cloudpi-db mysqladmin ping -h localhost
docker compose logs db
```

### Secrets not loading

```bash
sudo systemctl status cloudpi-fetch-secrets
journalctl -u cloudpi-fetch-secrets -f
mountpoint /run/secrets-tmp
ls -la /run/secrets-tmp/
```

## License

This software is proprietary and paid. See [LICENSE](./LICENSE) for details on usage and distribution.

## Support

Maintained by PurpleData Inc.

For support, contact your CloudPi account representative.
