#!/usr/bin/env bash
# interactive.sh — CloudPi AWS EC2 Interactive Deployment (v2)
# A single guided session covering every step in DEPLOYMENT_RUNBOOK.md.
#
# Re-runnable: completed steps are recorded in .deploy_state and skipped.
# This is a hardened rewrite of deploy_interactive.sh with bug fixes:
#   • Region is threaded consistently everywhere (no more us-east-1 hardcoding).
#   • DB admin operations authenticate as root with the correct password.
#   • Post-install steps run their AWS lookups ON EC2 (not locally) and
#     handle bcrypt hashes / special characters safely.
#   • Fetch-secrets script makes a single Secrets Manager call.
#   • Target directory is always created before files are copied into it.
# Plus a smoother UI: status overview, resume/reset menu, step counter,
# spinners for long operations, input validation, and a final summary.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/.deploy_state"
SECRETS_JSON="$SCRIPT_DIR/cloudpi-secrets.json"
export SCRIPT_DIR
TOTAL_STEPS=12

# ── Colors / formatting ─────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

TERM_COLS=$(tput cols 2>/dev/null || echo 70)
[[ "$TERM_COLS" =~ ^[0-9]+$ ]] || TERM_COLS=70
(( TERM_COLS > 78 )) && TERM_COLS=78
(( TERM_COLS < 50 )) && TERM_COLS=50

rule() { printf "${DIM}%*s${NC}\n" "$TERM_COLS" '' | tr ' ' '─'; }

# ── UI helpers ───────────────────────────────────────────────────────────────────
header() {   # header N "Title"
    echo
    rule
    printf "  ${BOLD}${CYAN}STEP %s/%s${NC}   ${BOLD}%s${NC}\n" "$1" "$TOTAL_STEPS" "$2"
    rule
}
ok()   { echo -e "${GREEN}  ✓  ${*}${NC}"; }
warn() { echo -e "${YELLOW}  ⚠  ${*}${NC}"; }
die()  { echo -e "${RED}  ✗  ${*}${NC}" >&2; exit 1; }
info() { echo    "     ${*}"; }

confirm() {   # confirm "prompt" [Y|N]  → 0=yes 1=no
    local msg="${1:-Continue?}" def="${2:-Y}"
    local opts; [[ "$def" == "Y" ]] && opts="[Y/n]" || opts="[y/N]"
    printf "\n${YELLOW}  ▶  %s %s: ${NC}" "$msg" "$opts"
    read -r _ca
    _ca="${_ca:-$def}"
    [[ "$_ca" =~ ^[Yy]$ ]]
}

ask() {       # ask VARNAME "prompt" [default]
    local _v="$1" _p="$2" _d="${3:-}"
    [[ -n "$_d" ]] && printf "     %s [%s]: " "$_p" "$_d" \
                    || printf "     %s: " "$_p"
    read -r _in
    printf -v "$_v" '%s' "${_in:-$_d}"
}

ask_pass() {  # ask_pass VARNAME "prompt"
    local _v="$1" _p="$2"
    printf "     %s (hidden): " "$_p"
    read -rs _sp; echo
    printf -v "$_v" '%s' "$_sp"
}

# ask_host VARNAME "prompt" [default] — re-prompts until a plausible IP/hostname
ask_host() {
    local _v="$1" _p="$2" _d="${3:-}" _val
    while true; do
        ask _val "$_p" "$_d"
        if [[ "$_val" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$_val" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
            printf -v "$_v" '%s' "$_val"; return 0
        fi
        warn "That does not look like a valid IP or hostname — try again."
    done
}

# with_spinner "message" cmd args...  — runs cmd, animates a spinner, prints ✓/✗
with_spinner() {
    local msg="$1"; shift
    local logf; logf="$(mktemp "/tmp/cloudpi-spin.XXXXXX")"
    local frames='|/-\' i=0 rc
    ( "$@" ) >"$logf" 2>&1 &
    local pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % 4 ))
        printf "\r   ${CYAN}%s${NC} %s " "${frames:$i:1}" "$msg"
        sleep 0.1
    done
    if wait "$pid"; then rc=0; else rc=$?; fi
    if (( rc == 0 )); then
        printf "\r   ${GREEN}✓${NC} %s\n" "$msg"
    else
        printf "\r   ${RED}✗${NC} %s\n" "$msg"
        sed 's/^/       /' "$logf"
    fi
    rm -f "$logf"
    return "$rc"
}

# ── State helpers ──────────────────────────────────────────────────────────────
touch "$STATE_FILE"

st_get() { grep -E "^${1}=" "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true; }
st_set() {
    local k="$1" v="$2"
    { grep -vE "^${k}=" "$STATE_FILE" 2>/dev/null || true; echo "${k}=${v}"; } \
        > "${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
}
st_done() { [[ "$(st_get "$1")" == "done" ]]; }

# Returns 0 (run) or 1 (skip)
should_run() {
    local k="$1" label="${2:-step}"
    if st_done "$k"; then
        warn "Already completed: $label"
        if ! confirm "Re-run this step?" N; then
            return 1
        fi
    fi
    return 0
}

# ── Status overview ─────────────────────────────────────────────────────────────
_ov() {   # _ov NUM "title" STATE_KEY   (STATE_KEY empty = not tracked; KEY_FILE special)
    local num="$1" title="$2" key="$3" mark
    if [[ -z "$key" ]]; then
        mark="${DIM}·${NC}"
    elif [[ "$key" == "KEY_FILE" ]]; then
        [[ -n "$(st_get KEY_FILE)" ]] && mark="${GREEN}✓${NC}" || mark="${YELLOW}○${NC}"
    elif st_done "$key"; then
        mark="${GREEN}✓${NC}"
    else
        mark="${YELLOW}○${NC}"
    fi
    printf "   %b  ${BOLD}%2s${NC}  %s\n" "$mark" "$num" "$title"
}

overview() {
    local _ip; _ip="$(st_get PUBLIC_IP)"
    echo
    rule
    printf "  ${BOLD}CloudPi AWS EC2 — Deployment Status${NC}\n"
    rule
    _ov  1 "Prerequisites"              ""
    _ov  2 "AWS credentials"            ""
    _ov  3 "Python dependencies"        STEP_3
    _ov  4 "Secrets file"               STEP_4
    _ov  5 "SSH key pair"               KEY_FILE
    _ov  6 "Provision EC2"              STEP_6
    _ov  7 "CLIENT_DOMAIN"             STEP_7
    _ov  8 "Wait for bootstrap"         STEP_8
    _ov  9 "Upload secrets"             STEP_9
    _ov 10 "Configure EC2 instance"     STEP_10H
    _ov 11 "First boot & verify"        STEP_11C
    _ov 12 "Post-install (optional)"    ""
    rule
    [[ -n "$_ip" ]] && printf "  ${DIM}Current target IP:${NC} ${CYAN}%s${NC}\n" "$_ip"
    printf "  ${DIM}State file:${NC} %s\n" "$STATE_FILE"
}

# ── SSH shorthands (available once KEY_FILE / PUBLIC_IP are known) ─────────────
# UserKnownHostsFile=/dev/null avoids "REMOTE HOST IDENTIFICATION HAS CHANGED"
# failures when an Elastic IP is reused across re-provisioned instances.
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o PasswordAuthentication=no -o ConnectTimeout=15 -o LogLevel=ERROR)

ssh_run() {   # ssh_run "remote command" — '-n' detaches stdin from /dev/null so the
              # ssh call can NEVER drain the script's own stdin (the classic
              # "ssh eats the loop's input" bug that breaks piped/automated runs).
    ssh -n -i "$KEY_FILE" "${SSH_OPTS[@]}" "cloudpiadmin@${PUBLIC_IP}" "$@"
}
ssh_in()  {   # ssh_in "remote command" — keeps stdin (for heredocs / piped data).
    ssh -i "$KEY_FILE" "${SSH_OPTS[@]}" "cloudpiadmin@${PUBLIC_IP}" "$@"
}
scp_up() {    # scp_up local_file remote_path
    scp -i "$KEY_FILE" "${SSH_OPTS[@]}" "$1" "cloudpiadmin@${PUBLIC_IP}:$2"
}

# ── Remediation helpers (shared by step 10 setup and step 11 auto-repair) ─────
# These are idempotent and safe to call repeatedly; the step-11 health loop
# calls them automatically when it detects the matching failure signature, so a
# transient/first-boot problem self-heals without a manual re-run.

# ensure_log_dir — create /var/log/pico writable by the in-container app (UID
# 1000). Missing/root-owned dir makes Flask crash-loop on 'PermissionError'.
ensure_log_dir() {
    ssh_run "sudo mkdir -p /var/log/pico && { sudo chown -R 1000:syslog /var/log/pico 2>/dev/null || sudo chown -R 1000:1000 /var/log/pico; } && sudo chmod 2750 /var/log/pico"
}

# restart_fetch_secrets — re-pull secrets into tmpfs and re-apply the stack.
restart_fetch_secrets() {
    ssh_run "sudo systemctl restart cloudpi-fetch-secrets && cd /home/cloudpiadmin/cloudpi && sudo docker compose up -d"
}

# reconcile_db_password — make the DB's masteradmin/root passwords match the
# secrets. The prebuilt cloudpi-db image ships a PRE-INITIALIZED datadir, so
# MySQL ignores the MYSQL_* env vars on first boot and the baked-in password
# (unknown to us) sticks — the app then fails with "Access denied" forever
# (while the DB still reports 'healthy', since mysqladmin ping doesn't auth).
# We probe the app's exact auth path; only if it fails do we bounce the datadir
# through a throwaway mysqld with --skip-grant-tables and force the passwords.
reconcile_db_password() {
    ssh_in "REGION='$REGION' bash -s" <<'REMOTE'
set -euo pipefail
APP_DIR=/home/cloudpiadmin/cloudpi

# Pull the credentials the app will use, straight from Secrets Manager.
SM=$(/usr/local/bin/aws secretsmanager get-secret-value \
    --region "$REGION" --secret-id cloudpi-secrets \
    --query SecretString --output text)
DB_PW=$(printf   '%s' "$SM" | python3 -c "import json,sys; print(json.load(sys.stdin)['MYSQL_PASSWORD'])")
DB_ROOT=$(printf '%s' "$SM" | python3 -c "import json,sys; print(json.load(sys.stdin).get('MYSQL_ROOT_PASSWORD',''))")
APP_USER=$(printf '%s' "$SM" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('DB_USER') or d.get('MYSQL_USER') or 'masteradmin')")

# Wait for the db container to exist (compose was just started).
for i in $(seq 1 30); do
    sudo docker ps --format '{{.Names}}' | grep -qx cloudpi-db && break
    sleep 2
done

# Discover the real volume / network / image from the running container so this
# never drifts from the compose project name.
VOL=$(sudo docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/mysql"}}{{.Name}}{{end}}{{end}}' cloudpi-db)
NET=$(sudo docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' cloudpi-db)
IMG=$(sudo docker inspect -f '{{.Config.Image}}' cloudpi-db)
[ -n "$VOL" ] || { echo "ERROR: could not resolve the mysql data volume"; exit 1; }

# Probe the app's exact path: TCP as APP_USER@'%' to host cloudpi-db.
if sudo docker run --rm --network "$NET" -e MYSQL_PWD="$DB_PW" --entrypoint mysql "$IMG" \
       -u "$APP_USER" -h cloudpi-db -e "SELECT 1" >/dev/null 2>&1; then
    echo "OK: '$APP_USER' authenticates over the network — no reset needed."
    exit 0
fi

echo "Auth failed — resetting DB passwords to match secrets (skip-grant-tables) ..."
# Escape single quotes for SQL string literals (double them).
APP_USER_SQL=${APP_USER//\'/\'\'}
DB_PW_SQL=${DB_PW//\'/\'\'}
DB_ROOT_SQL=${DB_ROOT//\'/\'\'}

cd "$APP_DIR"
sudo docker compose stop db

# Never leave a stale reset container around.
sudo docker rm -f mysql-reset >/dev/null 2>&1 || true
sudo docker run --rm -d --name mysql-reset \
    -v "$VOL":/var/lib/mysql --user mysql --entrypoint mysqld \
    "$IMG" --skip-grant-tables --skip-networking

# Wait for the throwaway mysqld to accept local connections.
for i in $(seq 1 30); do
    sudo docker exec mysql-reset mysqladmin ping >/dev/null 2>&1 && break
    sleep 2
done

sudo docker exec mysql-reset mysql -e "
FLUSH PRIVILEGES;
ALTER USER IF EXISTS '${APP_USER_SQL}'@'%'         IDENTIFIED BY '${DB_PW_SQL}';
ALTER USER IF EXISTS '${APP_USER_SQL}'@'localhost' IDENTIFIED BY '${DB_PW_SQL}';
ALTER USER IF EXISTS 'root'@'localhost'            IDENTIFIED BY '${DB_ROOT_SQL}';
FLUSH PRIVILEGES;
"
sudo docker stop mysql-reset >/dev/null 2>&1 || true

# Bring the real stack back up and re-probe.
sudo docker compose up -d
for i in $(seq 1 30); do
    sudo docker ps --format '{{.Names}}' | grep -qx cloudpi-db && break
    sleep 2
done
if sudo docker run --rm --network "$NET" -e MYSQL_PWD="$DB_PW" --entrypoint mysql "$IMG" \
       -u "$APP_USER" -h cloudpi-db -e "SELECT 1" >/dev/null 2>&1; then
    echo "OK: password reset succeeded — '$APP_USER' now authenticates."
else
    echo "ERROR: reset ran but '$APP_USER' still cannot authenticate."; exit 1
fi
REMOTE
}

# Placeholders so `set -u` doesn't complain before steps 5/6 populate them
KEY_FILE=""; PUBLIC_IP=""; REGION="us-east-1"

trap 'echo; warn "Interrupted. Re-run interactive.sh to resume — completed steps are saved."; exit 130' INT

# ══════════════════════════════════════════════════════════════════════════════
clear 2>/dev/null || true
echo
echo -e "  ${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}${CYAN}║        CloudPi  ·  AWS EC2 Interactive Deploy        ║${NC}"
echo -e "  ${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"

overview

# ── Start menu ────────────────────────────────────────────────────────────────
echo
echo "   What would you like to do?"
echo "     1) Resume / run pending steps          (default)"
echo "     2) Reset deployment state and start fresh"
echo "     3) Show status only, then exit"
ask _menu "Choice" "1"
case "${_menu:-1}" in
    2)
        if confirm "This clears $STATE_FILE (AWS resources are NOT deleted). Continue?" N; then
            : > "$STATE_FILE"
            ok "State cleared — starting fresh."
        else
            info "Keeping existing state."
        fi
        ;;
    3)
        echo; info "No changes made."; exit 0 ;;
    *) : ;;
esac

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1 — Prerequisites
# ══════════════════════════════════════════════════════════════════════════════
header 1 "Prerequisites"

_missing=0
for _cmd in python3 pip3 ssh scp openssl curl rsync; do
    if command -v "$_cmd" &>/dev/null; then ok "$_cmd found"
    else warn "$_cmd NOT found"; _missing=1; fi
done
(( _missing )) && die "Install the missing tools above before continuing."
ok "All prerequisites met."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2 — AWS Credentials
# ══════════════════════════════════════════════════════════════════════════════
header 2 "AWS Credentials"

if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
    warn "AWS_ACCESS_KEY_ID not set in environment."
    ask AWS_ACCESS_KEY_ID    "AWS Access Key ID"
    ask_pass AWS_SECRET_ACCESS_KEY "AWS Secret Access Key"
    ask AWS_DEFAULT_REGION   "AWS Region" "us-east-1"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
else
    ok "Using AWS credentials from environment."
fi
: "${AWS_DEFAULT_REGION:=us-east-1}"
export AWS_DEFAULT_REGION

# Single source of truth for region — propagated to every AWS call / remote script.
REGION="$AWS_DEFAULT_REGION"
export REGION

info "Verifying credentials..."
_acct=$(python3 -c "
import boto3, sys
try:
    r = boto3.client('sts', region_name='${REGION}').get_caller_identity()
    print(r['Account'])
except Exception as e:
    print('ERROR:' + str(e), file=sys.stderr)
    sys.exit(1)
") || die "AWS credential check failed. Check key/secret/region."
ok "AWS account: $_acct  |  Region: $REGION"

# ── Automation & Recommendations checkbox ─────────────────────────────────────
# Matches the third checkbox in the CloudPi console onboarding.
# Yes → cloudpi-aws-automation.tf (automation + read-only permissions)
# No  → main.tf (read-only permissions only)
echo
if confirm "Enable Automation & Recommendations? (third checkbox in CloudPi console)" N; then
    TF_SCRIPT="cloudpi-aws-automation.tf"
    ok "Automation selected — Terraform will use ${TF_SCRIPT}."
else
    TF_SCRIPT="main.tf"
    ok "Read-only selected — Terraform will use ${TF_SCRIPT}."
fi
st_set TF_SCRIPT "$TF_SCRIPT"
echo
# ─────────────────────────────────────────────────────────────────────────────

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3 — Python Dependencies
# ══════════════════════════════════════════════════════════════════════════════
header 3 "Python Dependencies"

if should_run STEP_3 "pip install boto3 cryptography"; then
    with_spinner "Installing boto3 + cryptography" \
        pip3 install --quiet boto3 cryptography \
        || die "pip install failed — see output above."
    st_set STEP_3 "done"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4 — Prepare cloudpi-secrets.json
# ══════════════════════════════════════════════════════════════════════════════
header 4 "Prepare cloudpi-secrets.json"

if should_run STEP_4 "secrets file ready"; then
    if [[ -f "$SECRETS_JSON" ]]; then
        info "Existing keys in $SECRETS_JSON:"
        python3 -c "
import json, os
d = json.load(open(os.environ['SCRIPT_DIR'] + '/cloudpi-secrets.json'))
[print('       •', k) for k in d]
"
        echo
        echo "     Options:"
        echo "       1) Use existing file as-is            (default)"
        echo "       2) Regenerate random secrets (CLIENT_* values are preserved)"
        ask _schoice "Choice" "1"
    else
        warn "cloudpi-secrets.json not found — will generate."
        _schoice="2"
    fi

    if [[ "${_schoice:-1}" == "2" ]]; then
        python3 - <<'PYEOF'
import json, secrets, uuid, os
from cryptography.fernet import Fernet
from pathlib import Path

p = Path(os.environ['SCRIPT_DIR']) / 'cloudpi-secrets.json'
ex = json.loads(p.read_text()) if p.exists() else {}

db_pw   = ex.get("DB_PASSWORD")      or secrets.token_urlsafe(16)
db_root = ex.get("DB_ROOT_PASSWORD") or secrets.token_urlsafe(16)

new_s = {
    "DB_PASSWORD":               db_pw,
    "DB_ROOT_PASSWORD":          db_root,
    "DB_NAME":                   "pidb",
    "DB_HOST":                   "cloudpi-db",
    "DB_USER":                   "masteradmin",
    "MYSQL_PASSWORD":            db_pw,
    "MYSQL_ROOT_PASSWORD":       db_root,
    "MYSQL_DATABASE":            "pidb",
    "MYSQL_USER":                "masteradmin",
    "SECRET_KEY":                secrets.token_hex(32),
    "REDIS_PASSWORD":            secrets.token_hex(16),
    "CRYPTO_SECRET":             secrets.token_hex(16),
    "ENCRYPTION_KEY":            Fernet.generate_key().decode(),
    "CREDENTIAL_ENCRYPTION_KEY": Fernet.generate_key().decode(),
    "HMAC_SECRET_KEY":           secrets.token_hex(32),
    "PAR_SECRET_KEY":            Fernet.generate_key().decode(),
    "WORKSPACE_ID":              ex.get("WORKSPACE_ID") or str(uuid.uuid4()),
    "CLIENT_NAME":               ex.get("CLIENT_NAME",           "CloudPi"),
    "CLIENT_CODE":               ex.get("CLIENT_CODE",           "CPI"),
    "CLIENT_DOMAIN":             ex.get("CLIENT_DOMAIN",         "PLACEHOLDER"),
    "REACT_APP_ORIGIN_URL":      ex.get("REACT_APP_ORIGIN_URL",  "http://localhost:3000"),
    "CLIENT_EMAIL":              ex.get("CLIENT_EMAIL",          ""),
    "CLIENT_CONTACT_NAME":       ex.get("CLIENT_CONTACT_NAME",   ""),
    "CLIENT_CONTACT_NUMBER":     ex.get("CLIENT_CONTACT_NUMBER", ""),
    "FISCAL_YEAR":               ex.get("FISCAL_YEAR",           "JAN-DEC"),
}
p.write_text(json.dumps(new_s, indent=2))
print("     Fresh secrets generated (random keys, CLIENT_* values preserved).")
PYEOF
        ok "Secrets file generated."
    else
        ok "Using existing secrets file."
    fi

    # Prompt for blank client fields
    _cl_name=$(python3 -c "import json,os; print(json.load(open(os.environ['SCRIPT_DIR']+'/cloudpi-secrets.json')).get('CLIENT_NAME',''))")
    _cl_email=$(python3 -c "import json,os; print(json.load(open(os.environ['SCRIPT_DIR']+'/cloudpi-secrets.json')).get('CLIENT_EMAIL',''))")
    [[ -z "$_cl_name"  || "$_cl_name"  == "CloudPi" ]] && ask _cl_name  "Client name"  "CloudPi"
    [[ -z "$_cl_email" ]]                               && ask _cl_email "Client email" ""
    CL_NAME="$_cl_name" CL_EMAIL="$_cl_email" python3 - <<'PYEOF'
import json, os
p = os.environ['SCRIPT_DIR'] + '/cloudpi-secrets.json'
d = json.load(open(p))
d['CLIENT_NAME']  = os.environ['CL_NAME']
d['CLIENT_EMAIL'] = os.environ['CL_EMAIL']
open(p, 'w').write(json.dumps(d, indent=2))
PYEOF

    # Validate Fernet-type keys. The CloudPi app's Flask service refuses to start
    # on a malformed Fernet key (must be 32 url-safe base64 bytes → 44 chars) and
    # crash-loops — which only surfaces as an HTTP 503 on login after a full
    # deploy. Catch it here instead.
    _bad_fernet=$(python3 - <<'PYEOF'
import json, os
from cryptography.fernet import Fernet
p = os.environ['SCRIPT_DIR'] + '/cloudpi-secrets.json'
d = json.load(open(p))
bad = []
for k in ("PAR_SECRET_KEY", "ENCRYPTION_KEY", "CREDENTIAL_ENCRYPTION_KEY"):
    try:
        Fernet((d.get(k, "") or "").encode())
    except Exception:
        bad.append(k)
print(",".join(bad))
PYEOF
)
    if [[ -n "$_bad_fernet" ]]; then
        warn "Invalid Fernet key(s) in cloudpi-secrets.json: ${_bad_fernet}"
        warn "The app (Flask) will crash-loop on these — login would return HTTP 503."
        if confirm "Regenerate the invalid Fernet key(s)? (all other values preserved)" Y; then
            BAD_KEYS="$_bad_fernet" python3 - <<'PYEOF'
import json, os
from cryptography.fernet import Fernet
p = os.environ['SCRIPT_DIR'] + '/cloudpi-secrets.json'
d = json.load(open(p))
for k in os.environ['BAD_KEYS'].split(','):
    if k:
        d[k] = Fernet.generate_key().decode()
open(p, 'w').write(json.dumps(d, indent=2))
print("     Regenerated: " + os.environ['BAD_KEYS'])
PYEOF
            ok "Fernet keys fixed."
        else
            warn "Continuing with invalid Fernet key(s) — the app will fail until fixed."
        fi
    else
        ok "Fernet keys valid (PAR_SECRET_KEY, ENCRYPTION_KEY, CREDENTIAL_ENCRYPTION_KEY)."
    fi

    st_set STEP_4 "done"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5 — SSH Key Pair
# ══════════════════════════════════════════════════════════════════════════════
header 5 "SSH Key Pair"

KEY_PAIR_NAME="${KEY_PAIR_NAME:-cloudpi-key}"; export KEY_PAIR_NAME
KEY_FILE="$(st_get KEY_FILE)"
[[ -z "$KEY_FILE" ]] && KEY_FILE="$HOME/.ssh/cloudpi-key.pem"
KEY_FILE="${KEY_FILE/#\~/$HOME}"

# ── key helpers ───────────────────────────────────────────────────────────────
# Public-key material (2nd field) of the local private key, or "" if unreadable.
_local_pubkey() {
    [[ -f "$KEY_FILE" ]] || { printf ''; return 0; }
    ssh-keygen -y -P '' -f "$KEY_FILE" 2>/dev/null | awk '{print $2}' || true
}
# AWS key pair public-key material, or sentinel __ABSENT__ / __ERROR__:<code>.
_aws_pubkey() {
    python3 - <<'PYEOF' 2>/dev/null || true
import os, boto3
from botocore.exceptions import ClientError
ec2 = boto3.client('ec2', region_name=os.environ.get('AWS_DEFAULT_REGION', 'us-east-1'))
name = os.environ['KEY_PAIR_NAME']
try:
    kp = ec2.describe_key_pairs(KeyNames=[name], IncludePublicKey=True)['KeyPairs'][0]
    parts = (kp.get('PublicKey') or '').split()
    print(parts[1] if len(parts) > 1 else '')
except ClientError as e:
    code = e.response.get('Error', {}).get('Code', 'ClientError')
    print('__ABSENT__' if code == 'InvalidKeyPair.NotFound' else '__ERROR__:' + code)
except Exception as e:
    print('__ERROR__:' + type(e).__name__)
PYEOF
}
_kp_create() {   # create a new AWS pair, save the private key locally (overwrites)
    KEY_PATH="$KEY_FILE" python3 - <<'PYEOF'
import os, boto3
ec2 = boto3.client('ec2', region_name=os.environ.get('AWS_DEFAULT_REGION', 'us-east-1'))
path = os.path.expanduser(os.environ['KEY_PATH'])
kp = ec2.create_key_pair(KeyName=os.environ['KEY_PAIR_NAME'])
os.makedirs(os.path.dirname(path), exist_ok=True)
# Move any existing (0400) key aside first: a read-only .pem would make
# open('w') raise PermissionError, and this preserves a still-needed key.
if os.path.exists(path):
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    os.replace(path, path + '.bak')
    print('     Previous private key backed up to ' + path + '.bak')
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as f:
    f.write(kp['KeyMaterial'])
os.chmod(path, 0o400)
print('     New key pair created; private key saved: ' + path)
PYEOF
}
_kp_delete() {   # delete the AWS pair (no error if it doesn't exist)
    python3 - <<'PYEOF'
import os, boto3
ec2 = boto3.client('ec2', region_name=os.environ.get('AWS_DEFAULT_REGION', 'us-east-1'))
ec2.delete_key_pair(KeyName=os.environ['KEY_PAIR_NAME'])
print('     Deleted AWS key pair: ' + os.environ['KEY_PAIR_NAME'])
PYEOF
}
_kp_import() {   # import the local public key into AWS as the key pair
    KEY_PATH="$KEY_FILE" python3 - <<'PYEOF'
import os, subprocess, boto3
ec2 = boto3.client('ec2', region_name=os.environ.get('AWS_DEFAULT_REGION', 'us-east-1'))
pub = subprocess.check_output(['ssh-keygen', '-y', '-P', '', '-f', os.path.expanduser(os.environ['KEY_PATH'])])
ec2.import_key_pair(KeyName=os.environ['KEY_PAIR_NAME'], PublicKeyMaterial=pub)
print('     Imported local public key into AWS key pair: ' + os.environ['KEY_PAIR_NAME'])
PYEOF
}

# ── assess current state (local .pem? AWS pair? do they match?) ───────────────
_lpub="$(_local_pubkey)"
_apub="$(_aws_pubkey)"
[[ -n "$_lpub" ]] && info "Local key : $KEY_FILE  (present)" || info "Local key : $KEY_FILE  (absent)"
case "$_apub" in
    __ABSENT__)  info "AWS pair  : '$KEY_PAIR_NAME' does not exist yet" ;;
    __ERROR__:*) warn "AWS pair  : could not check (${_apub#__ERROR__:})" ;;
    "")          warn "AWS pair  : could not check" ;;
    *)           info "AWS pair  : '$KEY_PAIR_NAME' exists" ;;
esac

# ── recommended (default) action based on the state above ─────────────────────
if [[ -n "$_lpub" ]]; then
    if   [[ "$_apub" == "$_lpub" ]];                   then _rec=use;      _rl="Use current key — it matches AWS '$KEY_PAIR_NAME'"
    elif [[ "$_apub" == "__ABSENT__" ]];               then _rec=import;   _rl="Import your local key into AWS as '$KEY_PAIR_NAME'"
    elif [[ "$_apub" == __ERROR__:* || -z "$_apub" ]]; then _rec=use;      _rl="Use current key (couldn't verify the AWS pair)"
    else                                                    _rec=reimport; _rl="Replace AWS '$KEY_PAIR_NAME' with your local key (they currently MISMATCH)"
    fi
else
    if   [[ "$_apub" == "__ABSENT__" ]];               then _rec=create;   _rl="Create a new '$KEY_PAIR_NAME' pair and save the .pem locally"
    elif [[ "$_apub" == __ERROR__:* || -z "$_apub" ]]; then _rec=create;   _rl="Create a new '$KEY_PAIR_NAME' pair"
    else                                                    _rec=recreate; _rl="AWS '$KEY_PAIR_NAME' exists but you have no .pem — delete & recreate it"
    fi
fi

if st_done STEP_6 && [[ "$_rec" == "use" ]]; then
    # Resume fast-path: EC2 already provisioned and the local key already matches
    # the AWS pair — keep it without prompting (still verified below).
    info "EC2 already provisioned and key matches AWS '$KEY_PAIR_NAME' — keeping it (no prompt)."
    _kopt=1
else
    echo "     Options:"
    echo "       1) ${_rl}  (recommended)"
    echo "       2) Create a BRAND-NEW pair — deletes any existing AWS '$KEY_PAIR_NAME' and overwrites local .pem"
    echo "       3) Use a different existing .pem file"
    echo "       4) Use a different key pair name (currently: '$KEY_PAIR_NAME')"
    ask _kopt "Choice" "1"
fi
case "${_kopt:-1}" in
    2) _action=recreate ;;
    3) _action=path ;;
    4) _action=rename ;;
    *) _action="$_rec" ;;
esac

# ── execute the chosen action ─────────────────────────────────────────────────
case "$_action" in
    use)
        ok "Using existing key: $KEY_FILE" ;;
    import)
        if _kp_import; then ok "Local key imported to AWS '$KEY_PAIR_NAME'."
        else die "import-key-pair failed (check IAM permission ec2:ImportKeyPair)."; fi ;;
    reimport)
        info "Replacing AWS '$KEY_PAIR_NAME' so it matches your local key ..."
        _kp_delete || true
        if _kp_import; then ok "AWS '$KEY_PAIR_NAME' now matches your local key."
        else die "import-key-pair failed."; fi ;;
    create)
        if _kp_create; then ok "Key pair created."
        else die "create-key-pair failed (does '$KEY_PAIR_NAME' already exist? use option 2)."; fi ;;
    recreate)
        if [[ -n "$_lpub" && "$_apub" == "$_lpub" ]]; then
            warn "Your current key matches AWS '$KEY_PAIR_NAME' and may be in use by running instances."
            warn "After recreating, any instance already running on it is reachable ONLY via EC2 Instance Connect."
        fi
        info "The current .pem (if any) will be backed up to ${KEY_FILE}.bak before being replaced."
        confirm "Delete the AWS pair and create a brand-new one?" N || die "Aborted key recreation."
        _kp_delete || true
        if _kp_create; then ok "Fresh key pair created; previous key (if any) saved to ${KEY_FILE}.bak."
        else die "create-key-pair failed."; fi ;;
    path)
        ask KEY_FILE "Path to .pem file"
        KEY_FILE="${KEY_FILE/#\~/$HOME}"
        KEY_FILE="${KEY_FILE//.pem.pem/.pem}"   # collapse an accidental double .pem
        [[ -f "$KEY_FILE" ]] || die "File not found: $KEY_FILE"
        _lpub="$(_local_pubkey)"; _apub="$(_aws_pubkey)"
        if [[ -z "$_lpub" ]]; then
            warn "Couldn't read a public key from $KEY_FILE (passphrase-protected?)."
        elif [[ "$_apub" == "$_lpub" ]]; then
            ok "This key matches AWS '$KEY_PAIR_NAME'."
        elif [[ "$_apub" == "__ABSENT__" ]]; then
            info "AWS '$KEY_PAIR_NAME' absent — importing this key."
            _kp_import || die "import-key-pair failed."
        elif [[ "$_apub" == __ERROR__:* || -z "$_apub" ]]; then
            warn "Couldn't verify against AWS (${_apub#__ERROR__:})."
        else
            warn "This .pem does NOT match AWS '$KEY_PAIR_NAME'."
            if confirm "Replace the AWS pair with this key?" Y; then
                _kp_delete || true; _kp_import || die "import-key-pair failed."
                ok "AWS '$KEY_PAIR_NAME' now matches this key."
            fi
        fi
        ok "Using key: $KEY_FILE" ;;
    rename)
        ask KEY_PAIR_NAME "New key pair name (no file extension)" "$KEY_PAIR_NAME"
        # An AWS key pair name must NOT include a file extension. Strip a trailing
        # .pem/.pub if the user typed one, otherwise the default .pem path doubles
        # to 'name.pem.pem' and the instance launches with the wrong pair name.
        KEY_PAIR_NAME="${KEY_PAIR_NAME%.pem}"; KEY_PAIR_NAME="${KEY_PAIR_NAME%.pub}"
        export KEY_PAIR_NAME
        _default_pem="$HOME/.ssh/${KEY_PAIR_NAME}.pem"
        ask KEY_FILE "Path to .pem file for '${KEY_PAIR_NAME}'" "$_default_pem"
        KEY_FILE="${KEY_FILE/#\~/$HOME}"
        KEY_FILE="${KEY_FILE//.pem.pem/.pem}"   # collapse an accidental double .pem
        if [[ ! -f "$KEY_FILE" ]]; then
            warn "File not found: $KEY_FILE — ensure it is accessible before Step 6."
        else
            _lpub="$(_local_pubkey)"; _apub="$(_aws_pubkey)"
            if [[ -n "$_lpub" && "$_apub" == "$_lpub" ]]; then
                ok "Key pair '$KEY_PAIR_NAME' exists in AWS and matches local .pem."
            elif [[ "$_apub" == "__ABSENT__" ]]; then
                info "AWS key pair '$KEY_PAIR_NAME' not found — importing local key ..."
                _kp_import || die "import-key-pair failed."
                ok "Local key imported to AWS as '$KEY_PAIR_NAME'."
            elif [[ "$_apub" == __ERROR__:* || -z "$_apub" ]]; then
                warn "Couldn't verify against AWS (${_apub#__ERROR__:}) — proceeding."
            else
                warn "Local .pem does NOT match AWS '$KEY_PAIR_NAME'."
                if confirm "Replace the AWS pair with this local key?" Y; then
                    _kp_delete || true; _kp_import || die "import-key-pair failed."
                    ok "AWS '$KEY_PAIR_NAME' now matches your local key."
                fi
            fi
        fi
        ok "Key pair name: '$KEY_PAIR_NAME'   Key file: $KEY_FILE" ;;
esac
# Final safety net: never persist a doubled .pem extension.
KEY_FILE="${KEY_FILE//.pem.pem/.pem}"
st_set KEY_FILE "$KEY_FILE"

# ── final safety check: the local key MUST match the AWS pair before Step 6 ────
# Instances launch with KeyName=$KEY_PAIR_NAME; a mismatch here means certain
# lockout ("Permission denied (publickey)") and EC2-Instance-Connect recovery.
_lpub="$(_local_pubkey)"; _apub="$(_aws_pubkey)"
if [[ -z "$_lpub" ]]; then
    warn "Cannot read local public key (passphrase-protected?) — cannot verify it matches AWS '$KEY_PAIR_NAME'."
    confirm "Continue without verifying the key match (risk of lockout)?" N || die "Resolve the unreadable .pem, then re-run."
elif [[ "$_apub" == "$_lpub" ]]; then
    ok "Verified: local key matches AWS '$KEY_PAIR_NAME' — SSH will work after provisioning."
elif [[ "$_apub" == "__ABSENT__" || -z "$_apub" ]]; then
    warn "AWS '$KEY_PAIR_NAME' still not present — Step 6 would fail with InvalidKeyPair.NotFound."
    confirm "Continue anyway?" N || die "Resolve the key pair, then re-run."
elif [[ "$_apub" == __ERROR__:* ]]; then
    warn "Could not verify key match (${_apub#__ERROR__:}) — proceeding without the guard."
else
    warn "Local key still does NOT match AWS '$KEY_PAIR_NAME' — you would be locked out."
    confirm "Continue anyway (recovery needs EC2 Instance Connect)?" N || die "Resolve the key mismatch, then re-run."
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6 — Provision EC2
# ══════════════════════════════════════════════════════════════════════════════
header 6 "Provision EC2 Infrastructure"

PUBLIC_IP="$(st_get PUBLIC_IP)"

if should_run STEP_6 "EC2 provisioned (IP: ${PUBLIC_IP:-none})"; then
    echo "     This creates: IAM role, security group (22/80/443),"
    echo "     EC2 t3.large + 30 GB gp3, and an Elastic IP — in region ${REGION}."
    echo
    echo "     Options:"
    echo "       1) Run deploy_aws_ec2.py now  (default)"
    echo "       2) Enter an existing EC2 IP   (skip provisioning)"
    ask _popt "Choice" "1"

    if [[ "${_popt:-1}" == "1" ]]; then
        info "Running deploy_aws_ec2.py in region ${REGION} (TF: ${TF_SCRIPT}) ..."
        # REGION and TF_SCRIPT are exported so deploy_aws_ec2.py branches correctly.
        TF_SCRIPT="$(st_get TF_SCRIPT)"
        _out=$(REGION="$REGION" TF_SCRIPT="$TF_SCRIPT" python3 "$SCRIPT_DIR/deploy_aws_ec2.py" 2>&1 | tee /dev/stderr)
        PUBLIC_IP=$(echo "$_out" | grep -E "Public IP" | head -1 | awk '{print $NF}')
        [[ -n "$PUBLIC_IP" ]] || die "Could not capture Public IP from deploy_aws_ec2.py output."
    else
        ask_host PUBLIC_IP "Existing EC2 Public IP" "${PUBLIC_IP:-}"
    fi
    st_set PUBLIC_IP "$PUBLIC_IP"
    st_set STEP_6 "done"
    ok "EC2 ready. Public IP: $PUBLIC_IP"
fi

# Reload from state (in case the step was skipped)
PUBLIC_IP="$(st_get PUBLIC_IP)"
KEY_FILE="$(st_get KEY_FILE)"
[[ -n "$PUBLIC_IP" ]] || die "PUBLIC_IP not set — re-run step 6."
[[ -n "$KEY_FILE"  ]] || die "KEY_FILE not set — re-run step 5."
info "IP: $PUBLIC_IP   Key: $KEY_FILE   Region: $REGION"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7 — Update CLIENT_DOMAIN with real IP
# ══════════════════════════════════════════════════════════════════════════════
header 7 "Update CLIENT_DOMAIN in Secrets"

if should_run STEP_7 "CLIENT_DOMAIN updated"; then
    _cur=$(python3 -c "import json,os; print(json.load(open(os.environ['SCRIPT_DIR']+'/cloudpi-secrets.json')).get('CLIENT_DOMAIN',''))")
    info "Current CLIENT_DOMAIN: $_cur"
    ask_host _new_domain "Set CLIENT_DOMAIN to" "$PUBLIC_IP"
    NEW_DOMAIN="$_new_domain" python3 - <<'PYEOF'
import json, os
p = os.environ['SCRIPT_DIR'] + '/cloudpi-secrets.json'
d = json.load(open(p))
d['CLIENT_DOMAIN'] = os.environ['NEW_DOMAIN']
open(p, 'w').write(json.dumps(d, indent=2))
print("     Updated CLIENT_DOMAIN -> " + os.environ['NEW_DOMAIN'])
PYEOF
    st_set STEP_7 "done"
    ok "CLIENT_DOMAIN = ${_new_domain}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 8 — Wait for EC2 Bootstrap (~3-5 min)
# ══════════════════════════════════════════════════════════════════════════════
header 8 "Wait for EC2 Bootstrap"

if should_run STEP_8 "bootstrap complete"; then
    info "Polling for /var/log/cloudpi-bootstrap-done on $PUBLIC_IP ..."
    info "SSH check: ssh -i $KEY_FILE cloudpiadmin@${PUBLIC_IP} '[ -f /var/log/cloudpi-bootstrap-done ]'"
    _n=0; _max=10; _start=$SECONDS
    until ssh -n -i "$KEY_FILE" "${SSH_OPTS[@]}" "cloudpiadmin@${PUBLIC_IP}" \
        "[ -f /var/log/cloudpi-bootstrap-done ]" 2>/dev/null; do
        if (( ++_n >= _max )); then
            echo
            warn "Bootstrap has not completed after ${_max} min (or the SSH check is failing)."
            info "Debug: ssh -i $KEY_FILE cloudpiadmin@${PUBLIC_IP} '[ -f /var/log/cloudpi-bootstrap-done ] && echo done || echo missing'"
            info "Enter minutes to extend, or 0 to mark complete if you've verified bootstrap manually."
            ask _extend "Extend wait by how many minutes?" "10"
            _extra=${_extend:-10}
            if (( _extra == 0 )); then
                warn "Marking bootstrap complete based on manual verification."
                break
            fi
            _max=$(( _max + _extra ))
            info "Extended timeout — will wait up to ${_max} min total."
        fi

        _elapsed=$(( SECONDS - _start ))
        _em=$(( _elapsed / 60 )); _es=$(( _elapsed % 60 ))
        printf "     [%02d:%02d elapsed] Attempt %d/%d — not done yet, next check in 60s\n" \
            "$_em" "$_es" "$_n" "$_max"

        if ssh -n -i "$KEY_FILE" "${SSH_OPTS[@]}" "cloudpiadmin@${PUBLIC_IP}" "echo ok" 2>/dev/null | grep -q ok; then
            info "  → SSH connection OK — bootstrap is still running on EC2"
        else
            warn "  → Bootstrap of EC2 in progress — SSH not yet available"
        fi

        info "  → Last line of /var/log/cloudpi-bootstrap.log on EC2:"
        ssh -n -i "$KEY_FILE" "${SSH_OPTS[@]}" "cloudpiadmin@${PUBLIC_IP}" \
            "sudo tail -1 /var/log/cloudpi-bootstrap.log 2>/dev/null || echo '(log not yet available)'" \
            2>/dev/null | sed 's/^/       /' || true

        sleep 60
    done
    echo
    ok "Bootstrap complete."
    st_set STEP_8 "done"
fi

# ── Ensure cloudpiadmin has passwordless sudo ─────────────────────────────────
# All subsequent SSH steps run sudo non-interactively; this check runs once
# after bootstrap and auto-fixes via the ubuntu user (same key, always NOPASSWD).
info "Checking passwordless sudo for cloudpiadmin ..."
if ssh_run "sudo -n true" 2>/dev/null; then
    ok "cloudpiadmin already has passwordless sudo."
else
    warn "cloudpiadmin requires a sudo password — granting NOPASSWD via ubuntu ..."
    ssh -n -i "$KEY_FILE" "${SSH_OPTS[@]}" "ubuntu@${PUBLIC_IP}" \
        "echo 'cloudpiadmin ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/cloudpiadmin > /dev/null && sudo chmod 440 /etc/sudoers.d/cloudpiadmin"
    ssh_run "sudo -n true" || die "Failed to grant passwordless sudo to cloudpiadmin. Check the instance manually."
    ok "Passwordless sudo granted to cloudpiadmin."
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 9 — Upload Secrets to AWS Secrets Manager
# ══════════════════════════════════════════════════════════════════════════════
header 9 "Upload Secrets to AWS Secrets Manager"

if should_run STEP_9 "secrets uploaded"; then
    # --region is passed explicitly so the upload region matches the EC2 region.
    with_spinner "Uploading secrets to AWS Secrets Manager (region ${REGION})" \
        python3 "$SCRIPT_DIR/setup_aws_secrets.py" upload --region "$REGION" --file "$SECRETS_JSON" \
        || die "Secrets upload failed — see output above."
    st_set STEP_9 "done"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 10 — Configure EC2 Instance (via SSH)
# ══════════════════════════════════════════════════════════════════════════════
header 10 "Configure EC2 Instance"

# ── 10a  Deploy type ──────────────────────────────────────────────────────────
if should_run STEP_10A "install type chosen"; then
    echo "     Install type:"
    echo "       1) Fresh install — git clone from GitHub  (default)"
    echo "       2) Migration     — rsync from existing server"
    echo "       3) Upload local cloudpi-files folder → EC2"
    ask _dt "Choice" "1"
    st_set DEPLOY_TYPE "${_dt:-1}"
    st_set STEP_10A "done"
fi
DEPLOY_TYPE="$(st_get DEPLOY_TYPE)"; DEPLOY_TYPE="${DEPLOY_TYPE:-1}"

# ── 10b  Copy / clone files ───────────────────────────────────────────────────
if should_run STEP_10B "files on EC2"; then
    # Always ensure the target directory exists and is owned by cloudpiadmin,
    # regardless of install type (fixes the case where a fresh git clone fails).
    ssh_in bash -s <<'REMOTE'
sudo mkdir -p /home/cloudpiadmin/cloudpi/certs
sudo chown -R cloudpiadmin:cloudpiadmin /home/cloudpiadmin/cloudpi
REMOTE

    if [[ "$DEPLOY_TYPE" == "3" ]]; then
        info "=== Upload local cloudpi-files → EC2 /home/cloudpiadmin/cloudpi ==="
        # Re-prompt until we get a real app-bundle folder. Guards against the
        # common mistake of pointing this at the deploy toolkit directory itself
        # (which would rsync deploy_interactive.sh, the .py scripts, state files,
        # etc. onto the instance instead of the CloudPi app files).
        while true; do
            ask _local_src "Local source folder (the cloudpi-files app bundle)" "$SCRIPT_DIR/cloudpi-files"
            _local_src="${_local_src/#\~/$HOME}"
            _local_src="${_local_src%/}"   # strip any trailing slash

            if [[ ! -d "$_local_src" ]]; then
                warn "Folder not found: $_local_src — try again."
                continue
            fi
            # Refuse the deploy toolkit dir (identified by deploy_interactive.sh).
            if [[ -e "$_local_src/deploy_interactive.sh" ]]; then
                warn "That is the deploy toolkit folder, not the CloudPi app bundle."
                warn "Point this at the 'cloudpi-files' folder (contains docker-compose.yml)."
                continue
            fi
            # Sanity-check it looks like the app bundle.
            if [[ ! -e "$_local_src/docker-compose.yml" ]]; then
                warn "No docker-compose.yml in $_local_src — this may not be the app bundle."
                confirm "Upload it anyway?" N || continue
            fi
            break
        done

        info "Uploading $_local_src → cloudpiadmin@${PUBLIC_IP}:/home/cloudpiadmin/cloudpi/ ..."
        rsync -az \
            --exclude='.git/' \
            --exclude='.DS_Store' \
            --exclude='*.bak' \
            --exclude='__pycache__/' \
            --exclude='*.pyc' \
            -e "ssh -i $KEY_FILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PasswordAuthentication=no -o ConnectTimeout=15 -o LogLevel=ERROR" \
            "$_local_src/" \
            "cloudpiadmin@${PUBLIC_IP}:/home/cloudpiadmin/cloudpi/"

        # Restore cert ownership for the container (must be UID 1000)
        ssh_run "sudo chown -R cloudpiadmin:cloudpiadmin /home/cloudpiadmin/cloudpi && \
                 sudo chown -R 1000:1000 /home/cloudpiadmin/cloudpi/certs"
        ok "Files uploaded from $_local_src."

    elif [[ "$DEPLOY_TYPE" == "2" ]]; then
        info "=== Migration path: existing server → EC2 ==="
        ask_host _az_ip   "Existing server public IP"       ""
        ask      _az_user "Existing server SSH username"    ""
        ask      _az_key  "Path to existing server SSH key" ""
        _az_key="${_az_key/#\~/$HOME}"
        [[ -f "$_az_key" ]] || die "SSH key not found: $_az_key"

        info "Copying existing-server key to EC2 ..."
        scp_up "$_az_key" "/home/cloudpiadmin/.ssh/migration_key"
        ssh_run "chmod 400 ~/.ssh/migration_key"

        info "Rsyncing from existing server → EC2 (may take a few minutes) ..."
        ssh_in "AZ_USER='$_az_user' AZ_IP='$_az_ip' bash -s" <<'REMOTE'
set -euo pipefail
sudo mkdir -p /home/cloudpiadmin/cloudpi
sudo rsync -avz -e "ssh -i /home/cloudpiadmin/.ssh/migration_key -o StrictHostKeyChecking=no" \
    "${AZ_USER}@${AZ_IP}:/home/${AZ_USER}/cloudpi/" \
    /home/cloudpiadmin/cloudpi/
sudo chown -R cloudpiadmin:cloudpiadmin /home/cloudpiadmin/cloudpi
REMOTE
        ok "Files migrated from existing server."

    else
        info "=== Fresh install: git clone the app bundle ==="
        ssh_in bash -s <<'REMOTE'
set -euo pipefail
DEST=/home/cloudpiadmin/cloudpi
if [ -e "$DEST/docker-compose.yml" ]; then
    echo "     CloudPi files already present — skipping clone."
else
    TMP=$(sudo -u cloudpiadmin mktemp -d)
    if sudo -u cloudpiadmin git clone --depth 1 \
         https://github.com/PurpleDataInc-TX/AWS_EC2-Deploy.git "$TMP/repo" 2>/dev/null; then
        # The APP BUNDLE lives in the repo's cloudpi-files/ subdir. Copy ONLY that
        # (not the deploy toolkit at the repo root — deploy_interactive.sh, the
        # .py scripts, Install from EC2/, etc.) so the app dir stays clean and the
        # compose/.env land at the top level where the app expects them.
        if [ -d "$TMP/repo/cloudpi-files" ]; then
            sudo -u cloudpiadmin cp -rn "$TMP/repo/cloudpi-files/." "$DEST/"
            echo "     Copied app bundle from repo cloudpi-files/."
        elif [ -e "$TMP/repo/docker-compose.yml" ]; then
            sudo -u cloudpiadmin cp -rn "$TMP/repo/." "$DEST/"
            echo "     Copied app files from repo root."
        else
            echo "     WARNING: no docker-compose.yml in the repo — steps 10c/10d will generate one."
        fi
        sudo rm -rf "$TMP"
    else
        echo "     (git clone failed — generated files in steps 10c/10d will be used.)"
    fi
fi
REMOTE
        ok "CloudPi directory ready."
    fi

    # ── Mandatory: cp_upgrade.sh must be on the server for future upgrades ─────
    # Uploaded explicitly (not left to the install-type path) so it is ALWAYS
    # present regardless of type 1/2/3.
    _cpupg="$SCRIPT_DIR/cloudpi-files/cp_upgrade.sh"
    if [[ -f "$_cpupg" ]]; then
        scp_up "$_cpupg" "/tmp/cp_upgrade.sh"
        ssh_run "sudo mv /tmp/cp_upgrade.sh /home/cloudpiadmin/cloudpi/cp_upgrade.sh && \
                 sudo chown cloudpiadmin:cloudpiadmin /home/cloudpiadmin/cloudpi/cp_upgrade.sh && \
                 sudo chmod 755 /home/cloudpiadmin/cloudpi/cp_upgrade.sh"
        ok "cp_upgrade.sh installed at /home/cloudpiadmin/cloudpi/cp_upgrade.sh (executable)."
    else
        die "Required file not found: $_cpupg — cp_upgrade.sh is mandatory for upgrades."
    fi

    st_set STEP_10B "done"
fi

# ── 10c  docker-compose.yml ───────────────────────────────────────────────────
if should_run STEP_10C "docker-compose.yml configured"; then
    info "Current image tags on EC2:"
    ssh_run "grep 'image:' /home/cloudpiadmin/cloudpi/docker-compose.yml 2>/dev/null || echo '     (none found)'"
    echo
    echo "     Options:"
    echo "       1) Generate new docker-compose.yml from template  (default)"
    echo "       2) Update image tags only in existing docker-compose.yml"
    echo "       3) Skip"
    ask _copt "Choice" "1"

    if [[ "${_copt:-1}" == "3" ]]; then
        ok "docker-compose.yml step skipped."
    else
        ask _ver "Target release version (e.g. v1.1.048)" "v1.1.048"
        [[ "$_ver" =~ ^v?[0-9]+(\.[0-9]+)*$ ]] || warn "Version '${_ver}' looks unusual — continuing anyway."

        if [[ "${_copt:-1}" == "2" ]]; then
            info "Updating image tags in existing docker-compose.yml to ${_ver} ..."
            ssh_in "VER='$_ver' bash -s" <<'REMOTE'
set -euo pipefail
FILE=/home/cloudpiadmin/cloudpi/docker-compose.yml
if [ ! -f "$FILE" ]; then
    echo "ERROR: docker-compose.yml not found at $FILE" >&2
    exit 1
fi
sudo sed -i "s|cloudpi1/cloudpi:Cloudpi_db_[a-zA-Z0-9._-]*|cloudpi1/cloudpi:Cloudpi_db_${VER}|g" "$FILE"
sudo sed -i "/Cloudpi_db_/!s|cloudpi1/cloudpi:Cloudpi_[a-zA-Z0-9._-]*|cloudpi1/cloudpi:Cloudpi_${VER}|g" "$FILE"
echo "     Updated tags:"
grep 'image:' "$FILE"
REMOTE
            ok "Image tags updated to ${_ver}."
        else
            _compose_tmp=$(mktemp /tmp/cloudpi-compose.XXXXXX.yml)
            cat > "$_compose_tmp" <<COMPOSE
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
    image: cloudpi1/cloudpi:Cloudpi_db_${_ver}
    container_name: cloudpi-db
    restart: unless-stopped
    env_file:
      - .env
      - /run/secrets-tmp/cloudpi.secrets
    volumes:
      - cloudpi_db_data:/var/lib/mysql
    networks:
      - cloudpi_network
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5

  app:
    image: cloudpi1/cloudpi:Cloudpi_${_ver}
    container_name: cloudpi-app
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    env_file:
      - .env
      - /run/secrets-tmp/cloudpi.secrets
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
COMPOSE

            scp_up "$_compose_tmp" "/tmp/docker-compose.yml"
            rm -f "$_compose_tmp"
            ssh_run "sudo mv /tmp/docker-compose.yml /home/cloudpiadmin/cloudpi/docker-compose.yml && \
                     sudo chown cloudpiadmin:cloudpiadmin /home/cloudpiadmin/cloudpi/docker-compose.yml"
            ok "docker-compose.yml generated (version: ${_ver})."
        fi
    fi
    st_set STEP_10C "done"
fi

# ── 10d  .env file ────────────────────────────────────────────────────────────
# MERGE (not overwrite): if a .env was uploaded with the app bundle (deploy type
# 3) it carries app config (CLIENT_*, WORKERS, DB_*, intervals, ...). We must
# keep those and only set/fix the deploy-critical keys — HOST/SUBDOMAIN to this
# instance, HTTPS on, and the cert paths to the .pem files step 10e actually
# creates (bundle templates often ship .crt/.key paths that don't exist here).
if should_run STEP_10D ".env file"; then
    ssh_in "HOSTVAL='$PUBLIC_IP' bash -s" <<'REMOTE'
set -euo pipefail
ENV=/home/cloudpiadmin/cloudpi/.env
sudo touch "$ENV"
# set_kv KEY VALUE — replace an existing KEY= line, else append it.
set_kv() {
    local k="$1" v="$2"
    if sudo grep -qE "^[[:space:]]*${k}=" "$ENV"; then
        sudo sed -i "s#^[[:space:]]*${k}=.*#${k}=${v}#" "$ENV"
    else
        printf '%s=%s\n' "$k" "$v" | sudo tee -a "$ENV" >/dev/null
    fi
}
set_kv HOST           "$HOSTVAL"
set_kv HTTPS          true
set_kv SUBDOMAIN      "$HOSTVAL"
set_kv CERT_PATH      /home/certs/cert.pem
set_kv KEY_PATH       /home/certs/privkey.pem
set_kv CA_BUNDLE_PATH /home/certs/ca_bundle.pem
sudo chown cloudpiadmin:cloudpiadmin "$ENV"
echo ".env merged (deploy-critical keys set; existing app config preserved)."
REMOTE
    ok ".env configured (merged with uploaded bundle, if any)."
    st_set STEP_10D "done"
fi

# ── 10e  TLS certificates (self-signed or Let's Encrypt) ─────────────────────
if should_run STEP_10E "TLS certificates"; then
    echo "     TLS certificate options:"
    echo "       1) Self-signed for the EC2 IP   (default; browser shows a warning)"
    echo "       2) Let's Encrypt for a domain   (trusted cert; needs a domain pointing to ${PUBLIC_IP})"
    ask _tlsopt "Choice" "1"

    if [[ "${_tlsopt:-1}" == "2" ]]; then
        # ── Let's Encrypt (trusted cert for a real domain) ────────────────────
        ask_host _le_domain "Domain name (its A record must point to ${PUBLIC_IP})" ""
        ask      _le_email  "Email for Let's Encrypt renewal notices"              ""
        [[ -n "$_le_domain" && -n "$_le_email" ]] || die "Domain and email are required for Let's Encrypt."

        # DNS sanity check (warn-only; requires the domain to resolve to this IP).
        _resolved=$(dig +short "$_le_domain" A 2>/dev/null | tail -1 || true)
        if [[ -n "$_resolved" && "$_resolved" != "$PUBLIC_IP" ]]; then
            warn "DNS: ${_le_domain} resolves to ${_resolved}, not ${PUBLIC_IP}."
            warn "Let's Encrypt HTTP validation will fail until the A record points to ${PUBLIC_IP}."
            confirm "Continue anyway?" N || die "Point ${_le_domain} at ${PUBLIC_IP}, then re-run step 10e."
        elif [[ -z "$_resolved" ]]; then
            warn "Could not resolve ${_le_domain} locally — make sure its A record points to ${PUBLIC_IP}."
        fi

        info "Requesting Let's Encrypt certificate for ${_le_domain} (certbot --standalone, port 80) ..."
        # certbot --standalone binds port 80 for the ACME HTTP-01 challenge. The
        # app stack starts later (step 10h), so port 80 is free here, and the
        # security group already allows 80 inbound.
        if ssh_in "REGION='$REGION' DOMAIN='$_le_domain' EMAIL='$_le_email' bash -s" <<'REMOTE'
set -euo pipefail
CERTS=/home/cloudpiadmin/cloudpi/certs
ENV=/home/cloudpiadmin/cloudpi/.env

# Free port 80 for the standalone ACME challenge. On a fresh deploy nothing is
# bound yet (the app starts in step 10h); on a re-run the app may hold :80, so
# stop it first. An EXIT trap guarantees it comes back even if certbot fails
# (otherwise 'set -e' would leave a running site down on a failed renewal).
APP_WAS_UP=0
restore_app() {
    [ "$APP_WAS_UP" = "1" ] && { cd /home/cloudpiadmin/cloudpi && sudo docker compose up -d >/dev/null 2>&1 || true; }
}
trap restore_app EXIT
if sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -qx cloudpi-app; then
    APP_WAS_UP=1
    sudo docker stop cloudpi-app >/dev/null 2>&1 || true
fi

sudo certbot certonly --standalone --non-interactive --agree-tos \
    --preferred-challenges http -m "$EMAIL" -d "$DOMAIN" --keep-until-expiring

LE=/etc/letsencrypt/live/"$DOMAIN"
sudo mkdir -p "$CERTS"
# The app entrypoint builds fullchain from CERT_PATH + CA_BUNDLE_PATH, so map:
#   cert.pem      = leaf cert        (LE cert.pem)
#   ca_bundle.pem = intermediate(s)  (LE chain.pem)
#   privkey.pem   = private key      (LE privkey.pem)
sudo cp "$LE/cert.pem"    "$CERTS/cert.pem"
sudo cp "$LE/chain.pem"   "$CERTS/ca_bundle.pem"
sudo cp "$LE/privkey.pem" "$CERTS/privkey.pem"
sudo chown -R 1000:1000 "$CERTS"
sudo chmod 644 "$CERTS/cert.pem" "$CERTS/ca_bundle.pem"
sudo chmod 640 "$CERTS/privkey.pem"

# Serve on the domain so the host matches the certificate CN/SAN.
if [ -f "$ENV" ]; then
    sudo sed -i "s#^HOST=.*#HOST=${DOMAIN}#"           "$ENV"
    sudo sed -i "s#^SUBDOMAIN=.*#SUBDOMAIN=${DOMAIN}#" "$ENV"
fi

# Keep CLIENT_DOMAIN (used for app origin URLs) in Secrets Manager aligned.
# Best-effort: the cert is already installed, so a Secrets Manager hiccup here
# must not fail the whole TLS step (set -e would otherwise abort).
if SM=$(/usr/local/bin/aws secretsmanager get-secret-value \
        --region "$REGION" --secret-id cloudpi-secrets --query SecretString --output text 2>/dev/null) \
   && NEW=$(printf '%s' "$SM" | DOMAIN="$DOMAIN" python3 -c \
        "import json,sys,os; d=json.load(sys.stdin); d['CLIENT_DOMAIN']=os.environ['DOMAIN']; print(json.dumps(d))") \
   && /usr/local/bin/aws secretsmanager put-secret-value \
        --region "$REGION" --secret-id cloudpi-secrets --secret-string "$NEW" >/dev/null 2>&1; then
    echo "CLIENT_DOMAIN updated to ${DOMAIN} in Secrets Manager."
else
    echo "WARN: could not update CLIENT_DOMAIN in Secrets Manager — set it manually if needed."
fi

# Auto-renewal: on each renewal, redeploy the cert into the app dir + restart.
sudo mkdir -p /etc/letsencrypt/renewal-hooks/deploy
sudo tee /etc/letsencrypt/renewal-hooks/deploy/cloudpi-cert.sh >/dev/null <<HOOKEOF
#!/bin/bash
set -euo pipefail
LE=/etc/letsencrypt/live/${DOMAIN}
CERTS=/home/cloudpiadmin/cloudpi/certs
cp "\$LE/cert.pem"    "\$CERTS/cert.pem"
cp "\$LE/chain.pem"   "\$CERTS/ca_bundle.pem"
cp "\$LE/privkey.pem" "\$CERTS/privkey.pem"
chown -R 1000:1000 "\$CERTS"
cd /home/cloudpiadmin/cloudpi && docker compose restart app || true
HOOKEOF
sudo chmod 755 /etc/letsencrypt/renewal-hooks/deploy/cloudpi-cert.sh

# The app (if it was stopped to free port 80) is restarted by the EXIT trap.
echo "Let's Encrypt certificate installed for ${DOMAIN}; auto-renewal hook created."
REMOTE
        then
            ok "Let's Encrypt certificate issued for ${_le_domain} (auto-renews via certbot timer)."
            # Mirror CLIENT_DOMAIN into the local secrets file so a later re-run of step 9 stays consistent.
            NEW_DOMAIN="$_le_domain" python3 - <<'PYEOF'
import json, os
p = os.environ['SCRIPT_DIR'] + '/cloudpi-secrets.json'
d = json.load(open(p))
d['CLIENT_DOMAIN'] = os.environ['NEW_DOMAIN']
open(p, 'w').write(json.dumps(d, indent=2))
print("     Local secrets CLIENT_DOMAIN -> " + os.environ['NEW_DOMAIN'])
PYEOF
        else
            warn "Let's Encrypt issuance failed — check the domain's A record and that port 80 is reachable."
            die "TLS setup incomplete. Fix DNS/port 80 and re-run step 10e, or choose self-signed."
        fi
    else
        # ── Self-signed for the EC2 IP (default) ──────────────────────────────
        info "Generating self-signed certificate for CN=${PUBLIC_IP} ..."
        ssh_in "PUBIP='$PUBLIC_IP' bash -s" <<'REMOTE'
set -euo pipefail
sudo mkdir -p /home/cloudpiadmin/cloudpi/certs
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /home/cloudpiadmin/cloudpi/certs/privkey.pem \
    -out    /home/cloudpiadmin/cloudpi/certs/cert.pem \
    -subj   "/CN=${PUBIP}" 2>&1 | tail -2
sudo cp /home/cloudpiadmin/cloudpi/certs/cert.pem \
        /home/cloudpiadmin/cloudpi/certs/ca_bundle.pem
sudo chown -R 1000:1000 /home/cloudpiadmin/cloudpi/certs
sudo chmod 644 /home/cloudpiadmin/cloudpi/certs/cert.pem
sudo chmod 640 /home/cloudpiadmin/cloudpi/certs/privkey.pem
sudo chmod 644 /home/cloudpiadmin/cloudpi/certs/ca_bundle.pem
REMOTE
        ok "Self-signed TLS certificate created."
    fi
    st_set STEP_10E "done"
fi

# ── 10f  Secrets fetch script ─────────────────────────────────────────────────
if should_run STEP_10F "secrets fetch script installed"; then
    _fetch_tmp=$(mktemp /tmp/cloudpi-fetch.XXXXXX.sh)
    # Template keeps remote $-expansions intact; __REGION__ is substituted below.
    cat > "$_fetch_tmp" <<'FETCHSCRIPT'
#!/bin/bash
set -euo pipefail

REGION="__REGION__"

mkdir -p /run/secrets-tmp
mount | grep -q secrets-tmp || mount -t tmpfs -o size=2m,mode=0700 tmpfs /run/secrets-tmp
chgrp cloudpiadmin /run/secrets-tmp
chmod 750 /run/secrets-tmp

# Single Secrets Manager call, reused for all outputs.
SECRET=$(/usr/local/bin/aws secretsmanager get-secret-value \
    --region "$REGION" --secret-id cloudpi-secrets \
    --query SecretString --output text)

printf '%s' "$SECRET" \
    | python3 -c 'import json,sys; [print(k+"="+str(v)) for k,v in json.load(sys.stdin).items()]' \
    > /run/secrets-tmp/cloudpi.secrets

printf '%s' "$SECRET" | python3 -c "
import json, sys, pathlib
d = json.load(sys.stdin)
pathlib.Path('/run/secrets-tmp/db_password').write_text(d.get('MYSQL_PASSWORD',''))
pathlib.Path('/run/secrets-tmp/db_root_password').write_text(d.get('MYSQL_ROOT_PASSWORD',''))
"

chmod 640 /run/secrets-tmp/cloudpi.secrets /run/secrets-tmp/db_password /run/secrets-tmp/db_root_password
chown cloudpiadmin:cloudpiadmin /run/secrets-tmp/cloudpi.secrets \
    /run/secrets-tmp/db_password /run/secrets-tmp/db_root_password
echo "Secrets fetched successfully."
FETCHSCRIPT

    sed -i.bak "s/__REGION__/${REGION}/" "$_fetch_tmp" && rm -f "${_fetch_tmp}.bak"

    scp_up "$_fetch_tmp" "/tmp/cloudpi-fetch-secrets.sh"
    rm -f "$_fetch_tmp"
    ssh_run "sudo mv /tmp/cloudpi-fetch-secrets.sh /usr/local/bin/cloudpi-fetch-secrets.sh && \
             sudo chmod 755 /usr/local/bin/cloudpi-fetch-secrets.sh"
    ok "Secrets fetch script installed (region: ${REGION})."
    st_set STEP_10F "done"
fi

# ── 10g  Docker Hub login ─────────────────────────────────────────────────────
if should_run STEP_10G "Docker Hub login"; then
    info "Logging in to Docker Hub (account: cloudpi1) for private images."
    _pat_file="$SCRIPT_DIR/docker-pat.txt"
    if [[ -f "$_pat_file" ]]; then
        _docker_pat=$(grep -v '^#' "$_pat_file" | grep -i 'DOCKER_PAT=' | head -1 | cut -d= -f2-)
        if [[ -n "$_docker_pat" ]]; then
            ok "Docker PAT loaded from docker-pat.txt."
        else
            warn "docker-pat.txt found but DOCKER_PAT= line is empty or missing — prompting manually."
            ask_pass _docker_pat "Docker Hub Personal Access Token"
        fi
    else
        ask_pass _docker_pat "Docker Hub Personal Access Token"
    fi
    echo "$_docker_pat" | ssh -i "$KEY_FILE" "${SSH_OPTS[@]}" "cloudpiadmin@${PUBLIC_IP}" \
        "sudo docker login -u cloudpi1 --password-stdin"
    ssh_in bash -s <<'REMOTE'
sudo mkdir -p /home/cloudpiadmin/.docker
sudo cp /root/.docker/config.json /home/cloudpiadmin/.docker/config.json
sudo chown -R cloudpiadmin:cloudpiadmin /home/cloudpiadmin/.docker
sudo chmod 600 /home/cloudpiadmin/.docker/config.json
REMOTE
    ok "Docker Hub login complete."
    st_set STEP_10G "done"
fi

# ── 10h  setup_docker_compose_service.py ─────────────────────────────────────
if should_run STEP_10H "systemd services installed"; then
    info "Uploading setup_docker_compose_service.py ..."
    scp_up "$SCRIPT_DIR/setup_docker_compose_service.py" "/tmp/setup_docker_compose_service.py"
    info "Running setup_docker_compose_service.py (installs systemd units) ..."
    # REGION exported on the remote so the unit/fetch path stays region-consistent.
    ssh_run "sudo REGION='$REGION' python3 /tmp/setup_docker_compose_service.py" || \
        warn "setup_docker_compose_service.py reported an issue — review output above."

    info "Starting cloudpi-fetch-secrets (pulls secrets from AWS Secrets Manager) ..."
    if ssh_run "sudo systemctl start cloudpi-fetch-secrets" 2>/dev/null; then
        ok "cloudpi-fetch-secrets started."
    else
        warn "cloudpi-fetch-secrets failed to start — checking logs:"
        ssh_run "sudo journalctl -u cloudpi-fetch-secrets --no-pager -n 20" 2>/dev/null || true
        warn "Verify the EC2 IAM role has Secrets Manager access and that step 9 completed."
        warn "Retry manually on EC2: sudo systemctl start cloudpi-fetch-secrets"
    fi

    # The app (Flask, UID 1000 in-container) writes its JSON log to
    # /var/log/pico, bind-mounted from the host. The dir MUST exist and be
    # writable by UID 1000 BEFORE the container starts, or Flask crash-loops
    # with 'PermissionError: /var/log/pico/app.log'. 'syslog' group lets the
    # host rsyslog tail it; fall back to UID 1000 if that group is absent.
    info "Pre-creating /var/log/pico (host log dir for the app) ..."
    ensure_log_dir \
        && ok "/var/log/pico ready (owner UID 1000)." \
        || warn "Could not set up /var/log/pico — the app may fail to write logs."

    info "Starting cloudpi-docker-compose ..."
    if ssh_run "sudo systemctl start cloudpi-docker-compose" 2>/dev/null; then
        ok "cloudpi-docker-compose started."
    else
        warn "cloudpi-docker-compose failed to start — checking logs:"
        ssh_run "sudo journalctl -u cloudpi-docker-compose --no-pager -n 20" 2>/dev/null || true
    fi

    st_set STEP_10H "done"
fi

# ── 10i  Reconcile DB password with secrets (baked-in datadir fix) ────────────
# See reconcile_db_password() near the top for the full explanation. Guarded by
# an auth probe inside the function, so it only resets when actually needed.
if should_run STEP_10I "DB password reconciled with secrets"; then
    info "Checking whether the app can authenticate to MySQL ..."
    if reconcile_db_password; then
        ok "DB password reconciled with secrets."
        st_set STEP_10I "done"
    else
        warn "Could not reconcile the DB password automatically."
        warn "Re-run this step, or reset manually with a --skip-grant-tables container."
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 11 — First Boot & Verification
# ══════════════════════════════════════════════════════════════════════════════
header 11 "First Boot & Verification"

# ── 11a  Wait for containers (with automatic self-repair) ─────────────────────
# Pass only when BOTH containers are in docker's 'healthy' set. If they don't
# become healthy in time, inspect the app log and AUTO-APPLY the matching fix
# (log-dir perms / DB-password reconcile / secrets re-fetch), then wait again —
# up to _MAX_REPAIRS rounds — so first-boot problems self-heal without a manual
# re-run of steps 10h/10i.
if should_run STEP_11A "containers healthy"; then
    _MAX_REPAIRS=3; _repair=0; _ok=0

    # _wait_healthy — poll up to ~100s; returns 0 if both healthy, 1 on timeout.
    _wait_healthy() {
        local n=0 max=10
        until ssh_run 'h=$(sudo docker ps --filter health=healthy --format "{{.Names}}" 2>/dev/null); echo "$h" | grep -qx cloudpi-db && echo "$h" | grep -qx cloudpi-app' 2>/dev/null; do
            if (( ++n >= max )); then echo; return 1; fi
            printf "\r     Attempt %d/%d — waiting for containers ..." "$n" "$max"
            sleep 10
        done
        echo; return 0
    }

    while true; do
        info "Waiting for BOTH cloudpi-db and cloudpi-app to report 'healthy' — up to ~100s ..."
        if _wait_healthy; then _ok=1; break; fi

        if (( _repair >= _MAX_REPAIRS )); then
            warn "Auto-repair exhausted after ${_MAX_REPAIRS} round(s)."
            break
        fi
        (( ++_repair ))

        # Gather signals: recent app log + fetch-secrets service state.
        _applog=$(ssh_run "sudo docker logs cloudpi-app --tail 40 2>&1" 2>/dev/null || true)
        _fetch=$(ssh_run "systemctl is-active cloudpi-fetch-secrets 2>/dev/null || echo inactive" 2>/dev/null || true)

        warn "Containers not healthy — auto-repair round ${_repair}/${_MAX_REPAIRS} ..."
        if echo "$_applog" | grep -q "PermissionError.*/var/log/pico"; then
            info "  → /var/log/pico permission error detected — fixing log dir + restarting app."
            ensure_log_dir && ok "  log dir fixed." || warn "  log dir fix failed."
            ssh_run "cd /home/cloudpiadmin/cloudpi && sudo docker compose restart app" 2>/dev/null || true
        elif echo "$_applog" | grep -qiE "access denied|mysql connection failed"; then
            info "  → DB auth failure detected — reconciling DB password with secrets."
            reconcile_db_password && ok "  DB password reconciled." || warn "  DB reconcile failed."
        elif [[ "$_fetch" != "active" ]]; then
            info "  → cloudpi-fetch-secrets not active — re-fetching secrets + re-applying stack."
            restart_fetch_secrets && ok "  secrets re-fetched." || warn "  fetch-secrets restart failed."
        else
            info "  → No known failure signature; giving the stack more time and retrying."
            sleep 10
        fi
    done

    if (( _ok )); then
        ssh_run "sudo docker ps" || true
        ok "Containers healthy."
        st_set STEP_11A "done"
    else
        warn "Timed out — both containers never became healthy. Final state:"
        ssh_run "sudo docker ps -a" || true
        warn "Auto-repair could not resolve it. Inspect 'sudo docker logs cloudpi-app'."
        warn "Manual fallbacks:"
        warn "  • cloudpi-fetch-secrets failed → re-run step 10h to reinstall the systemd unit."
        warn "  • 'Access denied'/'Waiting for MySQL' → re-run step 10i (DB password reconcile)."
        warn "  • 'PermissionError: /var/log/pico/app.log' → re-run step 10h (creates /var/log/pico)."
    fi
fi

# ── 11b  MySQL app user & privileges ──────────────────────────────────────────
# The app connects as DB_USER (from secrets — e.g. 'masteradmin' or 'cloudpiadmin').
# The prebuilt cloudpi-db image ships a pre-initialized datadir, so 'root' may be
# locked to localhost-only while a 'masteradmin' superuser exists (auth via
# MYSQL_PASSWORD). We pick whichever admin login actually works, then ensure the
# app's DB_USER exists with the right password + the privileges migrations need
# (SYSTEM_USER lets the migration system restore stored routines from backups).
if should_run STEP_11B "MySQL app user & privileges configured"; then
    info "Configuring MySQL app user + privileges ..."
    if ssh_in "REGION='$REGION' bash -s" <<'REMOTE'
set -euo pipefail
SM=$(/usr/local/bin/aws secretsmanager get-secret-value \
    --region "$REGION" --secret-id cloudpi-secrets \
    --query SecretString --output text)
DB_PW=$(printf '%s'   "$SM" | python3 -c "import json,sys; print(json.load(sys.stdin)['MYSQL_PASSWORD'])")
DB_ROOT=$(printf '%s' "$SM" | python3 -c "import json,sys; print(json.load(sys.stdin).get('MYSQL_ROOT_PASSWORD',''))")
APP_USER=$(printf '%s' "$SM" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('DB_USER') or d.get('MYSQL_USER') or 'masteradmin')")

# Find a MySQL admin login that works (image variants differ).
ADMIN_USER=""; ADMIN_PW=""
for cand in "root:$DB_ROOT" "masteradmin:$DB_PW" "masteradmin:$DB_ROOT"; do
    u="${cand%%:*}"; pw="${cand#*:}"
    [ -n "$pw" ] || continue
    if sudo docker exec -e MYSQL_PWD="$pw" cloudpi-db mysql -u "$u" -e "SELECT 1" >/dev/null 2>&1; then
        ADMIN_USER="$u"; ADMIN_PW="$pw"; break
    fi
done
[ -n "$ADMIN_USER" ] || { echo "ERROR: no working MySQL admin login (tried root + masteradmin)"; exit 1; }
echo "     Admin login: $ADMIN_USER   |   App DB user: $APP_USER"

# Escape single quotes (double them) before interpolating into SQL string
# literals, so a password/username containing a quote can't break or inject SQL.
APP_USER_SQL=${APP_USER//\'/\'\'}
DB_PW_SQL=${DB_PW//\'/\'\'}

sudo docker exec -e MYSQL_PWD="$ADMIN_PW" cloudpi-db mysql -u "$ADMIN_USER" -e "
CREATE USER IF NOT EXISTS '${APP_USER_SQL}'@'%' IDENTIFIED BY '${DB_PW_SQL}';
ALTER USER '${APP_USER_SQL}'@'%' IDENTIFIED BY '${DB_PW_SQL}';
GRANT ALL PRIVILEGES ON pidb.* TO '${APP_USER_SQL}'@'%';
GRANT PROCESS, SHOW_ROUTINE, SYSTEM_USER ON *.* TO '${APP_USER_SQL}'@'%';
FLUSH PRIVILEGES;
"
echo "     App DB user '${APP_USER}' ensured with required privileges."
REMOTE
    then
        ok "MySQL app user configured."
        st_set STEP_11B "done"
    else
        warn "MySQL user setup failed — no working admin login, or the DB isn't ready."
        info "  sudo docker exec -it cloudpi-db mysql -u masteradmin -p   # verify admin login"
        info "  sudo docker logs cloudpi-app                              # look for DB connection errors"
        warn "If the DB volume was initialized with stale passwords:"
        info "  cd /home/cloudpiadmin/cloudpi && docker compose down -v && docker compose up -d"
        warn "Then re-run this step (11b)."
    fi
fi

# ── 11c  Test login ───────────────────────────────────────────────────────────
# The app (Flask + migrations) needs ~1-2 min AFTER the container reports healthy
# before it serves the API, so poll for a couple of minutes rather than once.
if should_run STEP_11C "API login verified"; then
    info "Testing https://${PUBLIC_IP}/CPiN/v1/user/login (waiting for app warmup, up to ~2.5 min) ..."
    _http="000"
    for _i in $(seq 1 15); do
        _http=$(curl -sk -o /dev/null -w "%{http_code}" \
            -X POST "https://${PUBLIC_IP}/CPiN/v1/user/login" \
            -H 'Content-Type: application/json' \
            -d '{"email":"admin@cloudpi.ai","password":"admin123"}' || echo "000")
        [[ "$_http" == "200" ]] && break
        printf "\r     attempt %d/15 — HTTP %s, retrying in 10s ..." "$_i" "$_http"
        sleep 10
    done
    echo
    if [[ "$_http" == "200" ]]; then
        ok "Login successful (HTTP 200)."
        st_set STEP_11C "done"
    else
        warn "Login still returns HTTP $_http after warmup window — check: sudo docker logs cloudpi-app"
        info "Retry: curl -sk -X POST https://${PUBLIC_IP}/CPiN/v1/user/login -H 'Content-Type: application/json' -d '{\"email\":\"admin@cloudpi.ai\",\"password\":\"admin123\"}'"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 12 — Post-Install (optional)
# ══════════════════════════════════════════════════════════════════════════════
header 12 "Post-Install (Optional)"

if confirm "Reset the default admin@cloudpi.ai password?" N; then
    ask_pass _new_admin_pw "New admin password"
    _q_pw=$(printf '%q' "$_new_admin_pw")
    # Everything runs ON EC2: bcrypt is in the backend's node_modules (so node runs
    # with -w /app/backend), and the DB write uses whichever admin login works
    # (root is locked in the prebuilt image; masteradmin is the real admin).
    if ssh_in "REGION='$REGION' NPW=$_q_pw bash -s" <<'REMOTE'
set -euo pipefail
HASH=$(sudo docker exec -w /app/backend -e NPW="$NPW" cloudpi-app \
    node -e 'const b=require("bcrypt");b.hash(process.env.NPW,10).then(h=>console.log(h)).catch(e=>{console.error(e);process.exit(1);});')
SM=$(/usr/local/bin/aws secretsmanager get-secret-value \
    --region "$REGION" --secret-id cloudpi-secrets --query SecretString --output text)
DB_PW=$(printf '%s'   "$SM" | python3 -c "import json,sys; print(json.load(sys.stdin)['MYSQL_PASSWORD'])")
DB_ROOT=$(printf '%s' "$SM" | python3 -c "import json,sys; print(json.load(sys.stdin).get('MYSQL_ROOT_PASSWORD',''))")
ADMIN_USER=""; ADMIN_PW=""
for cand in "root:$DB_ROOT" "masteradmin:$DB_PW" "masteradmin:$DB_ROOT"; do
    u="${cand%%:*}"; pw="${cand#*:}"; [ -n "$pw" ] || continue
    if sudo docker exec -e MYSQL_PWD="$pw" cloudpi-db mysql -u "$u" -e "SELECT 1" >/dev/null 2>&1; then
        ADMIN_USER="$u"; ADMIN_PW="$pw"; break
    fi
done
[ -n "$ADMIN_USER" ] || { echo "ERROR: no working MySQL admin login"; exit 1; }
sudo docker exec -e MYSQL_PWD="$ADMIN_PW" -e ADMU="$ADMIN_USER" -e HASH="$HASH" cloudpi-db \
    sh -c 'mysql -u "$ADMU" pidb -e "UPDATE user SET password=\"$HASH\" WHERE email=\"admin@cloudpi.ai\";"'
echo "     Admin password updated (via $ADMIN_USER)."
REMOTE
    then
        ok "Admin password updated."
    else
        warn "Password reset failed (DB not ready or bcrypt unavailable). Skipping."
    fi
fi

if confirm "Update CLIENT_DOMAIN in the database?" N; then
    _cl_domain=$(python3 -c "import json,os; print(json.load(open(os.environ['SCRIPT_DIR']+'/cloudpi-secrets.json'))['CLIENT_DOMAIN'])")
    ask_host _new_cl_domain "New CLIENT_DOMAIN value" "$_cl_domain"
    _q_dom=$(printf '%q' "$_new_cl_domain")
    if ssh_in "REGION='$REGION' DOM=$_q_dom bash -s" <<'REMOTE'
set -euo pipefail
SM=$(/usr/local/bin/aws secretsmanager get-secret-value \
    --region "$REGION" --secret-id cloudpi-secrets --query SecretString --output text)
DB_PW=$(printf '%s'   "$SM" | python3 -c "import json,sys; print(json.load(sys.stdin)['MYSQL_PASSWORD'])")
DB_ROOT=$(printf '%s' "$SM" | python3 -c "import json,sys; print(json.load(sys.stdin).get('MYSQL_ROOT_PASSWORD',''))")
ADMIN_USER=""; ADMIN_PW=""
for cand in "root:$DB_ROOT" "masteradmin:$DB_PW" "masteradmin:$DB_ROOT"; do
    u="${cand%%:*}"; pw="${cand#*:}"; [ -n "$pw" ] || continue
    if sudo docker exec -e MYSQL_PWD="$pw" cloudpi-db mysql -u "$u" -e "SELECT 1" >/dev/null 2>&1; then
        ADMIN_USER="$u"; ADMIN_PW="$pw"; break
    fi
done
[ -n "$ADMIN_USER" ] || { echo "ERROR: no working MySQL admin login"; exit 1; }
sudo docker exec -e MYSQL_PWD="$ADMIN_PW" -e ADMU="$ADMIN_USER" -e DOM="$DOM" cloudpi-db \
    sh -c 'mysql -u "$ADMU" pidb -e "UPDATE client SET domain=\"$DOM\" WHERE id=1;"'
echo "     CLIENT_DOMAIN updated in database (via $ADMIN_USER)."
REMOTE
    then
        ok "CLIENT_DOMAIN updated in database."
    else
        warn "CLIENT_DOMAIN update failed. Skipping."
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# Done
# ══════════════════════════════════════════════════════════════════════════════
echo
echo -e "  ${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}${GREEN}║                Deployment complete!                  ║${NC}"
echo -e "  ${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo
echo -e "  ${BOLD}URL${NC}     : ${CYAN}https://${PUBLIC_IP}/${NC}"
echo -e "  ${BOLD}SSH${NC}     : ${CYAN}ssh -i ${KEY_FILE} cloudpiadmin@${PUBLIC_IP}${NC}"
echo -e "  ${BOLD}Region${NC}  : ${REGION}"
echo -e "  ${BOLD}Login${NC}   : admin@cloudpi.ai / admin123  (change it via step 12)"
echo -e "  ${BOLD}Logs${NC}    : sudo docker logs -f cloudpi-app"
echo -e "  ${BOLD}State${NC}   : $STATE_FILE  (delete to start fresh)"
echo
