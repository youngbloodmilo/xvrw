#!/bin/bash

# ====================================================================
# Xray VLESS-REALITY + WARP (Socks5) Auto-Deployment Script
# Target OS: Rocky Linux 8
# Features: Idempotent, Automated Routing, Watchdog, Health Check
# ====================================================================

set -e
set -o pipefail

# ========== User Configuration (Variables) ==========
XRAY_PORT=443
FALLBACK_PORT=8080
WARP_PORT=40000

TARGET_SNI="www.nvidia.com"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_SERVICE="xray"

WARP_WATCHDOG_SCRIPT="/usr/local/bin/warp-watchdog.sh"
CRON_FILE="/etc/cron.d/xray-maintenance"

# Color outputs
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo "========================================================="
echo "   Xray VLESS-REALITY + WARP Installation Script         "
echo "                Target: Rocky Linux 8                    "
echo "========================================================="

# ========== 0. Pre-flight Checks ==========
log "Checking OS compatibility..."
if ! grep -qi "Rocky Linux" /etc/redhat-release || ! grep -q "release 8" /etc/redhat-release; then
    err "This script is strictly designed for Rocky Linux 8. Aborting."
fi

if [ "$EUID" -ne 0 ]; then
    err "Please run this script as root."
fi

# ========== 1. System Update & Dependencies ==========
log "Installing dependencies..."
dnf install -y epel-release >/dev/null 2>&1
dnf install -y curl wget socat jq tzdata util-linux nginx >/dev/null 2>&1

# ========== 2. Setup Timezone & SELinux ==========
log "Configuring Timezone (Asia/Shanghai)..."
timedatectl set-timezone Asia/Shanghai

log "Disabling SELinux..."
if [ "$(getenforce)" != "Disabled" ]; then
    setenforce 0 || true
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
fi

# ========== 3. Network Optimization (BBR) ==========
log "Applying TCP/BBR Optimizations..."
cat <<EOF > /etc/sysctl.d/99-xray-optimizations.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_tw_reuse=1
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
EOF
sysctl --system >/dev/null 2>&1

# ========== 4. Nginx Decoy Setup ==========
log "Configuring Nginx Decoy on port ${FALLBACK_PORT}..."
cat <<EOF > /etc/nginx/nginx.conf
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events { worker_connections 1024; }

http {
    include             /etc/nginx/mime.types;
    default_type        application/octet-stream;
    sendfile            on;
    keepalive_timeout   65;
    server {
        listen       ${FALLBACK_PORT};
        listen       [::]:${FALLBACK_PORT};
        server_name  _;
        root         /usr/share/nginx/html;
        location / { index index.html; }
    }
}
EOF
systemctl enable --now nginx >/dev/null 2>&1
systemctl restart nginx

# ========== 5. Install & Configure WARP (Socks5) ==========
log "Setting up Cloudflare WARP..."
if [ ! -f /etc/yum.repos.d/cloudflare-warp.repo ]; then
  curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo | tee /etc/yum.repos.d/cloudflare-warp.repo >/dev/null
fi
dnf -y install cloudflare-warp >/dev/null 2>&1

systemctl enable --now warp-svc >/dev/null 2>&1
sleep 2

# Robust Registration: Handle TOS and existing broken registrations
if ! warp-cli --accept-tos account 2>/dev/null | grep -q "Account Type"; then
  log "Registering WARP (Auto-accepting TOS)..."
  warp-cli --accept-tos registration delete >/dev/null 2>&1 || true
  warp-cli --accept-tos registration new >/dev/null 2>&1 || true
fi

log "Configuring WARP Proxy & Watchdog Services..."
cat > /etc/systemd/system/warp-proxy.service <<EOF
[Unit]
Description=WARP Proxy Init (SOCKS5 ${WARP_PORT})
After=network-online.target warp-svc.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c "warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true; warp-cli --accept-tos proxy port ${WARP_PORT} >/dev/null 2>&1 || true; warp-cli --accept-tos connect >/dev/null 2>&1 || true"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > "$WARP_WATCHDOG_SCRIPT" <<EOF
#!/bin/bash
set -euo pipefail
WARP_PORT=${WARP_PORT}
systemctl is-active --quiet warp-svc || systemctl restart warp-svc
if warp-cli --accept-tos status 2>/dev/null | grep -q "Connected"; then
  ss -lnt 2>/dev/null | grep -q ":\$WARP_PORT " && exit 0
fi
warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true
warp-cli --accept-tos proxy port \$WARP_PORT >/dev/null 2>&1 || true
warp-cli --accept-tos connect >/dev/null 2>&1 || true
EOF
chmod +x "$WARP_WATCHDOG_SCRIPT"

cat > /etc/systemd/system/warp-watchdog.service <<EOF
[Unit]
Description=WARP Watchdog

[Service]
Type=oneshot
ExecStart=${WARP_WATCHDOG_SCRIPT}
EOF

cat > /etc/systemd/system/warp-watchdog.timer <<EOF
[Unit]
Description=Run WARP Watchdog every 2 minutes

[Timer]
OnBootSec=30
OnUnitActiveSec=120
Unit=warp-watchdog.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now warp-proxy.service >/dev/null 2>&1
systemctl enable --now warp-watchdog.timer >/dev/null 2>&1

# ========== 6. Install Xray Core ==========
log "Installing Xray Core..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root >/dev/null 2>&1

# ========== 7. Handle Credentials (Idempotency) ==========
log "Checking for existing Xray credentials..."
UUID=""
PRIVATE_KEY=""
SHORT_ID=""

if [ -f "$XRAY_CONFIG" ] && command -v jq >/dev/null; then
    UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG" 2>/dev/null || true)
    PRIVATE_KEY=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$XRAY_CONFIG" 2>/dev/null || true)
    SHORT_ID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG" 2>/dev/null || true)
fi

# Clean up empty strings from broken jq reads (Fixing the previous syntax bug)
if [ "$UUID" == "null" ]; then 
    UUID=""
fi

if [ "$PRIVATE_KEY" == "null" ]; then 
    PRIVATE_KEY=""
fi

if [ "$SHORT_ID" == "null" ]; then 
    SHORT_ID=""
fi

# Generate credentials if they are empty
if [ -z "$UUID" ]; then
    UUID=$(uuidgen)
    log "Generated new UUID."
fi

if [ -z "$PRIVATE_KEY" ]; then
    KEY_PAIR=$($XRAY_BIN x25519)
    PRIVATE_KEY=$(echo "$KEY_PAIR" | grep -i "Private" | cut -d':' -f2 | tr -d ' ' | tr -d '\r')
    PUBLIC_KEY=$(echo "$KEY_PAIR" | grep -i "Public" | cut -d':' -f2 | tr -d ' ' | tr -d '\r')
    log "Generated new REALITY Key Pair."
else
    PUBLIC_KEY=$($XRAY_BIN x25519 -i "$PRIVATE_KEY" | grep -i "Public" | cut -d':' -f2 | tr -d ' ' | tr -d '\r')
    log "Restored existing REALITY Keys."
fi

if [ -z "$SHORT_ID" ]; then
    SHORT_ID=$(openssl rand -hex 4)
    log "Generated new ShortID."
fi

# ========== 8. Write Xray Configuration ==========
log "Generating Xray Configuration..."
mkdir -p "$(dirname "$XRAY_CONFIG")"
mkdir -p /var/log/xray
chown -R root:root /var/log/xray

cat <<EOF > "$XRAY_CONFIG"
{
  "log": { "loglevel": "error", "access": "/dev/null", "error": "/var/log/xray/error.log" },
  "dns": {
    "tag": "dns-internal",
    "queryStrategy": "UseIP",
    "disableCache": false,
    "servers":[
      { "address": "https://1.1.1.1/dns-query", "domains": ["geosite:geolocation-!cn"], "skipFallback": true },
      { "address": "https://223.5.5.5/dns-query", "domains":["geosite:cn"], "expectIPs": ["geoip:cn"], "skipFallback": false }
    ]
  },
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules":[
      { "type": "field", "outboundTag": "block", "protocol": ["bittorrent"] },
      { "type": "field", "outboundTag": "block", "domain":["geosite:category-ads-all"] },
      { "type": "field", "outboundTag": "block", "ip": ["geoip:private"] },
      { "type": "field", "outboundTag": "block", "domain": ["geosite:cn"] },
      { "type": "field", "outboundTag": "block", "ip": ["geoip:cn"] },
      { "type": "field", "outboundTag": "direct", "domain":[
        "domain:whatismyipaddress.com", "domain:google.com", "domain:googleapis.com", 
        "domain:gstatic.com", "domain:gmail.com", "domain:chatgpt.com", "domain:openai.com", 
        "domain:oaistatic.com", "domain:oaiusercontent.com", "domain:anthropic.com", 
        "domain:claude.ai", "domain:linux.do", "domain:idcflare.com", "domain:dmit.io", "domain:vmrack.net"
      ]},
      { "type": "field", "outboundTag": "warp", "domain":["geosite:geolocation-!cn"]},
      { "type": "field", "outboundTag": "warp", "ip":["geoip:!cn"]},
      { "type": "field", "network": "tcp,udp", "outboundTag": "warp" }
    ]
  },
  "inbounds":[
    {
      "listen": "::",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients":[{ "id": "${UUID}", "flow": "xtls-rprx-vision" }],
        "decryption": "none",
        "fallbacks":[{ "dest": ${FALLBACK_PORT}, "xver": 0 }]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${TARGET_SNI}:443",
          "xver": 0,
          "serverNames":["${TARGET_SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds":["${SHORT_ID}"]
        },
        "sockopt": { "tcpFastOpen": false, "freebind": true }
      },
      "sniffing": { "enabled": true, "destOverride":["http", "tls", "quic"], "metadataOnly": false, "routeOnly": true }
    }
  ],
  "outbounds":[
    { "tag": "warp","protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":${WARP_PORT}}]}},
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } },
    { "tag": "block", "protocol": "blackhole" }
  ]
}
EOF

# ========== 9. Finalize Xray Services ==========
log "Validating Xray config..."
if ! $XRAY_BIN -test -config "$XRAY_CONFIG"; then
    echo -e "\n${RED}[ERROR] Xray configuration validation failed!${NC}"
    exit 1
fi
log "Configuration OK."

systemctl enable --now $XRAY_SERVICE >/dev/null 2>&1
systemctl restart $XRAY_SERVICE

# ========== 10. Firewall Configuration ==========
log "Configuring Firewalld..."
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=${XRAY_PORT}/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1
else
    warn "Firewalld is not running. Skipping port rules."
fi

# ========== 11. Maintenance Cron Jobs (Idempotent) ==========
log "Adding Maintenance Cron Jobs to /etc/cron.d/ ..."
cat <<EOF > "$CRON_FILE"
# Xray & System Maintenance Tasks
0 * * * * root sync; echo 3 > /proc/sys/vm/drop_caches
0 2 * * 0 root bash -c "\$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root >/dev/null 2>&1
0 3 * * 0 root dnf -y upgrade >> /var/log/dnf-upgrade.log 2>&1 && /sbin/reboot
EOF
chmod 644 "$CRON_FILE"

# ========== 12. Final Health Check ==========
echo -e "\n${YELLOW}>>> Performing final health checks on all components...${NC}"
HEALTH_FLAG=0

if systemctl is-active --quiet nginx; then
    echo -e "  [✔] Nginx (Decoy)   : ${GREEN}Running${NC}"
else
    echo -e "  [✘] Nginx (Decoy)   : ${RED}Failed${NC} (Check: journalctl -u nginx --no-pager -n 20)"
    HEALTH_FLAG=1
fi

if systemctl is-active --quiet warp-svc && ss -lnt | grep -q ":${WARP_PORT} "; then
    echo -e "  [✔] WARP (Socks5)   : ${GREEN}Running & Proxying on port ${WARP_PORT}${NC}"
else
    echo -e "  [✘] WARP (Socks5)   : ${RED}Failed${NC} (Check: warp-cli status OR systemctl status warp-proxy)"
    HEALTH_FLAG=1
fi

if systemctl is-active --quiet $XRAY_SERVICE; then
    echo -e "  [✔] Xray Core       : ${GREEN}Running${NC}"
else
    echo -e "  [✘] Xray Core       : ${RED}Failed${NC} (Check: journalctl -u $XRAY_SERVICE --no-pager -n 20)"
    HEALTH_FLAG=1
fi

if [ "$HEALTH_FLAG" -ne 0 ]; then
    echo -e "\n${RED}=========================================================${NC}"
    echo -e "${RED}   Deployment Finished with Errors!                      ${NC}"
    echo -e "${RED}   Please fix the failed services before using.          ${NC}"
    echo -e "${RED}=========================================================${NC}\n"
    exit 1
fi

# ========== 13. Output Information ==========
IPV4=$(curl -s4 https://api.ipify.org || echo "YOUR_IPV4")

echo -e "\n${GREEN}=========================================================${NC}"
echo -e "${GREEN}          Deployment Successful! System is Ready.        ${NC}"
echo -e "${GREEN}=========================================================${NC}"

echo -e "\n${YELLOW}▶ [1/3] Nginx (回退伪装服务)${NC}"
echo -e "  启停命令 : systemctl {start|stop|restart|status} nginx"
echo -e "  配置文件 : /etc/nginx/nginx.conf"
echo -e "  日志文件 : /var/log/nginx/error.log"

echo -e "\n${YELLOW}▶ [2/3] Cloudflare WARP (Socks5落地代理)${NC}"
echo -e "  主启停令 : systemctl {start|stop|restart|status} warp-svc"
echo -e "  代理启停 : systemctl {start|stop|restart|status} warp-proxy.service"
echo -e "  配置文件 : 无配置，使用命令交互 -> warp-cli"
echo -e "  日志文件 : journalctl -u warp-svc --no-pager -n 50"
echo -e "  账号信息 : 执行命令查看 -> warp-cli --accept-tos account"
echo -e "  内部监听 : 127.0.0.1:${WARP_PORT}"

echo -e "\n${YELLOW}▶ [3/3] Xray Core (核心路由与防封锁系统)${NC}"
echo -e "  启停命令 : systemctl {start|stop|restart|status} xray"
echo -e "  配置文件 : ${XRAY_CONFIG}"
echo -e "  日志文件 : /var/log/xray/error.log"
echo -e "  \n  ${GREEN}--- 客户端连接详细参数 ---${NC}"
echo -e "  地址 (Address) : ${IPV4}"
echo -e "  端口 (Port)    : ${XRAY_PORT}"
echo -e "  协议 (Protocol): vless"
echo -e "  用户ID (UUID)  : ${UUID}"
echo -e "  流控 (Flow)    : xtls-rprx-vision"
echo -e "  传输网 (Network): tcp"
echo -e "  安全 (Security): reality"
echo -e "  伪装域 (SNI)   : ${TARGET_SNI}"
echo -e "  指纹 (uTLS)    : chrome"
echo -e "  公钥 (PublicKey): ${PUBLIC_KEY}"
echo -e "  短ID (ShortId) : ${SHORT_ID}"

echo -e "\n${GREEN}--- VLESS 极速分享链接 (直接复制导入客户端) ---${NC}"
echo -e "vless://${UUID}@${IPV4}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${TARGET_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Xray-Reality-Rocky"
echo -e "\n${GREEN}=========================================================${NC}"
