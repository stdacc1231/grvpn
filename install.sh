#!/bin/bash
# GRVPN PANEL v3.0 - DOMAIN SSL EDITION
# Complete SSH VPN with Domain SSL Certificate
# Run as root

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

clear
echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  🐱 GRVPN PANEL v3.0 - DOMAIN SSL EDITION                          ║"
echo "║  Complete SSH VPN with Domain SSL Certificate                      ║"
echo "║  SSH VPN | SSH WS | SSH TLS | Payload Injection                    ║"
echo "║  ROOT PATH: /  (NO OTHER PATHS)                                    ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

# Check root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[❌] Run as root!${NC}"
    exit 1
fi

# Get domain
echo -e "${BLUE}[🌐] Enter your domain (e.g., vpn.example.com):${NC}"
read -p "Domain: " GRVPN_DOMAIN

if [ -z "$GRVPN_DOMAIN" ]; then
    echo -e "${RED}[❌] Domain required!${NC}"
    exit 1
fi

echo -e "${GREEN}[✅] Using domain: $GRVPN_DOMAIN${NC}"

# Get server IP
SERVER_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || hostname -I | awk '{print $1}')
echo -e "${BLUE}[🌐] Server IP: $SERVER_IP${NC}"
echo -e "${YELLOW}[⚠️] Make sure DNS A record points $GRVPN_DOMAIN -> $SERVER_IP${NC}"
echo ""
read -p "Press Enter to continue..."

# Create directories
echo -e "${BLUE}[📁] Creating directories...${NC}"
mkdir -p /opt/grvpn/{data,logs,scripts,users,domains,ssh,ws,nginx,stunnel5,banners,payloads,configs,backups,bin}
mkdir -p /etc/grvpn
mkdir -p /var/log/grvpn
mkdir -p /etc/ssh/sshd_config.d
mkdir -p /var/run/grvpn
mkdir -p /etc/letsencrypt

# Update system
echo -e "${BLUE}[🔄] Updating system...${NC}"
apt update && apt upgrade -y

# Install packages
echo -e "${BLUE}[📦] Installing packages...${NC}"
apt install -y openssh-server stunnel5 nginx \
    certbot python3-certbot-nginx python3-pip \
    screen tmux ufw fail2ban redis-server \
    sqlite3 bc net-tools iptables-persistent \
    curl wget git unzip jq htop nload \
    openssl netcat socat python3-bcrypt \
    apache2-utils whois dnsutils uuid-runtime \
    sshuttle python3-sshuttle iptables \
    build-essential autoconf libtool pkg-config

# Install Python packages
echo -e "${BLUE}[🐍] Installing Python packages...${NC}"
pip3 install psutil bcrypt cryptography pyOpenSSL sqlalchemy redis requests \
    colorama prettytable tabulate python-dateutil

# Install websocat
echo -e "${BLUE}[🌐] Installing websocat...${NC}"
wget -q -O /usr/local/bin/websocat https://github.com/vi/websocat/releases/download/v1.12.0/websocat.x86_64-unknown-linux-musl
chmod +x /usr/local/bin/websocat

# Generate SSL certificate for domain
echo -e "${BLUE}[🔐] Generating SSL certificate for $GRVPN_DOMAIN...${NC}"

# Stop nginx first
systemctl stop nginx 2>/dev/null || true

# Try Let's Encrypt
echo -e "${YELLOW}[🔐] Trying Let's Encrypt...${NC}"
certbot certonly --standalone -d "$GRVPN_DOMAIN" \
    --non-interactive --agree-tos \
    -m "admin@$GRVPN_DOMAIN" \
    --keep-until-expiring 2>/dev/null

if [ -f "/etc/letsencrypt/live/$GRVPN_DOMAIN/fullchain.pem" ]; then
    CERT_PATH="/etc/letsencrypt/live/$GRVPN_DOMAIN/fullchain.pem"
    KEY_PATH="/etc/letsencrypt/live/$GRVPN_DOMAIN/privkey.pem"
    echo -e "${GREEN}[✅] Let's Encrypt certificate obtained!${NC}"
else
    echo -e "${YELLOW}[⚠️] Let's Encrypt failed. Using self-signed...${NC}"
    mkdir -p "/etc/letsencrypt/live/$GRVPN_DOMAIN"
    openssl req -x509 -newkey rsa:4096 -keyout "/etc/letsencrypt/live/$GRVPN_DOMAIN/privkey.pem" \
        -out "/etc/letsencrypt/live/$GRVPN_DOMAIN/fullchain.pem" -days 365 -nodes \
        -subj "/CN=$GRVPN_DOMAIN"
    CERT_PATH="/etc/letsencrypt/live/$GRVPN_DOMAIN/fullchain.pem"
    KEY_PATH="/etc/letsencrypt/live/$GRVPN_DOMAIN/privkey.pem"
fi

# Copy certs to standard location
cp "$CERT_PATH" /etc/ssl/grvpn.pem
cp "$KEY_PATH" /etc/ssl/grvpn.key
chmod 600 /etc/ssl/grvpn.key
chmod 644 /etc/ssl/grvpn.pem

echo -e "${GREEN}[✅] SSL certificate installed for $GRVPN_DOMAIN${NC}"

# Generate SSH host keys
echo -e "${BLUE}[🔑] Generating SSH host keys...${NC}"
ssh-keygen -A

# Create dynamic banner script
echo -e "${BLUE}[📝] Creating dynamic banner...${NC}"
cat > /opt/grvpn/bin/grvpn-banner << 'BANNER_EOF'
#!/bin/bash
# GRVPN Dynamic Banner Script

USERNAME="$1"
if [ -z "$USERNAME" ]; then
    echo "Welcome to GRVPN VPN Server"
    exit 0
fi

# Get user data
USER_DATA=$(sqlite3 /opt/grvpn/data.db "SELECT data_limit, download_speed, upload_speed, ip_limit, bandwidth_used, connections, created_at, expires_at, ssh_banner FROM users WHERE username='$USERNAME' AND is_active=1" 2>/dev/null)

if [ -z "$USER_DATA" ]; then
    echo "Welcome to GRVPN VPN Server"
    exit 0
fi

IFS='|' read -r DATA_LIMIT DL_SPEED UL_SPEED IP_LIMIT BANDWIDTH_USED CONNECTIONS CREATED_AT EXPIRES_AT SSH_BANNER <<< "$USER_DATA"

# Calculate remaining data
if [ "$DATA_LIMIT" -eq 0 ]; then
    DATA_REMAINING="∞ (Unlimited)"
    DATA_PERCENT="∞"
    DATA_USED_GB="0.00"
else
    DATA_USED_GB=$(echo "scale=2; $BANDWIDTH_USED/1024/1024/1024" | bc 2>/dev/null)
    if [ -z "$DATA_USED_GB" ]; then
        DATA_USED_GB="0.00"
    fi
    DATA_REMAINING_GB=$(echo "scale=2; ($DATA_LIMIT - ($BANDWIDTH_USED/1024/1024/1024))" | bc 2>/dev/null)
    if [ -z "$DATA_REMAINING_GB" ] || (( $(echo "$DATA_REMAINING_GB < 0" | bc -l 2>/dev/null) )); then
        DATA_REMAINING_GB="0.00"
    fi
    DATA_REMAINING="${DATA_REMAINING_GB}GB"
    DATA_PERCENT=$(echo "scale=0; ($DATA_USED_GB/$DATA_LIMIT)*100" | bc 2>/dev/null)
    if [ -z "$DATA_PERCENT" ]; then
        DATA_PERCENT="0"
    fi
fi

# Get active sessions
ACTIVE_SESSIONS=$(sqlite3 /opt/grvpn/data.db "SELECT COUNT(*) FROM sessions WHERE user_id=(SELECT id FROM users WHERE username='$USERNAME') AND is_active=1" 2>/dev/null)
if [ -z "$ACTIVE_SESSIONS" ]; then
    ACTIVE_SESSIONS="0"
fi

# Get last login
LAST_LOGIN=$(sqlite3 /opt/grvpn/data.db "SELECT ip, connected_at FROM sessions WHERE user_id=(SELECT id FROM users WHERE username='$USERNAME') AND is_active=1 ORDER BY connected_at DESC LIMIT 1" 2>/dev/null)
if [ -n "$LAST_LOGIN" ]; then
    LAST_IP=$(echo "$LAST_LOGIN" | cut -d'|' -f1)
    LAST_TIME=$(echo "$LAST_LOGIN" | cut -d'|' -f2)
else
    LAST_IP="N/A"
    LAST_TIME="N/A"
fi

# Get server info
SERVER_NAME=$(hostname)
SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
UPTIME=$(uptime -p 2>/dev/null)

# Build banner
echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  🐱 GRVPN VPN SERVER                                                ║"
echo "║  Secure SSH VPN Tunnel - Ultimate Edition                           ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║                                                                      ║"
echo "║  👤 User: $USERNAME                                                  ║"
echo "║  🌐 Server: $SERVER_NAME ($SERVER_IP)                                 ║"
echo "║  🕐 Uptime: $UPTIME                                                  ║"
echo "║                                                                      ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║  📊 YOUR ACCOUNT STATS                                              ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║  Data Limit   : $DATA_LIMIT GB                                      ║"
echo "║  Data Used    : $DATA_USED_GB GB                                    ║"
echo "║  Data Remaining: $DATA_REMAINING                                    ║"
echo "║  Data Usage   : $DATA_PERCENT%                                      ║"
echo "║  Download Speed: $DL_SPEED Mbps                                     ║"
echo "║  Upload Speed  : $UL_SPEED Mbps                                     ║"
echo "║  IP Limit     : $IP_LIMIT                                           ║"
echo "║  Active Sessions: $ACTIVE_SESSIONS                                  ║"
echo "║  Last Login IP : $LAST_IP                                           ║"
echo "║  Last Login    : $LAST_TIME                                         ║"
echo "║  Created       : $CREATED_AT                                        ║"
echo "║  Expires       : $EXPIRES_AT                                        ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║                                                                      ║"
if [ -n "$SSH_BANNER" ]; then
    echo "$SSH_BANNER"
else
    echo "║  💡 Welcome to GRVPN VPN Tunnel!                                  ║"
    echo "║  📡 All traffic is encrypted and secure                          ║"
fi
echo "║                                                                      ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
BANNER_EOF

chmod +x /opt/grvpn/bin/grvpn-banner

# Configure SSH
echo -e "${BLUE}[🔧] Configuring SSH...${NC}"
cat > /etc/ssh/sshd_config << 'EOF'
# GRVPN SSH Configuration
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

Banner /opt/grvpn/bin/grvpn-banner

ClientAliveInterval 60
ClientAliveCountMax 3
TCPKeepAlive yes
Compression yes

MaxSessions 100
MaxStartups 100:30:200
LoginGraceTime 30
PermitTunnel yes
AllowTcpForwarding yes
GatewayPorts yes
EOF

# Configure Nginx with domain
echo -e "${BLUE}[🔧] Configuring Nginx with domain $GRVPN_DOMAIN...${NC}"
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
    
    server_name $GRVPN_DOMAIN;
    
    ssl_certificate /etc/ssl/grvpn.pem;
    ssl_certificate_key /etc/ssl/grvpn.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    
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
}
EOF

ln -sf /etc/nginx/sites-available/grvpn /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Configure Stunnel5
echo -e "${BLUE}[🔧] Configuring Stunnel5...${NC}"
cat > /etc/stunnel5/stunnel.conf << 'STUNNEL_EOF'
; GRVPN Stunnel5 Configuration
pid = /var/run/stunnel5.pid
debug = 3
output = /var/log/stunnel5.log
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1
client = no
compression = zlib
options = NO_SSLv2
options = NO_SSLv3
ciphers = ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384
sslVersion = TLSv1.2

[grvpn-ssh-443]
accept = 0.0.0.0:443
connect = 127.0.0.1:22
cert = /etc/ssl/grvpn.pem
key = /etc/ssl/grvpn.key
retry = yes

[grvpn-ssh-8443]
accept = 0.0.0.0:8443
connect = 127.0.0.1:22
cert = /etc/ssl/grvpn.pem
key = /etc/ssl/grvpn.key
retry = yes

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
STUNNEL_EOF

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

# Configure Fail2ban
echo -e "${BLUE}[🛡️] Configuring fail2ban...${NC}"
cat > /etc/fail2ban/jail.local << 'FAIL2BAN_EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 7200
FAIL2BAN_EOF

systemctl restart fail2ban 2>/dev/null || true

# Create database
echo -e "${BLUE}[💾] Creating database...${NC}"
sqlite3 /opt/grvpn/data.db << 'SQL_EOF'
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
    ssh_port INTEGER,
    ws_port INTEGER,
    ssh_banner TEXT,
    payload_config TEXT,
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

INSERT OR IGNORE INTO settings (key, value) VALUES 
    ('domain', '$GRVPN_DOMAIN'),
    ('server_name', 'GRVPN Server');
SQL_EOF

# Create admin user
echo -e "${BLUE}[👤] Creating admin user...${NC}"
python3 << 'PYTHON_ADMIN'
import sqlite3, bcrypt
conn = sqlite3.connect('/opt/grvpn/data.db')
c = conn.cursor()
c.execute("SELECT * FROM users WHERE username='grvpn'")
if not c.fetchone():
    pwd = bcrypt.hashpw(b'GRVPN@2026', bcrypt.gensalt())
    c.execute("INSERT INTO users(username, password, is_admin, is_active) VALUES('grvpn', ?, 1, 1)", (pwd,))
    conn.commit()
conn.close()
print("[✅] Admin created: grvpn / GRVPN@2026")
PYTHON_ADMIN

# Create panel script
echo -e "${BLUE}[📝] Creating GRVPN panel...${NC}"
cat > /usr/local/bin/grvpn << 'GRVPN_PANEL'
#!/usr/bin/env python3
"""
GRVPN PANEL v3.0 - COMPLETE CLI MANAGEMENT
Domain SSL Edition
"""

import os, sys, sqlite3, subprocess, time, json, psutil, bcrypt, uuid
from datetime import datetime, timedelta
from prettytable import PrettyTable
import colorama
colorama.init()

DB = '/opt/grvpn/data.db'

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

def log_activity(user_id, action, ip='', details=''):
    conn = get_conn()
    c = conn.cursor()
    c.execute("INSERT INTO logs(user_id, action, ip, details) VALUES(?,?,?,?)",
              (user_id, action, ip, details))
    conn.commit()
    conn.close()

def clear_screen():
    os.system('clear' if os.name == 'posix' else 'cls')

# ============ MAIN PANEL ============
def main_menu():
    while True:
        clear_screen()
        print("""
╔══════════════════════════════════════════════════════════════════════╗
║  🐱 GRVPN PANEL v3.0 - DOMAIN SSL EDITION                          ║
╠══════════════════════════════════════════════════════════════════════╣
║  1.  👤 User Management                                             ║
║  2.  📊 Monitor & Logs                                              ║
║  3.  🔌 Session Management                                          ║
║  4.  ⚡ Speed & Limits                                              ║
║  5.  🛡️ IP Rules                                                   ║
║  6.  🌐 Domain Management                                           ║
║  7.  📈 System Stats                                                ║
║  8.  🔧 Service Management                                          ║
║  9.  🚀 Connection Info                                             ║
║  10. 💾 Backup/Restore                                              ║
║  11. 🚪 Exit                                                       ║
╚══════════════════════════════════════════════════════════════════════╝
        """)
        
        choice = input("🐱 Choice: ").strip()
        if choice == '1': user_menu()
        elif choice == '2': monitor_menu()
        elif choice == '3': session_menu()
        elif choice == '4': limit_menu()
        elif choice == '5': ip_menu()
        elif choice == '6': domain_menu()
        elif choice == '7': stats_menu()
        elif choice == '8': service_menu()
        elif choice == '9': connect_info()
        elif choice == '10': backup_menu()
        elif choice == '11': 
            print("\n[👋] Goodbye!")
            sys.exit(0)

# ============ USER MENU ============
def user_menu():
    while True:
        clear_screen()
        print("\n👤 USER MANAGEMENT")
        print("="*50)
        print("1. List Users")
        print("2. Create User")
        print("3. View User Details")
        print("4. Edit User")
        print("5. Delete User")
        print("6. Change Password")
        print("7. Set SSH Banner")
        print("8. Back to Main")
        
        choice = input("\nChoice: ").strip()
        if choice == '1': list_users()
        elif choice == '2': create_user()
        elif choice == '3': view_user()
        elif choice == '4': edit_user()
        elif choice == '5': delete_user()
        elif choice == '6': change_password()
        elif choice == '7': set_banner()
        elif choice == '8': break

def list_users():
    clear_screen()
    users = get_all_users()
    if not users:
        print("[ℹ️] No users found")
        input("Press Enter...")
        return
    
    table = PrettyTable()
    table.field_names = ["ID", "Username", "Data", "DL", "UL", "IP", "Conn", "SSH", "Admin"]
    for u in users:
        data = f"{u['data_limit']}GB" if u['data_limit'] > 0 else "∞"
        dl = f"{u['download_speed']}M" if u['download_speed'] > 0 else "∞"
        ul = f"{u['upload_speed']}M" if u['upload_speed'] > 0 else "∞"
        ip = f"{u['ip_limit']}" if u['ip_limit'] > 0 else "∞"
        table.add_row([u['id'], u['username'][:15], data, dl, ul, ip, 
                       u.get('connections',0), u.get('ssh_port','N/A'), 
                       "✅" if u['is_admin'] else "❌"])
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
    
    ssh_port = get_free_port(2000)
    ws_port = get_free_port(3000)
    
    pwd_hash = bcrypt.hashpw(password.encode(), bcrypt.gensalt())
    
    conn = get_conn()
    c = conn.cursor()
    c.execute('''INSERT INTO users
        (username, password, email, data_limit, download_speed, upload_speed,
         ip_limit, is_admin, ssh_port, ws_port)
        VALUES(?,?,?,?,?,?,?,?,?,?)''',
        (username, pwd_hash, email, data_limit, dl_speed, ul_speed,
         ip_limit, 1 if is_admin else 0, ssh_port, ws_port))
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
    input("\nPress Enter...")

def view_user():
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

def edit_user():
    clear_screen()
    username = input("Username: ").strip()
    user = get_user(username)
    if not user:
        print("[❌] User not found!")
        input("Press Enter...")
        return
    
    print(f"\n✏️ EDIT: {username}")
    print("Fields: email, data_limit, download_speed, upload_speed, ip_limit, is_active")
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
    
    print("[✅] Password changed!")
    input("Press Enter...")

def set_banner():
    clear_screen()
    username = input("Username: ").strip()
    user = get_user(username)
    if not user:
        print("[❌] User not found!")
        input("Press Enter...")
        return
    
    print("Current banner: " + user.get('ssh_banner', 'None'))
    print("\nEnter new banner (use \\n for new lines):")
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
    
    print("[✅] Banner set!")
    input("Press Enter...")

# ============ MONITOR MENU ============
def monitor_menu():
    clear_screen()
    print("\n📊 MONITOR & LOGS")
    print("="*50)
    
    sessions = get_active_sessions()
    if sessions:
        print("\n🟢 ONLINE USERS:")
        print("="*80)
        for s in sessions:
            print(f"{s['username']:20} | IP: {s['ip']:20} | {s['protocol']:10} | Port: {s['port']} | {s['connected_at'][:19]}")
    else:
        print("\n[ℹ️] No online users")
    
    print("\n📋 RECENT LOGS (last 10):")
    print("="*80)
    conn = get_conn()
    conn.row_factory = sqlite3.Row
    c = conn.cursor()
    c.execute('''SELECT l.*, u.username 
        FROM logs l JOIN users u ON l.user_id = u.id 
        ORDER BY l.timestamp DESC LIMIT 10''')
    logs = c.fetchall()
    conn.close()
    for log in logs:
        print(f"{log['timestamp'][:19]} | {log['username']:20} | {log['action']:15} | {log['details']}")
    
    input("\nPress Enter...")

# ============ SESSION MENU ============
def session_menu():
    while True:
        clear_screen()
        print("\n🔌 SESSION MANAGEMENT")
        print("="*50)
        print("1. List Active Sessions")
        print("2. Kill Session")
        print("3. Kill All User Sessions")
        print("4. Back")
        
        choice = input("\nChoice: ").strip()
        if choice == '1': list_sessions()
        elif choice == '2': kill_session()
        elif choice == '3': kill_all()
        elif choice == '4': break

def list_sessions():
    clear_screen()
    sessions = get_active_sessions()
    if not sessions:
        print("[ℹ️] No active sessions")
        input("Press Enter...")
        return
    
    table = PrettyTable()
    table.field_names = ["ID", "User", "IP", "Protocol", "Port", "Connected"]
    for s in sessions:
        table.add_row([s['id'], s['username'][:15], s['ip'], s['protocol'], 
                       s['port'], s['connected_at'][:19]])
    print(table)
    input("\nPress Enter...")

def kill_session():
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
    print("[✅] Session killed!")
    input("Press Enter...")

def kill_all():
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
    print(f"[✅] All sessions killed for {username}")
    input("Press Enter...")

# ============ LIMIT MENU ============
def limit_menu():
    while True:
        clear_screen()
        print("\n⚡ SPEED & LIMITS")
        print("="*50)
        print("1. List All Limits")
        print("2. Set User Limits")
        print("3. Reset Bandwidth")
        print("4. Back")
        
        choice = input("\nChoice: ").strip()
        if choice == '1': list_limits()
        elif choice == '2': set_limits()
        elif choice == '3': reset_bandwidth()
        elif choice == '4': break

def list_limits():
    clear_screen()
    users = get_all_users()
    table = PrettyTable()
    table.field_names = ["User", "Data", "DL", "UL", "IP", "Used"]
    for u in users:
        data = f"{u['data_limit']}GB" if u['data_limit'] > 0 else "∞"
        dl = f"{u['download_speed']}M" if u['download_speed'] > 0 else "∞"
        ul = f"{u['upload_speed']}M" if u['upload_speed'] > 0 else "∞"
        used = f"{u['bandwidth_used']/1024/1024/1024:.2f}GB"
        table.add_row([u['username'][:15], data, dl, ul, u['ip_limit'], used])
    print(table)
    input("\nPress Enter...")

def set_limits():
    clear_screen()
    username = input("Username: ").strip()
    user = get_user(username)
    if not user:
        print("[❌] User not found!")
        input("Press Enter...")
        return
    
    print(f"\n✏️ SET LIMITS: {username}")
    data = input(f"Data Limit GB (current: {user['data_limit']}): ").strip()
    dl = input(f"Download Speed Mbps (current: {user['download_speed']}): ").strip()
    ul = input(f"Upload Speed Mbps (current: {user['upload_speed']}): ").strip()
    ip = input(f"IP Limit (current: {user['ip_limit']}): ").strip()
    
    updates = {}
    if data: updates['data_limit'] = int(data)
    if dl: updates['download_speed'] = int(dl)
    if ul: updates['upload_speed'] = int(ul)
    if ip: updates['ip_limit'] = int(ip)
    
    if updates:
        conn = get_conn()
        c = conn.cursor()
        for key, val in updates.items():
            c.execute(f"UPDATE users SET {key}=? WHERE id=?", (val, user['id']))
        conn.commit()
        conn.close()
        print("[✅] Limits updated!")
    else:
        print("[ℹ️] No changes")
    input("Press Enter...")

def reset_bandwidth():
    clear_screen()
    username = input("Username: ").strip()
    user = get_user(username)
    if not user:
        print("[❌] User not found!")
        input("Press Enter...")
        return
    
    if input(f"Reset {username} bandwidth? (y/n): ").strip().lower() != 'y':
        return
    
    conn = get_conn()
    c = conn.cursor()
    c.execute("UPDATE users SET bandwidth_used=0 WHERE id=?", (user['id'],))
    conn.commit()
    conn.close()
    print("[✅] Bandwidth reset!")
    input("Press Enter...")

# ============ IP MENU ============
def ip_menu():
    while True:
        clear_screen()
        print("\n🛡️ IP RULES")
        print("="*50)
        print("1. List IP Rules")
        print("2. Add IP Rule")
        print("3. Remove IP Rule")
        print("4. Back")
        
        choice = input("\nChoice: ").strip()
        if choice == '1': list_ip()
        elif choice == '2': add_ip()
        elif choice == '3': remove_ip()
        elif choice == '4': break

def list_ip():
    clear_screen()
    conn = get_conn()
    conn.row_factory = sqlite3.Row
    c = conn.cursor()
    c.execute("SELECT * FROM ip_rules WHERE is_active=1")
    rules = c.fetchall()
    conn.close()
    
    if not rules:
        print("[ℹ️] No IP rules")
    else:
        table = PrettyTable()
        table.field_names = ["ID", "IP", "Action", "Reason", "Expires"]
        for r in rules:
            table.add_row([r['id'], r['ip'], r['action'], r['reason'] or '-', r['expires_at'] or 'Never'])
        print(table)
    input("\nPress Enter...")

def add_ip():
    clear_screen()
    ip = input("IP: ").strip()
    action = input("Action (allow/block): ").strip().lower()
    reason = input("Reason: ").strip()
    expires = input("Expires (days, 0=never): ").strip()
    
    expires_at = None
    if expires and int(expires) > 0:
        expires_at = datetime.now() + timedelta(days=int(expires))
    
    conn = get_conn()
    c = conn.cursor()
    c.execute("INSERT OR REPLACE INTO ip_rules(ip, action, reason, expires_at) VALUES(?,?,?,?)",
              (ip, action, reason, expires_at))
    conn.commit()
    conn.close()
    
    if action == 'block':
        subprocess.run(f"iptables -A INPUT -s {ip} -j DROP", shell=True)
    else:
        subprocess.run(f"iptables -D INPUT -s {ip} -j DROP", shell=True)
    
    print(f"[🛡️] IP {ip} {action}ed!")
    input("Press Enter...")

def remove_ip():
    clear_screen()
    ip = input("IP: ").strip()
    conn = get_conn()
    c = conn.cursor()
    c.execute("UPDATE ip_rules SET is_active=0 WHERE ip=?", (ip,))
    conn.commit()
    conn.close()
    subprocess.run(f"iptables -D INPUT -s {ip} -j DROP", shell=True)
    print(f"[✅] IP {ip} removed!")
    input("Press Enter...")

# ============ DOMAIN MENU ============
def domain_menu():
    while True:
        clear_screen()
        print("\n🌐 DOMAIN MANAGEMENT")
        print("="*50)
        print("1. Show Current Domain")
        print("2. Change Domain (New SSL)")
        print("3. Renew SSL")
        print("4. Back")
        
        choice = input("\nChoice: ").strip()
        if choice == '1': show_domain()
        elif choice == '2': change_domain()
        elif choice == '3': renew_ssl()
        elif choice == '4': break

def show_domain():
    clear_screen()
    conn = get_conn()
    c = conn.cursor()
    c.execute("SELECT value FROM settings WHERE key='domain'")
    domain = c.fetchone()
    conn.close()
    
    if domain:
        print(f"\n🌐 Current Domain: {domain[0]}")
        print(f"   SSL Cert: /etc/ssl/grvpn.pem")
        print(f"   SSL Key: /etc/ssl/grvpn.key")
    else:
        print("[ℹ️] No domain configured")
    input("\nPress Enter...")

def change_domain():
    clear_screen()
    print("\n🌐 CHANGE DOMAIN")
    print("="*50)
    print("⚠️ This will replace existing SSL certificate")
    
    new_domain = input("New domain: ").strip()
    if not new_domain:
        print("[❌] Domain required!")
        input("Press Enter...")
        return
    
    # Stop services
    subprocess.run(['systemctl', 'stop', 'nginx'], check=False)
    
    # Get new cert
    print(f"[🔐] Getting SSL for {new_domain}...")
    certbot certonly --standalone -d "$new_domain" \
        --non-interactive --agree-tos \
        -m "admin@$new_domain" 2>/dev/null
    
    if os.path.exists(f"/etc/letsencrypt/live/{new_domain}/fullchain.pem"):
        subprocess.run(f"cp /etc/letsencrypt/live/{new_domain}/fullchain.pem /etc/ssl/grvpn.pem", shell=True)
        subprocess.run(f"cp /etc/letsencrypt/live/{new_domain}/privkey.pem /etc/ssl/grvpn.key", shell=True)
        
        # Update domain in DB
        conn = get_conn()
        c = conn.cursor()
        c.execute("UPDATE settings SET value=? WHERE key='domain'", (new_domain,))
        conn.commit()
        conn.close()
        
        # Update Nginx
        subprocess.run(f"sed -i 's/server_name .*/server_name {new_domain};/g' /etc/nginx/sites-available/grvpn", shell=True)
        subprocess.run(['systemctl', 'reload', 'nginx'], check=False)
        
        print(f"[✅] Domain changed to {new_domain}")
    else:
        print("[❌] SSL certificate failed!")
        subprocess.run(['systemctl', 'start', 'nginx'], check=False)
    
    input("Press Enter...")

def renew_ssl():
    clear_screen()
    print("[🔄] Renewing SSL...")
    result = subprocess.run(['certbot', 'renew', '--nginx', '--non-interactive'], capture_output=True)
    if result.returncode == 0:
        print("[✅] SSL renewed!")
    else:
        print("[❌] Renewal failed!")
    input("Press Enter...")

# ============ STATS MENU ============
def stats_menu():
    clear_screen()
    cpu = psutil.cpu_percent()
    mem = psutil.virtual_memory()
    disk = psutil.disk_usage('/')
    net = psutil.net_io_counters()
    
    conn = get_conn()
    c = conn.cursor()
    c.execute("SELECT COUNT(*) FROM users WHERE is_active=1")
    users = c.fetchone()[0]
    c.execute("SELECT COUNT(*) FROM sessions WHERE is_active=1")
    sessions = c.fetchone()[0]
    conn.close()
    
    print("\n📊 SYSTEM STATS")
    print("="*50)
    print(f"CPU: {cpu}%")
    print(f"Memory: {mem.used/1024**3:.2f}GB / {mem.total/1024**3:.2f}GB ({mem.percent}%)")
    print(f"Disk: {disk.used/1024**3:.2f}GB / {disk.total/1024**3:.2f}GB ({disk.percent}%)")
    print(f"Users: {users}")
    print(f"Active Sessions: {sessions}")
    print(f"Network Sent: {net.bytes_sent/1024**3:.2f}GB")
    print(f"Network Received: {net.bytes_recv/1024**3:.2f}GB")
    input("\nPress Enter...")

# ============ SERVICE MENU ============
def service_menu():
    while True:
        clear_screen()
        print("\n🔧 SERVICE MANAGEMENT")
        print("="*50)
        print("1. Status All")
        print("2. Restart All")
        print("3. Start/Stop Service")
        print("4. View Logs")
        print("5. Back")
        
        choice = input("\nChoice: ").strip()
        if choice == '1': service_status()
        elif choice == '2': restart_all()
        elif choice == '3': service_control()
        elif choice == '4': view_logs()
        elif choice == '5': break

def service_status():
    clear_screen()
    services = ['nginx', 'ssh', 'stunnel5', 'fail2ban']
    print("\n📊 SERVICE STATUS")
    print("="*50)
    for svc in services:
        result = subprocess.run(['systemctl', 'is-active', svc], capture_output=True)
        status = result.stdout.decode().strip()
        print(f"{svc:15}: {'✅' if status == 'active' else '❌'} ({status})")
    input("\nPress Enter...")

def restart_all():
    if input("Restart ALL services? (y/n): ").strip().lower() != 'y':
        return
    for svc in ['nginx', 'ssh', 'stunnel5']:
        subprocess.run(['systemctl', 'restart', svc])
        print(f"[✅] {svc} restarted!")
    input("Press Enter...")

def service_control():
    service = input("Service name: ").strip()
    action = input("Action (start/stop/restart/reload): ").strip()
    subprocess.run(['systemctl', action, service])
    print(f"[✅] {service} {action}ed!")
    input("Press Enter...")

def view_logs():
    service = input("Service name: ").strip()
    lines = input("Lines (default 50): ").strip() or "50"
    subprocess.run(['journalctl', '-u', service, '-n', lines, '--no-pager'])
    input("Press Enter...")

# ============ CONNECTION INFO ============
def connect_info():
    clear_screen()
    
    # Get domain
    conn = get_conn()
    c = conn.cursor()
    c.execute("SELECT value FROM settings WHERE key='domain'")
    domain_row = c.fetchone()
    conn.close()
    domain = domain_row[0] if domain_row else "YOUR_DOMAIN"
    
    print("\n🚀 CONNECTION INFO - ROOT PATH \"/\"")
    print("="*70)
    print(f"Domain: {domain}")
    print()
    print("📡 SSH Direct (No TLS):")
    print(f"   ssh -p 22 username@{domain}")
    print(f"   ssh -p 80 username@{domain}")
    print()
    print("📡 SSH TLS/SSL:")
    print(f"   ssh -p 443 username@{domain}")
    print(f"   ssh -p 8443 username@{domain}")
    print()
    print("📡 WebSocket (ROOT \"/\"):")
    print(f"   ws://{domain}/")
    print(f"   wss://{domain}/")
    print(f"   websocat -v ws://{domain}/")
    print(f"   websocat -v wss://{domain}/")
    
    users = get_all_users()
    if users:
        print("\n👤 USER PORTS:")
        print("="*50)
        for u in users:
            print(f"{u['username']:20} | SSH: {u['ssh_port']} | WS: {u['ws_port']}")
    
    input("\nPress Enter...")

# ============ BACKUP MENU ============
def backup_menu():
    while True:
        clear_screen()
        print("\n💾 BACKUP/RESTORE")
        print("="*50)
        print("1. Create Backup")
        print("2. List Backups")
        print("3. Restore Backup")
        print("4. Back")
        
        choice = input("\nChoice: ").strip()
        if choice == '1': create_backup()
        elif choice == '2': list_backups()
        elif choice == '3': restore_backup()
        elif choice == '4': break

def create_backup():
    backup_path = f"/opt/grvpn/backups/backup_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    os.makedirs(backup_path, exist_ok=True)
    subprocess.run(f"cp {DB} {backup_path}/", shell=True)
    subprocess.run(f"cp -r /etc/nginx/sites-available {backup_path}/", shell=True)
    subprocess.run(f"cp -r /etc/stunnel5 {backup_path}/", shell=True)
    subprocess.run(f"cp -r /etc/ssh/sshd_config.d {backup_path}/", shell=True)
    print(f"[✅] Backup: {backup_path}")
    input("Press Enter...")

def list_backups():
    subprocess.run("ls -la /opt/grvpn/backups/ 2>/dev/null", shell=True)
    input("Press Enter...")

def restore_backup():
    backup = input("Backup path: ").strip()
    if not os.path.exists(backup):
        print("[❌] Not found!")
        input("Press Enter...")
        return
    if input("Restore? (y/n): ").strip().lower() != 'y':
        return
    subprocess.run(f"cp {backup}/data.db {DB}", shell=True)
    subprocess.run(f"cp -r {backup}/nginx/* /etc/nginx/", shell=True)
    subprocess.run(f"cp -r {backup}/stunnel5/* /etc/stunnel5/", shell=True)
    subprocess.run(['systemctl', 'reload', 'nginx'])
    print("[✅] Restored!")
    input("Press Enter...")

# ============ RUN ============
if __name__ == "__main__":
    try:
        main_menu()
    except KeyboardInterrupt:
        print("\n[👋] Goodbye!")
        sys.exit(0)
GRVPN_PANEL

chmod +x /usr/local/bin/grvpn

# Start services
echo -e "${BLUE}[🚀] Starting services...${NC}"
systemctl daemon-reload
systemctl enable nginx ssh stunnel5 fail2ban
systemctl restart nginx ssh stunnel5 fail2ban

# Start websocat
echo -e "${BLUE}[🌐] Starting WebSocket...${NC}"
nohup websocat -s 0.0.0.0:8080 -- sh -c "ssh -o StrictHostKeyChecking=no localhost" > /var/log/grvpn/websocat.log 2>&1 &

# Final message
echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  🐱 GRVPN PANEL v3.0 INSTALLATION COMPLETE!                        ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║                                                                      ║"
echo "║  Run: grvpn                                                          ║"
echo "║  Login: grvpn / GRVPN@2026                                          ║"
echo "║                                                                      ║"
echo "║  🌐 Domain: $GRVPN_DOMAIN                                            ║"
echo "║  📡 SSL Certificate: Valid for $GRVPN_DOMAIN                        ║"
echo "║                                                                      ║"
echo "║  📡 CONNECTION METHODS:                                              ║"
echo "║  SSH Direct: ssh -p 22 username@$GRVPN_DOMAIN                       ║"
echo "║  SSH TLS:    ssh -p 443 username@$GRVPN_DOMAIN                      ║"
echo "║  WebSocket:  ws://$GRVPN_DOMAIN/  or  wss://$GRVPN_DOMAIN/          ║"
echo "║                                                                      ║"
echo "║  📂 Path: /opt/grvpn                                                ║"
echo "║  📋 Logs: /var/log/grvpn                                            ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Run panel
grvpn
