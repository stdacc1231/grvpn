#!/bin/bash
# GRVPN ENTERPRISE SSH SERVER MANAGER v4.0
# Production-Ready OpenSSH Management Platform
# Run as root

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

# Version
VERSION="4.0.0"
RELEASE_DATE="2026-07-14"

# Banner
clear
echo -e "${CYAN}"
cat << "EOF"
╔══════════════════════════════════════════════════════════════════════╗
║                                                                      ║
║   ██████╗ ██████╗ ██╗   ██╗██████╗ ███╗   ██╗                      ║
║  ██╔════╝ ██╔══██╗██║   ██║██╔══██╗████╗  ██║                      ║
║  ██║  ███╗██████╔╝██║   ██║██████╔╝██╔██╗ ██║                      ║
║  ██║   ██║██╔══██╗╚██╗ ██╔╝██╔═══╝ ██║╚██╗██║                      ║
║  ╚██████╔╝██║  ██║ ╚████╔╝ ██║     ██║ ╚████║                      ║
║   ╚═════╝ ╚═╝  ╚═╝  ╚═══╝  ╚═╝     ╚═╝  ╚═══╝                      ║
║                                                                      ║
║  ███████╗███╗   ██╗████████╗███████╗██████╗ ██████╗ ██████╗ ██╗███████╗
║  ██╔════╝████╗  ██║╚══██╔══╝██╔════╝██╔══██╗██╔══██╗██╔══██╗██║██╔════╝
║  █████╗  ██╔██╗ ██║   ██║   █████╗  ██████╔╝██████╔╝██████╔╝██║███████╗
║  ██╔══╝  ██║╚██╗██║   ██║   ██╔══╝  ██╔══██╗██╔══██╗██╔══██╗██║╚════██║
║  ███████╗██║ ╚████║   ██║   ███████╗██║  ██║██████╔╝██║  ██║██║███████║
║  ╚══════╝╚═╝  ╚═══╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═════╝ ╚═╝  ╚═╝╚═╝╚══════╝
║                                                                      ║
║  🐱 GRVPN ENTERPRISE SSH SERVER MANAGER v${VERSION}                    ║
║  Production-Ready OpenSSH Management Platform                        ║
║  Release: ${RELEASE_DATE}                                              ║
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# Check root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[❌] Run as root!${NC}"
    exit 1
fi

# Variables
INSTALL_DIR="/opt/grvpn"
DATA_DIR="${INSTALL_DIR}/data"
CONFIG_DIR="${INSTALL_DIR}/config"
LOG_DIR="${INSTALL_DIR}/logs"
BACKUP_DIR="${INSTALL_DIR}/backups"
MODULE_DIR="${INSTALL_DIR}/modules"
BIN_DIR="${INSTALL_DIR}/bin"
DB_FILE="${DATA_DIR}/grvpn.db"
PORT_START=2000

# Ask for domain
while true; do
    read -r -p "Enter your domain (e.g. ssh.example.com): " DOMAIN </dev/tty

    if [[ -n "$DOMAIN" ]]; then
        break
    fi

    echo "Domain cannot be empty."
done

echo -e "${GREEN}[✅] Using domain: $DOMAIN${NC}"

# Get server IP
SERVER_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || hostname -I | awk '{print $1}')
echo -e "${BLUE}[🌐] Server IP: $SERVER_IP${NC}"
echo -e "${YELLOW}[⚠️] Make sure DNS A record points $DOMAIN -> $SERVER_IP${NC}"
echo ""
echo -n "Press Enter to continue..."
read

# Create directories
echo -e "${BLUE}[📁] Creating directory structure...${NC}"
mkdir -p ${INSTALL_DIR} ${DATA_DIR} ${CONFIG_DIR} ${LOG_DIR} ${BACKUP_DIR} ${MODULE_DIR} ${BIN_DIR}
mkdir -p /etc/grvpn /var/log/grvpn /etc/ssh/sshd_config.d

# Update system
echo -e "${BLUE}[🔄] Updating system...${NC}"
apt update && apt upgrade -y

# Install core packages
echo -e "${BLUE}[📦] Installing core packages...${NC}"
apt install -y openssh-server nginx stunnel5 \
    certbot python3-certbot-nginx python3-pip \
    screen tmux ufw fail2ban redis-server \
    sqlite3 bc net-tools iptables-persistent \
    curl wget git unzip jq htop nload \
    openssl netcat socat python3-bcrypt \
    apache2-utils whois dnsutils uuid-runtime \
    sshuttle python3-sshuttle iptables \
    build-essential autoconf libtool pkg-config \
    htop nload iftop iotop ncdu

# Install Python packages
echo -e "${BLUE}[🐍] Installing Python packages...${NC}"
pip3 install psutil bcrypt cryptography pyOpenSSL sqlalchemy redis requests \
    colorama prettytable tabulate python-dateutil

# Install websocat
echo -e "${BLUE}[🌐] Installing websocat...${NC}"
wget -q -O /usr/local/bin/websocat https://github.com/vi/websocat/releases/download/v1.12.0/websocat.x86_64-unknown-linux-musl
chmod +x /usr/local/bin/websocat

# Get SSL certificate
echo -e "${BLUE}[🔐] Generating SSL certificate for $DOMAIN...${NC}"
systemctl stop nginx 2>/dev/null || true

certbot certonly --standalone -d "$DOMAIN" \
    --non-interactive --agree-tos \
    -m "admin@$DOMAIN" \
    --keep-until-expiring 2>/dev/null

if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    echo -e "${GREEN}[✅] Let's Encrypt certificate obtained!${NC}"
else
    echo -e "${YELLOW}[⚠️] Using self-signed...${NC}"
    mkdir -p "/etc/letsencrypt/live/$DOMAIN"
    openssl req -x509 -newkey rsa:4096 -keyout "/etc/letsencrypt/live/$DOMAIN/privkey.pem" \
        -out "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" -days 365 -nodes \
        -subj "/CN=$DOMAIN"
    CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
fi

cp "$CERT_PATH" /etc/ssl/grvpn.pem
cp "$KEY_PATH" /etc/ssl/grvpn.key
chmod 600 /etc/ssl/grvpn.key
chmod 644 /etc/ssl/grvpn.pem

# Harden SSH
echo -e "${BLUE}[🔒] Hardening OpenSSH...${NC}"
cat > /etc/ssh/sshd_config << 'EOF'
# GRVPN Enterprise SSH Configuration
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

# Security Hardening
PermitRootLogin no
PasswordAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd yes
PrintLastLog yes

# Performance
ClientAliveInterval 60
ClientAliveCountMax 3
TCPKeepAlive yes
Compression yes
MaxSessions 1000
MaxStartups 500:30:1000
LoginGraceTime 30

# Tunnel Support
PermitTunnel yes
AllowTcpForwarding yes
GatewayPorts yes

# Ciphers
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,umac-128-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,diffie-hellman-group-exchange-sha256
EOF

# Create SSH config directory
mkdir -p /etc/ssh/sshd_config.d

# Generate SSH host keys
ssh-keygen -A

# Configure Nginx
echo -e "${BLUE}[🔧] Configuring Nginx...${NC}"
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

    # WebSocket ROOT "/"
    location / {
        proxy_pass http://127.0.0.1:8080;
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

    # Health check
    location /health {
        access_log off;
        return 200 "OK";
        add_header Content-Type text/plain;
    }
}
EOF

ln -sf /etc/nginx/sites-available/grvpn /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Configure Stunnel5
echo -e "${BLUE}[🔧] Configuring Stunnel5...${NC}"
cat > /etc/stunnel5/stunnel.conf << 'STUNNEL_EOF'
; GRVPN Enterprise Stunnel5 Configuration
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
accept = 0.0.0.0:8080
connect = 127.0.0.1:22
cert = /etc/ssl/grvpn.pem
key = /etc/ssl/grvpn.key
protocol = websocket
retry = yes
TIMEOUTclose = 0
STUNNEL_EOF

# Configure Fail2ban
echo -e "${BLUE}[🛡️] Configuring Fail2ban...${NC}"
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

[recidive]
enabled = true
filter = recidive
logpath = /var/log/fail2ban.log
maxretry = 3
bantime = 86400
FAIL2BAN_EOF

# Configure UFW
echo -e "${BLUE}[🔥] Configuring firewall...${NC}"
ufw allow 22/tcp 2>/dev/null || true
ufw allow 80/tcp 2>/dev/null || true
ufw allow 443/tcp 2>/dev/null || true
ufw allow 8443/tcp 2>/dev/null || true
ufw allow 2052/tcp 2>/dev/null || true
ufw allow 2053/tcp 2>/dev/null || true
ufw allow 2082/tcp 2>/dev/null || true
ufw allow 2083/tcp 2>/dev/null || true
ufw allow 2086/tcp 2>/dev/null || true
ufw allow 2087/tcp 2>/dev/null || true
ufw allow 2095/tcp 2>/dev/null || true
ufw allow 2096/tcp 2>/dev/null || true
ufw allow 8880/tcp 2>/dev/null || true
ufw allow 8080/tcp 2>/dev/null || true
ufw --force enable 2>/dev/null || true

# Optimize kernel
echo -e "${BLUE}[⚡] Optimizing kernel...${NC}"
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

net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

fs.file-max = 2097152
vm.swappiness = 10
vm.vfs_cache_pressure = 50
KERNEL_EOF

sysctl -p 2>/dev/null || true

# Set file limits
echo -e "${BLUE}[📊] Setting file limits...${NC}"
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

# Create database
echo -e "${BLUE}[💾] Creating database...${NC}"
sqlite3 ${DB_FILE} << 'SQL_EOF'
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
    ('domain', '$DOMAIN'),
    ('server_name', 'GRVPN Enterprise Server'),
    ('version', '$VERSION'),
    ('trial_duration', '30'),
    ('default_data_limit', '0'),
    ('default_download_speed', '0'),
    ('default_upload_speed', '0'),
    ('default_ip_limit', '0');
SQL_EOF

# Create admin user
echo -e "${BLUE}[👤] Creating admin user...${NC}"
python3 << 'PYTHON_ADMIN'
import sqlite3, bcrypt, uuid
DB = '/opt/grvpn/data/grvpn.db'
conn = sqlite3.connect(DB)
c = conn.cursor()
c.execute("SELECT * FROM users WHERE username='grvpn'")
if not c.fetchone():
    pwd = bcrypt.hashpw(b'GRVPN@2026', bcrypt.gensalt())
    c.execute("INSERT INTO users(username, password, is_admin, is_active, ssh_port, ws_port) VALUES('grvpn', ?, 1, 1, 2000, 3000)", (pwd,))
    conn.commit()
conn.close()
print("[✅] Admin created: grvpn / GRVPN@2026")
PYTHON_ADMIN

# Create main panel
echo -e "${BLUE}[📝] Creating GRVPN Enterprise Panel...${NC}"
cat > ${BIN_DIR}/grvpn-panel << 'PANEL_EOF'
#!/usr/bin/env python3
"""
╔══════════════════════════════════════════════════════════════════════╗
║  🐱 GRVPN ENTERPRISE SSH SERVER MANAGER v4.0                      ║
║  Production-Ready OpenSSH Management Platform                     ║
║  Enterprise-Grade | High Performance | Secure                     ║
╚══════════════════════════════════════════════════════════════════════╝
"""

import os, sys, sqlite3, subprocess, time, json, psutil, bcrypt, uuid, platform
from datetime import datetime, timedelta
from prettytable import PrettyTable
import colorama
colorama.init()

# ============ CONSTANTS ============
INSTALL_DIR = '/opt/grvpn'
DB = f'{INSTALL_DIR}/data/grvpn.db'
VERSION = '4.0.0'

# ============ DATABASE ============
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

def log_activity(user_id, action, ip='', details=''):
    conn = get_conn()
    c = conn.cursor()
    c.execute("INSERT INTO logs(user_id, action, ip, details) VALUES(?,?,?,?)",
              (user_id, action, ip, details))
    conn.commit()
    conn.close()

def get_free_port(base):
    used = set()
    conn = get_conn()
    c = conn.cursor()
    c.execute("SELECT ssh_port, ws_port FROM users")
    for row in c.fetchall():
        if row[0]: used.add(row[0])
        if row[1]: used.add(row[1])
    conn.close()
    reserved = [22,80,443,8080,8443,2052,2053,2082,2083,2086,2087,2095,2096,8880]
    for p in reserved:
        used.add(p)
    port = base
    while port in used:
        port += 1
    return port

def clear_screen():
    os.system('clear' if os.name == 'posix' else 'cls')

def get_domain():
    conn = get_conn()
    c = conn.cursor()
    c.execute("SELECT value FROM settings WHERE key='domain'")
    result = c.fetchone()
    conn.close()
    return result[0] if result else 'localhost'

# ============ MAIN MENU ============
def main_menu():
    while True:
        clear_screen()
        print(f"""
╔══════════════════════════════════════════════════════════════════════╗
║  🐱 GRVPN ENTERPRISE SSH SERVER MANAGER v{VERSION}                  ║
║  Production-Ready OpenSSH Management Platform                      ║
╠══════════════════════════════════════════════════════════════════════╣
║  1.  👤 SSH Manager (Users & Accounts)                             ║
║  2.  🌐 Domain Manager                                              ║
║  3.  🔒 TLS Manager                                                 ║
║  4.  🌍 Nginx Manager                                               ║
║  5.  📋 Banner Manager                                              ║
║  6.  📊 Session Monitor                                             ║
║  7.  📈 Server Dashboard                                            ║
║  8.  💾 Backup Manager                                              ║
║  9.  🔄 Update Manager                                              ║
║  10. 🛡️ Security Manager                                            ║
║  11. 📜 Logs                                                        ║
║  12. ⚙️  System Services                                            ║
║  13. 🚪 Exit                                                       ║
╚══════════════════════════════════════════════════════════════════════╝
        """)
        
        choice = input("🐱 Choice: ").strip()
        
        if choice == '1': ssh_manager()
        elif choice == '2': domain_manager()
        elif choice == '3': tls_manager()
        elif choice == '4': nginx_manager()
        elif choice == '5': banner_manager()
        elif choice == '6': session_monitor()
        elif choice == '7': server_dashboard()
        elif choice == '8': backup_manager()
        elif choice == '9': update_manager()
        elif choice == '10': security_manager()
        elif choice == '11': logs_viewer()
        elif choice == '12': system_services()
        elif choice == '13':
            print("\n[👋] Goodbye!")
            sys.exit(0)

# ============ SSH MANAGER ============
def ssh_manager():
    while True:
        clear_screen()
        print("""
╔══════════════════════════════════════════════════════════════════════╗
║  👤 SSH MANAGER - User & Account Management                       ║
╠══════════════════════════════════════════════════════════════════════╣
║  1.  List Users                                                     ║
║  2.  Create User                                                    ║
║  3.  Create Trial User                                              ║
║  4.  Edit User                                                      ║
║  5.  Delete User                                                    ║
║  6.  Renew Account                                                  ║
║  7.  Change Password                                                ║
║  8.  Change Expiry                                                  ║
║  9.  Change Quota                                                   ║
║  10. Change Bandwidth Limits                                        ║
║  11. Change IP Limit                                                ║
║  12. Lock Account                                                   ║
║  13. Unlock Account                                                 ║
║  14. View Account                                                   ║
║  15. View Login History                                             ║
║  16. Disconnect User                                                ║
║  17. Disconnect All Sessions                                        ║
║  18. Backup Users                                                   ║
║  19. Restore Users                                                  ║
║  20. Back to Main                                                   ║
╚══════════════════════════════════════════════════════════════════════╝
        """)
        
        choice = input("🐱 Choice: ").strip()
        
        if choice == '1': list_users()
        elif choice == '2': create_user()
        elif choice == '3': create_trial()
        elif choice == '4': edit_user()
        elif choice == '5': delete_user()
        elif choice == '6': renew_account()
        elif choice == '7': change_password()
        elif choice == '8': change_expiry()
        elif choice == '9': change_quota()
        elif choice == '10': change_bandwidth()
        elif choice == '11': change_iplimit()
        elif choice == '12': lock_account()
        elif choice == '13': unlock_account()
        elif choice == '14': view_account()
        elif choice == '15': login_history()
        elif choice == '16': disconnect_user()
        elif choice == '17': disconnect_all()
        elif choice == '18': backup_users()
        elif choice == '19': restore_users()
        elif choice == '20': break

def list_users():
    clear_screen()
    users = get_all_users()
    if not users:
        print("[ℹ️] No users found")
        input("Press Enter...")
        return
    
    table = PrettyTable()
    table.field_names = ["ID", "Username", "Data", "DL", "UL", "IP", "Conn", "SSH", "Trial", "Admin", "Status"]
    for u in users:
        data = f"{u['data_limit']}GB" if u['data_limit'] > 0 else "∞"
        dl = f"{u['download_speed']}M" if u['download_speed'] > 0 else "∞"
        ul = f"{u['upload_speed']}M" if u['upload_speed'] > 0 else "∞"
        ip = f"{u['ip_limit']}" if u['ip_limit'] > 0 else "∞"
        status = "✅" if u['is_active'] else "🔒"
        trial = "T" if u.get('is_trial', 0) else "-"
        admin = "A" if u.get('is_admin', 0) else "-"
        table.add_row([u['id'], u['username'][:20], data, dl, ul, ip, 
                       u.get('connections',0), u.get('ssh_port','N/A'), trial, admin, status])
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
    is_admin = input("Admin? (y/n): ").strip().lower() == 'y'
    is_trial = input("Trial account? (y/n): ").strip().lower() == 'y'
    
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
         ip_limit, 1 if is_admin else 0, 1 if is_trial else 0, ssh_port, ws_port, expires_at))
    user_id = c.lastrowid
    conn.commit()
    conn.close()
    
    # Setup SSH
    with open(f'/etc/ssh/sshd_config.d/{username}.conf', 'w') as f:
        f.write(f"Match User {username}\n")
        f.write(f"    Port {ssh_port}\n")
        f.write("    PasswordAuthentication yes\n")
        f.write("    PermitEmptyPasswords no\n")
        f.write("    ClientAliveInterval 60\n")
        f.write("    TCPKeepAlive yes\n")
    
    subprocess.run(['systemctl', 'reload', 'ssh'], check=False)
    log_activity(user_id, 'user_created', details=f'Data:{data_limit}GB DL:{dl_speed} UL:{ul_speed} IP:{ip_limit}')
    
    print(f"\n[✅] User created: {username}")
    print(f"    SSH Port: {ssh_port}")
    print(f"    WS Port: {ws_port}")
    print(f"    Expiry: {expires_at if expires_at else 'Never'}")
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
    
    duration_choice = input("\nChoice: ").strip()
    
    duration_map = {
        '1': 10,
        '2': 20,
        '3': 30,
        '4': 60,
    }
    
    if duration_choice == '5':
        minutes = int(input("Minutes: ").strip())
    else:
        minutes = duration_map.get(duration_choice, 30)
    
    username = f"trial-{uuid.uuid4().hex[:8]}"
    password = f"trial{datetime.now().strftime('%Y%m%d')}"
    expiry = datetime.now() + timedelta(minutes=minutes)
    
    ssh_port = get_free_port(3000)
    ws_port = get_free_port(4000)
    
    pwd_hash = bcrypt.hashpw(password.encode(), bcrypt.gensalt())
    
    conn = get_conn()
    c = conn.cursor()
    c.execute('''INSERT INTO users
        (username, password, is_trial, is_active, ssh_port, ws_port, expires_at)
        VALUES(?,?,?,?,?,?,?)''',
        (username, pwd_hash, 1, 1, ssh_port, ws_port, expiry.isoformat()))
    user_id = c.lastrowid
    conn.commit()
    conn.close()
    
    # Setup SSH
    with open(f'/etc/ssh/sshd_config.d/{username}.conf', 'w') as f:
        f.write(f"Match User {username}\n")
        f.write(f"    Port {ssh_port}\n")
        f.write("    PasswordAuthentication yes\n")
        f.write("    PermitEmptyPasswords no\n")
        f.write("    ClientAliveInterval 60\n")
        f.write("    TCPKeepAlive yes\n")
    
    subprocess.run(['systemctl', 'reload', 'ssh'], check=False)
    log_activity(user_id, 'trial_created', details=f'Duration:{minutes}min')
    
    print(f"\n[✅] Trial user created!")
    print(f"    Username: {username}")
    print(f"    Password: {password}")
    print(f"    Expires: {expiry.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"    SSH Port: {ssh_port}")
    print(f"    WS Port: {ws_port}")
    input("\nPress Enter...")

def edit_user():
    clear_screen()
    username = input("Username: ").strip()
    user = get_user(username)
    if not user:
        print("[❌] User not found!")
        input("Press Enter...")
        return
    
    print(f"\n✏️ EDIT: {username}")
    print("Fields: email, data_limit, download_speed, upload_speed, ip_limit, is_active, notes")
    field = input("Field: ").strip()
    value = input("Value: ").strip()
    
    if field in ['data_limit', 'download_speed', 'upload_speed', 'ip_limit']:
        value = int(value) if value else 0
    elif field == 'is_active':
        value = 1 if value.lower() in ['y','yes','true'] else 0
    
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
    
    try:
        os.remove(f'/etc/ssh/sshd_config.d/{username}.conf')
        subprocess.run(['systemctl', 'reload', 'ssh'], check=False)
    except:
        pass
    
    print(f"[🗑️] User {username} deleted!")
    input("Press Enter...")

def renew_account():
    clear_screen()
    username = input("Username: ").strip()
    user = get_user(username)
    if not user:
        print("[❌] User not found!")
        input("Press Enter...")
        return
    
    days = int(input("Add days: ").strip())
    new_expiry = datetime.now() + timedelta(days=days)
    
    conn = get_conn()
    c = conn.cursor()
    c.execute("UPDATE users SET expires_at=? WHERE id=?", (new_expiry.isoformat(), user['id']))
    conn.commit()
    conn.close()
    
    log_activity(user['id'], 'account_renewed', details=f'Added {days} days')
    print(f"[✅] Account renewed until {new_expiry.strftime('%Y-%m-%d %H:%M:%S')}")
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

def change_expiry():
    clear_screen()
    username = input("Username: ").strip()
    user = get_user(username)
    if not user:
        print("[❌] User not found!")
        input("Press Enter...")
        return
    
    days = int(input("Days (0=never): ").strip())
    expires_at = None
    if days > 0:
        expires_at = (datetime.now() + timedelta(days=days)).isoformat()
    
    conn = get_conn()
    c = conn.cursor()
    c.execute("UPDATE users SET expires_at=? WHERE id=?", (expires_at, user['id']))
    conn.commit()
    conn.close()
    
    log_activity(user['id'], 'expiry_changed', details=f'{days} days')
    print("[✅] Expiry updated!")
    input("Press Enter...")

def change_quota():
    clear_screen()
    username = input("Username: ").strip()
    user = get_user(username)
    if not user:
        print("[❌] User not found!")
        input("Press Enter...")
        return
    
    quota = int(input("Data Limit (GB, 0=unlimited): ").strip())
    
    conn = get_conn()
    c = conn.cursor()
    c.execute("UPDATE users SET data_limit=? WHERE id=?", (quota, user['id']))
    conn.commit()
    conn.close()
    
    log_activity(user['id'], 'quota_changed', details=f'{quota}GB')
    print("[✅] Quota updated!")
    input("Press Enter...")

def change_bandwidth():
    clear_screen()
    username = input("Username: ").strip()
    user = get_user(username)
    if not user:
        print("[❌] User not found!")
        input("Press Enter...")
        return
    
    dl = int(input("Download Speed (Mbps, 0=unlimited): ").strip())
    ul = int(input("Upload Speed (Mbps, 0=unlimited): ").strip())
    
    conn = get_conn()
    c = conn.cursor()
    c.execute("UPDATE users SET download_speed=?, upload_speed=? WHERE id=?", (dl, ul, user['id']))
    conn.commit()
    conn.close()
    
    log_activity(user['id'], 'bandwidth_changed', details=f'DL:{dl} UL:{ul}')
    print("[✅] Bandwidth limits updated!")
    input("Press Enter...")

def change_iplimit():
    clear_screen()
    username = input("Username: ").strip()
    user = get_user(username)
    if not user:
        print("[❌] User not found!")
        input("Press Enter...")
        return
    
    limit = int(input("IP Limit (0=unlimited): ").strip())
    
    conn = get_conn()
    c = conn.cursor()
    c.execute("UPDATE users SET ip_limit=? WHERE id=?", (limit, user['id']))
    conn.commit()
    conn.close()
    
    log_activity(user['id'], 'iplimit_changed', details=f'{limit}')
    print("[✅] IP limit updated!")
    input("Press Enter...")

def lock_account():
    clear_screen()
    username = input("Username: ").strip()
    user = get_user(username)
    if not user:
        print("[❌] User not found!")
        input("Press Enter...")
        return
    
    conn = get_conn()
    c = conn.cursor()
    c.execute("UPDATE users SET is_active=0 WHERE id=?", (user['id'],))
    c.execute("UPDATE sessions SET is_active=0 WHERE user_id=? AND is_active=1", (user['id'],))
    conn.commit()
    conn.close()
    
    log_activity(user['id'], 'account_locked')
    print(f"[🔒] Account {username} locked!")
    input("Press Enter...")

def unlock_account():
    clear_screen()
    username = input("Username: ").strip()
    user = get_user(username)
    if not user:
        print("[❌] User not found!")
        input("Press Enter...")
        return
    
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

def backup_users():
    clear_screen()
    backup_path = f"/opt/grvpn/backups/users_{datetime.now().strftime('%Y%m%d_%H%M%S')}.db"
    subprocess.run(f"cp {DB} {backup_path}", shell=True)
    print(f"[✅] Users backed up: {backup_path}")
    input("Press Enter...")

def restore_users():
    clear_screen()
    backup = input("Backup path: ").strip()
    if not os.path.exists(backup):
        print("[❌] Backup not found!")
        input("Press Enter...")
        return
    
    if input("Restore users? (y/n): ").strip().lower() != 'y':
        return
    
    subprocess.run(f"cp {backup} {DB}", shell=True)
    subprocess.run(['systemctl', 'reload', 'ssh'], check=False)
    print("[✅] Users restored!")
    input("Press Enter...")

# ============ DOMAIN MANAGER ============
def domain_manager():
    while True:
        clear_screen()
        print("""
╔══════════════════════════════════════════════════════════════════════╗
║  🌐 DOMAIN MANAGER                                                 ║
╠══════════════════════════════════════════════════════════════════════╣
║  1.  View Current Domain                                            ║
║  2.  Set Primary Domain                                             ║
║  3.  Replace Domain                                                 ║
║  4.  Generate Let's Encrypt Certificate                             ║
║  5.  Renew Certificate                                              ║
║  6.  Install Custom Certificate                                     ║
║  7.  Install Custom Private Key                                     ║
║  8.  Validate Certificate                                           ║
║  9.  Display Certificate Expiry                                     ║
║  10. Restart Affected Services                                      ║
║  11. Back to Main                                                   ║
╚══════════════════════════════════════════════════════════════════════╝
        """)
        
        choice = input("🐱 Choice: ").strip()
        
        if choice == '1': view_domain()
        elif choice == '2': set_domain()
        elif choice == '3': replace_domain()
        elif choice == '4': generate_cert()
        elif choice == '5': renew_cert()
        elif choice == '6': install_custom_cert()
        elif choice == '7': install_custom_key()
        elif choice == '8': validate_cert()
        elif choice == '9': cert_expiry()
        elif choice == '10': restart_services()
        elif choice == '11': break

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
    
    subprocess.run(f"sed -i 's/server_name .*/server_name {domain};/g' /etc/nginx/sites-available/grvpn", shell=True)
    subprocess.run(['systemctl', 'reload', 'nginx'], check=False)
    
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
    
    # Stop services
    subprocess.run(['systemctl', 'stop', 'nginx'], check=False)
    
    # Get new cert
    print(f"[🔐] Getting SSL for {new}...")
    subprocess.run(f"certbot certonly --standalone -d {new} --non-interactive --agree-tos -m admin@{new}", shell=True)
    
    if os.path.exists(f"/etc/letsencrypt/live/{new}/fullchain.pem"):
        subprocess.run(f"cp /etc/letsencrypt/live/{new}/fullchain.pem /etc/ssl/grvpn.pem", shell=True)
        subprocess.run(f"cp /etc/letsencrypt/live/{new}/privkey.pem /etc/ssl/grvpn.key", shell=True)
        
        conn = get_conn()
        c = conn.cursor()
        c.execute("UPDATE settings SET value=? WHERE key='domain'", (new,))
        conn.commit()
        conn.close()
        
        subprocess.run(f"sed -i 's/server_name .*/server_name {new};/g' /etc/nginx/sites-available/grvpn", shell=True)
        subprocess.run(['systemctl', 'reload', 'nginx'], check=False)
        
        print(f"[✅] Domain replaced: {old} -> {new}")
    else:
        print("[❌] SSL certificate failed!")
        subprocess.run(['systemctl', 'start', 'nginx'], check=False)
    
    input("Press Enter...")

def generate_cert():
    clear_screen()
    domain = get_domain()
    print(f"[🔐] Generating certificate for {domain}...")
    
    subprocess.run(['systemctl', 'stop', 'nginx'], check=False)
    result = subprocess.run(f"certbot certonly --standalone -d {domain} --non-interactive --agree-tos -m admin@{domain}", shell=True)
    
    if result.returncode == 0:
        subprocess.run(f"cp /etc/letsencrypt/live/{domain}/fullchain.pem /etc/ssl/grvpn.pem", shell=True)
        subprocess.run(f"cp /etc/letsencrypt/live/{domain}/privkey.pem /etc/ssl/grvpn.key", shell=True)
        print("[✅] Certificate generated!")
    else:
        print("[❌] Certificate generation failed!")
    
    subprocess.run(['systemctl', 'start', 'nginx'], check=False)
    input("Press Enter...")

def renew_cert():
    clear_screen()
    print("[🔄] Renewing certificate...")
    result = subprocess.run(['certbot', 'renew', '--nginx', '--non-interactive'], capture_output=True)
    if result.returncode == 0:
        print("[✅] Certificate renewed!")
    else:
        print("[❌] Renewal failed!")
    input("Press Enter...")

def install_custom_cert():
    clear_screen()
    cert_path = input("Certificate path: ").strip()
    if not os.path.exists(cert_path):
        print("[❌] Certificate not found!")
        input("Press Enter...")
        return
    
    subprocess.run(f"cp {cert_path} /etc/ssl/grvpn.pem", shell=True)
    print("[✅] Certificate installed!")
    input("Press Enter...")

def install_custom_key():
    clear_screen()
    key_path = input("Private key path: ").strip()
    if not os.path.exists(key_path):
        print("[❌] Private key not found!")
        input("Press Enter...")
        return
    
    subprocess.run(f"cp {key_path} /etc/ssl/grvpn.key", shell=True)
    chmod 600 /etc/ssl/grvpn.key
    print("[✅] Private key installed!")
    input("Press Enter...")

def validate_cert():
    clear_screen()
    result = subprocess.run(['openssl', 'verify', '-CAfile', '/etc/ssl/grvpn.pem', '/etc/ssl/grvpn.pem'], capture_output=True)
    if result.returncode == 0:
        print("[✅] Certificate is valid!")
    else:
        print("[❌] Certificate validation failed!")
    input("Press Enter...")

def cert_expiry():
    clear_screen()
    result = subprocess.run(['openssl', 'x509', '-in', '/etc/ssl/grvpn.pem', '-noout', '-enddate'], capture_output=True)
    print(f"\n📅 {result.stdout.decode().strip()}")
    input("\nPress Enter...")

def restart_services():
    clear_screen()
    for svc in ['nginx', 'ssh', 'stunnel5']:
        subprocess.run(['systemctl', 'restart', svc])
        print(f"[✅] {svc} restarted!")
    input("Press Enter...")

# ============ TLS MANAGER ============
def tls_manager():
    while True:
        clear_screen()
        print("""
╔══════════════════════════════════════════════════════════════════════╗
║  🔒 TLS MANAGER                                                    ║
╠══════════════════════════════════════════════════════════════════════╣
║  1.  Regenerate Certificate                                         ║
║  2.  Install Custom Certificate                                     ║
║  3.  Install Private Key                                            ║
║  4.  View Certificate Details                                       ║
║  5.  Restart TLS Services                                           ║
║  6.  Back to Main                                                   ║
╚══════════════════════════════════════════════════════════════════════╝
        """)
        
        choice = input("🐱 Choice: ").strip()
        
        if choice == '1': generate_cert()
        elif choice == '2': install_custom_cert()
        elif choice == '3': install_custom_key()
        elif choice == '4': cert_details()
        elif choice == '5': restart_tls()
        elif choice == '6': break

def cert_details():
    clear_screen()
    result = subprocess.run(['openssl', 'x509', '-in', '/etc/ssl/grvpn.pem', '-noout', '-text'], capture_output=True)
    print(f"\n📋 {result.stdout.decode()}")
    input("\nPress Enter...")

def restart_tls():
    for svc in ['nginx', 'stunnel5']:
        subprocess.run(['systemctl', 'restart', svc])
        print(f"[✅] {svc} restarted!")
    input("Press Enter...")

# ============ NGINX MANAGER ============
def nginx_manager():
    while True:
        clear_screen()
        print("""
╔══════════════════════════════════════════════════════════════════════╗
║  🌍 NGINX MANAGER                                                  ║
╠══════════════════════════════════════════════════════════════════════╣
║  1.  Configure WebSocket Path                                       ║
║  2.  Reload Nginx                                                   ║
║  3.  Restart Nginx                                                  ║
║  4.  Validate Configuration                                         ║
║  5.  View Logs                                                      ║
║  6.  Show Config                                                    ║
║  7.  Back to Main                                                   ║
╚══════════════════════════════════════════════════════════════════════╝
        """)
        
        choice = input("🐱 Choice: ").strip()
        
        if choice == '1': configure_ws()
        elif choice == '2': reload_nginx()
        elif choice == '3': restart_nginx()
        elif choice == '4': validate_nginx()
        elif choice == '5': view_nginx_logs()
        elif choice == '6': show_nginx_config()
        elif choice == '7': break

def configure_ws():
    clear_screen()
    path = input("WebSocket path (default: /): ").strip() or "/"
    
    with open('/etc/nginx/sites-available/grvpn', 'r') as f:
        config = f.read()
    
    # Update location
    import re
    config = re.sub(r'location \S+ {', f'location {path} {{', config)
    
    with open('/etc/nginx/sites-available/grvpn', 'w') as f:
        f.write(config)
    
    subprocess.run(['nginx', '-t'], check=False)
    subprocess.run(['systemctl', 'reload', 'nginx'], check=False)
    print(f"[✅] WebSocket path set to: {path}")
    input("Press Enter...")

def reload_nginx():
    subprocess.run(['systemctl', 'reload', 'nginx'])
    print("[✅] Nginx reloaded!")
    input("Press Enter...")

def restart_nginx():
    subprocess.run(['systemctl', 'restart', 'nginx'])
    print("[✅] Nginx restarted!")
    input("Press Enter...")

def validate_nginx():
    result = subprocess.run(['nginx', '-t'], capture_output=True)
    print(f"\n{result.stdout.decode()}{result.stderr.decode()}")
    input("\nPress Enter...")

def view_nginx_logs():
    clear_screen()
    lines = input("Lines (default 50): ").strip() or "50"
    subprocess.run(['tail', f'-{lines}', '/var/log/nginx/error.log'])
    input("\nPress Enter...")

def show_nginx_config():
    clear_screen()
    subprocess.run(['cat', '/etc/nginx/sites-available/grvpn'])
    input("\nPress Enter...")

# ============ BANNER MANAGER ============
def banner_manager():
    while True:
        clear_screen()
        print("""
╔══════════════════════════════════════════════════════════════════════╗
║  📋 BANNER MANAGER                                                 ║
╠══════════════════════════════════════════════════════════════════════╣
║  1.  Set Global Banner                                              ║
║  2.  Set User Banner                                                ║
║  3.  View Banner                                                    ║
║  4.  Reset to Default                                               ║
║  5.  Back to Main                                                   ║
╚══════════════════════════════════════════════════════════════════════╝
        """)
        
        choice = input("🐱 Choice: ").strip()
        
        if choice == '1': set_global_banner()
        elif choice == '2': set_user_banner()
        elif choice == '3': view_banner()
        elif choice == '4': reset_banner()
        elif choice == '5': break

def set_global_banner():
    clear_screen()
    print("Enter banner (use \\n for new lines, press Ctrl+D when done):")
    lines = []
    try:
        while True:
            line = input()
            lines.append(line)
    except EOFError:
        pass
    
    banner = '\\n'.join(lines)
    
    conn = get_conn()
    c = conn.cursor()
    c.execute("UPDATE settings SET value=? WHERE key='global_banner'", (banner,))
    if c.rowcount == 0:
        c.execute("INSERT INTO settings(key, value) VALUES('global_banner', ?)", (banner,))
    conn.commit()
    conn.close()
    
    print("[✅] Global banner set!")
    input("Press Enter...")

def set_user_banner():
    clear_screen()
    username = input("Username: ").strip()
    user = get_user(username)
    if not user:
        print("[❌] User not found!")
        input("Press Enter...")
        return
    
    print("Enter banner (use \\n for new lines):")
    banner = input("Banner: ").strip()
    
    conn = get_conn()
    c = conn.cursor()
    try:
        c.execute("ALTER TABLE users ADD COLUMN ssh_banner TEXT")
    except:
        pass
    c.execute("UPDATE users SET ssh_banner=? WHERE id=?", (banner, user['id']))
    conn.commit()
    conn.close()
    
    print("[✅] User banner set!")
    input("Press Enter...")

def view_banner():
    clear_screen()
    conn = get_conn()
    c = conn.cursor()
    c.execute("SELECT value FROM settings WHERE key='global_banner'")
    result = c.fetchone()
    conn.close()
    
    if result:
        print(f"\n📋 GLOBAL BANNER:\n{result[0]}")
    else:
        print("[ℹ️] No global banner set")
    input("\nPress Enter...")

def reset_banner():
    clear_screen()
    if input("Reset to default banner? (y/n): ").strip().lower() != 'y':
        return
    
    conn = get_conn()
    c = conn.cursor()
    c.execute("DELETE FROM settings WHERE key='global_banner'")
    c.execute("UPDATE users SET ssh_banner=NULL")
    conn.commit()
    conn.close()
    
    print("[✅] Banner reset to default!")
    input("Press Enter...")

# ============ SESSION MONITOR ============
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
║  6.  Back to Main                                                   ║
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
        upload = s['bytes_sent'] // 1024        download = s['bytes_received'] // 1024
        table.add_row([s['id'], s['username'][:15], s['ip'], s['protocol'], 
                       s['port'], f"{duration}m", f"{upload}KB", f"{download}KB"])
    print(table)
    input("\nPress Enter...")

def session_details():
    clear_screen()
    session_id = input("Session ID: ").strip()
    conn = get_conn()
    conn.row_factory = sqlite3.Row
    c = conn.cursor()
    c.execute('''SELECT s.*, u.username FROM sessions s 
                JOIN users u ON s.user_id = u.id 
                WHERE s.id=? AND s.is_active=1''', (session_id,))
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
    session_id = input("Session ID: ").strip()
    conn = get_conn()
    c = conn.cursor()
    c.execute("SELECT user_id FROM sessions WHERE id=? AND is_active=1", (session_id,))
    result = c.fetchone()
    if not result:
        print("[❌] Session not found!")
        conn.close()
        input("Press Enter...")
        return
    
    c.execute("UPDATE sessions SET is_active=0 WHERE id=?", (session_id,))
    c.execute("UPDATE users SET connections=connections-1 WHERE id=?", (result[0],))
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

# ============ SERVER DASHBOARD ============
def server_dashboard():
    clear_screen()
    
    # System stats
    cpu = psutil.cpu_percent()
    mem = psutil.virtual_memory()
    disk = psutil.disk_usage('/')
    net = psutil.net_io_counters()
    
    # Service status
    services = ['nginx', 'ssh', 'stunnel5', 'fail2ban']
    service_status = {}
    for svc in services:
        result = subprocess.run(['systemctl', 'is-active', svc], capture_output=True)
        service_status[svc] = result.stdout.decode().strip()
    
    # User stats
    conn = get_conn()
    c = conn.cursor()
    c.execute("SELECT COUNT(*) FROM users WHERE is_active=1")
    total_users = c.fetchone()[0]
    c.execute("SELECT COUNT(*) FROM users WHERE is_active=1 AND is_trial=1")
    trial_users = c.fetchone()[0]
    c.execute("SELECT COUNT(*) FROM users WHERE is_active=1 AND expires_at < datetime('now')")
    expired_users = c.fetchone()[0]
    c.execute("SELECT COUNT(*) FROM sessions WHERE is_active=1")
    active_sessions = c.fetchone()[0]
    conn.close()
    
    print("""
╔══════════════════════════════════════════════════════════════════════╗
║  📈 SERVER DASHBOARD                                               ║
╠══════════════════════════════════════════════════════════════════════╣
""")
    print(f"║  🖥️  CPU           : {cpu}%                                                      ║")
    print(f"║  💾 Memory       : {mem.used/1024**3:.2f}GB / {mem.total/1024**3:.2f}GB ({mem.percent}%)              ║")
    print(f"║  💿 Disk         : {disk.used/1024**3:.2f}GB / {disk.total/1024**3:.2f}GB ({disk.percent}%)              ║")
    print(f"║  🌐 Network      : Sent {net.bytes_sent/1024**3:.2f}GB | Received {net.bytes_recv/1024**3:.2f}GB    ║")
    print("╠══════════════════════════════════════════════════════════════════════╣")
    print(f"║  👥 Users        : {total_users:>6} Total | {trial_users:>6} Trial | {expired_users:>6} Expired      ║")
    print(f"║  🔌 Sessions     : {active_sessions:>6} Active                                          ║")
    print("╠══════════════════════════════════════════════════════════════════════╣")
    print(f"║  🔧 Services     : Nginx {service_status.get('nginx','unknown')} | SSH {service_status.get('ssh','unknown')}               ║")
    print(f"║                  : Stunnel5 {service_status.get('stunnel5','unknown')} | Fail2ban {service_status.get('fail2ban','unknown')}        ║")
    print("╚══════════════════════════════════════════════════════════════════════╝")
    
    input("\nPress Enter...")

# ============ BACKUP MANAGER ============
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
║  7.  Back to Main                                                   ║
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
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    backup_path = f"/opt/grvpn/backups/full_backup_{timestamp}"
    os.makedirs(backup_path, exist_ok=True)
    
    subprocess.run(f"cp -r /opt/grvpn/data {backup_path}/", shell=True)
    subprocess.run(f"cp -r /etc/nginx/sites-available {backup_path}/", shell=True)
    subprocess.run(f"cp -r /etc/stunnel5 {backup_path}/", shell=True)
    subprocess.run(f"cp -r /etc/ssh/sshd_config.d {backup_path}/", shell=True)
    subprocess.run(f"cp /etc/ssl/grvpn.pem {backup_path}/", shell=True)
    subprocess.run(f"cp /etc/ssl/grvpn.key {backup_path}/", shell=True)
    
    print(f"[✅] Full backup created: {backup_path}")
    input("Press Enter...")

def user_backup():
    clear_screen()
    backup_path = f"/opt/grvpn/backups/users_{datetime.now().strftime('%Y%m%d_%H%M%S')}.db"
    subprocess.run(f"cp /opt/grvpn/data/grvpn.db {backup_path}", shell=True)
    print(f"[✅] Users backed up: {backup_path}")
    input("Press Enter...")

def config_backup():
    clear_screen()
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    backup_path = f"/opt/grvpn/backups/config_backup_{timestamp}.tar.gz"
    subprocess.run(f"tar -czf {backup_path} /etc/nginx/sites-available /etc/stunnel5 /etc/ssh/sshd_config.d", shell=True)
    print(f"[✅] Config backed up: {backup_path}")
    input("Press Enter...")

def list_backups():
    clear_screen()
    subprocess.run("ls -lh /opt/grvpn/backups/", shell=True)
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
        subprocess.run(f"cp -r {backup}/data/* /opt/grvpn/data/", shell=True)
        subprocess.run(f"cp -r {backup}/nginx/* /etc/nginx/", shell=True)
        subprocess.run(f"cp -r {backup}/stunnel5/* /etc/stunnel5/", shell=True)
        subprocess.run(f"cp -r {backup}/sshd_config.d/* /etc/ssh/sshd_config.d/", shell=True)
        if os.path.exists(f"{backup}/grvpn.pem"):
            subprocess.run(f"cp {backup}/grvpn.pem /etc/ssl/grvpn.pem", shell=True)
            subprocess.run(f"cp {backup}/grvpn.key /etc/ssl/grvpn.key", shell=True)
    else:
        subprocess.run(f"cp {backup} /opt/grvpn/data/grvpn.db", shell=True)
    
    subprocess.run(['systemctl', 'reload', 'nginx', 'ssh', 'stunnel5'], check=False)
    print("[✅] Restored!")
    input("Press Enter...")

def clean_backups():
    clear_screen()
    days = int(input("Keep backups from last N days: ").strip() or "7")
    subprocess.run(f"find /opt/grvpn/backups -type f -mtime +{days} -delete", shell=True)
    subprocess.run(f"find /opt/grvpn/backups -type d -mtime +{days} -exec rm -rf {{}} + 2>/dev/null", shell=True)
    print(f"[✅] Cleaned backups older than {days} days!")
    input("Press Enter...")

# ============ UPDATE MANAGER ============
def update_manager():
    while True:
        clear_screen()
        print("""
╔══════════════════════════════════════════════════════════════════════╗
║  🔄 UPDATE MANAGER                                                 ║
╠══════════════════════════════════════════════════════════════════════╣
║  1.  Check for Updates                                              ║
║  2.  Update Application                                             ║
║  3.  Update Dependencies                                            ║
║  4.  Restart Services After Update                                 ║
║  5.  View Update Log                                                ║
║  6.  Back to Main                                                   ║
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
    # Check latest version from git
    result = subprocess.run(['curl', '-s', 'https://raw.githubusercontent.com/stdacc1231/grvpn/main/version.txt'], capture_output=True)
    if result.returncode == 0:
        latest = result.stdout.decode().strip()
        print(f"Current version: {VERSION}")
        print(f"Latest version: {latest}")
        if latest != VERSION:
            print("[✅] Update available!")
        else:
            print("[ℹ️] Already up to date!")
    else:
        print("[❌] Failed to check updates!")
    input("\nPress Enter...")

def update_app():
    clear_screen()
    print("[🔄] Updating application...")
    subprocess.run(['curl', '-s', '-o', '/tmp/update.sh', 'https://raw.githubusercontent.com/stdacc1231/grvpn/main/update.sh'], check=False)
    if os.path.exists('/tmp/update.sh'):
        subprocess.run(['bash', '/tmp/update.sh'], check=False)
        print("[✅] Application updated!")
    else:
        print("[❌] Update failed!")
    input("Press Enter...")

def update_deps():
    clear_screen()
    print("[🔄] Updating dependencies...")
    subprocess.run(['apt', 'update'], check=False)
    subprocess.run(['apt', 'upgrade', '-y'], check=False)
    subprocess.run(['pip3', 'install', '--upgrade', 'psutil', 'bcrypt', 'cryptography', 'requests'], check=False)
    print("[✅] Dependencies updated!")
    input("Press Enter...")

def restart_after_update():
    clear_screen()
    for svc in ['nginx', 'ssh', 'stunnel5']:
        subprocess.run(['systemctl', 'restart', svc])
        print(f"[✅] {svc} restarted!")
    input("Press Enter...")

def view_update_log():
    clear_screen()
    if os.path.exists('/var/log/grvpn/update.log'):
        subprocess.run(['tail', '-50', '/var/log/grvpn/update.log'])
    else:
        print("[ℹ️] No update log found")
    input("\nPress Enter...")

# ============ SECURITY MANAGER ============
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
║  9.  SSH Hardening                                                  ║
║  10. Security Audit                                                 ║
║  11. Back to Main                                                   ║
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
        elif choice == '9': ssh_harden()
        elif choice == '10': security_audit()
        elif choice == '11': break

def view_firewall():
    clear_screen()
    subprocess.run(['ufw', 'status', 'numbered'])
    input("\nPress Enter...")

def add_firewall():
    clear_screen()
    port = input("Port: ").strip()
    proto = input("Protocol (tcp/udp): ").strip() or "tcp"
    subprocess.run(['ufw', 'allow', f"{port}/{proto}"])
    print(f"[✅] Port {port}/{proto} allowed!")
    input("Press Enter...")

def remove_firewall():
    clear_screen()
    subprocess.run(['ufw', 'status', 'numbered'])
    num = input("Rule number to delete: ").strip()
    subprocess.run(['ufw', 'delete', num])
    print("[✅] Rule deleted!")
    input("Press Enter...")

def view_blacklist():
    clear_screen()
    conn = get_conn()
    c = conn.cursor()
    c.execute("SELECT ip, reason, created_at FROM ip_rules WHERE action='block' AND is_active=1")
    rules = c.fetchall()
    conn.close()
    
    if not rules:
        print("[ℹ️] No IPs blacklisted")
    else:
        table = PrettyTable()
        table.field_names = ["IP", "Reason", "Created"]
        for r in rules:
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
    
    subprocess.run(f"iptables -A INPUT -s {ip} -j DROP", shell=True)
    subprocess.run(['ufw', 'deny', 'from', ip], shell=True)
    
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
    
    subprocess.run(f"iptables -D INPUT -s {ip} -j DROP", shell=True)
    subprocess.run(['ufw', 'delete', 'deny', 'from', ip], shell=True)
    
    print(f"[✅] IP {ip} unblocked!")
    input("Press Enter...")

def fail2ban_status():
    clear_screen()
    subprocess.run(['fail2ban-client', 'status'])
    input("\nPress Enter...")

def restart_fail2ban():
    subprocess.run(['systemctl', 'restart', 'fail2ban'])
    print("[✅] Fail2ban restarted!")
    input("Press Enter...")

def ssh_harden():
    clear_screen()
    print("[🔒] Hardening SSH...")
    subprocess.run(['sed', '-i', 's/#PermitRootLogin.*/PermitRootLogin no/', '/etc/ssh/sshd_config'], check=False)
    subprocess.run(['sed', '-i', 's/#MaxAuthTries.*/MaxAuthTries 3/', '/etc/ssh/sshd_config'], check=False)
    subprocess.run(['sed', '-i', 's/#MaxSessions.*/MaxSessions 1000/', '/etc/ssh/sshd_config'], check=False)
    subprocess.run(['systemctl', 'reload', 'ssh'], check=False)
    print("[✅] SSH hardened!")
    input("Press Enter...")

def security_audit():
    clear_screen()
    print("\n🔍 SECURITY AUDIT")
    print("="*50)
    
    # Check SSH config
    print("\n[1] SSH Configuration:")
    subprocess.run(['grep', '-E', '^PermitRootLogin|^MaxAuthTries|^MaxSessions|^PasswordAuthentication', '/etc/ssh/sshd_config'])
    
    # Check firewall
    print("\n[2] Firewall Status:")
    subprocess.run(['ufw', 'status', '|', 'grep', '-E', 'Status|22|80|443'], shell=True)
    
    # Check Fail2ban
    print("\n[3] Fail2ban Status:")
    subprocess.run(['fail2ban-client', 'status', 'sshd'])
    
    # Check SSL
    print("\n[4] SSL Certificate:")
    subprocess.run(['openssl', 'x509', '-in', '/etc/ssl/grvpn.pem', '-noout', '-dates'])
    
    # Check running services
    print("\n[5] Running Services:")
    subprocess.run(['systemctl', 'status', 'ssh', 'nginx', 'stunnel5', '--no-pager', '|', 'grep', '-E', 'Active:|Main PID:'], shell=True)
    
    input("\nPress Enter...")

# ============ LOGS VIEWER ============
def logs_viewer():
    while True:
        clear_screen()
        print("""
╔══════════════════════════════════════════════════════════════════════╗
║  📜 LOGS VIEWER                                                    ║
╠══════════════════════════════════════════════════════════════════════╣
║  1.  SSH Logs                                                       ║
║  2.  Authentication Logs                                            ║
║  3.  Nginx Logs                                                     ║
║  4.  TLS Logs                                                       ║
║  5.  Installer Logs                                                 ║
║  6.  System Logs                                                    ║
║  7.  WebSocket Logs                                                 ║
║  8.  Back to Main                                                   ║
╚══════════════════════════════════════════════════════════════════════╝
        """)
        
        choice = input("🐱 Choice: ").strip()
        
        if choice == '1': view_ssh_logs()
        elif choice == '2': view_auth_logs()
        elif choice == '3': view_nginx_logs()
        elif choice == '4': view_tls_logs()
        elif choice == '5': view_installer_logs()
        elif choice == '6': view_system_logs()
        elif choice == '7': view_ws_logs()
        elif choice == '8': break

def view_ssh_logs():
    clear_screen()
    lines = input("Lines (default 50): ").strip() or "50"
    subprocess.run(['journalctl', '-u', 'ssh', '-n', lines, '--no-pager'])
    input("\nPress Enter...")

def view_auth_logs():
    clear_screen()
    lines = input("Lines (default 50): ").strip() or "50"
    subprocess.run(['tail', f'-{lines}', '/var/log/auth.log'])
    input("\nPress Enter...")

def view_nginx_logs():
    clear_screen()
    lines = input("Lines (default 50): ").strip() or "50"
    subprocess.run(['tail', f'-{lines}', '/var/log/nginx/error.log'])
    input("\nPress Enter...")

def view_tls_logs():
    clear_screen()
    lines = input("Lines (default 50): ").strip() or "50"
    subprocess.run(['tail', f'-{lines}', '/var/log/stunnel5.log'])
    input("\nPress Enter...")

def view_installer_logs():
    clear_screen()
    if os.path.exists('/var/log/grvpn/install.log'):
        lines = input("Lines (default 50): ").strip() or "50"
        subprocess.run(['tail', f'-{lines}', '/var/log/grvpn/install.log'])
    else:
        print("[ℹ️] No installer log found")
    input("\nPress Enter...")

def view_system_logs():
    clear_screen()
    lines = input("Lines (default 50): ").strip() or "50"
    subprocess.run(['journalctl', '-n', lines, '--no-pager'])
    input("\nPress Enter...")

def view_ws_logs():
    clear_screen()
    lines = input("Lines (default 50): ").strip() or "50"
    if os.path.exists('/var/log/grvpn/websocat.log'):
        subprocess.run(['tail', f'-{lines}', '/var/log/grvpn/websocat.log'])
    else:
        print("[ℹ️] No WebSocket log found")
    input("\nPress Enter...")

# ============ SYSTEM SERVICES ============
def system_services():
    while True:
        clear_screen()
        print("""
╔══════════════════════════════════════════════════════════════════════╗
║  ⚙️  SYSTEM SERVICES                                                ║
╠══════════════════════════════════════════════════════════════════════╣
║  1.  View All Services                                               ║
║  2.  Start Service                                                   ║
║  3.  Stop Service                                                    ║
║  4.  Restart Service                                                 ║
║  5.  Reload Service                                                  ║
║  6.  Enable Service                                                  ║
║  7.  Disable Service                                                 ║
║  8.  View Service Status                                             ║
║  9.  Back to Main                                                    ║
╚══════════════════════════════════════════════════════════════════════╝
        """)
        
        choice = input("🐱 Choice: ").strip()
        
        if choice == '1': view_all_services()
        elif choice == '2': start_service()
        elif choice == '3': stop_service()
        elif choice == '4': restart_service()
        elif choice == '5': reload_service()
        elif choice == '6': enable_service()
        elif choice == '7': disable_service()
        elif choice == '8': service_status()
        elif choice == '9': break

def view_all_services():
    clear_screen()
    services = ['nginx', 'ssh', 'stunnel5', 'fail2ban']
    table = PrettyTable()
    table.field_names = ["Service", "Status", "Enabled"]
    for svc in services:
        status = subprocess.run(['systemctl', 'is-active', svc], capture_output=True).stdout.decode().strip()
        enabled = subprocess.run(['systemctl', 'is-enabled', svc], capture_output=True).stdout.decode().strip()
        table.add_row([svc, "✅" if status == "active" else "❌", "✅" if enabled == "enabled" else "❌"])
    print(table)
    input("\nPress Enter...")

def start_service():
    service = input("Service name: ").strip()
    subprocess.run(['systemctl', 'start', service])
    print(f"[✅] {service} started!")
    input("Press Enter...")

def stop_service():
    service = input("Service name: ").strip()
    subprocess.run(['systemctl', 'stop', service])
    print(f"[✅] {service} stopped!")
    input("Press Enter...")

def restart_service():
    service = input("Service name: ").strip()
    subprocess.run(['systemctl', 'restart', service])
    print(f"[✅] {service} restarted!")
    input("Press Enter...")

def reload_service():
    service = input("Service name: ").strip()
    subprocess.run(['systemctl', 'reload', service])
    print(f"[✅] {service} reloaded!")
    input("Press Enter...")

def enable_service():
    service = input("Service name: ").strip()
    subprocess.run(['systemctl', 'enable', service])
    print(f"[✅] {service} enabled!")
    input("Press Enter...")

def disable_service():
    service = input("Service name: ").strip()
    subprocess.run(['systemctl', 'disable', service])
    print(f"[✅] {service} disabled!")
    input("Press Enter...")

def service_status():
    service = input("Service name: ").strip()
    subprocess.run(['systemctl', 'status', service, '--no-pager'])
    input("\nPress Enter...")

# ============ RUN ============
if __name__ == "__main__":
    try:
        main_menu()
    except KeyboardInterrupt:
        print("\n[👋] Goodbye!")
        sys.exit(0)
PANEL_EOF

chmod +x ${BIN_DIR}/grvpn-panel

# Create symlink
ln -sf ${BIN_DIR}/grvpn-panel /usr/local/bin/grvpn

# Create systemd service for websocat
echo -e "${BLUE}[🔧] Creating systemd services...${NC}"
cat > /etc/systemd/system/websocat.service << 'EOF'
[Unit]
Description=GRVPN WebSocket Proxy
After=network.target ssh.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/websocat -s 0.0.0.0:8080 -- sh -c "ssh -o StrictHostKeyChecking=no localhost"
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=websocat

[Install]
WantedBy=multi-user.target
EOF

# Create cron jobs for maintenance
echo -e "${BLUE}[📅] Setting up cron jobs...${NC}"
cat > /etc/cron.d/grvpn << 'CRON_EOF'
# GRVPN Maintenance Jobs
# Daily backup at 2 AM
0 2 * * * root /usr/local/bin/grvpn --backup > /dev/null 2>&1
# Weekly cleanup at 3 AM Sunday
0 3 * * 0 root find /opt/grvpn/backups -type f -mtime +30 -delete > /dev/null 2>&1
# Check expired trials every hour
0 * * * * root sqlite3 /opt/grvpn/data/grvpn.db "UPDATE users SET is_active=0 WHERE is_trial=1 AND expires_at < datetime('now')" > /dev/null 2>&1
# Renew certificates at 2 AM Monday
0 2 * * 1 root certbot renew --nginx --quiet > /dev/null 2>&1
CRON_EOF

# Start services
echo -e "${BLUE}[🚀] Starting services...${NC}"
systemctl daemon-reload
systemctl enable nginx ssh stunnel5 fail2ban websocat
systemctl restart nginx ssh stunnel5 fail2ban websocat

# Enable cron
systemctl enable cron
systemctl restart cron

# Set permissions
chown -R root:root ${INSTALL_DIR}
chmod 755 ${INSTALL_DIR}
chmod 644 ${DB_FILE}

# Create version file
echo "$VERSION" > ${INSTALL_DIR}/version.txt

# Final message
echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  🐱 GRVPN ENTERPRISE SSH SERVER MANAGER v${VERSION}                  ║"
echo "║  INSTALLATION COMPLETE!                                             ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║                                                                      ║"
echo "║  📌 Quick Start:                                                     ║"
echo "║  Run: grvpn                                                          ║"
echo "║  Login: grvpn / GRVPN@2026                                          ║"
echo "║                                                                      ║"
echo "║  🌐 Domain: $DOMAIN                                                  ║"
echo "║  📡 SSL: Valid for $DOMAIN                                          ║"
echo "║                                                                      ║"
echo "║  📡 CONNECTION METHODS:                                              ║"
echo "║  SSH Direct:  ssh -p 22 username@$DOMAIN                            ║"
echo "║  SSH TLS:     ssh -p 443 username@$DOMAIN                           ║"
echo "║  WebSocket:   ws://$DOMAIN/  or  wss://$DOMAIN/                     ║"
echo "║                                                                      ║"
echo "║  📋 FEATURES:                                                       ║"
echo "║  ✅ Full User Management (Create/Delete/Edit)                       ║"
echo "║  ✅ Trial Accounts (10/20/30/60 min)                               ║"
echo "║  ✅ Data Quota | Speed Limits | IP Limits                          ║"
echo "║  ✅ SSH/TLS/WS/WSS Support                                         ║"
echo "║  ✅ Domain & SSL Management                                        ║"
echo "║  ✅ Dynamic SSH Banners                                            ║"
echo "║  ✅ Session Monitoring                                             ║"
echo "║  ✅ Backup & Restore                                               ║"
echo "║  ✅ Firewall & Fail2ban                                            ║"
echo "║  ✅ Auto Certificate Renewal                                       ║"
echo "║                                                                      ║"
echo "║  📂 Path: ${INSTALL_DIR}                                            ║"
echo "║  📋 Logs: /var/log/grvpn                                            ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Run panel
grvpn
