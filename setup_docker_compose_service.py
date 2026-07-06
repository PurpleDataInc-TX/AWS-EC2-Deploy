#!/usr/bin/env python3
"""
setup_docker_compose_service.py
Installs the systemd units that run CloudPi on the EC2 instance.

Creates two units:
  cloudpi-fetch-secrets.service   — oneshot; pulls secrets from AWS Secrets
                                    Manager into tmpfs (/run/secrets-tmp) by
                                    running /usr/local/bin/cloudpi-fetch-secrets.sh.
  cloudpi-docker-compose.service  — brings the Docker Compose stack up; depends
                                    on docker.service and cloudpi-fetch-secrets.

Run as root on the EC2 instance (the interactive deploy does this over SSH):
  sudo REGION=us-east-1 python3 setup_docker_compose_service.py

Idempotent: re-running rewrites the unit files and reloads systemd.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path


# ─── Configuration ────────────────────────────────────────────────────────────
REGION        = os.getenv("REGION",        "us-east-1")
SERVICE_USER  = os.getenv("SERVICE_USER",  "cloudpiadmin")
APP_DIR       = os.getenv("APP_DIR",       f"/home/{os.getenv('SERVICE_USER', 'cloudpiadmin')}/cloudpi")
FETCH_SCRIPT  = os.getenv("FETCH_SCRIPT",  "/usr/local/bin/cloudpi-fetch-secrets.sh")
SYSTEMD_DIR   = Path("/etc/systemd/system")


# ─── Helpers ──────────────────────────────────────────────────────────────────
def info(msg): print(f"[INFO]  {msg}")
def ok(msg):   print(f"[OK]    {msg}")
def warn(msg): print(f"[WARN]  {msg}")
def die(msg):  sys.exit(f"[ERROR] {msg}")


def require_root():
    if os.geteuid() != 0:
        die("This script must be run as root (use sudo).")


def resolve_docker() -> str:
    """Return the docker binary path; the compose plugin is invoked as 'docker compose'."""
    path = shutil.which("docker")
    if not path:
        die("docker not found on PATH — is Docker installed on this instance?")
    return path


def write_unit(name: str, content: str):
    dest = SYSTEMD_DIR / name
    dest.write_text(content, encoding="utf-8")
    os.chmod(dest, 0o644)
    ok(f"Wrote {dest}")


# ─── Unit definitions ─────────────────────────────────────────────────────────
def fetch_secrets_unit() -> str:
    return f"""\
[Unit]
Description=CloudPi - fetch secrets from AWS Secrets Manager into tmpfs
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=REGION={REGION}
ExecStart={FETCH_SCRIPT}

[Install]
WantedBy=multi-user.target
"""


def docker_compose_unit(docker_bin: str) -> str:
    # ExecReload re-fetches secrets then re-applies the stack so rotations take
    # effect without a full restart.
    return f"""\
[Unit]
Description=CloudPi - Docker Compose application stack
Requires=docker.service cloudpi-fetch-secrets.service
After=docker.service cloudpi-fetch-secrets.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory={APP_DIR}
ExecStart={docker_bin} compose up -d
ExecStop={docker_bin} compose down
ExecReload=/bin/sh -c '{FETCH_SCRIPT} && {docker_bin} compose up -d'
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
"""


# ─── Main ─────────────────────────────────────────────────────────────────────
def main():
    require_root()

    if not Path(FETCH_SCRIPT).exists():
        warn(f"Fetch-secrets script not found at {FETCH_SCRIPT} — "
             "cloudpi-fetch-secrets will fail until it is installed (deploy step 10f).")
    if not Path(APP_DIR, "docker-compose.yml").exists():
        warn(f"{APP_DIR}/docker-compose.yml not found — "
             "cloudpi-docker-compose will fail until the compose file is in place.")

    docker_bin = resolve_docker()
    info(f"Using docker binary: {docker_bin}")
    info(f"App directory       : {APP_DIR}")
    info(f"Fetch script        : {FETCH_SCRIPT}")
    info(f"Region              : {REGION}")

    write_unit("cloudpi-fetch-secrets.service", fetch_secrets_unit())
    write_unit("cloudpi-docker-compose.service", docker_compose_unit(docker_bin))

    info("Reloading systemd daemon...")
    subprocess.run(["systemctl", "daemon-reload"], check=True)

    info("Enabling units (start on boot)...")
    subprocess.run(["systemctl", "enable", "cloudpi-fetch-secrets.service"], check=True)
    subprocess.run(["systemctl", "enable", "cloudpi-docker-compose.service"], check=True)

    ok("systemd units installed and enabled.")
    ok("Start them with:")
    print("    sudo systemctl start cloudpi-fetch-secrets")
    print("    sudo systemctl start cloudpi-docker-compose")


if __name__ == "__main__":
    main()
