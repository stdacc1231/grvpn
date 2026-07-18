#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# GRVPN ENTERPRISE SSH SERVER MANAGER v4.0.13 – VPN TUNNEL EDITION
# Python WebSocket server (no websocat) + UDPGW support
# Fixed 502 errors, simplified CLI
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

# ─── Colours ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

VERSION="4.0.13"
INSTALL_DIR="/opt/grvpn"
DATA_DIR="${INSTALL_DIR}/data"
CONFIG_DIR="${INSTALL_DIR}/config"
LOG_DIR="${INSTALL_DIR}/logs"
BACKUP_DIR="${INSTALL_DIR}/backups"
BIN_DIR="${INSTALL_DIR}/bin"
DB_FILE="${DATA_DIR}/grvpn.db"
PANEL_SCRIPT="${BIN_DIR}/grvpn-panel.py"
SYMLINK="/usr/local/bin/grvpn"
WS_BACKEND_PORT="8080"          # fixed port – no random
UDPGW_PORT="7300"               # BadVPN UDP gateway port
ACME_SH="$HOME/.acme.sh/acme.sh"

mkdir -p /var/log/grvpn
INSTALL_LOG="/var/log/grvpn/install.log"
exec > >(tee -a "${INSTALL_LOG}") 2>&1

FAILED_PACKAGES=()
FAILED_STEPS=()

log_ok()   { echo -e "${GREEN}[✅] $*${NC}"; }
log_info() { echo -e "${BLUE}[ℹ️] $*${NC}"; }
log_warn() { echo -e "${YELLOW}[⚠️] $*${NC}"; }
log_err()  { echo -e "${RED}[❌] $*${NC}"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

retry() {
    local tries=3 delay=3 n=1
    until "$@"; do
        if (( n >= tries )); then
            log_err "Failed after ${tries} attempts: $*"
            return 1
        fi
        log_warn "Attempt ${n} failed: $*  — retrying in ${delay}s..."
        n=$((n+1)); sleep "$delay"
    done
}

apt_install_each() {
    local pkg
    for pkg in "$@"; do
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            continue
        fi
        log_info "Installing ${pkg}..."
        if ! retry apt-get install -y -qq "$pkg"; then
            FAILED_PACKAGES+=("$pkg")
        fi
    done
}

ensure_pip() {
    if command_exists pip3; then
        log_ok "pip3 already present."
        return 0
    fi
    log_warn "pip3 not found — installing python3-pip."
    retry apt-get install -y -qq python3-pip python3-venv || true
    if command_exists pip3; then
        log_ok "pip3 installed via apt."
        return 0
    fi
    if command_exists python3; then
        python3 -m ensurepip --upgrade >/dev/null 2>&1 || true
    fi
    if command_exists pip3; then
        log_ok "pip3 installed via ensurepip."
        return 0
    fi
    log_warn "ensurepip failed — bootstrapping pip directly."
    if curl -fsSL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py 2>/dev/null; then
        python3 /tmp/get-pip.py --quiet || true
        rm -f /tmp/get-pip.py
    fi
    if command_exists pip3; then
        log_ok "pip3 installed via get-pip.py."
        return 0
    fi
    log_err "Could not install pip3."
    FAILED_STEPS+=("pip3 bootstrap")
    return 1
}

latest_github_release() {
    local repo="$1" fallback="$2" tag
    tag=$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
          | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/')
    if [[ -z "$tag" ]]; then
        log_warn "Could not resolve latest release for ${repo} — using pinned fallback ${fallback}."
        echo "$fallback"
    else
        echo "$tag"
    fi
}

clear
echo -e "${CYAN}"
cat << "EOF"
╔══════════════════════════════════════════════════════════════════════╗
║  🐱 GRVPN ENTERPRISE SSH SERVER MANAGER v4.0.13                    ║
║  VPN TUNNEL EDITION – Python WebSocket + UDPGW                     ║
║  Fixed 502 errors, ready for gaming/VoIP                          ║
╚══════════════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

if [[ $EUID -ne 0 ]]; then
    log_err "Run as root."
    exit 1
fi

IS_UPDATE=0
if [[ -f "${DB_FILE}" ]]; then
    IS_UPDATE=1
    log_info "Existing installation detected — running in UPDATE mode (data/config preserved)."
fi

EXISTING_DOMAIN=""
if [[ "$IS_UPDATE" -eq 1 ]] && command_exists sqlite3; then
    EXISTING_DOMAIN=$(sqlite3 "${DB_FILE}" "SELECT value FROM settings WHERE key='domain';" 2>/dev/null || true)
fi

if [[ -n "$EXISTING_DOMAIN" ]]; then
    log_info "Using existing domain: ${EXISTING_DOMAIN}"
    DOMAIN="$EXISTING_DOMAIN"
    CERT_TYPE="1"
else
    echo -e "${BLUE}[🌐] Domain setup${NC}"
    echo "Select certificate type:"
    echo "  1) Single domain (e.g., vpn.example.com) – HTTP-01 challenge (port 80)"
    echo "  2) Wildcard domain (e.g., *.example.com) – DNS-01 challenge (requires API token)"
    echo ""
    read -p "Enter choice [1/2]: " CERT_TYPE

    if [[ "$CERT_TYPE" != "1" && "$CERT_TYPE" != "2" ]]; then
        log_err "Invalid choice."
        exit 1
    fi

    read -p "Enter domain (e.g., example.com or vpn.example.com): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        log_err "Domain cannot be empty."
        exit 1
    fi
fi

# ─── Warn about DNS ─────────────────────────────────────────────────────
SERVER_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || hostname -I | awk '{print $1}')
if [[ -n "$SERVER_IP" ]]; then
    log_info "Your server public IP appears to be: ${SERVER_IP}"
    log_warn "IMPORTANT: Ensure your domain '${DOMAIN}' has an A record pointing to ${SERVER_IP}."
    log_warn "Let's Encrypt will validate ownership via DNS. If incorrect, certificate issuance will fail."
    echo ""
    read -p "Press Enter to continue (or Ctrl+C to abort and fix DNS)..." 
else
    log_warn "Could not detect public IP. Ensure domain '${DOMAIN}' points to this server."
    read -p "Press Enter to continue..." 
fi

# ─── Directories ────────────────────────────────────────────────────────
log_info "Creating directory structure..."
mkdir -p "${INSTALL_DIR}" "${DATA_DIR}" "${CONFIG_DIR}" "${LOG_DIR}" "${BACKUP_DIR}" "${BIN_DIR}"
mkdir -p /etc/grvpn /var/log/grvpn /etc/ssh/sshd_config.d
mkdir -p /etc/stunnel5 /etc/stunnel /var/run/stunnel5
chmod 755 /var/run/stunnel5

# ─── System update ─────────────────────────────────────────────────────
log_info "Updating package index..."
retry apt-get update -qq || log_warn "apt-get update reported issues."
apt-get upgrade -y -qq || log_warn "apt-get upgrade reported issues."

# ─── Install packages ──────────────────────────────────────────────────
log_info "Installing core packages (missing ones only — safe to re-run)..."
apt_install_each \
    openssh-server nginx \
    python3-pip python3-venv \
    screen tmux ufw fail2ban redis-server \
    sqlite3 bc net-tools iptables-persistent \
    curl wget git unzip jq htop nload \
    openssl netcat-openbsd socat python3-bcrypt \
    apache2-utils whois dnsutils uuid-runtime \
    sshuttle iptables \
    build-essential autoconf libtool pkg-config \
    cron socat

if ! dpkg -s stunnel5 >/dev/null 2>&1 && ! dpkg -s stunnel4 >/dev/null 2>&1; then
    log_info "Installing stunnel..."
    if ! retry apt-get install -y -qq stunnel5; then
        if ! retry apt-get install -y -qq stunnel4; then
            FAILED_PACKAGES+=("stunnel5/stunnel4")
        fi
    fi
fi
if command_exists stunnel4 && ! command_exists stunnel5; then
    ln -sf "$(command -v stunnel4)" /usr/bin/stunnel5
    log_ok "Linked stunnel4 -> stunnel5 for compatibility."
fi

if (( ${#FAILED_PACKAGES[@]} > 0 )); then
    log_warn "Packages that failed: ${FAILED_PACKAGES[*]}"
fi

# ─── Install BadVPN UDPGW for UDP support ─────────────────────────────
log_info "Installing BadVPN UDPGW (UDP over TCP tunnel for gaming/VoIP)..."
if ! command_exists badvpn-udpgw; then
    # Build from source
    apt_install_each cmake build-essential
    cd /tmp
    git clone https://github.com/ambrop72/badvpn.git 2>/dev/null || true
    cd badvpn
    mkdir build && cd build
    cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1
    make -j$(nproc)
    make install
    cd / && rm -rf /tmp/badvpn
    log_ok "BadVPN UDPGW installed."
else
    log_ok "BadVPN UDPGW already installed."
fi

# ─── Python modules ────────────────────────────────────────────────────
log_info "Setting up Python environment..."
ensure_pip

if command_exists pip3; then
    log_info "Upgrading pip..."
    pip3 install --upgrade pip --quiet || true

    if pip3 install --help | grep -q -- "--break-system-packages"; then
        PIP_BREAK="--break-system-packages"
    else
        PIP_BREAK=""
    fi

    log_info "Installing Python modules..."
    if ! pip3 install ${PIP_BREAK} --upgrade \
        psutil bcrypt sqlalchemy redis \
        requests colorama prettytable tabulate python-dateutil websockets asyncio --quiet; then
        log_warn "Install with ${PIP_BREAK} failed, retrying without."
        pip3 install --upgrade \
            psutil bcrypt sqlalchemy redis \
            requests colorama prettytable tabulate python-dateutil websockets asyncio --quiet \
            || FAILED_STEPS+=("python module install")
    fi
else
    FAILED_STEPS+=("python module install (no pip3)")
fi

# ─── Install acme.sh ──────────────────────────────────────────────────
log_info "Installing acme.sh (Let's Encrypt client)..."
if [ ! -f "$ACME_SH" ]; then
    curl -fsSL https://get.acme.sh | sh -s email=admin@"$DOMAIN" || {
        log_err "acme.sh installation failed."
        exit 1
    }
fi
export PATH="$HOME/.acme.sh:$PATH"
log_ok "acme.sh installed."

# ─── SSL certificate via acme.sh ──────────────────────────────────────
log_info "Obtaining SSL certificate for ${DOMAIN} using acme.sh..."
systemctl stop nginx 2>/dev/null || true

if [[ "$CERT_TYPE" == "2" ]]; then
    log_warn "Wildcard DNS challenge requires API credentials for your DNS provider."
    read -p "Enter Cloudflare API token (or press Enter for manual DNS): " CF_API_TOKEN
    if [[ -n "$CF_API_TOKEN" ]]; then
        export CF_Key="$CF_API_TOKEN"
        export CF_Email="admin@$DOMAIN"
        DNS_MODE="--dns dns_cf"
    else
        DNS_MODE="--dns --yes-I-know-dns-manual-mode-enough-go-ahead-please"
    fi
    $HOME/.acme.sh/acme.sh --issue -d "$DOMAIN" -d "*.${DOMAIN}" $DNS_MODE --force || {
        log_err "Certificate issuance failed."
        exit 1
    }
else
    if ! $HOME/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --force; then
        log_err "Certificate issuance failed. Check domain DNS."
        exit 1
    fi
fi

# ─── Install certificate to system location ──────────────────────────
log_info "Installing certificate to /etc/ssl/..."
$HOME/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --cert-file /etc/ssl/grvpn.pem \
    --key-file /etc/ssl/grvpn.key \
    --fullchain-file /etc/ssl/grvpn-fullchain.pem \
    --reloadcmd "systemctl reload nginx" || {
    log_warn "acme.sh install-cert failed; attempting manual copy..."
    CERT_DIR="$HOME/.acme.sh/${DOMAIN}_ecc"
    if [[ -d "$CERT_DIR" ]]; then
        cp "$CERT_DIR/fullchain.cer" /etc/ssl/grvpn.pem
        cp "$CERT_DIR/${DOMAIN}.key" /etc/ssl/grvpn.key
        cp "$CERT_DIR/fullchain.cer" /etc/ssl/grvpn-fullchain.pem
        log_ok "Manual copy succeeded."
    else
        log_err "Could not locate certificate files. Exiting."
        exit 1
    fi
}

systemctl start nginx 2>/dev/null || true
systemctl reload nginx 2>/dev/null || true
log_ok "Nginx reloaded with new certificate."

# ─── SSH Hardening (fixed) ──────────────────────────────────────────
log_info "Configuring SSH (secure defaults)..."
cat > /etc/ssh/sshd_config << 'EOF'
# GRVPN Enterprise SSH Configuration – Secure by default
Port 22
Port 80
Port 443
Port 8443
Port 2052
Port 2053
Port 2082
Port 2083
Port 2086
Port 2087
Port 2095
Port 2096
Port 8880

Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

PermitRootLogin no
PasswordAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd yes
PrintLastLog yes

ClientAliveInterval 60
ClientAliveCountMax 3
TCPKeepAlive yes
Compression yes
MaxSessions 1000
MaxStartups 500:30:1000
LoginGraceTime 30
MaxAuthTries 4

PermitTunnel yes
AllowTcpForwarding yes
GatewayPorts yes

Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,umac-128-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group-exchange-sha256
EOF

mkdir -p /etc/ssh/sshd_config.d
ssh-keygen -A

if sshd -t 2>/dev/null; then
    log_ok "sshd config validated."
else
    log_err "sshd config validation failed! Showing error:"
    sshd -t
    FAILED_STEPS+=("sshd config validation")
fi

# ─── Nginx Configuration (proxies to backend port) ────────────────────
log_info "Configuring Nginx with backend on port $WS_BACKEND_PORT..."
cat > /etc/nginx/sites-available/grvpn << EOF
server {
    listen 80;
    listen [::]:80;
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    listen 8443 ssl http2;
    listen 2052;
    listen 2053 ssl;
    listen 2082;
    listen 2083 ssl;
    listen 2086;
    listen 2087 ssl;
    listen 2095;
    listen 2096 ssl;
    listen 8880;

    server_name $DOMAIN;

    ssl_certificate /etc/ssl/grvpn.pem;
    ssl_certificate_key /etc/ssl/grvpn.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    location / {
        proxy_pass http://127.0.0.1:$WS_BACKEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
        proxy_connect_timeout 86400;
    }

    location /health {
        access_log off;
        return 200 "OK";
        add_header Content-Type text/plain;
    }
}
EOF

ln -sf /etc/nginx/sites-available/grvpn /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

if nginx -t 2>/dev/null; then
    log_ok "nginx config validated."
else
    log_err "nginx config validation failed."
    FAILED_STEPS+=("nginx config validation")
fi

# ─── Stunnel5 Configuration ────────────────────────────────────────────
log_info "Configuring Stunnel..."
mkdir -p /etc/stunnel5 /var/run/stunnel5
chmod 755 /var/run/stunnel5

cat > /etc/stunnel5/stunnel.conf << 'STUNNEL_EOF'
; GRVPN Enterprise Stunnel Configuration
pid = /var/run/stunnel5.pid
debug = 3
output = /var/log/stunnel5.log
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1
client = no
compression = zlib
options = NO_SSLv2
options = NO_SSLv3
ciphers = ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384
sslVersion = TLSv1.2

[grvpn-ssh-443]
accept = 0.0.0.0:443
connect = 127.0.0.1:22
cert = /etc/ssl/grvpn.pem
key = /etc/ssl/grvpn.key
retry = yes
TIMEOUTclose = 0

[grvpn-ssh-8443]
accept = 0.0.0.0:8443
connect = 127.0.0.1:22
cert = /etc/ssl/grvpn.pem
key = /etc/ssl/grvpn.key
retry = yes
TIMEOUTclose = 0

[grvpn-ssh-2053]
accept = 0.0.0.0:2053
connect = 127.0.0.1:22
cert = /etc/ssl/grvpn.pem
key = /etc/ssl/grvpn.key
retry = yes

[grvpn-ssh-2083]
accept = 0.0.0.0:2083
connect = 127.0.0.1:22
cert = /etc/ssl/grvpn.pem
key = /etc/ssl/grvpn.key
retry = yes

[grvpn-ssh-2087]
accept = 0.0.0.0:2087
connect = 127.0.0.1:22
cert = /etc/ssl/grvpn.pem
key = /etc/ssl/grvpn.key
retry = yes

[grvpn-ssh-2096]
accept = 0.0.0.0:2096
connect = 127.0.0.1:22
cert = /etc/ssl/grvpn.pem
key = /etc/ssl/grvpn.key
retry = yes

[grvpn-ws]
accept = 0.0.0.0:8080   # unused – we use Nginx proxy
connect = 127.0.0.1:22
cert = /etc/ssl/grvpn.pem
key = /etc/ssl/grvpn.key
protocol = websocket
retry = yes
TIMEOUTclose = 0
STUNNEL_EOF

# ─── Fail2ban ──────────────────────────────────────────────────────────
log_info "Configuring Fail2ban..."
cat > /etc/fail2ban/jail.local << 'FAIL2BAN_EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 7200

[ssh-ddos]
enabled = true
port = ssh
filter = sshd-ddos
logpath = /var/log/auth.log
maxretry = 3
bantime = 7200
FAIL2BAN_EOF

# ─── Firewall ──────────────────────────────────────────────────────────
log_info "Configuring UFW..."
for port in 22 80 443 8443 2052 2053 2082 2083 2086 2087 2095 2096 8880 $UDPGW_PORT; do
    ufw allow "$port"/tcp 2>/dev/null || true
    # Also allow UDP for UDPGW
    if [[ "$port" == "$UDPGW_PORT" ]]; then
        ufw allow "$port"/udp 2>/dev/null || true
    fi
done
ufw --force enable 2>/dev/null || true

# ─── Kernel tuning ─────────────────────────────────────────────────────
log_info "Optimising kernel parameters..."
if ! grep -q "# GRVPN Kernel Optimization" /etc/sysctl.conf 2>/dev/null; then
    cat >> /etc/sysctl.conf << 'KERNEL_EOF'
# GRVPN Kernel Optimization
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535

net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_slow_start_after_idle = 0

net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10

fs.file-max = 2097152
vm.swappiness = 10
vm.vfs_cache_pressure = 50
KERNEL_EOF
else
    log_info "Kernel tuning already applied — skipping duplicate append."
fi
sysctl -p 2>/dev/null || true

# ─── File limits ──────────────────────────────────────────────────────
log_info "Setting file limits..."
if ! grep -q "# GRVPN Limits" /etc/security/limits.conf 2>/dev/null; then
    cat >> /etc/security/limits.conf << 'LIMITS_EOF'
# GRVPN Limits
* soft nofile 2097152
* hard nofile 2097152
* soft nproc 2097152
* hard nproc 2097152
root soft nofile 2097152
root hard nofile 2097152
root soft nproc 2097152
root hard nproc 2097152
LIMITS_EOF
else
    log_info "File limits already applied — skipping duplicate append."
fi

# ─── Database ──────────────────────────────────────────────────────────
log_info "Setting up database (existing data preserved if present)..."
mkdir -p "${DATA_DIR}"
sqlite3 "${DB_FILE}" << 'SQL_EOF'
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    email TEXT,
    data_limit INTEGER DEFAULT 0,
    download_speed INTEGER DEFAULT 0,
    upload_speed INTEGER DEFAULT 0,
    ip_limit INTEGER DEFAULT 0,
    bandwidth_used INTEGER DEFAULT 0,
    connections INTEGER DEFAULT 0,
    is_active INTEGER DEFAULT 1,
    is_admin INTEGER DEFAULT 0,
    is_trial INTEGER DEFAULT 0,
    ssh_port INTEGER,
    ws_port INTEGER,
    ssh_banner TEXT,
    payload_template TEXT,
    payload_custom TEXT,
    notes TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP
);

CREATE TABLE IF NOT EXISTS sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER,
    session_key TEXT UNIQUE,
    ip TEXT,
    protocol TEXT,
    port INTEGER,
    payload_used TEXT,
    connected_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_activity TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    bytes_sent INTEGER DEFAULT 0,
    bytes_received INTEGER DEFAULT 0,
    is_active INTEGER DEFAULT 1,
    FOREIGN KEY(user_id) REFERENCES users(id)
);

CREATE TABLE IF NOT EXISTS logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER,
    action TEXT,
    ip TEXT,
    details TEXT,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY(user_id) REFERENCES users(id)
);

CREATE TABLE IF NOT EXISTS domains (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    domain TEXT UNIQUE,
    ssl_cert TEXT,
    ssl_key TEXT,
    user_id INTEGER,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP,
    is_active INTEGER DEFAULT 1,
    FOREIGN KEY(user_id) REFERENCES users(id)
);

CREATE TABLE IF NOT EXISTS ip_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ip TEXT UNIQUE,
    action TEXT,
    reason TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP,
    is_active INTEGER DEFAULT 1
);

CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS backups (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    backup_path TEXT,
    type TEXT,
    size INTEGER,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT OR IGNORE INTO settings (key, value) VALUES
    ('domain', 'DOMAIN_PLACEHOLDER'),
    ('server_name', 'GRVPN Enterprise Server'),
    ('version', '4.0.13'),
    ('trial_duration', '30'),
    ('default_data_limit', '0'),
    ('default_download_speed', '0'),
    ('default_upload_speed', '0'),
    ('default_ip_limit', '0'),
    ('kill_on_ip_limit', '1');
SQL_EOF

sqlite3 "${DB_FILE}" "UPDATE settings SET value='$DOMAIN' WHERE key='domain';"
sqlite3 "${DB_FILE}" "UPDATE settings SET value='${VERSION}' WHERE key='version';"

# ─── Admin user ────────────────────────────────────────────────────────
log_info "Ensuring admin user exists..."
if command_exists python3; then
python3 << PYTHON_ADMIN
import sqlite3, secrets, string
DB = '/opt/grvpn/data/grvpn.db'
conn = sqlite3.connect(DB)
c = conn.cursor()
c.execute("SELECT * FROM users WHERE username='grvpn'")
if not c.fetchone():
    try:
        import bcrypt
        alphabet = string.ascii_letters + string.digits
        pwd_plain = ''.join(secrets.choice(alphabet) for _ in range(16))
        pwd = bcrypt.hashpw(pwd_plain.encode(), bcrypt.gensalt())
        c.execute("INSERT INTO users(username, password, is_admin, is_active, ssh_port, ws_port) VALUES('grvpn', ?, 1, 1, 2000, 3000)", (pwd,))
        conn.commit()
        with open('/opt/grvpn/data/.admin_credentials', 'w') as f:
            f.write(f"username: grvpn\npassword: {pwd_plain}\n")
        import os
        os.chmod('/opt/grvpn/data/.admin_credentials', 0o600)
        print("[OK] Admin user created. Credentials saved to /opt/grvpn/data/.admin_credentials (root-only, chmod 600).")
    except ImportError:
        print("[WARN] bcrypt module missing — admin user NOT created. Re-run after fixing Python modules.")
else:
    print("[INFO] Admin user already exists — leaving password untouched.")
conn.close()
PYTHON_ADMIN
else
    log_err "python3 not available — cannot create admin user."
    FAILED_STEPS+=("admin user creation")
fi

# ─── Python WebSocket-to-SSH server ──────────────────────────────────
log_info "Deploying Python WebSocket server (ws2ssh)..."
cat > "${BIN_DIR}/ws2ssh.py" << 'WS2SSH_EOF'
#!/usr/bin/env python3
"""
GRVPN WebSocket-to-SSH Proxy – no websocat, fully custom
Listens on port 8080 (or specified), forwards WebSocket to SSH.
Supports payload injection, handles multiple connections.
"""
import asyncio
import websockets
import subprocess
import os
import sys
import logging
import json
import pty
import select
import termios
import fcntl
import struct

PORT = int(os.environ.get("WS_PORT", 8080))
SSH_HOST = "127.0.0.1"
SSH_PORT = 22

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s: %(message)s",
    handlers=[logging.StreamHandler()]
)
logger = logging.getLogger("ws2ssh")

async def handle_websocket(websocket, path):
    """Handle incoming WebSocket connection."""
    client_ip = websocket.remote_address[0] if websocket.remote_address else "unknown"
    logger.info(f"New WebSocket connection from {client_ip}")

    # Send a welcome message (optional)
    try:
        await websocket.send("Connected to GRVPN SSH proxy\n")
    except:
        pass

    # Create SSH process with a pseudo-terminal for better compatibility
    # Use -tt to force pseudo-terminal allocation
    ssh_cmd = [
        "ssh", "-tt",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR",
        "-p", str(SSH_PORT),
        "-l", "root",  # default user, but we can change per connection? Not needed for now.
        SSH_HOST
    ]

    # Use subprocess with pty for interactive shell
    master_fd, slave_fd = pty.openpty()
    # Set terminal size to reasonable
    winsize = struct.pack("HHHH", 24, 80, 0, 0)
    fcntl.ioctl(master_fd, termios.TIOCSWINSZ, winsize)

    proc = await asyncio.create_subprocess_exec(
        *ssh_cmd,
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        preexec_fn=os.setsid
    )

    # Close slave fds in parent
    os.close(slave_fd)

    # Buffer for reading from master
    def read_master():
        try:
            data = os.read(master_fd, 4096)
            return data
        except BlockingIOError:
            return b""
        except OSError:
            return b""

    # Set master to non-blocking
    flags = fcntl.fcntl(master_fd, fcntl.F_GETFL)
    fcntl.fcntl(master_fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

    # Loop to forward data
    try:
        while True:
            # Read from WebSocket
            try:
                message = await asyncio.wait_for(websocket.recv(), timeout=0.01)
                if message is None:
                    break
                # Write to SSH process
                os.write(master_fd, message if isinstance(message, bytes) else message.encode())
            except asyncio.TimeoutError:
                pass
            except websockets.exceptions.ConnectionClosed:
                logger.info("WebSocket closed by client")
                break

            # Read from SSH process
            try:
                data = read_master()
                if data:
                    await websocket.send(data)
                else:
                    # Small delay to avoid busy loop
                    await asyncio.sleep(0.001)
            except Exception as e:
                logger.error(f"Error reading from SSH: {e}")
                break

    except Exception as e:
        logger.error(f"Handler error: {e}")
    finally:
        # Clean up
        try:
            os.close(master_fd)
            proc.terminate()
            await asyncio.sleep(0.1)
            proc.kill()
        except:
            pass
        logger.info(f"Connection closed for {client_ip}")

async def main():
    """Start the WebSocket server."""
    logger.info(f"Starting WebSocket-to-SSH proxy on port {PORT}")
    try:
        server = await websockets.serve(handle_websocket, "0.0.0.0", PORT)
        logger.info(f"WebSocket server listening on ws://0.0.0.0:{PORT}")
        await server.wait_closed()
    except Exception as e:
        logger.error(f"Server error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    asyncio.run(main())
WS2SSH_EOF
chmod +x "${BIN_DIR}/ws2ssh.py"

# ─── Systemd service for WebSocket proxy ────────────────────────────
log_info "Creating WebSocket systemd service..."
cat > /etc/systemd/system/ws2ssh.service << EOF
[Unit]
Description=GRVPN WebSocket-to-SSH Proxy (Python)
After=network.target ssh.service
Wants=network.target

[Service]
Type=simple
User=root
Environment="WS_PORT=$WS_BACKEND_PORT"
ExecStart=/usr/bin/python3 ${BIN_DIR}/ws2ssh.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ws2ssh

[Install]
WantedBy=multi-user.target
EOF

# ─── Systemd service for BadVPN UDPGW ──────────────────────────────
log_info "Creating BadVPN UDPGW systemd service..."
cat > /etc/systemd/system/badvpn-udpgw.service << EOF
[Unit]
Description=BadVPN UDP Gateway (UDP over TCP tunnel)
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 0.0.0.0:$UDPGW_PORT --max-clients 1000
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=badvpn

[Install]
WantedBy=multi-user.target
EOF

# ─── Panel script (simplified) ──────────────────────────────────────
log_info "Deploying GRVPN Enterprise Panel (simplified)..."
cat > "${PANEL_SCRIPT}" << 'PANEL_EOF'
#!/usr/bin/env python3
"""
GRVPN ENTERPRISE SSH SERVER MANAGER – VPN TUNNEL EDITION
Simplified CLI – only essential operations.
"""
import os, sys, sqlite3, subprocess, time, json, uuid, socket
from datetime import datetime, timedelta

try:
    import psutil, bcrypt
    from prettytable import PrettyTable
    import colorama
    colorama.init()
except ImportError as e:
    print(f"[❌] Missing Python module: {e.name}")
    print("Run: pip3 install --upgrade psutil bcrypt prettytable colorama")
    sys.exit(1)

INSTALL_DIR = '/opt/grvpn'
DB = f'{INSTALL_DIR}/data/grvpn.db'
VERSION = '4.0.13'

def get_conn():
    return sqlite3.connect(DB)

def get_user(username=None, user_id=None):
    conn = get_conn()
    conn.row_factory = sqlite3.Row
    c = conn.cursor()
    if username:
        c.execute("SELECT * FROM users WHERE username=?", (username,))
    elif user_id:
        c.execute("SELECT * FROM users WHERE id=?", (user_id,))
    else:
        conn.close()
        return None
    user = c.fetchone()
    conn.close()
    return dict(user) if user else None

def get_all_users():
    conn = get_conn()
    conn.row_factory = sqlite3.Row
    c = conn.cursor()
    c.execute('''SELECT u.*, 
        (SELECT COUNT(*) FROM sessions WHERE user_id=u.id AND is_active=1) as active_sessions
        FROM users u WHERE is_active=1''')
    users = [dict(row) for row in c.fetchall()]
    conn.close()
    return users

def get_active_sessions():
    conn = get_conn()
    conn.row_factory = sqlite3.Row
    c = conn.cursor()
    c.execute('''SELECT s.*, u.username, u.download_speed, u.upload_speed
        FROM sessions s JOIN users u ON s.user_id = u.id
        WHERE s.is_active=1 ORDER BY s.connected_at DESC''')
    sessions = [dict(row) for row in c.fetchall()]
    conn.close()
    return sessions

def get_free_port(base):
    used = set()
    conn = get_conn()
    c = conn.cursor()
    c.execute("SELECT ssh_port, ws_port FROM users")
    for row in c.fetchall():
        if row[0]: used.add(row[0])
        if row[1]: used.add(row[1])
    conn.close()
    reserved = [22,80,443,8080,8443,2052,2053,2082,2083,2086,2087,2095,2096,8880,7300]
    for p in reserved:
        used.add(p)
    port = base
    while port in used:
        port += 1
    return port

def log_activity(user_id, action, ip='', details=''):
    conn = get_conn()
    c = conn.cursor()
    c.execute("INSERT INTO logs(user_id, action, ip, details) VALUES(?,?,?,?)",
              (user_id, action, ip, details))
    conn.commit()
    conn.close()

def clear_screen():
    os.system('clear' if os.name == 'posix' else 'cls')

def get_domain():
    conn = get_conn()
    c = conn.cursor()
    c.execute("SELECT value FROM settings WHERE key='domain'")
    result = c.fetchone()
    conn.close()
    return result[0] if result else 'localhost'

def get_server_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except:
        return 'YOUR_SERVER_IP'

def get_setting(key, default=None):
    conn = get_conn()
    c = conn.cursor()
    c.execute("SELECT value FROM settings WHERE key=?", (key,))
    row = c.fetchone()
    conn.close()
    return row[0] if row else default

def set_setting(key, value):
    conn = get_conn()
    c = conn.cursor()
    c.execute("REPLACE INTO settings(key, value) VALUES(?,?)", (key, str(value)))
    conn.commit()
    conn.close()

def run(cmd, **kwargs):
    try:
        return subprocess.run(cmd, **kwargs)
    except FileNotFoundError:
        print(f"[❌] Command not found: {cmd[0] if isinstance(cmd, list) else cmd}")
        return subprocess.CompletedProcess(cmd, 127)

def print_account_info(username, ssh_port, ws_port, data_limit, dl_speed, ul_speed, ip_limit, expires_at, password=""):
    domain = get_domain()
    server_ip = get_server_ip()
    expiry_str = expires_at if expires_at else "Never"
    
    print("\n" + "="*50)
    print("🐱 GRVPN ACCOUNT INFORMATION")
    print("="*50)
    print(f"IP/Host        : {server_ip}")
    print(f"Domain         : {domain}")
    print(f"Username       : {username}")
    if password:
        print(f"Password       : {password}")
    else:
        print("Password       : (hidden)")
    print(f"Data Limit     : {data_limit} GB" if data_limit > 0 else "Data Limit     : ∞")
    print(f"Download Speed : {dl_speed} Mbps" if dl_speed > 0 else "Download Speed : ∞")
    print(f"Upload Speed   : {ul_speed} Mbps" if ul_speed > 0 else "Upload Speed   : ∞")
    print(f"IP Limit       : {ip_limit}" if ip_limit > 0 else "IP Limit       : ∞")
    print(f"Expires        : {expiry_str}")
    print("\n📡 WEBSOCKET ENDPOINTS")
    print("---------------------")
    print(f"  ws://{domain}/")
    print(f"  wss://{domain}/")
    print("\n📋 PAYLOAD EXAMPLES")
    print("------------------")
    print("For WSS (TLS):")
    print(f"  GET wss://bug.com/ HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf][crlf]")
    print("For WS (HTTP):")
    print(f"  GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf][crlf]")
    print("\n🔹 UDP Gateway (for gaming/VoIP):")
    print(f"  UDPGW port: 7300 (connect to this port for UDP forwarding)")
    print("="*50)

# ================== MAIN MENU ==================
def main_menu():
    while True:
        clear_screen()
        print(f"""
╔══════════════════════════════════════════════════════════════════════╗
║  🐱 GRVPN ENTERPRISE SSH SERVER MANAGER v{VERSION}                  ║
╠══════════════════════════════════════════════════════════════════════╣
║  1.  👤 SSH Manager (users, limits, etc.)                          ║
║  2.  🌐 Domain Manager                                              ║
║  3.  📊 Session Monitor                                             ║
║  4.  📈 Server Dashboard                                            ║
║  5.  💾 Backup Manager                                              ║
║  6.  🔄 Update Manager                                              ║
║  7.  🛡️ Security (firewall, IP blacklist)                          ║
║  8.  📜 Logs                                                        ║
║  9.  🚪 Exit                                                       ║
╚══════════════════════════════════════════════════════════════════════╝
        """)
        choice = input("🐱 Choice: ").strip()
        if choice == '1': ssh_manager()
        elif choice == '2': domain_manager()
        elif choice == '3': session_monitor()
        elif choice == '4': server_dashboard()
        elif choice == '5': backup_manager()
        elif choice == '6': update_manager()
        elif choice == '7': security_manager()
        elif choice == '8': logs_viewer()
        elif choice == '9':
            print("\n[👋] Goodbye!")
            sys.exit(0)

# ================== SSH MANAGER ==================
def ssh_manager():
    while True:
        clear_screen()
        print("""
╔══════════════════════════════════════════════════════════════════════╗
║  👤 SSH MANAGER                                                    ║
╠══════════════════════════════════════════════════════════════════════╣
║  1.  List Users                                                     ║
║  2.  Create User                                                    ║
║  3.  Create Trial User                                              ║
║  4.  Edit User (fields)                                             ║
║  5.  Delete User                                                    ║
║  6.  Change Password                                                ║
║  7.  Lock/Unlock Account                                            ║
║  8.  View Account                                                   ║
║  9.  View Login History                                             ║
║  10. Disconnect User                                                ║
║  11. Disconnect All Sessions                                        ║
║  12. Backup/Restore Users                                           ║
║  13. Back to Main                                                   ║
╚══════════════════════════════════════════════════════════════════════╝
        """)
        choice = input("🐱 Choice: ").strip()
        if choice == '1': list_users()
        elif choice == '2': create_user()
        elif choice == '3': create_trial()
        elif choice == '4': edit_user()
        elif choice == '5': delete_user()
        elif choice == '6': change_password()
        elif choice == '7': lock_unlock()
        elif choice == '8': view_account()
        elif choice == '9': login_history()
        elif choice == '10': disconnect_user()
        elif choice == '11': disconnect_all()
        elif choice == '12': backup_restore()
        elif choice == '13': break

def list_users():
    clear_screen()
    users = get_all_users()
    if not users:
        print("[ℹ️] No users found")
        input("Press Enter...")
        return
    table = PrettyTable()
    table.field_names = ["ID", "Username", "Data", "DL", "UL", "IP", "Conn", "SSH", "Trial", "Status"]
    for u in users:
        data = f"{u['data_limit']}GB" if u['data_limit'] > 0 else "∞"
        dl = f"{u['download_speed']}M" if u['download_speed'] > 0 else "∞"
        ul = f"{u['upload_speed']}M" if u['upload_speed'] > 0 else "∞"
        ip = f"{u['ip_limit']}" if u['ip_limit'] > 0 else "∞"
        status = "✅" if u['is_active'] else "🔒"
        trial = "T" if u.get('is_trial', 0) else "-"
        table.add_row([u['id'], u['username'][:20], data, dl, ul, ip,
                       u.get('connections',0), u.get('ssh_port','N/A'), trial, status])
    print(table)
    input("\nPress Enter...")

def create_user():
    clear_screen()
    print("\n✏️ CREATE USER")
    print("="*50)
    username = input("Username: ").strip()
    if not username:
        print("[❌] Username required!")
        input("Press Enter...")
        return
    if not username.startswith('grvpn-'):
        username = f"grvpn-{username}"
    if get_user(username):
        print("[❌] User exists!")
        input("Press Enter...")
        return
    password = input("Password: ").strip()
    if not password:
        print("[❌] Password required!")
        input("Press Enter...")
        return
    email = input("Email (optional): ").strip()
    print("\n📊 LIMITS (0 = unlimited):")
    data_limit = int(input("Data Limit (GB): ").strip() or "0")
    dl_speed = int(input("Download Speed (Mbps): ").strip() or "0")
    ul_speed = int(input("Upload Speed (Mbps): ").strip() or "0")
    ip_limit = int(input("IP Limit: ").strip() or "0")
    expiry = input("Expiry (days, 0=never): ").strip()
    expires_at = None
    if expiry and int(expiry) > 0:
        expires_at = (datetime.now() + timedelta(days=int(expiry))).isoformat()

    ssh_port = get_free_port(2000)
    ws_port = get_free_port(3000)

    pwd_hash = bcrypt.hashpw(password.encode(), bcrypt.gensalt())
    conn = get_conn()
    c = conn.cursor()
    c.execute('''INSERT INTO users
        (username, password, email, data_limit, download_speed, upload_speed,
         ip_limit, is_admin, is_trial, ssh_port, ws_port, expires_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?)''',
        (username, pwd_hash, email, data_limit, dl_speed, ul_speed,
         ip_limit, 0, 0, ssh_port, ws_port, expires_at))
    user_id = c.lastrowid
    conn.commit()
    conn.close()

    with open(f'/etc/ssh/sshd_config.d/{username}.conf', 'w') as f:
        f.write(f"Match User {username}\n")
        f.write(f"    Port {ssh_port}\n")
        f.write("    PasswordAuthentication yes\n")
        f.write("    PermitEmptyPasswords no\n")
        f.write("    ClientAliveInterval 60\n")
        f.write("    TCPKeepAlive yes\n")
        f.write("    ForceCommand /bin/false\n")
    run(['systemctl', 'reload', 'ssh'], check=False)
    log_activity(user_id, 'user_created', details=f'Data:{data_limit}GB DL:{dl_speed} UL:{ul_speed} IP:{ip_limit}')
    
    print_account_info(username, ssh_port, ws_port, data_limit, dl_speed, ul_speed, ip_limit, expires_at, password)
    input("\nPress Enter...")

def create_trial():
    clear_screen()
    print("\n✏️ CREATE TRIAL USER")
    print("="*50)
    print("Trial durations:")
    print("1. 10 minutes")
    print("2. 20 minutes")
    print("3. 30 minutes")
    print("4. 1 hour")
    print("5. Custom")
    choice = input("Choice: ").strip()
    dur_map = {'1':10, '2':20, '3':30, '4':60}
    if choice == '5':
        minutes = int(input("Minutes: ").strip())
    else:
        minutes = dur_map.get(choice, 30)
    username = f"trial-{uuid.uuid4().hex[:8]}"
    password = f"trial{datetime.now().strftime('%Y%m%d')}"
    expiry = datetime.now() + timedelta(minutes=minutes)
    ssh_port = get_free_port(3000)
    ws_port = get_free_port(4000)
    data_limit = 10
    ip_limit = 2
    dl_speed = 0
    ul_speed = 0
    pwd_hash = bcrypt.hashpw(password.encode(), bcrypt.gensalt())
    conn = get_conn()
    c = conn.cursor()
    c.execute('''INSERT INTO users
        (username, password, is_trial, is_active, ssh_port, ws_port, expires_at,
         data_limit, ip_limit, download_speed, upload_speed)
        VALUES(?,?,?,?,?,?,?,?,?,?,?)''',
        (username, pwd_hash, 1, 1, ssh_port, ws_port, expiry.isoformat(),
         data_limit, ip_limit, dl_speed, ul_speed))
    user_id = c.lastrowid
    conn.commit()
    conn.close()
    with open(f'/etc/ssh/sshd_config.d/{username}.conf', 'w') as f:
        f.write(f"Match User {username}\n")
        f.write(f"    Port {ssh_port}\n")
        f.write("    PasswordAuthentication yes\n")
        f.write("    PermitEmptyPasswords no\n")
        f.write("    ClientAliveInterval 60\n")
        f.write("    TCPKeepAlive yes\n")
        f.write("    ForceCommand /bin/false\n")
    run(['systemctl', 'reload', 'ssh'], check=False)
    log_activity(user_id, 'trial_created', details=f'Duration:{minutes}min')
    
    print_account_info(username, ssh_port, ws_port, data_limit, dl_speed, ul_speed, ip_limit, expiry.isoformat(), password)
    input("\nPress Enter...")

def edit_user():
    clear_screen()
    username = input("Username: ").strip()
    user = get_user(username)
    if not user:
        print("[❌] User not found!")
        input("Press Enter...")
        return
    print(f"\n✏️ EDIT USER: {username}")
    allowed_fields = {'email','data_limit','download_speed','upload_speed','ip_limit','is_active','notes','expires_at'}
    print(f"Available fields: {', '.join(sorted(allowed_fields))} (expires_at format: YYYY-MM-DD HH:MM:SS)")
    field = input("Field: ").strip()
    if field not in allowed_fields:
        print("[❌] Invalid/disallowed field.")
        input("Press Enter...")
        return
    value = input("Value: ").strip()
    if field in ['data_limit', 'download_speed', 'upload_speed', 'ip_limit']:
        value = int(value) if value else 0
    elif field == 'is_active':
        value = 1 if value.lower() in ['y','yes','true'] else 0
    elif field == 'expires_at':
        try:
            datetime.fromisoformat(value)
        except ValueError:
            print("[❌] Invalid date format. Use YYYY-MM-DD HH:MM:SS")
            input("Press Enter...")
            return
    conn = get_conn()
    c = conn.cursor()
    c.execute(f"UPDATE users SET {field}=? WHERE id=?", (value, user['id']))
    conn.commit()
    conn.close()
    log_activity(user['id'], 'user_updated', details=f'{field}={value}')
    print("[✅] Updated!")
    input("Press Enter...")

def delete_user():
    clear_screen()
    username = input("Username: ").strip()
    user = get_user(username)
    if not user:
        print("[❌] User not found!")
        input("Press Enter...")
        return
    if input(f"Delete {username}? (y/n): ").strip().lower() != 'y':
        return
    conn = get_conn()
    c = conn.cursor()
    c.execute("DELETE FROM sessions WHERE user_id=?", (user['id'],))
    c.execute("DELETE FROM logs WHERE user_id=?", (user['id'],))
    c.execute("DELETE FROM users WHERE id=?", (user['id'],))
    conn.commit()
    conn.close()
    conf_file = f'/etc/ssh/sshd_config.d/{username}.conf'
    if os.path.exists(conf_file):
        os.remove(conf_file)
        run(['systemctl', 'reload', 'ssh'], check=False)
    print(f"[🗑️] User {username} deleted!")
    input("Press Enter...")

def change_password():
    clear_screen()
    username = input("Username: ").strip()
    user = get_user(username)
    if not user:
        print("[❌] User not found!")
        input("Press Enter...")
        return
    password = input("New password: ").strip()
    if not password:
        print("[❌] Password required!")
        input("Press Enter...")
        return
    pwd_hash = bcrypt.hashpw(password.encode(), bcrypt.gensalt())
    conn = get_conn()
    c = conn.cursor()
    c.execute("UPDATE users SET password=? WHERE id=?", (pwd_hash, user['id']))
    conn.commit()
    conn.close()
    log_activity(user['id'], 'password_changed')
    print("[✅] Password changed!")
    input("Press Enter...")

def lock_unlock():
    clear_screen()
    username = input("Username: ").strip()
    user = get_user(username)
    if not user:
        print("[❌] User not found!")
        input("Press Enter...")
        return
    if user['is_active']:
        # Lock
        conn = get_conn()
        c = conn.cursor()
        c.execute("UPDATE users SET is_active=0 WHERE id=?", (user['id'],))
        c.execute("UPDATE sessions SET is_active=0 WHERE user_id=? AND is_active=1", (user['id'],))
        conn.commit()
        conn.close()
        log_activity(user['id'], 'account_locked')
        print(f"[🔒] Account {username} locked!")
    else:
        # Unlock
        conn = get_conn()
        c = conn.cursor()
        c.execute("UPDATE users SET is_active=1 WHERE id=?", (user['id'],))
        conn.commit()
        conn.close()
        log_activity(user['id'], 'account_unlocked')
        print(f"[🔓] Account {username} unlocked!")
    input("Press Enter...")

def view_account():
    clear_screen()
    username = input("Username: ").strip()
    user = get_user(username)
    if not user:
        print("[❌] User not found!")
        input("Press Enter...")
        return
    print(f"\n📋 USER: {username}")
    print("="*50)
    for key, val in user.items():
        if key != 'password':
            print(f"{key:20}: {val}")
    input("\nPress Enter...")

def login_history():
    clear_screen()
    username = input("Username: ").strip()
    user = get_user(username)
    if not user:
        print("[❌] User not found!")
        input("Press Enter...")
        return
    conn = get_conn()
    conn.row_factory = sqlite3.Row
    c = conn.cursor()
    c.execute('''SELECT * FROM logs WHERE user_id=? ORDER BY timestamp DESC LIMIT 50''', (user['id'],))
    logs = c.fetchall()
    conn.close()
    if not logs:
        print("[ℹ️] No logs found")
    else:
        table = PrettyTable()
        table.field_names = ["Time", "Action", "IP", "Details"]
        for log in logs:
            table.add_row([log['timestamp'][:19], log['action'], log['ip'] or '-', log['details'] or '-'])
        print(table)
    input("\nPress Enter...")

def disconnect_user():
    clear_screen()
    username = input("Username: ").strip()
    user = get_user(username)
    if not user:
        print("[❌] User not found!")
        input("Press Enter...")
        return
    conn = get_conn()
    c = conn.cursor()
    c.execute("UPDATE sessions SET is_active=0 WHERE user_id=? AND is_active=1", (user['id'],))
    c.execute("UPDATE users SET connections=0 WHERE id=?", (user['id'],))
    conn.commit()
    conn.close()
    log_activity(user['id'], 'disconnected')
    print(f"[✅] User {username} disconnected!")
    input("Press Enter...")

def disconnect_all():
    clear_screen()
    if input("Disconnect ALL users? (y/n): ").strip().lower() != 'y':
        return
    conn = get_conn()
    c = conn.cursor()
    c.execute("UPDATE sessions SET is_active=0 WHERE is_active=1")
    c.execute("UPDATE users SET connections=0")
    conn.commit()
    conn.close()
    print("[✅] All users disconnected!")
    input("Press Enter...")

def backup_restore():
    clear_screen()
    print("1. Backup users")
    print("2. Restore users")
    ch = input("Choice: ").strip()
    if ch == '1':
        backup_path = f"/opt/grvpn/backups/users_{datetime.now().strftime('%Y%m%d_%H%M%S')}.db"
        run(['cp', DB, backup_path], check=False)
        print(f"[✅] Users backed up: {backup_path}")
    elif ch == '2':
        backup = input("Backup path: ").strip()
        if not os.path.exists(backup):
            print("[❌] Backup not found!")
        else:
            if input("Restore users? (y/n): ").strip().lower() != 'y':
                return
            run(['cp', backup, DB], check=False)
            run(['systemctl', 'reload', 'ssh'], check=False)
            print("[✅] Users restored!")
    input("Press Enter...")

# ================== DOMAIN MANAGER ==================
def domain_manager():
    while True:
        clear_screen()
        print("""
╔══════════════════════════════════════════════════════════════════════╗
║  🌐 DOMAIN MANAGER                                                 ║
╠══════════════════════════════════════════════════════════════════════╣
║  1.  View Current Domain                                            ║
║  2.  Set Primary Domain                                             ║
║  3.  Replace Domain (with new certificate)                          ║
║  4.  Renew Certificate                                              ║
║  5.  Install Custom Certificate                                     ║
║  6.  Install Custom Private Key                                     ║
║  7.  Validate Certificate                                           ║
║  8.  Display Certificate Expiry                                     ║
║  9.  Restart Affected Services                                      ║
║  10. Back                                                          ║
╚══════════════════════════════════════════════════════════════════════╝
        """)
        choice = input("🐱 Choice: ").strip()
        if choice == '1': view_domain()
        elif choice == '2': set_domain()
        elif choice == '3': replace_domain()
        elif choice == '4': renew_cert()
        elif choice == '5': install_custom_cert()
        elif choice == '6': install_custom_key()
        elif choice == '7': validate_cert()
        elif choice == '8': cert_expiry()
        elif choice == '9': restart_services()
        elif choice == '10': break

def view_domain():
    clear_screen()
    domain = get_domain()
    print(f"\n🌐 Current Domain: {domain}")
    print(f"   SSL Cert: /etc/ssl/grvpn.pem")
    print(f"   SSL Key: /etc/ssl/grvpn.key")
    input("\nPress Enter...")

def set_domain():
    clear_screen()
    domain = input("Domain: ").strip()
    if not domain:
        print("[❌] Domain required!")
        input("Press Enter...")
        return
    conn = get_conn()
    c = conn.cursor()
    c.execute("UPDATE settings SET value=? WHERE key='domain'", (domain,))
    conn.commit()
    conn.close()
    run(f"sed -i 's/server_name .*/server_name {domain};/g' /etc/nginx/sites-available/grvpn", shell=True, check=False)
    run(['systemctl', 'reload', 'nginx'], check=False)
    print(f"[✅] Domain set to: {domain}")
    input("Press Enter...")

def replace_domain():
    clear_screen()
    old = get_domain()
    print(f"Current domain: {old}")
    new = input("New domain: ").strip()
    if not new:
        print("[❌] Domain required!")
        input("Press Enter...")
        return
    print("[🔐] Obtaining new certificate via acme.sh...")
    run(['systemctl', 'stop', 'nginx'], check=False)
    if run(f"/root/.acme.sh/acme.sh --issue -d {new} --standalone --force", shell=True, check=False).returncode == 0:
        run(f"/root/.acme.sh/acme.sh --install-cert -d {new} --cert-file /etc/ssl/grvpn.pem --key-file /etc/ssl/grvpn.key --fullchain-file /etc/ssl/grvpn-fullchain.pem --reloadcmd 'systemctl reload nginx'", shell=True, check=False)
        conn = get_conn()
        c = conn.cursor()
        c.execute("UPDATE settings SET value=? WHERE key='domain'", (new,))
        conn.commit()
        conn.close()
        run(f"sed -i 's/server_name .*/server_name {new};/g' /etc/nginx/sites-available/grvpn", shell=True, check=False)
        run(['systemctl', 'reload', 'nginx'], check=False)
        print(f"[✅] Domain replaced: {old} -> {new}")
    else:
        print("[❌] Certificate issuance failed.")
        run(['systemctl', 'start', 'nginx'], check=False)
    input("Press Enter...")

def renew_cert():
    clear_screen()
    print("[🔄] Renewing certificate via acme.sh...")
    domain = get_domain()
    run(f"/root/.acme.sh/acme.sh --renew -d {domain} --force", shell=True, check=False)
    run(f"/root/.acme.sh/acme.sh --install-cert -d {domain} --cert-file /etc/ssl/grvpn.pem --key-file /etc/ssl/grvpn.key --fullchain-file /etc/ssl/grvpn-fullchain.pem --reloadcmd 'systemctl reload nginx'", shell=True, check=False)
    print("[✅] Renewal attempted. Check logs if failed.")
    input("Press Enter...")

def install_custom_cert():
    clear_screen()
    cert_path = input("Certificate path: ").strip()
    if not os.path.exists(cert_path):
        print("[❌] Certificate not found!")
        input("Press Enter...")
        return
    run(['cp', cert_path, '/etc/ssl/grvpn.pem'], check=False)
    print("[✅] Certificate installed!")
    input("Press Enter...")

def install_custom_key():
    clear_screen()
    key_path = input("Private key path: ").strip()
    if not os.path.exists(key_path):
        print("[❌] Private key not found!")
        input("Press Enter...")
        return
    run(['cp', key_path, '/etc/ssl/grvpn.key'], check=False)
    run(['chmod', '600', '/etc/ssl/grvpn.key'], check=False)
    print("[✅] Private key installed!")
    input("Press Enter...")

def validate_cert():
    clear_screen()
    result = run(['openssl', 'verify', '-CAfile', '/etc/ssl/grvpn.pem', '/etc/ssl/grvpn.pem'], capture_output=True, check=False)
    if result.returncode == 0:
        print("[✅] Certificate is valid!")
    else:
        print("[❌] Certificate validation failed!")
    input("Press Enter...")

def cert_expiry():
    clear_screen()
    result = run(['openssl', 'x509', '-in', '/etc/ssl/grvpn.pem', '-noout', '-enddate'], capture_output=True, check=False)
    print(f"\n📅 {result.stdout.decode().strip() if result.stdout else 'unavailable'}")
    input("\nPress Enter...")

def restart_services():
    clear_screen()
    for svc in ['nginx', 'ssh', 'stunnel5', 'ws2ssh', 'badvpn-udpgw']:
        run(['systemctl', 'restart', svc], check=False)
        print(f"[✅] {svc} restarted!")
    input("Press Enter...")

# ================== SESSION MONITOR ==================
def session_monitor():
    while True:
        clear_screen()
        print("""
╔══════════════════════════════════════════════════════════════════════╗
║  📊 SESSION MONITOR                                                ║
╠══════════════════════════════════════════════════════════════════════╣
║  1.  View Active Sessions                                           ║
║  2.  View Session Details                                           ║
║  3.  Disconnect Session                                             ║
║  4.  Disconnect All Sessions                                        ║
║  5.  Auto-Refresh (5s)                                              ║
║  6.  Back                                                          ║
╚══════════════════════════════════════════════════════════════════════╝
        """)
        choice = input("🐱 Choice: ").strip()
        if choice == '1': view_sessions()
        elif choice == '2': session_details()
        elif choice == '3': disconnect_session()
        elif choice == '4': disconnect_all_sessions()
        elif choice == '5': auto_refresh_sessions()
        elif choice == '6': break

def view_sessions():
    clear_screen()
    sessions = get_active_sessions()
    if not sessions:
        print("[ℹ️] No active sessions")
        input("Press Enter...")
        return
    table = PrettyTable()
    table.field_names = ["ID", "User", "IP", "Protocol", "Port", "Duration", "Upload", "Download"]
    for s in sessions:
        duration = (datetime.now() - datetime.fromisoformat(s['connected_at'])).seconds // 60
        upload = s['bytes_sent'] // 1024
        download = s['bytes_received'] // 1024
        table.add_row([s['id'], s['username'][:15], s['ip'], s['protocol'],
                       s['port'], f"{duration}m", f"{upload}KB", f"{download}KB"])
    print(table)
    input("\nPress Enter...")

def session_details():
    clear_screen()
    sid = input("Session ID: ").strip()
    conn = get_conn()
    conn.row_factory = sqlite3.Row
    c = conn.cursor()
    c.execute('''SELECT s.*, u.username FROM sessions s
                JOIN users u ON s.user_id = u.id
                WHERE s.id=? AND s.is_active=1''', (sid,))
    session = c.fetchone()
    conn.close()
    if not session:
        print("[❌] Session not found!")
        input("Press Enter...")
        return
    print(f"\n📋 SESSION DETAILS")
    print("="*50)
    for key, val in dict(session).items():
        print(f"{key:20}: {val}")
    input("\nPress Enter...")

def disconnect_session():
    clear_screen()
    sid = input("Session ID: ").strip()
    conn = get_conn()
    c = conn.cursor()
    c.execute("SELECT user_id FROM sessions WHERE id=? AND is_active=1", (sid,))
    row = c.fetchone()
    if not row:
        print("[❌] Session not found!")
        conn.close()
        input("Press Enter...")
        return
    c.execute("UPDATE sessions SET is_active=0 WHERE id=?", (sid,))
    c.execute("UPDATE users SET connections=connections-1 WHERE id=?", (row[0],))
    conn.commit()
    conn.close()
    print("[✅] Session disconnected!")
    input("Press Enter...")

def disconnect_all_sessions():
    clear_screen()
    if input("Disconnect ALL sessions? (y/n): ").strip().lower() != 'y':
        return
    conn = get_conn()
    c = conn.cursor()
    c.execute("UPDATE sessions SET is_active=0 WHERE is_active=1")
    c.execute("UPDATE users SET connections=0")
    conn.commit()
    conn.close()
    print("[✅] All sessions disconnected!")
    input("Press Enter...")

def auto_refresh_sessions():
    try:
        while True:
            clear_screen()
            print("📊 SESSION MONITOR - Auto-Refresh (5s)")
            print("Press Ctrl+C to stop")
            print("="*50)
            sessions = get_active_sessions()
            if sessions:
                table = PrettyTable()
                table.field_names = ["User", "IP", "Protocol", "Port", "Duration"]
                for s in sessions:
                    duration = (datetime.now() - datetime.fromisoformat(s['connected_at'])).seconds // 60
                    table.add_row([s['username'][:15], s['ip'], s['protocol'], s['port'], f"{duration}m"])
                print(table)
            else:
                print("[ℹ️] No active sessions")
            time.sleep(5)
    except KeyboardInterrupt:
        pass

# ================== SERVER DASHBOARD ==================
def server_dashboard():
    clear_screen()
    cpu = psutil.cpu_percent()
    mem = psutil.virtual_memory()
    disk = psutil.disk_usage('/')
    net = psutil.net_io_counters()

    conn = get_conn()
    c = conn.cursor()
    c.execute("SELECT COUNT(*) FROM users WHERE is_active=1")
    total_users = c.fetchone()[0]
    c.execute("SELECT COUNT(*) FROM sessions WHERE is_active=1")
    active_sessions = c.fetchone()[0]
    conn.close()

    print("""
╔══════════════════════════════════════════════════════════════════════╗
║  📈 SERVER DASHBOARD                                               ║
╠══════════════════════════════════════════════════════════════════════╣
""")
    print(f"║  🖥️  CPU           : {cpu}%")
    print(f"║  💾 Memory       : {mem.used/1024**3:.2f}GB / {mem.total/1024**3:.2f}GB ({mem.percent}%)")
    print(f"║  💿 Disk         : {disk.used/1024**3:.2f}GB / {disk.total/1024**3:.2f}GB ({disk.percent}%)")
    print(f"║  🌐 Network      : Sent {net.bytes_sent/1024**3:.2f}GB | Received {net.bytes_recv/1024**3:.2f}GB")
    print("╠══════════════════════════════════════════════════════════════════════╣")
    print(f"║  👥 Users        : {total_users} Total")
    print(f"║  🔌 Sessions     : {active_sessions} Active")
    print("╚══════════════════════════════════════════════════════════════════════╝")
    input("\nPress Enter...")

# ================== BACKUP MANAGER ==================
def backup_manager():
    while True:
        clear_screen()
        print("""
╔══════════════════════════════════════════════════════════════════════╗
║  💾 BACKUP MANAGER                                                 ║
╠══════════════════════════════════════════════════════════════════════╣
║  1.  Create Full Backup                                             ║
║  2.  Create User Backup                                             ║
║  3.  Create Config Backup                                           ║
║  4.  List Backups                                                   ║
║  5.  Restore Backup                                                 ║
║  6.  Clean Old Backups                                              ║
║  7.  Back                                                          ║
╚══════════════════════════════════════════════════════════════════════╝
        """)
        choice = input("🐱 Choice: ").strip()
        if choice == '1': full_backup()
        elif choice == '2': user_backup()
        elif choice == '3': config_backup()
        elif choice == '4': list_backups()
        elif choice == '5': restore_backup()
        elif choice == '6': clean_backups()
        elif choice == '7': break

def full_backup():
    clear_screen()
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    path = f"/opt/grvpn/backups/full_backup_{ts}"
    os.makedirs(path, exist_ok=True)
    run(f"cp -r /opt/grvpn/data {path}/", shell=True, check=False)
    run(f"cp -r /etc/nginx/sites-available {path}/", shell=True, check=False)
    run(f"cp -r /etc/stunnel5 {path}/", shell=True, check=False)
    run(f"cp -r /etc/ssh/sshd_config.d {path}/", shell=True, check=False)
    run(f"cp /etc/ssl/grvpn.pem {path}/", shell=True, check=False)
    run(f"cp /etc/ssl/grvpn.key {path}/", shell=True, check=False)
    print(f"[✅] Full backup created: {path}")
    input("Press Enter...")

def user_backup():
    clear_screen()
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    path = f"/opt/grvpn/backups/users_{ts}.db"
    run(['cp', DB, path], check=False)
    print(f"[✅] Users backed up: {path}")
    input("Press Enter...")

def config_backup():
    clear_screen()
    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    path = f"/opt/grvpn/backups/config_{ts}.tar.gz"
    run(f"tar -czf {path} /etc/nginx/sites-available /etc/stunnel5 /etc/ssh/sshd_config.d", shell=True, check=False)
    print(f"[✅] Config backed up: {path}")
    input("Press Enter...")

def list_backups():
    clear_screen()
    run("ls -lh /opt/grvpn/backups/", shell=True, check=False)
    input("\nPress Enter...")

def restore_backup():
    clear_screen()
    backup = input("Backup path: ").strip()
    if not os.path.exists(backup):
        print("[❌] Backup not found!")
        input("Press Enter...")
        return
    if input("Restore will overwrite current data! Continue? (y/n): ").strip().lower() != 'y':
        return
    if os.path.isdir(backup):
        run(f"cp -r {backup}/data/* /opt/grvpn/data/", shell=True, check=False)
        run(f"cp -r {backup}/sites-available/* /etc/nginx/sites-available/", shell=True, check=False)
        run(f"cp -r {backup}/stunnel5/* /etc/stunnel5/", shell=True, check=False)
        run(f"cp -r {backup}/sshd_config.d/* /etc/ssh/sshd_config.d/", shell=True, check=False)
        if os.path.exists(f"{backup}/grvpn.pem"):
            run(f"cp {backup}/grvpn.pem /etc/ssl/grvpn.pem", shell=True, check=False)
            run(f"cp {backup}/grvpn.key /etc/ssl/grvpn.key", shell=True, check=False)
    else:
        run(f"cp {backup} /opt/grvpn/data/grvpn.db", shell=True, check=False)
    run(['systemctl', 'reload', 'nginx'], check=False)
    run(['systemctl', 'reload', 'ssh'], check=False)
    run(['systemctl', 'restart', 'stunnel5'], check=False)
    print("[✅] Restored!")
    input("Press Enter...")

def clean_backups():
    clear_screen()
    days = int(input("Keep backups from last N days (default 30): ").strip() or "30")
    run(f"find /opt/grvpn/backups -type f -mtime +{days} -delete", shell=True, check=False)
    run(f"find /opt/grvpn/backups -type d -empty -mtime +{days} -delete", shell=True, check=False)
    print(f"[✅] Cleaned backups older than {days} days.")
    input("Press Enter...")

# ================== UPDATE MANAGER ==================
def update_manager():
    while True:
        clear_screen()
        print("""
╔══════════════════════════════════════════════════════════════════════╗
║  🔄 UPDATE MANAGER                                                 ║
╠══════════════════════════════════════════════════════════════════════╣
║  1.  Check for Updates                                              ║
║  2.  Update Application (pull from Git + re-run installer)          ║
║  3.  Update Dependencies (apt + pip, latest versions)                ║
║  4.  Restart Services After Update                                 ║
║  5.  View Update/Install Log                                        ║
║  6.  Back                                                          ║
╚══════════════════════════════════════════════════════════════════════╝
        """)
        choice = input("🐱 Choice: ").strip()
        if choice == '1': check_updates()
        elif choice == '2': update_app()
        elif choice == '3': update_deps()
        elif choice == '4': restart_after_update()
        elif choice == '5': view_update_log()
        elif choice == '6': break

def check_updates():
    clear_screen()
    print("[🔄] Checking for updates...")
    run(['git', '-C', '/opt/grvpn', 'remote', 'update'], check=False)
    status = run(['git', '-C', '/opt/grvpn', 'status', '-uno'], capture_output=True, text=True, check=False)
    if status.stdout and "Your branch is behind" in status.stdout:
        print("[✅] Updates available!")
    else:
        print("[ℹ️] Already up to date (or not a git checkout).")
    input("\nPress Enter...")

def update_app():
    clear_screen()
    print("[🔄] Pulling updates from Git and re-running installer (idempotent — your data/config is preserved)...")
    run(['git', '-C', '/opt/grvpn', 'pull'], check=False)
    result = run(['bash', '/opt/grvpn/install.sh'], check=False)
    if result.returncode == 0:
        print("[✅] Application updated.")
    else:
        print("[⚠️] Installer exited with a non-zero status — check the log below.")
    input("\nPress Enter...")

def update_deps():
    clear_screen()
    print("[🔄] Updating system dependencies to latest versions...")
    run("apt-get update -qq && apt-get upgrade -y -qq", shell=True, check=False)
    run(['pip3', 'install', '--upgrade',
         'psutil', 'bcrypt', 'sqlalchemy', 'redis',
         'requests', 'colorama', 'prettytable', 'tabulate', 'python-dateutil', 'websockets', 'asyncio', '--quiet'], check=False)
    print("[✅] Dependencies updated.")
    input("Press Enter...")

def restart_after_update():
    clear_screen()
    for svc in ['nginx', 'ssh', 'stunnel5', 'ws2ssh', 'badvpn-udpgw']:
        run(['systemctl', 'restart', svc], check=False)
        print(f"[✅] {svc} restarted!")
    input("Press Enter...")

def view_update_log():
    clear_screen()
    if os.path.exists('/var/log/grvpn/install.log'):
        lines = input("Lines (default 80): ").strip() or "80"
        run(['tail', f'-{lines}', '/var/log/grvpn/install.log'], check=False)
    else:
        print("[ℹ️] No install/update log found.")
    input("\nPress Enter...")

# ================== SECURITY MANAGER ==================
def security_manager():
    while True:
        clear_screen()
        print("""
╔══════════════════════════════════════════════════════════════════════╗
║  🛡️ SECURITY MANAGER                                               ║
╠══════════════════════════════════════════════════════════════════════╣
║  1.  View Firewall Rules                                            ║
║  2.  Add Firewall Rule                                              ║
║  3.  Remove Firewall Rule                                           ║
║  4.  View IP Blacklist                                              ║
║  5.  Add IP to Blacklist                                            ║
║  6.  Remove IP from Blacklist                                       ║
║  7.  View Fail2ban Status                                           ║
║  8.  Restart Fail2ban                                               ║
║  9.  Back                                                          ║
╚══════════════════════════════════════════════════════════════════════╝
        """)
        choice = input("🐱 Choice: ").strip()
        if choice == '1': view_firewall()
        elif choice == '2': add_firewall()
        elif choice == '3': remove_firewall()
        elif choice == '4': view_blacklist()
        elif choice == '5': add_blacklist()
        elif choice == '6': remove_blacklist()
        elif choice == '7': fail2ban_status()
        elif choice == '8': restart_fail2ban()
        elif choice == '9': break

def view_firewall():
    clear_screen()
    run(['ufw', 'status', 'numbered'], check=False)
    input("\nPress Enter...")

def add_firewall():
    clear_screen()
    port = input("Port: ").strip()
    proto = input("Protocol (tcp/udp): ").strip() or "tcp"
    if not port.isdigit():
        print("[❌] Invalid port.")
        input("Press Enter...")
        return
    run(['ufw', 'allow', f"{port}/{proto}"], check=False)
    print(f"[✅] Port {port}/{proto} allowed!")
    input("Press Enter...")

def remove_firewall():
    clear_screen()
    run(['ufw', 'status', 'numbered'], check=False)
    num = input("Rule number to delete: ").strip()
    run(['ufw', '--force', 'delete', num], check=False)
    print("[✅] Rule deleted!")
    input("Press Enter...")

def view_blacklist():
    clear_screen()
    conn = get_conn()
    c = conn.cursor()
    c.execute("SELECT ip, reason, created_at FROM ip_rules WHERE action='block' AND is_active=1")
    rows = c.fetchall()
    conn.close()
    if not rows:
        print("[ℹ️] No IPs blacklisted")
    else:
        table = PrettyTable()
        table.field_names = ["IP", "Reason", "Created"]
        for r in rows:
            table.add_row(r)
        print(table)
    input("\nPress Enter...")

def add_blacklist():
    clear_screen()
    ip = input("IP to block: ").strip()
    reason = input("Reason: ").strip()
    conn = get_conn()
    c = conn.cursor()
    c.execute("INSERT OR REPLACE INTO ip_rules(ip, action, reason) VALUES(?, 'block', ?)", (ip, reason))
    conn.commit()
    conn.close()
    run(['iptables', '-A', 'INPUT', '-s', ip, '-j', 'DROP'], check=False)
    run(['ufw', 'deny', 'from', ip], check=False)
    print(f"[🛡️] IP {ip} blocked!")
    input("Press Enter...")

def remove_blacklist():
    clear_screen()
    ip = input("IP to unblock: ").strip()
    conn = get_conn()
    c = conn.cursor()
    c.execute("UPDATE ip_rules SET is_active=0 WHERE ip=?", (ip,))
    conn.commit()
    conn.close()
    run(['iptables', '-D', 'INPUT', '-s', ip, '-j', 'DROP'], check=False)
    run(['ufw', 'delete', 'deny', 'from', ip], check=False)
    print(f"[✅] IP {ip} unblocked!")
    input("Press Enter...")

def fail2ban_status():
    clear_screen()
    run(['fail2ban-client', 'status'], check=False)
    input("\nPress Enter...")

def restart_fail2ban():
    run(['systemctl', 'restart', 'fail2ban'], check=False)
    print("[✅] Fail2ban restarted!")
    input("Press Enter...")

# ================== LOGS VIEWER ==================
def logs_viewer():
    while True:
        clear_screen()
        print("""
╔══════════════════════════════════════════════════════════════════════╗
║  📜 LOGS VIEWER                                                    ║
╠══════════════════════════════════════════════════════════════════════╣
║  1.  SSH Logs                                                       ║
║  2.  Authentication Logs                                            ║
║  3.  Nginx Error Logs                                               ║
║  4.  Stunnel Logs                                                   ║
║  5.  WebSocket Proxy Logs (ws2ssh)                                 ║
║  6.  Installer Logs                                                 ║
║  7.  System Logs                                                    ║
║  8.  Back                                                          ║
╚══════════════════════════════════════════════════════════════════════╝
        """)
        choice = input("🐱 Choice: ").strip()
        if choice == '1': view_ssh_logs()
        elif choice == '2': view_auth_logs()
        elif choice == '3': view_nginx_logs()
        elif choice == '4': view_tls_logs()
        elif choice == '5': view_ws_logs()
        elif choice == '6': view_installer_logs()
        elif choice == '7': view_system_logs()
        elif choice == '8': break

def view_ssh_logs():
    clear_screen()
    lines = input("Lines (default 50): ").strip() or "50"
    run(['journalctl', '-u', 'ssh', '-n', lines, '--no-pager'], check=False)
    input("\nPress Enter...")

def view_auth_logs():
    clear_screen()
    lines = input("Lines (default 50): ").strip() or "50"
    run(['tail', f'-{lines}', '/var/log/auth.log'], check=False)
    input("\nPress Enter...")

def view_tls_logs():
    clear_screen()
    lines = input("Lines (default 50): ").strip() or "50"
    run(['tail', f'-{lines}', '/var/log/stunnel5.log'], check=False)
    input("\nPress Enter...")

def view_ws_logs():
    clear_screen()
    lines = input("Lines (default 50): ").strip() or "50"
    run(['journalctl', '-u', 'ws2ssh', '-n', lines, '--no-pager'], check=False)
    input("\nPress Enter...")

def view_installer_logs():
    clear_screen()
    if os.path.exists('/var/log/grvpn/install.log'):
        lines = input("Lines (default 50): ").strip() or "50"
        run(['tail', f'-{lines}', '/var/log/grvpn/install.log'], check=False)
    else:
        print("[ℹ️] No installer log found.")
    input("\nPress Enter...")

def view_system_logs():
    clear_screen()
    lines = input("Lines (default 50): ").strip() or "50"
    run(['journalctl', '-n', lines, '--no-pager'], check=False)
    input("\nPress Enter...")

# ================== RUN ==================
if __name__ == "__main__":
    try:
        main_menu()
    except KeyboardInterrupt:
        print("\n[👋] Goodbye!")
        sys.exit(0)
PANEL_EOF

chmod +x "${PANEL_SCRIPT}"

# ─── Symlink ──────────────────────────────────────────────────────────
log_info "Creating symlink..."
cat > "${SYMLINK}" << 'SYM_EOF'
#!/bin/bash
python3 /opt/grvpn/bin/grvpn-panel.py "$@"
SYM_EOF
chmod +x "${SYMLINK}"

# ─── Cron watchdog for Python WebSocket and UDPGW ──────────────────
log_info "Adding cron watchdog for ws2ssh and badvpn..."
cat > /etc/cron.d/grvpn-watchdog << 'WATCHDOG_EOF'
# Every minute, restart services if they are not running
* * * * * root systemctl is-active --quiet ws2ssh || systemctl restart ws2ssh
* * * * * root systemctl is-active --quiet badvpn-udpgw || systemctl restart badvpn-udpgw
WATCHDOG_EOF
chmod 644 /etc/cron.d/grvpn-watchdog

# ─── Cron jobs for maintenance ────────────────────────────────────────
log_info "Setting up cron jobs..."
cat > /etc/cron.d/grvpn << 'CRON_EOF'
# GRVPN Maintenance Jobs
# Weekly cleanup at 3 AM Sunday
0 3 * * 0 root find /opt/grvpn/backups -type f -mtime +30 -delete > /dev/null 2>&1
# Check expired trials every hour
0 * * * * root sqlite3 /opt/grvpn/data/grvpn.db "UPDATE users SET is_active=0 WHERE is_trial=1 AND expires_at < datetime('now')" > /dev/null 2>&1
# acme.sh auto-renewal is handled by its own cron
CRON_EOF

command_exists cron && { systemctl enable cron 2>/dev/null || true; systemctl restart cron 2>/dev/null || true; }

# ─── Start services ──────────────────────────────────────────────────
log_info "Starting services..."
systemctl daemon-reload
for svc in nginx ssh stunnel5 ws2ssh badvpn-udpgw fail2ban; do
    if systemctl enable "$svc" 2>/dev/null && systemctl restart "$svc" 2>/dev/null; then
        log_ok "${svc} running."
    else
        log_warn "${svc} did not start cleanly — check 'systemctl status ${svc}'."
        FAILED_STEPS+=("service: ${svc}")
    fi
done

# ─── Final message ──────────────────────────────────────────────────
echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  🐱 GRVPN ENTERPRISE SSH SERVER MANAGER v${VERSION} INSTALLED!       ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║                                                                      ║"
echo "║  📌 Run: grvpn                                                       ║"
if [[ -f "${DATA_DIR}/.admin_credentials" ]]; then
echo "║  🔐 Admin credentials saved to: /opt/grvpn/data/.admin_credentials  ║"
fi
echo "║                                                                      ║"
echo "║  🌐 Domain: ${DOMAIN}"
echo "║  🔹 WebSocket backend port: 8080 (fixed)                             ║"
echo "║  🔹 UDPGW port: 7300 (UDP over TCP tunnel)                           ║"
echo "║                                                                      ║"
echo "║  📡 WEBSOCKET CONNECTION (with payload):                             ║"
echo "║  WS: ws://${DOMAIN}/                                                 ║"
echo "║  WSS: wss://${DOMAIN}/                                               ║"
echo "║                                                                      ║"
echo "║  📂 Install dir: /opt/grvpn                                         ║"
echo "║  📋 Logs: /var/log/grvpn/install.log                                ║"
echo "║  🔄 Update: git pull && bash install.sh   (safe to re-run anytime)  ║"
echo "║                                                                      ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

if (( ${#FAILED_PACKAGES[@]} > 0 || ${#FAILED_STEPS[@]} > 0 )); then
    echo -e "${YELLOW}"
    echo "──────────────────────────────────────────────────────────────────────"
    echo " ⚠️  Install finished, but with issues that need your attention:"
    (( ${#FAILED_PACKAGES[@]} > 0 )) && echo "   • Packages that failed: ${FAILED_PACKAGES[*]}"
    (( ${#FAILED_STEPS[@]} > 0 ))    && printf '   • Steps that failed: %s\n' "${FAILED_STEPS[*]}"
    echo " Full log: ${INSTALL_LOG}"
    echo " Fix the issue and just re-run: bash install.sh — it's idempotent."
    echo "──────────────────────────────────────────────────────────────────────"
    echo -e "${NC}"
else
    log_ok "Everything installed cleanly."
fi

# ─── Run panel ────────────────────────────────────────────────────────
grvpn
