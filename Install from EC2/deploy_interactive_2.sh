#!/usr/bin/env bash
# deploy_interactive_2.sh — CloudPi AWS EC2 Interactive Deployment (ON-EC2 variant)
#
# Designed to run DIRECTLY on the EC2 instance (e.g. via EC2 Instance Connect
# or AWS Systems Manager Session Manager) when you do NOT have an AWS access
# key on your local PC.
#
# AWS credentials come from the instance's IAM role — the same role created by
# deploy_aws_ec2.py (cloudpi-ec2-role / cloudpi-ec2-profile) which grants
# Secrets Manager read/write on the cloudpi-secrets secret.
#
# What it DOES (re-runnable; progress kept in .deploy_state_2):
#   1.  Prerequisites check (python3, pip3, openssl, curl, rsync, docker,
#       docker compose plugin, AWS CLI, sudo if not root)
#   2.  Verify IAM instance-role / region (IMDSv2 + STS)
#   3.  pip install boto3 + cryptography
#   4.  Build / repair cloudpi-secrets.json (incl. Fernet key validation)
#   5.  Detect host address — optional; cached → IMDSv2 public → private →
#       hostname -I → prompt → 'localhost' fallback
#   6.  Update CLIENT_DOMAIN in the secrets file
#   7.  Upload secrets to AWS Secrets Manager
#   8.  Prepare /home/cloudpiadmin/cloudpi (fresh clone / local copy /
#       rsync migration / skip)
#   9.  Generate or patch docker-compose.yml
#  10.  Generate .env
#  11.  Generate self-signed TLS certificates
#  12.  Install cloudpi-fetch-secrets.sh + Docker Hub login + systemd units
#  13.  Wait for containers to become healthy + verify secrets chain
#       (13b dumps the host tmpfs, the container's /run/secrets/, and the
#        names of every secret env var visible to the app)
#  14.  Configure MySQL app user + privileges
#  15.  Verify login endpoint
#  16.  Post-install (admin password reset, CLIENT_DOMAIN DB update)
#
# What it does NOT do (the local-PC version did these):
#   • No AWS access-key prompt    — uses the instance role.
#   • No EC2 provisioning         — you are already on EC2.
#   • No SSH key pair management  — no SSH is used.
#   • No SCP / SSH transport      — all work is local.
#   • No "wait for bootstrap"     — this script IS the post-bootstrap step.
#
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/.deploy_state_2"
SECRETS_JSON="$SCRIPT_DIR/cloudpi-secrets.json"
export SCRIPT_DIR
TOTAL_STEPS=16

# Where the running app lives on the EC2 host.
CLOUDPI_USER="${CLOUDPI_USER:-cloudpiadmin}"
CLOUDPI_DIR="/home/${CLOUDPI_USER}/cloudpi"
export CLOUDPI_USER CLOUDPI_DIR

# ── Colors / formatting ─────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

TERM_COLS=$(tput cols 2>/dev/null || echo 70)
[[ "$TERM_COLS" =~ ^[0-9]+$ ]] || TERM_COLS=70
(( TERM_COLS > 78 )) && TERM_COLS=78
(( TERM_COLS < 50 )) && TERM_COLS=50

rule() { printf "${DIM}%*s${NC}\n" "$TERM_COLS" '' | tr ' ' '─'; }

# ── UI helpers ───────────────────────────────────────────────────────────────────
header() {
    echo
    rule
    printf "  ${BOLD}${CYAN}STEP %s/%s${NC}   ${BOLD}%s${NC}\n" "$1" "$TOTAL_STEPS" "$2"
    rule
}
ok()   { echo -e "${GREEN}  ✓  ${*}${NC}"; }
warn() { echo -e "${YELLOW}  ⚠  ${*}${NC}"; }
die()  { echo -e "${RED}  ✗  ${*}${NC}" >&2; exit 1; }
info() { echo    "     ${*}"; }

confirm() {
    local msg="${1:-Continue?}" def="${2:-Y}"
    local opts; [[ "$def" == "Y" ]] && opts="[Y/n]" || opts="[y/N]"
    printf "\n${YELLOW}  ▶  %s %s: ${NC}" "$msg" "$opts"
    read -r _ca
    _ca="${_ca:-$def}"
    [[ "$_ca" =~ ^[Yy]$ ]]
}

ask() {
    local _v="$1" _p="$2" _d="${3:-}"
    [[ -n "$_d" ]] && printf "     %s [%s]: " "$_p" "$_d" \
                    || printf "     %s: " "$_p"
    read -r _in
    printf -v "$_v" '%s' "${_in:-$_d}"
}

ask_pass() {
    local _v="$1" _p="$2"
    printf "     %s (hidden): " "$_p"
    read -rs _sp; echo
    printf -v "$_v" '%s' "$_sp"
}

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

with_spinner() {
    local msg="$1"; shift
    local logf; logf="$(mktemp "/tmp/cloudpi-spin.XXXXXX")"
    local frames='|/-\' i=0 rc
    # Detach stdin from the script — a backgrounded child that happens to
    # read stdin would otherwise consume the user's next interactive prompt
    # (the classic "ssh ate the loop's input" bug the old script also had).
    ( "$@" ) </dev/null >"$logf" 2>&1 &
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
st_get()  { grep -E "^${1}=" "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true; }
st_set()  {
    local k="$1" v="$2"
    { grep -vE "^${k}=" "$STATE_FILE" 2>/dev/null || true; echo "${k}=${v}"; } \
        > "${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
}
st_done() { [[ "$(st_get "$1")" == "done" ]]; }

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

# ── Privilege wrapper ──────────────────────────────────────────────────────────
# Almost every action needs root on the host. If we're root, run directly;
# otherwise sudo. If sudo isn't available either, the script aborts in step 1.
SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
    SUDO="sudo"
fi

run_as_root() { $SUDO "$@"; }
run_as_user() {
    # Run as $CLOUDPI_USER:
    #   • already that user      → just run.
    #   • running as a non-root  → sudo -u.
    #   • running as root        → runuser (sudo isn't necessarily installed,
    #     and `$SUDO -u user cmd` with $SUDO empty would parse `-u` as the
    #     command name — bash decides argv[0] before parameter expansion).
    if [[ "$(id -un)" == "$CLOUDPI_USER" ]]; then
        "$@"
    elif [[ -n "$SUDO" ]]; then
        $SUDO -u "$CLOUDPI_USER" "$@"
    else
        runuser -u "$CLOUDPI_USER" -- "$@"
    fi
}

# ── IMDSv2 helpers — fetch instance metadata from the AWS metadata service ─────
imds_token() {
    curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 300" 2>/dev/null || true
}
imds_get() {
    local path="$1" token
    token="$(imds_token)"
    [[ -n "$token" ]] || return 1
    curl -fsS -H "X-aws-ec2-metadata-token: $token" \
        "http://169.254.169.254/latest/meta-data/${path}" 2>/dev/null || true
}

# ── Overview ───────────────────────────────────────────────────────────────────
_ov() {
    local num="$1" title="$2" key="$3" mark
    if [[ -z "$key" ]]; then
        mark="${DIM}·${NC}"
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
    printf "  ${BOLD}CloudPi AWS EC2 — On-EC2 Deployment Status${NC}\n"
    rule
    _ov  1 "Prerequisites"              ""
    _ov  2 "IAM instance role / region" ""
    _ov  3 "Python dependencies"        STEP_3
    _ov  4 "Secrets file"               STEP_4
    _ov  5 "Detect host address (opt.)" ""
    _ov  6 "CLIENT_DOMAIN updated"      STEP_6
    _ov  7 "Upload secrets"             STEP_7
    _ov  8 "Files in $CLOUDPI_DIR"     STEP_8
    _ov  9 "docker-compose.yml"        STEP_9
    _ov 10 ".env file"                  STEP_10
    _ov 11 "TLS certificates"           STEP_11
    _ov 12 "Systemd services"           STEP_12C
    _ov 13 "Containers + secrets chain" STEP_13B
    _ov 14 "MySQL app user"             STEP_14
    _ov 15 "Login verified"             STEP_15
    _ov 16 "Post-install (optional)"    ""
    rule
    [[ -n "$_ip" ]] && printf "  ${DIM}Host addr:${NC} ${CYAN}%s${NC}\n" "$_ip"
    printf "  ${DIM}State file:${NC} %s\n" "$STATE_FILE"
}

REGION=""; PUBLIC_IP=""

trap 'echo; warn "Interrupted. Re-run to resume — completed steps are saved."; exit 130' INT

# ══════════════════════════════════════════════════════════════════════════════
clear 2>/dev/null || true
echo
echo -e "  ${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}${CYAN}║   CloudPi · AWS EC2 Interactive Deploy (on-EC2 v2)   ║${NC}"
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
# STEP 1 — Prerequisites (must run on EC2 with sudo available)
# ══════════════════════════════════════════════════════════════════════════════
header 1 "Prerequisites"

_missing=0
for _cmd in python3 pip3 openssl curl rsync docker; do
    if command -v "$_cmd" &>/dev/null; then ok "$_cmd found"
    else warn "$_cmd NOT found"; _missing=1; fi
done
# AWS CLI ships at /usr/local/bin/aws on the bootstrap image; fall back to PATH.
if command -v aws &>/dev/null || [[ -x /usr/local/bin/aws ]]; then
    ok "aws CLI found"
else
    warn "aws CLI NOT found"; _missing=1
fi
if [[ -n "$SUDO" ]] && ! command -v sudo &>/dev/null; then
    warn "sudo NOT found — script needs root"
    _missing=1
fi
# Docker Compose plugin
if docker compose version &>/dev/null; then
    ok "docker compose plugin found"
else
    warn "docker compose plugin NOT found"; _missing=1
fi
(( _missing )) && die "Install the missing tools above before continuing."
ok "All prerequisites met."

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2 — IAM Instance Role / Region (no access keys needed)
# ══════════════════════════════════════════════════════════════════════════════
header 2 "IAM Instance Role & Region"

info "Reading region from EC2 instance metadata (IMDSv2) ..."
_az="$(imds_get placement/availability-zone || true)"
if [[ -n "$_az" ]]; then
    REGION="${_az%[a-z]}"   # us-east-1a -> us-east-1
    ok "Region detected: $REGION"
else
    warn "Could not read IMDSv2. (Are you running this on EC2?)"
    ask REGION "AWS Region" "us-east-1"
fi
export REGION AWS_DEFAULT_REGION="$REGION"

info "Verifying instance role can call STS ..."
_who=$(python3 - <<'PYEOF' 2>&1 || true
import boto3, os, json, sys
try:
    r = boto3.client('sts', region_name=os.environ['REGION']).get_caller_identity()
    print(r['Account'] + '|' + r['Arn'])
except Exception as e:
    print('ERROR:' + str(e))
    sys.exit(1)
PYEOF
)
if [[ "$_who" == ERROR:* || -z "$_who" ]]; then
    warn "STS check failed: ${_who#ERROR:}"
    warn "Make sure this EC2 instance has an IAM role attached that allows"
    warn "Secrets Manager Get/Put on 'cloudpi-secrets'. The role created by"
    warn "deploy_aws_ec2.py (cloudpi-ec2-role) already grants this."
    confirm "Continue anyway?" N || die "Attach the IAM role, then re-run."
else
    _acct="${_who%%|*}"; _arn="${_who#*|}"
    ok "AWS account: $_acct"
    info "Caller ARN : $_arn"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3 — Python Dependencies
# ══════════════════════════════════════════════════════════════════════════════
header 3 "Python Dependencies"

if should_run STEP_3 "pip install boto3 cryptography"; then
    with_spinner "Installing boto3 + cryptography" \
        pip3 install --quiet boto3 cryptography \
        || die "pip install failed — see output above."
    st_set STEP_3 done
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

    # Validate Fernet keys — same check as the local-PC version.
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
        ok "Fernet keys valid."
    fi

    st_set STEP_4 done
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5 — Detect Host Address (public IP is optional)
# ══════════════════════════════════════════════════════════════════════════════
# We pick an address in this order so the deploy can finish even on instances
# with no public IPv4 (private-subnet + LB, or behind a NAT):
#   1. cached PUBLIC_IP from a previous run
#   2. IMDSv2 public-ipv4
#   3. IMDSv2 local-ipv4 (private IP)
#   4. first non-loopback address from `hostname -I`
#   5. interactive prompt — Enter to accept the detected default,
#      or type a value, or type '-' / blank to skip and use 'localhost'.
header 5 "Detect Host Address"

PUBLIC_IP="$(st_get PUBLIC_IP)"
_src=""
if [[ -n "$PUBLIC_IP" ]]; then
    _src="state file"
else
    PUBLIC_IP="$(imds_get public-ipv4 || true)"
    [[ -n "$PUBLIC_IP" ]] && _src="IMDSv2 public-ipv4"
fi
if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP="$(imds_get local-ipv4 || true)"
    [[ -n "$PUBLIC_IP" ]] && _src="IMDSv2 private IP (no public IP on this instance)"
fi
if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    [[ -n "$PUBLIC_IP" ]] && _src="hostname -I"
fi

if [[ -n "$PUBLIC_IP" ]]; then
    ok "Detected host address: $PUBLIC_IP  (source: $_src)"
    info "Press Enter to accept, type a different value, or type '-' to leave it blank."
else
    warn "Could not auto-detect any address."
    info "Type an IP/hostname, or press Enter / '-' to skip (will use 'localhost')."
fi

_default="$PUBLIC_IP"
printf "     Host address [%s]: " "${_default:-skip}"
read -r _ip_in
_ip_in="${_ip_in:-$_default}"
if [[ "$_ip_in" == "-" || -z "$_ip_in" ]]; then
    PUBLIC_IP="localhost"
    warn "No address provided — falling back to 'localhost'."
    warn "CLIENT_DOMAIN / TLS cert CN / login test will use 'localhost'."
elif [[ "$_ip_in" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$_ip_in" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
    PUBLIC_IP="$_ip_in"
    ok "Using host address: $PUBLIC_IP"
else
    warn "Value '$_ip_in' doesn't look like a valid IP/hostname — using 'localhost'."
    PUBLIC_IP="localhost"
fi
st_set PUBLIC_IP "$PUBLIC_IP"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6 — Update CLIENT_DOMAIN in Secrets
# ══════════════════════════════════════════════════════════════════════════════
header 6 "Update CLIENT_DOMAIN in Secrets"

if should_run STEP_6 "CLIENT_DOMAIN updated"; then
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
    st_set STEP_6 done
    ok "CLIENT_DOMAIN = ${_new_domain}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7 — Upload Secrets to AWS Secrets Manager
# ══════════════════════════════════════════════════════════════════════════════
header 7 "Upload Secrets to AWS Secrets Manager"

if should_run STEP_7 "secrets uploaded"; then
    with_spinner "Uploading secrets to AWS Secrets Manager (region ${REGION})" \
        python3 "$SCRIPT_DIR/setup_aws_secrets.py" upload --region "$REGION" --file "$SECRETS_JSON" \
        || die "Secrets upload failed — check the IAM role permissions."
    st_set STEP_7 done
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 8 — Prepare $CLOUDPI_DIR (Files)
# ══════════════════════════════════════════════════════════════════════════════
header 8 "Prepare $CLOUDPI_DIR"

# Always make sure the directory and ownership exist.
run_as_root mkdir -p "$CLOUDPI_DIR/certs"
run_as_root chown -R "$CLOUDPI_USER:$CLOUDPI_USER" "$CLOUDPI_DIR"

if should_run STEP_8 "files in $CLOUDPI_DIR"; then
    echo "     Install type:"
    echo "       1) Fresh install — git clone from GitHub        (default)"
    echo "       2) Copy from a local folder on THIS EC2 instance"
    echo "       3) Migrate via rsync from another server"
    echo "       4) Skip (files already in $CLOUDPI_DIR)"
    ask _dt "Choice" "1"

    case "${_dt:-1}" in
        1)
            info "Fresh install: cloning repo (or reusing existing files) ..."
            if [[ -f "$CLOUDPI_DIR/docker-compose.yml" ]]; then
                ok "CloudPi files already present — skipping clone."
            elif run_as_user git clone \
                    https://github.com/PurpleDataInc-TX/cloudpi-aws-deploy.git \
                    "$CLOUDPI_DIR/repo" 2>/dev/null \
                 && run_as_user cp -rn "$CLOUDPI_DIR/repo/." "$CLOUDPI_DIR/"; then
                ok "Repo cloned."
            else
                warn "git clone skipped/failed — steps 9/10 still generate the needed files."
            fi
            ;;
        2)
            ask _local_src "Local source folder on EC2" "$SCRIPT_DIR/cloudpi-files"
            _local_src="${_local_src/#\~/$HOME}"
            [[ -d "$_local_src" ]] || die "Local folder not found: $_local_src"
            info "Copying $_local_src → $CLOUDPI_DIR ..."
            run_as_root rsync -az \
                --exclude='.git/' \
                --exclude='.DS_Store' \
                --exclude='*.bak' \
                --exclude='__pycache__/' \
                --exclude='*.pyc' \
                "$_local_src/" "$CLOUDPI_DIR/"
            run_as_root chown -R "$CLOUDPI_USER:$CLOUDPI_USER" "$CLOUDPI_DIR"
            run_as_root chown -R 1000:1000 "$CLOUDPI_DIR/certs"
            ok "Files copied from $_local_src."
            ;;
        3)
            ask_host _src_ip   "Source server public IP/hostname" ""
            ask      _src_user "Source server SSH username"       ""
            ask      _src_key  "Path to source server SSH key (on this EC2)" ""
            _src_key="${_src_key/#\~/$HOME}"
            [[ -f "$_src_key" ]] || die "SSH key not found: $_src_key"
            info "Rsyncing from ${_src_user}@${_src_ip}:/home/${_src_user}/cloudpi/ → $CLOUDPI_DIR ..."
            run_as_root rsync -avz \
                -e "ssh -i $_src_key -o StrictHostKeyChecking=no" \
                "${_src_user}@${_src_ip}:/home/${_src_user}/cloudpi/" \
                "$CLOUDPI_DIR/"
            run_as_root chown -R "$CLOUDPI_USER:$CLOUDPI_USER" "$CLOUDPI_DIR"
            ok "Files migrated."
            ;;
        4)
            ok "Skipped — using existing files in $CLOUDPI_DIR."
            ;;
    esac
    st_set STEP_8 done
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 9 — docker-compose.yml
# ══════════════════════════════════════════════════════════════════════════════
header 9 "docker-compose.yml"

if should_run STEP_9 "docker-compose.yml configured"; then
    info "Current image tags in $CLOUDPI_DIR/docker-compose.yml:"
    run_as_root grep 'image:' "$CLOUDPI_DIR/docker-compose.yml" 2>/dev/null || echo "     (none found)"
    echo
    echo "     Options:"
    echo "       1) Generate new docker-compose.yml from template  (default)"
    echo "       2) Update image tags only in existing docker-compose.yml"
    echo "       3) Skip"
    ask _copt "Choice" "1"

    if [[ "${_copt:-1}" == "3" ]]; then
        ok "docker-compose.yml step skipped."
    else
        ask _ver "Target release version (e.g. v1.1.044)" "v1.1.044"
        [[ "$_ver" =~ ^v?[0-9]+(\.[0-9]+)*$ ]] || warn "Version '${_ver}' looks unusual — continuing anyway."

        if [[ "${_copt:-1}" == "2" ]]; then
            info "Updating image tags to ${_ver} ..."
            FILE="$CLOUDPI_DIR/docker-compose.yml"
            [[ -f "$FILE" ]] || die "docker-compose.yml not found at $FILE"
            run_as_root sed -i "s|cloudpi1/cloudpi:Cloudpi_db_[a-zA-Z0-9._-]*|cloudpi1/cloudpi:Cloudpi_db_${_ver}|g" "$FILE"
            run_as_root sed -i "/Cloudpi_db_/!s|cloudpi1/cloudpi:Cloudpi_[a-zA-Z0-9._-]*|cloudpi1/cloudpi:Cloudpi_${_ver}|g" "$FILE"
            info "Updated tags:"
            run_as_root grep 'image:' "$FILE"
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
            run_as_root mv "$_compose_tmp" "$CLOUDPI_DIR/docker-compose.yml"
            run_as_root chown "$CLOUDPI_USER:$CLOUDPI_USER" "$CLOUDPI_DIR/docker-compose.yml"
            ok "docker-compose.yml generated (version: ${_ver})."
        fi
    fi
    st_set STEP_9 done
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 10 — .env file
# ══════════════════════════════════════════════════════════════════════════════
header 10 ".env file"

if should_run STEP_10 ".env file"; then
    _env_tmp=$(mktemp /tmp/cloudpi.env.XXXXXX)
    cat > "$_env_tmp" <<ENV
HOST=${PUBLIC_IP}
HTTPS=true
SUBDOMAIN=${PUBLIC_IP}
CERT_PATH=/home/certs/cert.pem
KEY_PATH=/home/certs/privkey.pem
CA_BUNDLE_PATH=/home/certs/ca_bundle.pem
ENV
    run_as_root mv "$_env_tmp" "$CLOUDPI_DIR/.env"
    run_as_root chown "$CLOUDPI_USER:$CLOUDPI_USER" "$CLOUDPI_DIR/.env"
    ok ".env file created."
    st_set STEP_10 done
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 11 — TLS Certificates (self-signed)
# ══════════════════════════════════════════════════════════════════════════════
header 11 "TLS Certificates"

if should_run STEP_11 "TLS certificates"; then
    info "Generating self-signed certificate for CN=${PUBLIC_IP} ..."
    run_as_root mkdir -p "$CLOUDPI_DIR/certs"
    # Capture stderr to a temp file so the spinner-less output stays tidy but
    # we still surface failures clearly.
    _ssl_log=$(mktemp /tmp/cloudpi-openssl.XXXXXX)
    if ! run_as_root openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$CLOUDPI_DIR/certs/privkey.pem" \
            -out    "$CLOUDPI_DIR/certs/cert.pem" \
            -subj   "/CN=${PUBLIC_IP}" >"$_ssl_log" 2>&1; then
        cat "$_ssl_log" | sed 's/^/       /'
        rm -f "$_ssl_log"
        die "openssl failed to generate the certificate (see output above)."
    fi
    rm -f "$_ssl_log"
    # Belt + braces: confirm the two outputs actually exist before we copy.
    run_as_root test -s "$CLOUDPI_DIR/certs/cert.pem"   || die "cert.pem missing after openssl."
    run_as_root test -s "$CLOUDPI_DIR/certs/privkey.pem" || die "privkey.pem missing after openssl."
    run_as_root cp "$CLOUDPI_DIR/certs/cert.pem" "$CLOUDPI_DIR/certs/ca_bundle.pem"
    run_as_root chown -R 1000:1000 "$CLOUDPI_DIR/certs"
    run_as_root chmod 644 "$CLOUDPI_DIR/certs/cert.pem"
    run_as_root chmod 640 "$CLOUDPI_DIR/certs/privkey.pem"
    run_as_root chmod 644 "$CLOUDPI_DIR/certs/ca_bundle.pem"
    ok "TLS certificates created."
    st_set STEP_11 done
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 12 — Install secrets-fetch script + systemd units + start services
# ══════════════════════════════════════════════════════════════════════════════
header 12 "Systemd Services"

# ── 12a  Install cloudpi-fetch-secrets.sh into /usr/local/bin
if should_run STEP_12A "secrets fetch script installed"; then
    _fetch_tmp=$(mktemp /tmp/cloudpi-fetch.XXXXXX.sh)
    cat > "$_fetch_tmp" <<'FETCHSCRIPT'
#!/bin/bash
set -euo pipefail

REGION="__REGION__"
SVC_USER="__SVC_USER__"

mkdir -p /run/secrets-tmp
mount | grep -q secrets-tmp || mount -t tmpfs -o size=2m,mode=0700 tmpfs /run/secrets-tmp
chgrp "$SVC_USER" /run/secrets-tmp
chmod 750 /run/secrets-tmp

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
chown "$SVC_USER:$SVC_USER" /run/secrets-tmp/cloudpi.secrets \
    /run/secrets-tmp/db_password /run/secrets-tmp/db_root_password
echo "Secrets fetched successfully."
FETCHSCRIPT
    sed -i.bak \
        -e "s/__REGION__/${REGION}/" \
        -e "s/__SVC_USER__/${CLOUDPI_USER}/" \
        "$_fetch_tmp" && rm -f "${_fetch_tmp}.bak"
    run_as_root mv "$_fetch_tmp" /usr/local/bin/cloudpi-fetch-secrets.sh
    run_as_root chmod 755 /usr/local/bin/cloudpi-fetch-secrets.sh
    ok "Secrets fetch script installed (region: ${REGION})."
    st_set STEP_12A done
fi

# ── 12b  Docker Hub login (for private images)
if should_run STEP_12B "Docker Hub login"; then
    info "Logging in to Docker Hub (account: cloudpi1) for private images."
    _pat_file="$SCRIPT_DIR/docker-pat.txt"
    if [[ -f "$_pat_file" ]]; then
        _docker_pat=$(grep -v '^#' "$_pat_file" | grep -i 'DOCKER_PAT=' | head -1 | cut -d= -f2-)
        if [[ -n "$_docker_pat" ]]; then
            ok "Docker PAT loaded from docker-pat.txt."
        else
            warn "docker-pat.txt found but DOCKER_PAT= line is empty — prompting manually."
            ask_pass _docker_pat "Docker Hub Personal Access Token"
        fi
    else
        ask_pass _docker_pat "Docker Hub Personal Access Token"
    fi
    if ! echo "$_docker_pat" | run_as_root docker login -u cloudpi1 --password-stdin; then
        die "Docker Hub login failed — check the PAT in docker-pat.txt (or the value you just typed)."
    fi
    run_as_root mkdir -p "/home/${CLOUDPI_USER}/.docker"
    # docker login writes config to /root/.docker (when sudo'd) or ~/.docker
    # (when already root) — copy from whichever exists.
    if [[ -f /root/.docker/config.json ]]; then
        run_as_root cp /root/.docker/config.json "/home/${CLOUDPI_USER}/.docker/config.json"
    elif [[ -f "$HOME/.docker/config.json" ]]; then
        run_as_root cp "$HOME/.docker/config.json" "/home/${CLOUDPI_USER}/.docker/config.json"
    else
        die "Docker login appeared to succeed but no config.json was written — investigate."
    fi
    run_as_root chown -R "$CLOUDPI_USER:$CLOUDPI_USER" "/home/${CLOUDPI_USER}/.docker"
    run_as_root chmod 600 "/home/${CLOUDPI_USER}/.docker/config.json"
    ok "Docker Hub login complete."
    st_set STEP_12B done
fi

# ── 12c  setup_docker_compose_service.py (installs systemd units, starts them)
if should_run STEP_12C "systemd units installed"; then
    info "Running setup_docker_compose_service.py (installs systemd units) ..."
    run_as_root env REGION="$REGION" SERVICE_USER="$CLOUDPI_USER" CLOUDPI_DIR="$CLOUDPI_DIR" \
        python3 "$SCRIPT_DIR/setup_docker_compose_service.py" \
        || warn "setup_docker_compose_service.py reported an issue — review output above."

    info "Starting cloudpi-fetch-secrets ..."
    if run_as_root systemctl start cloudpi-fetch-secrets 2>/dev/null; then
        ok "cloudpi-fetch-secrets started."
    else
        warn "cloudpi-fetch-secrets failed to start — last 20 log lines:"
        run_as_root journalctl -u cloudpi-fetch-secrets --no-pager -n 20 || true
        warn "Verify the EC2 IAM role has Secrets Manager access and that step 7 completed."
    fi

    info "Starting cloudpi-docker-compose ..."
    if run_as_root systemctl start cloudpi-docker-compose 2>/dev/null; then
        ok "cloudpi-docker-compose started."
    else
        warn "cloudpi-docker-compose failed to start — last 20 log lines:"
        run_as_root journalctl -u cloudpi-docker-compose --no-pager -n 20 || true
    fi

    st_set STEP_12C done
fi
# (No top-level STEP_12 marker — the three sub-step markers are the truth.)

# ══════════════════════════════════════════════════════════════════════════════
# STEP 13 — Wait for containers
# ══════════════════════════════════════════════════════════════════════════════
header 13 "Wait for Containers"

if should_run STEP_13 "containers healthy"; then
    info "Waiting for cloudpi-db AND cloudpi-app to report 'healthy' (up to ~10 min) ..."
    _n=0; _max=60; _timed_out=0
    while true; do
        h=$(run_as_root docker ps --filter health=healthy --format "{{.Names}}" 2>/dev/null || true)
        if echo "$h" | grep -qx cloudpi-db && echo "$h" | grep -qx cloudpi-app; then
            break
        fi
        if (( ++_n >= _max )); then
            _timed_out=1; break
        fi
        if (( _n % 3 == 0 )); then
            echo
            info "--- Diagnostics (attempt ${_n}/${_max}) ---"
            echo "==> Secrets in tmpfs:"
            run_as_root ls /run/secrets-tmp/ 2>/dev/null || echo "     (empty)"
            echo "==> Fetch-secrets service:"
            run_as_root systemctl is-active cloudpi-fetch-secrets 2>/dev/null || echo "     inactive/failed"
            echo "==> Container status:"
            run_as_root docker ps -a --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null || echo "     (none)"
            echo "==> Last 5 lines of cloudpi-app log:"
            run_as_root docker logs cloudpi-app --tail 5 2>/dev/null || echo "     (not running)"
        else
            printf "\r     Attempt %d/%d ..." "$_n" "$_max"
        fi
        sleep 10
    done
    echo

    if (( _timed_out )); then
        warn "Timed out — both containers never became healthy. Final state:"
        run_as_root docker ps -a || true
        warn "Check: sudo docker logs cloudpi-app  and  sudo docker logs cloudpi-db"
    else
        run_as_root docker ps || true
        ok "Containers healthy."
        st_set STEP_13 done
    fi
fi

# ── 13b  Verify secrets chain: host tmpfs → container env vars + bind-mount
# Visible proof that what cloudpi-fetch-secrets wrote to /run/secrets-tmp/
# actually reaches the running app — both as $MYSQL_PASSWORD etc. (env_file)
# and as the file /run/secrets/cloudpi_secrets (Docker's secrets mount).
if should_run STEP_13B "secrets chain verified"; then
    info "Verifying the secrets reach the running container ..."
    echo

    # ── 1/3  Host tmpfs ────────────────────────────────────────────────────────
    echo -e "${BOLD}     ── Host: /run/secrets-tmp/  (what fetch-secrets wrote) ──${NC}"
    # Capture so we can detect "dir missing/empty" without relying on pipefail
    # semantics (which differ subtly between bash versions and sed builds).
    _host_ls="$(run_as_root ls -la /run/secrets-tmp/ 2>/dev/null || true)"
    if [[ -n "$_host_ls" ]]; then
        printf '%s\n' "$_host_ls" | sed 's/^/     /'
    else
        warn "     (empty or missing — cloudpi-fetch-secrets did not run)"
    fi
    echo

    # ── 2/3  Container bind-mount ──────────────────────────────────────────────
    echo -e "${BOLD}     ── Container cloudpi-app: /run/secrets/  (Docker bind-mount) ──${NC}"
    _cont_ls="$(run_as_root docker exec cloudpi-app ls -la /run/secrets/ 2>/dev/null || true)"
    if [[ -n "$_cont_ls" ]]; then
        printf '%s\n' "$_cont_ls" | sed 's/^/     /'
    else
        warn "     (could not exec cloudpi-app — is it running?)"
    fi
    echo

    # ── 3/3  Container env vars (names only, values redacted) ──────────────────
    echo -e "${BOLD}     ── Container cloudpi-app: secret env vars (names only, values redacted) ──${NC}"
    _cont_env="$(run_as_root docker exec cloudpi-app sh -c '
        env | grep -E "^(DB_|MYSQL_|SECRET_KEY=|CLIENT_|REDIS_|CRYPTO_|ENCRYPTION_|CREDENTIAL_|HMAC_|PAR_|WORKSPACE_|FISCAL_|REACT_)" \
            | sed "s/=.*/=<set>/" \
            | sort
    ' 2>/dev/null || true)"
    if [[ -n "$_cont_env" ]]; then
        printf '%s\n' "$_cont_env" | sed 's/^/     /'
    else
        # Could be either "container down" or "container up but no secret vars
        # loaded". The next two checks will disambiguate.
        warn "     (no matching env vars visible — container down OR env_file didn't load)"
    fi
    echo

    # ── Pass/fail gates — both must pass for STEP_13B to be marked done. ───────
    _mysql_ok=0; _file_ok=0

    if run_as_root docker exec cloudpi-app sh -c 'test -n "${MYSQL_PASSWORD:-}"' 2>/dev/null; then
        ok "MYSQL_PASSWORD is set inside cloudpi-app — env_file chain works."
        _mysql_ok=1
    else
        warn "MYSQL_PASSWORD is NOT set inside cloudpi-app."
        warn "→ Likely cause: /run/secrets-tmp/cloudpi.secrets was missing/empty"
        warn "  when compose started. Re-run step 12C, then restart compose:"
        warn "    sudo systemctl restart cloudpi-fetch-secrets cloudpi-docker-compose"
    fi

    if run_as_root docker exec cloudpi-app test -s /run/secrets/cloudpi_secrets 2>/dev/null; then
        ok "/run/secrets/cloudpi_secrets is mounted and non-empty in cloudpi-app."
        _file_ok=1
    else
        warn "/run/secrets/cloudpi_secrets is missing/empty in the app container."
        warn "→ The compose top-level secrets block didn't materialise."
    fi

    if (( _mysql_ok && _file_ok )); then
        st_set STEP_13B done
    else
        warn "Secrets chain check did NOT pass — leaving STEP_13B unset so a re-run will retry."
        if ! confirm "Continue to step 14 anyway (it will likely fail)?" N; then
            die "Fix the secrets chain, then re-run."
        fi
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 14 — MySQL app user & privileges
# ══════════════════════════════════════════════════════════════════════════════
header 14 "MySQL App User & Privileges"

if should_run STEP_14 "MySQL app user configured"; then
    info "Configuring MySQL app user + privileges ..."
    # sudo strips env vars by default, and `$EMPTY VAR=val cmd` doesn't treat
    # VAR=val as an assignment (bash decides that before expansion).
    # `$SUDO env VAR=val cmd` works in both cases.
    if $SUDO env REGION="$REGION" bash -s <<'REMOTE'
set -euo pipefail
SM=$(/usr/local/bin/aws secretsmanager get-secret-value \
    --region "$REGION" --secret-id cloudpi-secrets \
    --query SecretString --output text)
DB_PW=$(printf '%s'   "$SM" | python3 -c "import json,sys; print(json.load(sys.stdin)['MYSQL_PASSWORD'])")
DB_ROOT=$(printf '%s' "$SM" | python3 -c "import json,sys; print(json.load(sys.stdin).get('MYSQL_ROOT_PASSWORD',''))")
APP_USER=$(printf '%s' "$SM" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('DB_USER') or d.get('MYSQL_USER') or 'masteradmin')")

ADMIN_USER=""; ADMIN_PW=""
for cand in "root:$DB_ROOT" "masteradmin:$DB_PW" "masteradmin:$DB_ROOT"; do
    u="${cand%%:*}"; pw="${cand#*:}"
    [ -n "$pw" ] || continue
    if docker exec -e MYSQL_PWD="$pw" cloudpi-db mysql -u "$u" -e "SELECT 1" >/dev/null 2>&1; then
        ADMIN_USER="$u"; ADMIN_PW="$pw"; break
    fi
done
[ -n "$ADMIN_USER" ] || { echo "ERROR: no working MySQL admin login (tried root + masteradmin)"; exit 1; }
echo "     Admin login: $ADMIN_USER   |   App DB user: $APP_USER"

APP_USER_SQL=${APP_USER//\'/\'\'}
DB_PW_SQL=${DB_PW//\'/\'\'}

docker exec -e MYSQL_PWD="$ADMIN_PW" cloudpi-db mysql -u "$ADMIN_USER" -e "
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
        st_set STEP_14 done
    else
        warn "MySQL user setup failed — no working admin login, or the DB isn't ready."
        warn "If the DB volume was initialized with stale passwords:"
        info "  cd $CLOUDPI_DIR && docker compose down -v && docker compose up -d"
        warn "Then re-run this step."
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 15 — Verify login
# ══════════════════════════════════════════════════════════════════════════════
header 15 "Verify Login Endpoint"

if should_run STEP_15 "API login verified"; then
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
        st_set STEP_15 done
    else
        warn "Login still returns HTTP $_http after warmup window — check: sudo docker logs cloudpi-app"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 16 — Post-install (optional)
# ══════════════════════════════════════════════════════════════════════════════
header 16 "Post-Install (Optional)"

if confirm "Reset the default admin@cloudpi.ai password?" N; then
    ask_pass _new_admin_pw "New admin password"
    if $SUDO env REGION="$REGION" NPW="$_new_admin_pw" bash -s <<'REMOTE'
set -euo pipefail
HASH=$(docker exec -w /app/backend -e NPW="$NPW" cloudpi-app \
    node -e 'const b=require("bcrypt");b.hash(process.env.NPW,10).then(h=>console.log(h)).catch(e=>{console.error(e);process.exit(1);});')
SM=$(/usr/local/bin/aws secretsmanager get-secret-value \
    --region "$REGION" --secret-id cloudpi-secrets --query SecretString --output text)
DB_PW=$(printf '%s'   "$SM" | python3 -c "import json,sys; print(json.load(sys.stdin)['MYSQL_PASSWORD'])")
DB_ROOT=$(printf '%s' "$SM" | python3 -c "import json,sys; print(json.load(sys.stdin).get('MYSQL_ROOT_PASSWORD',''))")
ADMIN_USER=""; ADMIN_PW=""
for cand in "root:$DB_ROOT" "masteradmin:$DB_PW" "masteradmin:$DB_ROOT"; do
    u="${cand%%:*}"; pw="${cand#*:}"; [ -n "$pw" ] || continue
    if docker exec -e MYSQL_PWD="$pw" cloudpi-db mysql -u "$u" -e "SELECT 1" >/dev/null 2>&1; then
        ADMIN_USER="$u"; ADMIN_PW="$pw"; break
    fi
done
[ -n "$ADMIN_USER" ] || { echo "ERROR: no working MySQL admin login"; exit 1; }
docker exec -e MYSQL_PWD="$ADMIN_PW" -e ADMU="$ADMIN_USER" -e HASH="$HASH" cloudpi-db \
    sh -c 'mysql -u "$ADMU" pidb -e "UPDATE user SET password=\"$HASH\" WHERE email=\"admin@cloudpi.ai\";"'
echo "     Admin password updated (via $ADMIN_USER)."
REMOTE
    then
        ok "Admin password updated."
    else
        warn "Password reset failed (DB not ready or bcrypt unavailable)."
    fi
fi

if confirm "Update CLIENT_DOMAIN in the database?" N; then
    _cl_domain=$(python3 -c "import json,os; print(json.load(open(os.environ['SCRIPT_DIR']+'/cloudpi-secrets.json'))['CLIENT_DOMAIN'])")
    ask_host _new_cl_domain "New CLIENT_DOMAIN value" "$_cl_domain"
    if $SUDO env REGION="$REGION" DOM="$_new_cl_domain" bash -s <<'REMOTE'
set -euo pipefail
SM=$(/usr/local/bin/aws secretsmanager get-secret-value \
    --region "$REGION" --secret-id cloudpi-secrets --query SecretString --output text)
DB_PW=$(printf '%s'   "$SM" | python3 -c "import json,sys; print(json.load(sys.stdin)['MYSQL_PASSWORD'])")
DB_ROOT=$(printf '%s' "$SM" | python3 -c "import json,sys; print(json.load(sys.stdin).get('MYSQL_ROOT_PASSWORD',''))")
ADMIN_USER=""; ADMIN_PW=""
for cand in "root:$DB_ROOT" "masteradmin:$DB_PW" "masteradmin:$DB_ROOT"; do
    u="${cand%%:*}"; pw="${cand#*:}"; [ -n "$pw" ] || continue
    if docker exec -e MYSQL_PWD="$pw" cloudpi-db mysql -u "$u" -e "SELECT 1" >/dev/null 2>&1; then
        ADMIN_USER="$u"; ADMIN_PW="$pw"; break
    fi
done
[ -n "$ADMIN_USER" ] || { echo "ERROR: no working MySQL admin login"; exit 1; }
docker exec -e MYSQL_PWD="$ADMIN_PW" -e ADMU="$ADMIN_USER" -e DOM="$DOM" cloudpi-db \
    sh -c 'mysql -u "$ADMU" pidb -e "UPDATE client SET domain=\"$DOM\" WHERE id=1;"'
echo "     CLIENT_DOMAIN updated in database (via $ADMIN_USER)."
REMOTE
    then
        ok "CLIENT_DOMAIN updated in database."
    else
        warn "CLIENT_DOMAIN update failed."
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# Done
# ══════════════════════════════════════════════════════════════════════════════
echo
echo -e "  ${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}${GREEN}║               Deployment complete!                   ║${NC}"
echo -e "  ${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo
echo -e "  ${BOLD}URL${NC}     : ${CYAN}https://${PUBLIC_IP}/${NC}"
echo -e "  ${BOLD}Region${NC}  : ${REGION}"
echo -e "  ${BOLD}Login${NC}   : admin@cloudpi.ai / admin123  (change it via step 16)"
echo -e "  ${BOLD}Logs${NC}    : sudo docker logs -f cloudpi-app"
echo -e "  ${BOLD}State${NC}   : $STATE_FILE  (delete to start fresh)"
echo
