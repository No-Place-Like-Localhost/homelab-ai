#!/usr/bin/env bash
# =============================================================================
# ENTERPRISE PRODUCTION GRADE - AI STACK DEPLOYMENT v10.1 (DOCKER FIXED)
# Target: Ubuntu 22.04 / 24.04 LTS (Server)
# 
# v10.1 FIXES:
# - Fixed Docker daemon.json (removed invalid no-new-privileges daemon option)
# - Removed conflicting runtimes configuration
# - Simplified DNS config (container-level, not daemon-level)
# - All previous v10.0 fixes retained
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
SCRIPT_VERSION="10.1.0-docker-fixed"
LOG_FILE="/var/log/ai-prod-setup.log"
BACKUP_ROOT="/opt/backups/ai-stack"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
AI_STACK_DIR="/opt/ai-stack"
SECRETS_DIR="/opt/ai-stack/secrets"
AGENT0_DATA_DIR="/opt/ai-stack/agent0-data"

# Software Versions
OPENWEBUI_VERSION="v0.3.19"
OLLAMA_VERSION="0.5.7"
PROMETHEUS_VERSION="v2.54.1"
GRAFANA_VERSION="11.3.1"
NODE_EXPORTER_VERSION="1.8.2"
AGENT0_VERSION="latest"

# PKI Settings
CA_COUNTRY="US"
CA_STATE="State"
CA_LOCALITY="City"
CA_ORG="Homelab Root CA"
SERVER_ORG="Homelab Services"
CA_VALIDITY_DAYS=1095
CERT_VALIDITY_DAYS=395

# Docker GPG Fingerprint
DOCKER_GPG_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

# Ports
REQUIRED_PORTS=(80 443 3000 3001 9090 4242 9100 11434)

# Rollback protection
ROLLBACK_IN_PROGRESS=false

# -----------------------------------------------------------------------------
# LOGGING
# -----------------------------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log_info()  { echo -e "\033[0;32m[INFO]\033[0m  $(date '+%Y-%m-%d %H:%M:%S') | $*"; }
log_warn()  { echo -e "\033[1;33m[WARN]\033[0m $(date '+%Y-%m-%d %H:%M:%S') | $*"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $(date '+%Y-%m-%d %H:%M:%S') | $*"; }
log_step()  { echo -e "\n\033[0;36m====== $1 ======\033[0m"; }
log_success() { echo -e "\033[0;32m[SUCCESS]\033[0m $(date '+%Y-%m-%d %H:%M:%S') | $*"; }

check_port() { ss -tuln | grep -q ":${1} "; }

check_ports() {
    log_step "Checking Port Availability"
    local conflicts=()
    for port in "${REQUIRED_PORTS[@]}"; do
        check_port "$port" && { conflicts+=("$port"); log_warn "Port $port in use"; } || log_info "Port $port available"
    done
    if [[ ${#conflicts[@]} -gt 0 ]]; then
        log_error "Ports in use: ${conflicts[*]}"
        read -p "Continue? (y/N): " -n 1 -r; echo
        [[ $REPLY =~ ^[Yy]$ ]] || exit 1
    fi
}

check_disk_space() {
    local available_gb
    available_gb=$(df -BG / | awk 'NR==2 {sub(/G/,"",$4); print $4}')
    if (( available_gb < 20 )); then
        log_error "Insufficient disk space: ${available_gb}GB available, need 20GB"
        exit 1
    fi
    log_info "Disk space OK: ${available_gb}GB available"
}

# -----------------------------------------------------------------------------
# ROLLBACK
# -----------------------------------------------------------------------------
rollback() {
    [[ "$ROLLBACK_IN_PROGRESS" == "true" ]] && return 1
    ROLLBACK_IN_PROGRESS=true
    trap - ERR
    
    log_error "Rolling back..."
    
    # Restore DNS
    [[ -f "${BACKUP_DIR}/resolv.conf.bak" ]] && cp "${BACKUP_DIR}/resolv.conf.bak" /etc/resolv.conf 2>/dev/null || true
    [[ -f "${BACKUP_DIR}/systemd-resolved.conf.bak" ]] && {
        mkdir -p /etc/systemd/resolved.conf.d 2>/dev/null || true
        cp "${BACKUP_DIR}/systemd-resolved.conf.bak" /etc/systemd/resolved.conf.d/homelab-dns.conf 2>/dev/null || true
    }
    systemctl restart systemd-resolved 2>/dev/null || true
    
    # Stop Docker
    command -v docker >/dev/null 2>&1 && {
        cd "$AI_STACK_DIR" 2>/dev/null || true
        docker compose down 2>/dev/null || docker-compose down 2>/dev/null || true
    }
    
    # Restore UFW
    [[ -f "${BACKUP_DIR}/ufw.rules.bak" ]] && {
        cp "${BACKUP_DIR}/ufw.rules.bak" /etc/ufw/user.rules 2>/dev/null || true
        ufw reload 2>/dev/null || true
    }
    
    # Restore SSH
    [[ -f "${BACKUP_DIR}/sshd_config.bak" ]] && {
        cp "${BACKUP_DIR}/sshd_config.bak" /etc/ssh/sshd_config 2>/dev/null || true
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    }
    
    # Remove swap
    [[ -f /swapfile ]] && grep -q "^/swapfile" /etc/fstab && {
        swapoff /swapfile 2>/dev/null || true
        sed -i '\|^/swapfile|d' /etc/fstab
        rm -f /swapfile
    }
    
    # FIX: Remove broken Docker daemon.json and restart
    [[ -f /etc/docker/daemon.json ]] && {
        rm -f /etc/docker/daemon.json
        systemctl restart docker 2>/dev/null || true
        log_info "Removed broken daemon.json, Docker restarted with defaults"
    }
    
    log_error "Rollback complete. Check $LOG_FILE"
    exit 1
}

trap 'rollback' ERR

log_info "AI Stack Installer v$SCRIPT_VERSION starting..."
log_info "FIXED: Docker daemon.json configuration issue"

# -----------------------------------------------------------------------------
# PRE-FLIGHT
# -----------------------------------------------------------------------------
log_step "Pre-flight Checks"

[[ "$(id -u)" -eq 0 ]] || { log_error "Run as root"; exit 1; }

source /etc/os-release
[[ "$ID" == "ubuntu" ]] || {
    log_warn "Designed for Ubuntu, detected: $ID"
    read -p "Continue? (y/N): " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 1
}

check_ports
check_disk_space

mkdir -p "$BACKUP_DIR"
log_info "Backup dir: $BACKUP_DIR"

# Backups
[[ -f /etc/resolv.conf ]] && cp /etc/resolv.conf "${BACKUP_DIR}/resolv.conf.bak" 2>/dev/null || true
[[ -f /etc/systemd/resolved.conf.d/homelab-dns.conf ]] && cp /etc/systemd/resolved.conf.d/homelab-dns.conf "${BACKUP_DIR}/systemd-resolved.conf.bak" 2>/dev/null || true
ufw status 2>/dev/null | grep -q "Status: active" && cp /etc/ufw/user.rules "${BACKUP_DIR}/ufw.rules.bak" 2>/dev/null || true
[[ -f /etc/ssh/sshd_config ]] && cp /etc/ssh/sshd_config "${BACKUP_DIR}/sshd_config.bak" 2>/dev/null || true

RAM_GB=$(free -g | awk '/Mem:/ {print $2}')
log_info "RAM: ${RAM_GB}GB"

# Swap
if (( RAM_GB < 8 )); then
    log_warn "Low RAM, creating swap..."
    [[ ! -f /swapfile ]] && {
        fallocate -l 4G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        grep -q "^/swapfile" /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        sysctl vm.swappiness=10
    }
fi

# -----------------------------------------------------------------------------
# KERNEL HARDENING
# -----------------------------------------------------------------------------
log_step "Kernel Hardening"

cat > /etc/sysctl.d/99-homelab-hardening.conf << 'EOF'
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.conf.all.accept_source_route=0
net.ipv6.conf.all.accept_source_route=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.tcp_max_syn_backlog=2048
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_syn_retries=5
net.ipv4.conf.all.log_martians=1
kernel.shmmax=68719476736
kernel.shmall=4294967296
net.ipv4.conf.all.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0
kernel.kptr_restrict=2
kernel.dmesg_restrict=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_rfc1337=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system > /dev/null

cat > /etc/security/limits.d/99-homelab.conf << 'EOF'
* soft nofile 65536
* hard nofile 65536
root soft nofile 65536
root hard nofile 65536
EOF

# -----------------------------------------------------------------------------
# DEPENDENCIES
# -----------------------------------------------------------------------------
log_step "Installing Dependencies"

DEBIAN_FRONTEND=noninteractive apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    apt-transport-https ca-certificates curl gnupg lsb-release \
    ufw fail2ban openssl net-tools zip unzip htop rsync bc \
    apache2-utils unattended-upgrades apt-listchanges

cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins { "${distro_id}:${distro_codename}-security"; };
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# -----------------------------------------------------------------------------
# DNS
# -----------------------------------------------------------------------------
log_step "DNS Configuration"

PRIMARY_IP=$(hostname -I | awk '{print $1}')
HOSTNAME_FQDN=$(hostname -f | tr -cd 'a-zA-Z0-9.-')
[[ -z "$HOSTNAME_FQDN" ]] && HOSTNAME_FQDN="homelab.local"
log_info "IP: $PRIMARY_IP | Hostname: $HOSTNAME_FQDN"

if systemctl is-active --quiet systemd-resolved; then
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/homelab-dns.conf << 'EOF'
[Resolve]
DNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net
FallbackDNS=1.1.1.1 8.8.8.8
DNSSEC=yes
Cache=yes
EOF
    [[ ! -L /etc/resolv.conf ]] && cp /etc/resolv.conf "${BACKUP_DIR}/resolv.conf.bak" 2>/dev/null || true
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null || true
    systemctl restart systemd-resolved
    
    # Verify DNS
    getent hosts google.com &>/dev/null || {
        log_warn "DNS failed, restoring..."
        [[ -f "${BACKUP_DIR}/resolv.conf.bak" ]] && cp "${BACKUP_DIR}/resolv.conf.bak" /etc/resolv.conf
        rm -f /etc/systemd/resolved.conf.d/homelab-dns.conf
        systemctl restart systemd-resolved
    }
fi

# -----------------------------------------------------------------------------
# FIREWALL
# -----------------------------------------------------------------------------
log_step "Firewall (UFW)"

ufw status 2>/dev/null | grep -q "Status: active" || {
    ufw default deny incoming
    ufw default allow outgoing
}

for port in 22 80 443 9090 3000 3001 4242; do
    ufw delete allow "${port}/tcp" 2>/dev/null || true
done

ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 9090/tcp comment 'Prometheus'
ufw allow 3000/tcp comment 'OpenWebUI'
ufw allow 3001/tcp comment 'Grafana'
ufw allow 4242/tcp comment 'Agent-Zero'

ufw status 2>/dev/null | grep -q "Status: active" || ufw --force enable

# -----------------------------------------------------------------------------
# PKI
# -----------------------------------------------------------------------------
log_step "PKI & Certificates"

SSL_DIR="/etc/ssl/homelab"
mkdir -p "$SSL_DIR" && chmod 700 "$SSL_DIR"
cd "$SSL_DIR" || exit 1

[[ ! -f "ca.crt" ]] && {
    openssl genrsa -out ca.key 4096
    openssl req -x509 -new -nodes -key ca.key -sha256 -days $CA_VALIDITY_DAYS \
        -out ca.crt -subj "/C=$CA_COUNTRY/ST=$CA_STATE/L=$CA_LOCALITY/O=$CA_ORG/CN=Homelab Root CA"
}

[[ ! -f "server.key" ]] && openssl genrsa -out server.key 4096

cat > server.csr.conf << EOF
[req]
default_bits = 4096
prompt = no
distinguished_name = dn
req_extensions = req_ext
[dn]
C = $CA_COUNTRY
ST = $CA_STATE
L = $CA_LOCALITY
O = $SERVER_ORG
CN = $HOSTNAME_FQDN
[req_ext]
subjectAltName = @alt_names
[alt_names]
DNS.1 = $HOSTNAME_FQDN
DNS.2 = localhost
IP.1 = $PRIMARY_IP
IP.2 = 127.0.0.1
EOF

openssl req -new -key server.key -out server.csr -config server.csr.conf

[[ ! -f "server.crt" ]] && {
    openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
        -out server.crt -days $CERT_VALIDITY_DAYS -sha256 \
        -extensions req_ext -extfile server.csr.conf
    chmod 600 server.key
    chmod 644 server.crt ca.crt
}

cd - || exit 1

# -----------------------------------------------------------------------------
# DOCKER (FIXED CONFIGURATION)
# -----------------------------------------------------------------------------
log_step "Installing Docker"

if ! command -v docker >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    systemctl enable docker
    systemctl start docker
fi

# CRITICAL FIX: Minimal, SAFE Docker daemon configuration
# NOTE: "no-new-privileges" is NOT a valid daemon option - only works at container level!
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOF'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "storage-driver": "overlay2",
    "live-restore": true
}
EOF

log_info "Docker daemon.json created (minimal safe config)"
systemctl restart docker

# Verify Docker started successfully
if ! systemctl is-active --quiet docker; then
    log_error "Docker failed to start! Removing daemon.json..."
    rm -f /etc/docker/daemon.json
    systemctl restart docker
    systemctl is-active --quiet docker || {
        log_error "Docker still failing! Manual intervention required."
        exit 1
    }
fi
log_success "Docker is running"

[[ -n "${SUDO_USER:-}" ]] && usermod -aG docker "$SUDO_USER" 2>/dev/null || true

# -----------------------------------------------------------------------------
# SSH HARDENING
# -----------------------------------------------------------------------------
log_step "SSH Hardening"

SSHD_CONFIG="/etc/ssh/sshd_config"
[[ ! -f "${BACKUP_DIR}/sshd_config.bak" ]] && cp "$SSHD_CONFIG" "${BACKUP_DIR}/sshd_config.bak"

# Safety check for SSH keys
SSH_KEYS_EXIST=false
for kf in ~/.ssh/authorized_keys /root/.ssh/authorized_keys; do
    [[ -f "$kf" && -s "$kf" ]] && SSH_KEYS_EXIST=true && break
done

if [[ "$SSH_KEYS_EXIST" == "true" ]]; then
    log_info "SSH keys found - safe to disable password auth"
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
else
    log_warn "NO SSH KEYS - keeping password auth enabled!"
fi

sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"

sshd -t 2>/dev/null && systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

# -----------------------------------------------------------------------------
# SECRETS
# -----------------------------------------------------------------------------
log_step "Secrets Management"

mkdir -p "$SECRETS_DIR" "$AI_STACK_DIR"
chmod 700 "$AI_STACK_DIR" "$SECRETS_DIR"

[[ ! -f "${SECRETS_DIR}/webui-secret.env" ]] && {
    echo "WEBUI_SECRET=$(openssl rand -hex 32)" > "${SECRETS_DIR}/webui-secret.env"
    chmod 600 "${SECRETS_DIR}/webui-secret.env"
}

[[ ! -f "${SECRETS_DIR}/grafana-secret.env" ]] && {
    cat > "${SECRETS_DIR}/grafana-secret.env" << EOF
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=$(openssl rand -base64 16)
EOF
    chmod 600 "${SECRETS_DIR}/grafana-secret.env"
}

[[ ! -f "${SECRETS_DIR}/agent0.env" ]] && {
    cat > "${SECRETS_DIR}/agent0.env" << 'EOF'
# Add your API keys here:
# OPENAI_API_KEY=sk-...
# ANTHROPIC_API_KEY=sk-ant-...
EOF
    chmod 600 "${SECRETS_DIR}/agent0.env"
}

# -----------------------------------------------------------------------------
# DOCKER COMPOSE
# -----------------------------------------------------------------------------
log_step "Deploying AI Stack"

mkdir -p "$AI_STACK_DIR"/data/{ollama,openwebui,grafana,prometheus}
mkdir -p "$AGENT0_DATA_DIR"/{memory,knowledge,instruments,prompts,work_dir}
cd "$AI_STACK_DIR" || exit 1

# Dynamic memory allocation
TOTAL_RAM_GB="$(free -g | awk '/Mem:/ {print $2}')"
OLLAMA_MEM="4G"
if (( TOTAL_RAM_GB >= 16 )); then OLLAMA_MEM="8G"; fi
if (( TOTAL_RAM_GB >= 32 )); then OLLAMA_MEM="16G"; fi
log_info "Ollama memory: ${OLLAMA_MEM}"

cat > docker-compose.yml << EOF
version: '3.8'
services:
  ollama:
    image: ollama/ollama:${OLLAMA_VERSION}
    container_name: ollama
    restart: unless-stopped
    volumes: [./data/ollama:/root/.ollama]
    environment: [OLLAMA_HOST=0.0.0.0]
    networks: [ai-net]
    deploy: {resources: {limits: {memory: ${OLLAMA_MEM}}}}

  openwebui:
    image: ghcr.io/open-webui/open-webui:${OPENWEBUI_VERSION}
    container_name: openwebui
    restart: unless-stopped
    ports: ["127.0.0.1:3000:8080"]
    env_file: [${SECRETS_DIR}/webui-secret.env]
    environment: [OLLAMA_BASE_URL=http://ollama:11434, ENABLE_SIGNUP=false]
    volumes: [./data/openwebui:/app/backend/data]
    depends_on: [ollama]
    networks: [ai-net]

  prometheus:
    image: prom/prometheus:${PROMETHEUS_VERSION}
    container_name: prometheus
    restart: unless-stopped
    ports: ["127.0.0.1:9090:9090"]
    volumes: [./data/prometheus:/prometheus, ./prometheus.yml:/etc/prometheus/prometheus.yml]
    networks: [ai-net]

  grafana:
    image: grafana/grafana:${GRAFANA_VERSION}
    container_name: grafana
    restart: unless-stopped
    ports: ["127.0.0.1:3001:3000"]
    env_file: [${SECRETS_DIR}/grafana-secret.env]
    volumes: [./data/grafana:/var/lib/grafana]
    depends_on: [prometheus]
    networks: [ai-net]

  node-exporter:
    image: prom/node-exporter:${NODE_EXPORTER_VERSION}
    container_name: node-exporter
    restart: unless-stopped
    volumes: [/proc:/host/proc:ro, /sys:/host/sys:ro]
    command: ['--path.procfs=/host/proc', '--path.sysfs=/host/sys']
    networks: [ai-net]

  agent0:
    image: agent0ai/agent-zero:${AGENT0_VERSION}
    container_name: agent0
    restart: unless-stopped
    ports: ["127.0.0.1:4242:4242"]
    volumes: [${AGENT0_DATA_DIR}:/a0, ${SECRETS_DIR}/agent0.env:/a0/.env:ro]
    environment: [AGENT0_HOST=0.0.0.0, AGENT0_PORT=4242]
    networks: [ai-net]
    extra_hosts: ["host.docker.internal:host-gateway"]

networks:
  ai-net: {driver: bridge}
EOF

cat > prometheus.yml << 'EOF'
global: {scrape_interval: 15s}
scrape_configs:
  - {job_name: prometheus, static_configs: [{targets: [localhost:9090]}]}
  - {job_name: node-exporter, static_configs: [{targets: [node-exporter:9100]}]}
  - {job_name: ollama, static_configs: [{targets: [ollama:11434]}], metrics_path: /api/metrics}
EOF

log_info "Pulling images..."
for i in 1 2 3; do docker compose pull && break; log_warn "Pull $i failed, retry..."; sleep 5; done

log_info "Starting containers..."
docker compose up -d

sleep 20

# -----------------------------------------------------------------------------
# COMPLETE
# -----------------------------------------------------------------------------
log_step "Deployment Complete"

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║              AI STACK DEPLOYED SUCCESSFULLY                    ║"
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║  OpenWebUI  │ http://localhost:3000                             ║"
echo "║  Grafana    │ http://localhost:3001                             ║"
echo "║  Prometheus │ http://localhost:9090                             ║"
echo "║  Ollama API │ http://localhost:11434                            ║"
echo "║  Agent Zero │ http://localhost:4242                             ║"
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║  Secrets: ${SECRETS_DIR}"
echo "║  Log:    ${LOG_FILE}"
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║  Next: docker exec ollama ollama pull llama3.2                  ║"
echo "║        Edit ${SECRETS_DIR}/agent0.env for API keys               ║"
echo "╚════════════════════════════════════════════════════════════════╝"

log_success "Installation complete!"
trap - ERR
exit 0
