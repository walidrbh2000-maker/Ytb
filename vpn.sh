#!/usr/bin/env bash
# =============================================================================
#  vpn v3.0  —  Xray + Google Cloud Run Proxy Manager for Termux
#  GitHub  : https://raw.githubusercontent.com/YOUR/REPO/main/vpn.sh
# =============================================================================
#
#  QUICK START
#    bash <(curl -sL <RAW_URL>) install   ← install once
#    vpn start                            ← run every time
#
#  COMMANDS
#    vpn start      deploy (if needed) + start local SOCKS5/HTTP proxy
#    vpn stop       stop local proxy
#    vpn status     proxy + cloud status + exit IP
#    vpn switch     switch / add Google account  (free-tier rotation)
#    vpn project    change GCP project without full reset
#    vpn clear      delete Cloud Run service  (stops cloud usage)
#    vpn reset      nuke everything and start fresh
#    vpn update     self-update this script from GitHub
#    vpn logs       tail xray client logs
#    vpn install    install as persistent 'vpn' command
#    vpn help       show this command list
#
#  PROXY
#    SOCKS5  127.0.0.1:1080   HTTP  127.0.0.1:8118
# =============================================================================
set -euo pipefail

# ── Meta ─────────────────────────────────────────────────────────────────────
readonly VPN_VERSION="3.0.0"
readonly GITHUB_RAW_URL="https://raw.githubusercontent.com/YOUR/REPO/main/vpn.sh"

# ── Termux guard ─────────────────────────────────────────────────────────────
readonly _PFX="${PREFIX:-/data/data/com.termux/files/usr}"
[[ "$_PFX" == *"com.termux"* ]] || { echo "Run this inside Termux." >&2; exit 1; }

# ── Paths ─────────────────────────────────────────────────────────────────────
readonly CFG_DIR="${HOME}/.config/xrayvpn"
readonly CFG_FILE="${CFG_DIR}/config.env"
readonly CLIENT_JSON="${CFG_DIR}/client.json"
readonly PID_FILE="${CFG_DIR}/xray.pid"
readonly LOG_FILE="${CFG_DIR}/xray.log"
readonly DEBIAN_ROOT="${_PFX}/var/lib/proot-distro/installed-rootfs/debian"
readonly DEBIAN_OPS="${DEBIAN_ROOT}/root/.vpn_ops.sh"
readonly DEBIAN_PARAMS="${DEBIAN_ROOT}/root/.vpn_params.env"
readonly DEBIAN_OUT="${DEBIAN_ROOT}/root/.vpn_out.env"
readonly BUILD_DIR="${DEBIAN_ROOT}/root/vpn_build"
readonly SOCKS_PORT=1080
readonly HTTP_PORT=8118
readonly SERVICE_NAME="xray-proxy"
readonly AR_LOCATION="us"
readonly AR_REPO="xray-images"
readonly DEFAULT_REGION="us-central1"

# ── Colours ───────────────────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' M='\033[0;35m'
B='\033[1m'    D='\033[2m'    X='\033[0m'

banner() {
    echo -e "\n${B}${C}"
    echo "  ╔══════════════════════════════════════════╗"
    printf "  ║   VPN Manager %-4s  ·  Xray / Cloud Run  ║\n" "v${VPN_VERSION}"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${X}"
}
hdr()  { echo -e "\n${B}${C}  ── $* ──${X}\n"; }
ok()   { echo -e "  ${G}✓${X}  $*"; }
info() { echo -e "  ${C}·${X}  $*"; }
warn() { echo -e "  ${Y}!${X}  $*"; }
err()  { echo -e "  ${R}✗${X}  $*" >&2; }
die()  { err "$*"; echo ""; exit 1; }
sep()  { echo -e "  ${D}──────────────────────────────────────────${X}"; }
nl()   { echo ""; }

# ── Config ────────────────────────────────────────────────────────────────────
cfg_load() {
    PROJECT_ID=""; SERVICE_URL=""; IMAGE_URL=""
    UUID=""; REGION="$DEFAULT_REGION"
    GCLOUD_ACCOUNT=""; SETUP_DONE="false"
    [[ -f "$CFG_FILE" ]] && source "$CFG_FILE" || true
}

cfg_save() {
    mkdir -p "$CFG_DIR"
    cat > "$CFG_FILE" << EOF
# xrayvpn config — saved $(date '+%Y-%m-%d %H:%M:%S')
PROJECT_ID="${PROJECT_ID:-}"
SERVICE_URL="${SERVICE_URL:-}"
IMAGE_URL="${IMAGE_URL:-}"
UUID="${UUID:-}"
REGION="${REGION:-$DEFAULT_REGION}"
GCLOUD_ACCOUNT="${GCLOUD_ACCOUNT:-}"
SETUP_DONE="${SETUP_DONE:-false}"
EOF
}

gen_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null \
    || python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null \
    || uuidgen | tr '[:upper:]' '[:lower:]'
}

# ═════════════════════════════════════════════════════════════════════════════
#  TERMUX DEPENDENCY SETUP
# ═════════════════════════════════════════════════════════════════════════════
check_termux_deps() {
    hdr "Checking dependencies"
    dpkg --configure -a 2>/dev/null || true

    if ! command -v proot-distro &>/dev/null; then
        info "Installing proot-distro..."
        pkg install -y proot-distro 2>/dev/null || {
            pkg install -y --fix-broken; pkg install -y proot-distro
        }
    fi
    ok "proot-distro"

    # Debian rootfs integrity check
    local healthy=true
    if [[ -d "$DEBIAN_ROOT" ]]; then
        for d in root etc usr; do [[ -d "${DEBIAN_ROOT}/$d" ]] || healthy=false; done
    else
        healthy=false
    fi
    if [[ "$healthy" == false ]]; then
        warn "Debian rootfs incomplete — reinstalling (~300 MB)..."
        proot-distro remove debian 2>/dev/null || rm -rf "$DEBIAN_ROOT"
        proot-distro install debian
    fi
    ok "Debian (proot-distro)"

    if ! command -v xray &>/dev/null; then
        info "Installing xray from GitHub Releases..."
        local arch xray_zip xray_url xray_tmp
        arch=$(uname -m)
        case "$arch" in
            aarch64) xray_zip="Xray-android-arm64-v8a.zip" ;;
            x86_64)  xray_zip="Xray-android-x86_64.zip"   ;;
            *) die "Unsupported arch: $arch" ;;
        esac
        xray_url="https://github.com/XTLS/Xray-core/releases/latest/download/${xray_zip}"
        xray_tmp="$(mktemp -d)"
        curl -fsSL --retry 3 "$xray_url" -o "${xray_tmp}/xray.zip" \
            || die "Failed to download xray from GitHub."
        unzip -q "${xray_tmp}/xray.zip" xray -d "${xray_tmp}/"
        install -m 755 "${xray_tmp}/xray" "${_PFX}/bin/xray"
        rm -rf "$xray_tmp"
    fi
    ok "xray client ($(xray version 2>/dev/null | head -1 || echo "installed"))"
    nl
}

# ═════════════════════════════════════════════════════════════════════════════
#  DOCKER BUILD CONTEXT
# ═════════════════════════════════════════════════════════════════════════════
write_build_context() {
    mkdir -p "$BUILD_DIR"

    # Dockerfile — UUID/PORT injected at runtime via Cloud Run env vars
    cat > "${BUILD_DIR}/Dockerfile" << 'DOCKERFILE'
FROM alpine:3.19
ENV PORT=8080
ENV UUID=00000000-0000-0000-0000-000000000000
RUN apk add --no-cache curl unzip bash ca-certificates
RUN ARCH=$(uname -m); \
    case "$ARCH" in \
      aarch64) TAG="arm64-v8a" ;; \
      x86_64)  TAG="64"        ;; \
      *) echo "Unsupported: $ARCH" && exit 1 ;; \
    esac && \
    curl -fsSLo /tmp/xray.zip \
      "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${TAG}.zip" && \
    unzip /tmp/xray.zip xray -d /usr/local/bin/ && \
    chmod +x /usr/local/bin/xray && rm /tmp/xray.zip
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
DOCKERFILE

    # Entrypoint — generates xray config at container startup
    cat > "${BUILD_DIR}/entrypoint.sh" << 'ENTRYPOINT_SH'
#!/bin/sh
set -e
mkdir -p /etc/xray
cat > /etc/xray/config.json << XCFG
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": ${PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${UUID}"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": {"path": "/ws"}
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
XCFG
echo "[xray] port=${PORT} uuid=${UUID}"
exec /usr/local/bin/xray run -config /etc/xray/config.json
ENTRYPOINT_SH
    chmod +x "${BUILD_DIR}/entrypoint.sh"
}

# ═════════════════════════════════════════════════════════════════════════════
#  DEBIAN OPS SCRIPT
#  DEBIAN_PARAMS  Termux → Debian  (input)
#  DEBIAN_OUT     Debian → Termux  (output)
# ═════════════════════════════════════════════════════════════════════════════
write_debian_ops() {
    mkdir -p "$(dirname "$DEBIAN_PARAMS")" "$(dirname "$DEBIAN_OPS")"

    # Params file (expanded by Termux — intentional)
    cat > "$DEBIAN_PARAMS" << EOF
OP="${1}"
PROJECT_ID="${PROJECT_ID:-}"
UUID="${UUID:-}"
REGION="${REGION:-$DEFAULT_REGION}"
GCLOUD_ACCOUNT="${GCLOUD_ACCOUNT:-}"
SERVICE_NAME="${SERVICE_NAME}"
AR_LOCATION="${AR_LOCATION}"
AR_REPO="${AR_REPO}"
BUILD_DIR="/root/vpn_build"
OUT_FILE="/root/.vpn_out.env"
EOF

    # Debian script — single-quoted heredoc, no Termux expansion
    cat > "$DEBIAN_OPS" << 'DEBIAN_EOF'
#!/bin/bash
set -euo pipefail

G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'
R='\033[0;31m'; M='\033[0;35m'; B='\033[1m'; X='\033[0m'
ok()   { echo -e "  ${G}✓${X}  $*"; }
info() { echo -e "  ${C}·${X}  $*"; }
warn() { echo -e "  ${Y}!${X}  $*"; }
die()  { echo -e "  ${R}✗${X}  $*" >&2; exit 1; }
pick() { echo -en "  ${M}?${X}  $*"; }

source /root/.vpn_params.env
source /root/google-cloud-sdk/path.bash.inc 2>/dev/null \
    || die "gcloud SDK not found — run 'vpn reset' then 'vpn start'."

ensure_auth() {
    ACCOUNT=$(gcloud auth list --filter=status:ACTIVE \
        --format="value(account)" 2>/dev/null | head -1)
    if [[ -z "$ACCOUNT" ]]; then
        warn "No active Google account. Starting login..."
        gcloud auth login --no-launch-browser
        ACCOUNT=$(gcloud auth list --filter=status:ACTIVE \
            --format="value(account)" 2>/dev/null | head -1)
        [[ -n "$ACCOUNT" ]] || die "Authentication failed."
    fi
    ok "Account: $ACCOUNT"
}

check_billing() {
    local pid="$1"
    local b
    b=$(gcloud beta billing projects describe "$pid" \
        --format="value(billingEnabled)" 2>/dev/null || echo "unknown")
    if [[ "$b" == "False" ]]; then
        warn "Billing NOT enabled on '${pid}'."
        warn "Enable: https://console.cloud.google.com/billing/linkedaccount?project=${pid}"
        die "Enable billing then re-run 'vpn start'."
    elif [[ "$b" == "unknown" ]]; then
        warn "Could not verify billing (continuing)."
    fi
}

# ══════════════════════════════════════════════ OP: switch ═══════════════════
if [[ "$OP" == "switch" ]]; then
    echo ""
    info "Authenticated Google accounts:"
    echo ""
    mapfile -t ACCOUNTS < <(gcloud auth list --format="value(account)" 2>/dev/null)

    if [[ ${#ACCOUNTS[@]} -eq 0 ]]; then
        warn "No accounts found. Starting fresh login..."
        gcloud auth login --no-launch-browser
        CHOSEN=$(gcloud auth list --filter=status:ACTIVE \
            --format="value(account)" 2>/dev/null | head -1)
    else
        local i=1
        for acc in "${ACCOUNTS[@]}"; do
            STATUS=$(gcloud auth list --filter="account=${acc}" \
                --format="value(status)" 2>/dev/null)
            MARK=""; [[ "$STATUS" == "ACTIVE" ]] && MARK=" ${G}(active)${X}"
            echo -e "    ${B}${i})${X}  ${acc}${MARK}"
            ((i++))
        done
        echo -e "    ${B}${i})${X}  Add new account"
        echo ""
        pick "Select [1-${i}]: "; read -r CHOICE

        if [[ "$CHOICE" -eq "$i" ]] 2>/dev/null; then
            info "Starting new account login..."
            gcloud auth login --no-launch-browser
            CHOSEN=$(gcloud auth list --filter=status:ACTIVE \
                --format="value(account)" 2>/dev/null | head -1)
        elif [[ "$CHOICE" -ge 1 && "$CHOICE" -lt "$i" ]] 2>/dev/null; then
            CHOSEN="${ACCOUNTS[$((CHOICE-1))]}"
        else
            die "Invalid choice."
        fi
    fi

    gcloud config set account "$CHOSEN" --quiet
    ok "Switched to: $CHOSEN"
    echo ""
    info "Projects for ${CHOSEN}:"
    gcloud projects list --format="table(projectId,name)" 2>/dev/null
    echo ""
    pick "Enter PROJECT_ID (blank = keep current): "; read -r NEW_PID

    cat > "$OUT_FILE" << EOF
GCLOUD_ACCOUNT="$CHOSEN"
PROJECT_ID="${NEW_PID:-$PROJECT_ID}"
SETUP_DONE="false"
SERVICE_URL=""
IMAGE_URL=""
EOF
    ok "Done. Run 'vpn start' to deploy on the new account."
    exit 0
fi

# ══════════════════════════════════════════════ OP: set-project ══════════════
if [[ "$OP" == "set-project" ]]; then
    ensure_auth
    echo ""
    info "Available projects:"
    gcloud projects list --format="table(projectId,name)" 2>/dev/null
    echo ""
    pick "Enter PROJECT_ID: "; read -r NEW_PID
    [[ -n "$NEW_PID" ]] || die "No project entered."
    gcloud config set project "$NEW_PID" --quiet
    ok "Project set: $NEW_PID"
    cat > "$OUT_FILE" << EOF
PROJECT_ID="$NEW_PID"
SETUP_DONE="false"
SERVICE_URL=""
IMAGE_URL=""
EOF
    exit 0
fi

# ══════════════════════════════════════════════ OP: clear ════════════════════
if [[ "$OP" == "clear" ]]; then
    info "Deleting Cloud Run service '${SERVICE_NAME}'..."
    if gcloud run services delete "$SERVICE_NAME" \
        --region="$REGION" --quiet 2>/dev/null; then
        ok "Service deleted."
    else
        warn "Service not found (already deleted)."
    fi
    exit 0
fi

# ══════════════════════════════════════════════ OP: deploy ═══════════════════
ensure_auth
[[ -n "$GCLOUD_ACCOUNT" ]] && \
    gcloud config set account "$GCLOUD_ACCOUNT" --quiet 2>/dev/null || true

if [[ -z "$PROJECT_ID" ]]; then
    echo ""
    info "Available projects:"
    gcloud projects list --format="table(projectId,name)" 2>/dev/null
    echo ""
    pick "Enter PROJECT_ID: "; read -r PROJECT_ID
fi
gcloud config set project "$PROJECT_ID" --quiet
ok "Project: $PROJECT_ID"

check_billing "$PROJECT_ID"

info "Enabling APIs..."
gcloud services enable \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    --quiet
ok "APIs enabled."

# Check for existing deployment
EXISTING_URL=$(gcloud run services describe "$SERVICE_NAME" \
    --region="$REGION" --format="value(status.url)" 2>/dev/null || echo "")

if [[ -n "$EXISTING_URL" ]]; then
    ok "Already deployed: $EXISTING_URL"
    IMAGE_URL=$(gcloud run services describe "$SERVICE_NAME" \
        --region="$REGION" \
        --format="value(spec.template.spec.containers[0].image)" 2>/dev/null || echo "")
    cat > "$OUT_FILE" << EOF
PROJECT_ID="$PROJECT_ID"
SERVICE_URL="$EXISTING_URL"
IMAGE_URL="$IMAGE_URL"
UUID="$UUID"
REGION="$REGION"
GCLOUD_ACCOUNT="$ACCOUNT"
SETUP_DONE="true"
EOF
    exit 0
fi

# Artifact Registry
IMAGE_URL="${AR_LOCATION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/xray-server:latest"
gcloud artifacts repositories create "$AR_REPO" \
    --repository-format=docker --location="$AR_LOCATION" --quiet 2>/dev/null \
    && ok "Artifact Registry created." || ok "Artifact Registry exists."

# Cloud Build
info "Building Docker image (~3-5 min)..."
gcloud builds submit "$BUILD_DIR" --tag="$IMAGE_URL" --quiet
ok "Image built."

# Deploy to Cloud Run
info "Deploying to Cloud Run ($REGION)..."
gcloud run deploy "$SERVICE_NAME" \
    --image="$IMAGE_URL" \
    --platform=managed \
    --region="$REGION" \
    --allow-unauthenticated \
    --port=8080 \
    --min-instances=0 \
    --max-instances=1 \
    --memory=256Mi \
    --cpu=1 \
    --set-env-vars="UUID=${UUID}" \
    --quiet

SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" \
    --region="$REGION" --format="value(status.url)")
ok "Deployed: $SERVICE_URL"

cat > "$OUT_FILE" << EOF
PROJECT_ID="$PROJECT_ID"
SERVICE_URL="$SERVICE_URL"
IMAGE_URL="$IMAGE_URL"
UUID="$UUID"
REGION="$REGION"
GCLOUD_ACCOUNT="$ACCOUNT"
SETUP_DONE="true"
EOF
ok "Config saved."
DEBIAN_EOF

    chmod +x "$DEBIAN_OPS"
}

run_debian_ops() {
    nl; sep
    echo -e "  ${D}◀ Debian${X}"
    sep; nl
    proot-distro login debian -- bash "$DEBIAN_OPS"
    nl; sep
    echo -e "  ${D}▶ Termux${X}"
    sep; nl
}

# ═════════════════════════════════════════════════════════════════════════════
#  XRAY CLIENT
# ═════════════════════════════════════════════════════════════════════════════
write_client_config() {
    local url="$1" uuid="$2"
    local host="${url#https://}"; host="${host%%/*}"
    mkdir -p "$CFG_DIR"
    cat > "$CLIENT_JSON" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${LOG_FILE}",
    "error": "${LOG_FILE}"
  },
  "inbounds": [
    {
      "tag": "socks",
      "port": ${SOCKS_PORT},
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": {"auth": "noauth", "udp": true}
    },
    {
      "tag": "http",
      "port": ${HTTP_PORT},
      "listen": "127.0.0.1",
      "protocol": "http",
      "settings": {}
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "${host}",
          "port": 443,
          "users": [{"id": "${uuid}", "encryption": "none"}]
        }]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "wsSettings": {"path": "/ws", "headers": {"Host": "${host}"}},
        "tlsSettings": {"serverName": "${host}"}
      }
    },
    {"tag": "direct",  "protocol": "freedom"},
    {"tag": "blocked", "protocol": "blackhole"}
  ]
}
EOF
}

proxy_running() {
    [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

start_proxy() {
    stop_proxy 2>/dev/null || true
    mkdir -p "$CFG_DIR"
    nohup xray run -config "$CLIENT_JSON" >> "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 1
    kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

stop_proxy() {
    if [[ -f "$PID_FILE" ]]; then
        local pid; pid=$(cat "$PID_FILE")
        kill "$pid" 2>/dev/null && rm -f "$PID_FILE" && return 0
        rm -f "$PID_FILE"
    fi
    pkill -f "xray run -config" 2>/dev/null || true
}

cloud_reachable() {
    curl -sf --max-time 6 --head "$1" -o /dev/null 2>/dev/null
}

# ═════════════════════════════════════════════════════════════════════════════
#  COMMANDS
# ═════════════════════════════════════════════════════════════════════════════

cmd_start() {
    banner; cfg_load
    check_termux_deps

    local need_deploy=false
    if [[ "$SETUP_DONE" != "true" ]] || [[ -z "$SERVICE_URL" ]]; then
        need_deploy=true
    else
        hdr "Cloud Run"
        info "Checking existing service..."
        if cloud_reachable "$SERVICE_URL"; then
            ok "Service reachable: ${SERVICE_URL}"
        else
            warn "Service unreachable — redeploying..."
            SETUP_DONE="false"; SERVICE_URL=""; need_deploy=true
        fi
    fi

    if [[ "$need_deploy" == true ]]; then
        hdr "Cloud Run Deployment"
        [[ -n "$UUID" ]] || UUID=$(gen_uuid)
        info "UUID: $UUID"
        write_build_context
        write_debian_ops "deploy"
        rm -f "$DEBIAN_OUT"
        run_debian_ops
        if [[ -f "$DEBIAN_OUT" ]]; then
            source "$DEBIAN_OUT"; cfg_save
            ok "Cloud Run ready."
        else
            die "Deployment failed — see Debian output above."
        fi
    fi

    hdr "Local Proxy"
    write_client_config "$SERVICE_URL" "$UUID"
    ok "Client config written."

    if start_proxy; then
        ok "xray started (PID $(cat "$PID_FILE"))."
    else
        die "xray failed — run 'vpn logs' to debug."
    fi

    nl
    echo -e "${B}${G}  ✓  VPN active!${X}"
    nl
    echo -e "  ${B}SOCKS5${X}   127.0.0.1:${SOCKS_PORT}"
    echo -e "  ${B}HTTP${X}     127.0.0.1:${HTTP_PORT}"
    nl
    echo -e "  ${D}Test: curl --proxy socks5h://127.0.0.1:${SOCKS_PORT} https://ipinfo.io${X}"
    nl
}

cmd_stop() {
    banner; hdr "Stopping proxy"
    stop_proxy
    ok "Local proxy stopped."
    nl
    info "Cloud Run scales to 0 automatically when idle."
    info "Use 'vpn clear' to delete the service entirely."
    nl
}

cmd_status() {
    cfg_load; nl
    echo -e "${B}${C}  VPN Status  —  v${VPN_VERSION}${X}"; nl

    if proxy_running; then
        echo -e "  Proxy       ${G}● running${X}  (PID $(cat "$PID_FILE"))"
    else
        echo -e "  Proxy       ${R}○ stopped${X}"
    fi
    echo -e "  SOCKS5      127.0.0.1:${SOCKS_PORT}"
    echo -e "  HTTP        127.0.0.1:${HTTP_PORT}"; nl

    if [[ -n "$SERVICE_URL" ]]; then
        echo -e "  Cloud Run   ${G}✓ deployed${X}"
        echo -e "  URL         ${SERVICE_URL}"
        echo -e "  Project     ${PROJECT_ID:-—}"
        echo -e "  Region      ${REGION:-—}"
        echo -e "  Account     ${GCLOUD_ACCOUNT:-—}"
    else
        echo -e "  Cloud Run   ${Y}not deployed${X}"
    fi
    nl

    if proxy_running; then
        info "Checking exit IP..."
        local ip
        ip=$(curl -s --max-time 8 \
            --proxy "socks5h://127.0.0.1:${SOCKS_PORT}" \
            https://ipinfo.io/ip 2>/dev/null || echo "timeout")
        echo -e "  Exit IP     ${ip}"; nl
    fi
}

cmd_switch() {
    banner; cfg_load
    hdr "Account Switcher"
    check_termux_deps
    write_debian_ops "switch"
    rm -f "$DEBIAN_OUT"
    run_debian_ops
    if [[ -f "$DEBIAN_OUT" ]]; then
        source "$DEBIAN_OUT"; cfg_save
        ok "Account updated. Run 'vpn start' to deploy."
    fi
    nl
}

cmd_project() {
    banner; cfg_load
    hdr "Change GCP Project"
    check_termux_deps
    write_debian_ops "set-project"
    rm -f "$DEBIAN_OUT"
    run_debian_ops
    if [[ -f "$DEBIAN_OUT" ]]; then
        source "$DEBIAN_OUT"
        SERVICE_URL=""; SETUP_DONE="false"
        cfg_save
        ok "Project changed. Run 'vpn start' to redeploy."
    fi
    nl
}

cmd_clear() {
    banner; cfg_load
    hdr "Clearing Cloud Run service"
    stop_proxy 2>/dev/null || true; ok "Local proxy stopped."
    if [[ -n "$PROJECT_ID" ]]; then
        write_debian_ops "clear"
        run_debian_ops
    else
        warn "No project configured — nothing to delete."
    fi
    SETUP_DONE="false"; SERVICE_URL=""; IMAGE_URL=""
    cfg_save
    ok "Service removed. Run 'vpn start' to redeploy."
    nl
}

cmd_reset() {
    banner
    echo -e "  ${B}${R}⚠  Full Reset${X}"; nl
    echo -e "  Deletes:  Cloud Run service  +  all local config"
    nl
    read -rp "  Type 'yes' to confirm: " CONFIRM
    [[ "$CONFIRM" == "yes" ]] || { info "Aborted."; nl; return 0; }
    nl
    cfg_load
    stop_proxy 2>/dev/null || true
    if [[ -n "$PROJECT_ID" ]]; then
        write_debian_ops "clear"
        proot-distro login debian -- bash "$DEBIAN_OPS" 2>/dev/null || true
    fi
    rm -rf "$CFG_DIR"
    ok "All config removed. Run 'vpn start' to begin fresh."
    nl
}

cmd_update() {
    banner; hdr "Self-update"
    local self; self="$(realpath "$0")"
    local tmp; tmp="$(mktemp)"
    if [[ "$GITHUB_RAW_URL" == *"YOUR/REPO"* ]]; then
        die "Edit GITHUB_RAW_URL on line 9 of this script first."
    fi
    info "Downloading from GitHub..."
    if curl -fsSL "$GITHUB_RAW_URL" -o "$tmp"; then
        bash -n "$tmp" || { rm -f "$tmp"; die "Downloaded file is not valid bash."; }
        local new_ver
        new_ver=$(grep '^readonly VPN_VERSION=' "$tmp" | cut -d'"' -f2)
        info "Current: v${VPN_VERSION}  →  New: v${new_ver:-?}"
        cp "$tmp" "$self"; chmod +x "$self"; rm -f "$tmp"
        ok "Updated to v${new_ver}."
    else
        rm -f "$tmp"; die "Download failed."
    fi
    nl
}

cmd_logs() {
    if [[ -f "$LOG_FILE" ]]; then
        echo -e "${D}  Tailing ${LOG_FILE} — Ctrl+C to stop${X}\n"
        tail -f "$LOG_FILE"
    else
        warn "No log file yet."; info "Start proxy with 'vpn start' first."
    fi
}

cmd_install() {
    local target="${_PFX}/bin/vpn"
    local self; self="$(realpath "$0" 2>/dev/null || echo "")"

    if [[ -f "$self" ]]; then
        cp "$self" "$target"
    elif [[ "$GITHUB_RAW_URL" != *"YOUR/REPO"* ]]; then
        info "Downloading from GitHub..."
        curl -fsSL "$GITHUB_RAW_URL" -o "$target" \
            || die "Download failed."
    else
        die "Cannot install via pipe. Save first:\n  curl -sL <URL> -o vpn.sh \&\& bash vpn.sh install"
    fi

    chmod +x "$target"
    ok "Installed: $target"
    info "Use 'vpn <command>' from anywhere in Termux."
    nl
}

cmd_help() {
    echo ""
    echo -e "${B}${C}  vpn v${VPN_VERSION}${X}  —  Xray + Google Cloud Run Manager"
    nl
    echo -e "  ${B}${C}LIFECYCLE${X}"
    echo -e "  ${C}vpn start${X}      deploy (if needed) + start SOCKS5/HTTP proxy"
    echo -e "  ${C}vpn stop${X}       stop local proxy  (Cloud Run idles to 0)"
    echo -e "  ${C}vpn clear${X}      delete Cloud Run service  (stops billing)"
    echo -e "  ${C}vpn reset${X}      nuke everything — cloud + all local config"
    nl
    echo -e "  ${B}${C}ACCOUNT MANAGEMENT  ${D}← free-tier rotation${X}"
    echo -e "  ${C}vpn switch${X}     switch Google accounts or add a new one"
    echo -e "  ${C}vpn project${X}    change GCP project without full reset"
    nl
    echo -e "  ${B}${C}INFO & TOOLS${X}"
    echo -e "  ${C}vpn status${X}     proxy + cloud status + exit IP"
    echo -e "  ${C}vpn logs${X}       tail xray client logs (live)"
    echo -e "  ${C}vpn update${X}     self-update from GitHub"
    echo -e "  ${C}vpn install${X}    install as persistent 'vpn' command"
    echo -e "  ${C}vpn help${X}       show this menu"
    nl
    echo -e "  ${B}${C}PROXY${X}"
    echo -e "  SOCKS5  ${G}127.0.0.1:${SOCKS_PORT}${X}     HTTP  ${G}127.0.0.1:${HTTP_PORT}${X}"
    nl
    echo -e "  ${B}${C}TEST${X}"
    echo -e "  ${D}curl --proxy socks5h://127.0.0.1:${SOCKS_PORT} https://ipinfo.io${X}"
    nl
    echo -e "  ${B}${C}FREE TIER TIP${X}"
    echo -e "  ${D}Each Google account gets its own free Cloud Run + Build quota.${X}"
    echo -e "  ${D}Use 'vpn switch' to rotate accounts before quota runs out.${X}"
    nl
}

# ═════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═════════════════════════════════════════════════════════════════════════════
mkdir -p "$CFG_DIR"
case "${1:-help}" in
    start)          cmd_start   ;;
    stop)           cmd_stop    ;;
    status)         cmd_status  ;;
    switch)         cmd_switch  ;;
    project)        cmd_project ;;
    clear)          cmd_clear   ;;
    reset)          cmd_reset   ;;
    update)         cmd_update  ;;
    logs)           cmd_logs    ;;
    install)        cmd_install ;;
    help|--help|-h) cmd_help    ;;
    *)
        err "Unknown command: '${1}'"
        cmd_help
        exit 1
        ;;
esac
