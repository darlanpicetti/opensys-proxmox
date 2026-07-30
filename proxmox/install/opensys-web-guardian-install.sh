#!/usr/bin/env bash
# OpenSys Web Guardian — bootstrap nativo dentro do guest (CT/VM/Debian).
# Espelha o lab 192.168.0.33: apt Buildkite + e2guardian 5.6 + ClamAV + seeds + opensys-ui.
#
# Chamado pelo script Proxmox (pct exec) ou manualmente:
#   sudo bash opensys-web-guardian-install.sh
set -euo pipefail

OPENSYS_ROOT="${OPENSYS_ROOT:-/opt/opensys}"
STATE_DIR="${OPENSYS_ROOT}/var"
SEED_DIR="${OPENSYS_ROOT}/seed"
PANEL_ENV="${OPENSYS_ROOT}/panel.env"
FLAG="${STATE_DIR}/.initialized"
CREDS="${STATE_DIR}/firstboot-credentials.txt"
REPO_RAW="${OPENSYS_REPO_RAW:-https://raw.githubusercontent.com/darlanpicetti/opensys-proxmox/main}"
POLICY_SEED_URL="${OPENSYS_POLICY_SEED_URL:-${REPO_RAW}/seeds/policy-seed.tar.gz}"
REQUIREMENTS_URL="${OPENSYS_REQUIREMENTS_URL:-${REPO_RAW}/requirements.txt}"

ORG="${OPENSYS_UPDATES_REGISTRY_ORG:-darlanpicetti}"
REGISTRY="${OPENSYS_UPDATES_REGISTRY_SLUG:-opensys-web-guardian}"
REPO_URI="${OPENSYS_UPDATES_REPO_URI:-https://packages.buildkite.com/${ORG}/${REGISTRY}/any/}"
REPO_SUITE="${OPENSYS_UPDATES_REPO_SUITE:-any}"
REPO_COMPONENTS="${OPENSYS_UPDATES_REPO_COMPONENTS:-main}"
KEYRING="${OPENSYS_UPDATES_REPO_KEYRING:-/usr/share/keyrings/opensys-buildkite-archive-keyring.gpg}"
E2G_DEB_URL="${E2GUARDIAN_DEB_URL:-https://e2guardian.numsys.eu/v5.6/e2debian_bookworm_V5.6.1_20260330.deb}"

PANEL_PORT="${PANEL_PORT:-5001}"
TZ="${TZ:-America/Sao_Paulo}"
LICENSE_SERVER_URL="${LICENSE_SERVER_URL:-https://licensewg.opensys.com.br}"
ADMIN_USER="${ADMIN_USER:-admin}"

die() { echo "ERRO: $*" >&2; exit 1; }
info() { echo "→ $*"; }
ok() { echo "✓ $*"; }
warn() { echo "AVISO: $*" >&2; }

[[ "$(id -u)" -eq 0 ]] || die "execute como root"

if [[ -f "$FLAG" ]]; then
  ok "já inicializado ($FLAG) — reexecutando etapas idempotentes"
fi

export DEBIAN_FRONTEND=noninteractive
export TZ

rand_hex() { openssl rand -hex "${1:-24}"; }
rand_pass() { openssl rand -base64 18 | tr -d '/+=' | head -c 20; }

detect_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

download() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  else
    wget -qO "$dest" "$url"
  fi
}

# --- 1. Base OS ---
info "atualizando apt e pacotes base…"
apt-get update -qq
apt-get install -y -qq \
  curl wget ca-certificates gnupg openssl \
  python3 python3-venv python3-pip \
  acl sudo systemd \
  clamav clamav-daemon clamav-freshclam \
  >/dev/null

# --- 2. Buildkite keyring + sources ---
info "registrando apt Buildkite (${ORG}/${REGISTRY})…"
mkdir -p "$(dirname "$KEYRING")" /etc/apt/sources.list.d
GPG_URL="https://packages.buildkite.com/${ORG}/${REGISTRY}/gpgkey"
if [[ -n "${BUILDKITE_READ_TOKEN:-}" ]]; then
  GPG_URL="https://buildkite:${BUILDKITE_READ_TOKEN}@packages.buildkite.com/${ORG}/${REGISTRY}/gpgkey"
fi
download "$GPG_URL" /tmp/opensys-bk.gpg.key
gpg --dearmor </tmp/opensys-bk.gpg.key >"${KEYRING}.tmp"
install -m 644 "${KEYRING}.tmp" "$KEYRING"
rm -f "${KEYRING}.tmp" /tmp/opensys-bk.gpg.key

# Deb822 preferred on bookworm
cat > /etc/apt/sources.list.d/opensys-web-guardian.sources <<EOF
Types: deb
URIs: ${REPO_URI}
Suites: ${REPO_SUITE}
Components: ${REPO_COMPONENTS}
Signed-By: ${KEYRING}
EOF

apt-get update -qq || warn "apt update no registry OpenSys falhou — tentando continuar"

# --- 3. Pacotes produto ---
info "instalando opensys-ui (e dependências)…"
if ! apt-get install -y -qq opensys-ui; then
  die "falha ao instalar opensys-ui do registry — verifique rede até packages.buildkite.com"
fi

install_e2guardian() {
  if apt-cache show opensys-e2guardian >/dev/null 2>&1; then
    info "instalando opensys-e2guardian do registry…"
    apt-get install -y -qq opensys-e2guardian && return 0
  fi
  info "opensys-e2guardian ausente no apt — instalando e2guardian 5.6.1 (numsys/fredbcode)…"
  local deb_dir="${STATE_DIR}/n2"
  mkdir -p "$deb_dir"
  local deb_name
  deb_name="$(basename "$E2G_DEB_URL")"
  download "$E2G_DEB_URL" "${deb_dir}/${deb_name}"
  # Remove stock 5.3.x se presente
  apt-get remove -y --purge e2guardian 2>/dev/null || true
  if ! getent group e2guardian >/dev/null; then groupadd --system e2guardian; fi
  if ! getent passwd e2guardian >/dev/null; then
    useradd --system --gid e2guardian --home /var/log/e2guardian --shell /usr/sbin/nologin e2guardian
  fi
  dpkg -i "${deb_dir}/${deb_name}" || apt-get install -y -f -qq || true
  if [[ ! -x /usr/sbin/e2guardian ]]; then
    local xdir
    xdir="$(mktemp -d)"
    dpkg-deb -x "${deb_dir}/${deb_name}" "$xdir"
    cp -a "${xdir}/usr/sbin/e2guardian" /usr/sbin/e2guardian
    [[ -d "${xdir}/usr/lib" ]] && cp -a "${xdir}/usr/lib/." /usr/lib/ || true
    rm -rf "$xdir"
  fi
  /usr/sbin/e2guardian -v 2>&1 | head -3 || true
  if [[ ! -f /lib/systemd/system/e2guardian.service && ! -f /etc/systemd/system/e2guardian.service ]]; then
    cat > /etc/systemd/system/e2guardian.service <<'UNIT'
[Unit]
Description=OpenSys filter (e2guardian 5.6)
After=network-online.target clamav-daemon.service
Wants=network-online.target clamav-daemon.service

[Service]
Type=forking
ExecStart=/usr/sbin/e2guardian
ExecReload=/usr/sbin/e2guardian -r
PIDFile=/run/e2guardian.pid
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
  fi
}

install_e2guardian

# Holds (produto)
apt-mark hold opensys-ui e2guardian opensys-e2guardian opensys-appliance-meta 2>/dev/null || true

# --- 4. Layout / usuários ---
info "layout /opt/opensys e grupos…"
mkdir -p "$OPENSYS_ROOT"/{app,venv,seed,var,bin}
if ! getent passwd opensys >/dev/null; then
  adduser --disabled-password --gecos "OpenSys Panel" opensys
fi
groupadd -f opensys-scan
usermod -aG opensys-scan opensys || true
usermod -aG e2guardian opensys 2>/dev/null || true
usermod -aG opensys-scan e2guardian 2>/dev/null || true
usermod -aG opensys-scan clamav 2>/dev/null || true

mkdir -p /var/e2g-scan-cache /var/log/e2guardian /var/log/clamav /run/clamav /etc/e2guardian/lists
chown e2guardian:opensys-scan /var/e2g-scan-cache
chmod 2770 /var/e2g-scan-cache
chown e2guardian:e2guardian /var/log/e2guardian || true
chown clamav:clamav /var/log/clamav || true
chown -R opensys:opensys "$OPENSYS_ROOT/app" "$STATE_DIR" 2>/dev/null || true

# Helpers do pacote (se vierem em appliance/)
if [[ -f "${OPENSYS_ROOT}/app/appliance/scripts/opensys-net" ]]; then
  install -m 755 "${OPENSYS_ROOT}/app/appliance/scripts/opensys-net" "${OPENSYS_ROOT}/bin/opensys-net"
fi
if [[ -f "${OPENSYS_ROOT}/app/appliance/scripts/opensys-logs" ]]; then
  install -m 755 "${OPENSYS_ROOT}/app/appliance/scripts/opensys-logs" "${OPENSYS_ROOT}/bin/opensys-logs"
fi
if [[ -f "${OPENSYS_ROOT}/app/appliance/sudoers/90-opensys-updates" ]]; then
  if visudo -cf "${OPENSYS_ROOT}/app/appliance/sudoers/90-opensys-updates" >/dev/null 2>&1; then
    install -m 440 "${OPENSYS_ROOT}/app/appliance/sudoers/90-opensys-updates" /etc/sudoers.d/90-opensys-updates
  fi
fi
if [[ -f "${OPENSYS_ROOT}/app/appliance/sudoers/90-opensys-network" ]]; then
  if visudo -cf "${OPENSYS_ROOT}/app/appliance/sudoers/90-opensys-network" >/dev/null 2>&1; then
    install -m 440 "${OPENSYS_ROOT}/app/appliance/sudoers/90-opensys-network" /etc/sudoers.d/90-opensys-network
  fi
fi

# --- 5. Policy seed (DEC-008) ---
ensure_policy_seed() {
  local dest="${SEED_DIR}/policy-seed.tar.gz"
  mkdir -p "$SEED_DIR" "$STATE_DIR"
  if [[ ! -f "$dest" ]]; then
    info "baixando policy-seed…"
    download "$POLICY_SEED_URL" "$dest" || die "não baixou policy-seed de $POLICY_SEED_URL"
  fi
  # Cópia legada usada pelos scripts N2 do lab
  cp -a "$dest" "${STATE_DIR}/policy-seed.tar.gz"

  local marker="${STATE_DIR}/.policy-seed-applied"
  if [[ -f "$marker" && -f /etc/e2guardian/lists/e2g-ui-groups.json ]]; then
    ok "policy seed já aplicado"
    return 0
  fi

  info "aplicando policy seed em /etc/e2guardian…"
  local tmp
  tmp="$(mktemp -d)"
  tar -xzf "$dest" -C "$tmp"
  local root="$tmp"
  [[ -d "${tmp}/policy-seed" ]] && root="${tmp}/policy-seed"
  [[ -d "${root}/lists" ]] || die "seed inválido (sem lists/)"
  mkdir -p /etc/e2guardian/lists
  cp -a "${root}/lists/." /etc/e2guardian/lists/
  if [[ -d "${root}/conf" ]]; then
    cp -a "${root}/conf/." /etc/e2guardian/
  fi
  local n
  n="$(python3 -c "import json; print(len(json.load(open('/etc/e2guardian/lists/e2g-ui-groups.json'))))")"
  python3 - <<PY
import re
path = "/etc/e2guardian/e2guardian.conf"
n = int("${n}")
text = open(path, encoding="utf-8", errors="replace").read() if __import__("os").path.isfile(path) else ""
if re.search(r"(?m)^\s*filtergroups\s*=", text):
    text = re.sub(r"(?m)^\s*filtergroups\s*=\s*.*$", f"filtergroups = {n}", text)
else:
    text += f"\nfiltergroups = {n}\n"
if not re.search(r"(?m)^\s*authplugin\s*=", text):
    text += "\nauthplugin = '/etc/e2guardian/authplugins/ip.conf'\n"
open(path, "w", encoding="utf-8").write(text)
print(f"filtergroups = {n}")
PY
  mkdir -p /etc/e2guardian/lists/authplugins
  if [[ ! -f /etc/e2guardian/lists/authplugins/ipgroups ]]; then
    printf "# OpenSys — sem reservas de IP no seed\n" >/etc/e2guardian/lists/authplugins/ipgroups
  fi
  chown -R e2guardian:e2guardian /etc/e2guardian
  chmod -R g+rwX /etc/e2guardian
  setfacl -R -m u:opensys:rwx /etc/e2guardian 2>/dev/null || true
  date -u +%Y-%m-%dT%H:%M:%SZ >"$marker"
  rm -rf "$tmp"
  ok "policy seed (${n} grupos)"
}
ensure_policy_seed

# Category seed (Shallalist) — vem no .deb opensys-ui; se faltar, avisa
if [[ -f "${SEED_DIR}/category-seed.tar.gz" ]]; then
  ok "category-seed.tar.gz presente (Shallalist / merge na 1ª blacklist)"
else
  warn "category-seed.tar.gz ausente em ${SEED_DIR} — publique um opensys-ui com seed embutido"
fi

# --- 6. panel.env ---
info "gerando/atualizando panel.env…"
IP="$(detect_ip)"
[[ -n "$IP" ]] || IP="127.0.0.1"
UI_BASE="${UI_BASE_URL_HINT:-http://${IP}:${PANEL_PORT}}"

if [[ ! -f "$PANEL_ENV" ]]; then
  ADMIN_PASS="$(rand_pass)"
  SECRET="$(rand_hex 32)"
  TOKEN="$(rand_hex 32)"
  umask 077
  cat >"$PANEL_ENV" <<EOF
OPENSYS_RUNTIME=native
PANEL_PORT=${PANEL_PORT}
UI_BASE_URL=${UI_BASE}
PROXY_HOST=${IP}
ADMIN_USER=${ADMIN_USER}
ADMIN_PASS=${ADMIN_PASS}
SECRET_KEY=${SECRET}
AGENT_API_TOKEN=${TOKEN}
LICENSE_SERVER_URL=${LICENSE_SERVER_URL}
TZ=${TZ}
E2G_CONF_DIR=/etc/e2guardian
LISTS_ROOT=/etc/e2guardian/lists
E2G_LOG_PATH=/var/log/e2guardian/access.log
CLAMAV_SOCKET_PATH=/var/run/clamav/clamd.ctl
CLAMAV_SERVICE=clamav-daemon
E2GUARDIAN_SERVICE=e2guardian
DEFAULT_GROUP_HOST_PORT=8880
DEFAULT_GROUP_CONTAINER_PORT=8880
GROUP_PORT_OFFSET=0
UT1_BLACKLIST_URL=https://dsi.ut-capitole.fr/blacklists/download/blacklists.tar.gz
CRITICAL_DOMAINS_UPDATE_URL=${REPO_RAW}/critical-domains.json
CRITICAL_BR_META_UPDATE_URL=${REPO_RAW}/critical-br-meta.json
OPENSYS_UPDATES_REGISTRY_ORG=${ORG}
OPENSYS_UPDATES_REGISTRY_SLUG=${REGISTRY}
OPENSYS_UPDATES_REPO_URI=${REPO_URI}
OPENSYS_UPDATES_REPO_SUITE=${REPO_SUITE}
OPENSYS_UPDATES_REPO_COMPONENTS=${REPO_COMPONENTS}
OPENSYS_UPDATES_REPO_KEYRING=${KEYRING}
EOF
  chmod 600 "$PANEL_ENV"
  chown opensys:opensys "$PANEL_ENV"
  mkdir -p "$STATE_DIR"
  cat >"$CREDS" <<EOF
OpenSys Web Guardian — credenciais iniciais
URL: ${UI_BASE}
Usuário: ${ADMIN_USER}
Senha: ${ADMIN_PASS}
Gerado: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Altere a senha no wizard /bem-vindo.
EOF
  chmod 600 "$CREDS"
  ok "panel.env criado — senha em $CREDS"
else
  # Garante chaves críticas sem sobrescrever secrets
  grep -q '^OPENSYS_RUNTIME=' "$PANEL_ENV" || echo 'OPENSYS_RUNTIME=native' >>"$PANEL_ENV"
  sed -i 's|^OPENSYS_RUNTIME=.*|OPENSYS_RUNTIME=native|' "$PANEL_ENV"
  grep -q '^GROUP_PORT_OFFSET=' "$PANEL_ENV" || echo 'GROUP_PORT_OFFSET=0' >>"$PANEL_ENV"
  sed -i 's|^GROUP_PORT_OFFSET=.*|GROUP_PORT_OFFSET=0|' "$PANEL_ENV"
  grep -q '^DEFAULT_GROUP_HOST_PORT=' "$PANEL_ENV" || echo 'DEFAULT_GROUP_HOST_PORT=8880' >>"$PANEL_ENV"
  sed -i 's|^DEFAULT_GROUP_HOST_PORT=.*|DEFAULT_GROUP_HOST_PORT=8880|' "$PANEL_ENV"
  grep -q '^DEFAULT_GROUP_CONTAINER_PORT=' "$PANEL_ENV" || echo 'DEFAULT_GROUP_CONTAINER_PORT=8880' >>"$PANEL_ENV"
  sed -i 's|^DEFAULT_GROUP_CONTAINER_PORT=.*|DEFAULT_GROUP_CONTAINER_PORT=8880|' "$PANEL_ENV"
  grep -q '^CLAMAV_SOCKET_PATH=' "$PANEL_ENV" || echo 'CLAMAV_SOCKET_PATH=/var/run/clamav/clamd.ctl' >>"$PANEL_ENV"
  sed -i 's|^CLAMAV_SOCKET_PATH=.*|CLAMAV_SOCKET_PATH=/var/run/clamav/clamd.ctl|' "$PANEL_ENV"
  grep -q '^PANEL_PORT=' "$PANEL_ENV" || echo "PANEL_PORT=${PANEL_PORT}" >>"$PANEL_ENV"
  ok "panel.env atualizado (native)"
fi

# --- 7. Python venv ---
info "venv Python + requirements…"
REQ="${OPENSYS_ROOT}/app/requirements.txt"
if [[ ! -f "$REQ" ]]; then
  download "$REQUIREMENTS_URL" "$REQ" || true
fi
if [[ ! -x "${OPENSYS_ROOT}/venv/bin/python" ]]; then
  python3 -m venv "${OPENSYS_ROOT}/venv"
fi
# Native: instala deps; docker SDK opcional (adapter native não precisa do daemon)
"${OPENSYS_ROOT}/venv/bin/pip" install -q --upgrade pip
if [[ -f "$REQ" ]]; then
  "${OPENSYS_ROOT}/venv/bin/pip" install -q -r "$REQ" || \
    "${OPENSYS_ROOT}/venv/bin/pip" install -q Flask==3.0.3 requests==2.32.3 ldap3==2.9.1 docker==7.1.0
else
  "${OPENSYS_ROOT}/venv/bin/pip" install -q Flask==3.0.3 requests==2.32.3 ldap3==2.9.1 docker==7.1.0
fi
# critical JSON se o .deb não trouxe
for f in critical-domains.json critical-br-meta.json; do
  if [[ ! -f "${OPENSYS_ROOT}/app/${f}" ]]; then
    download "${REPO_RAW}/${f}" "${OPENSYS_ROOT}/app/${f}" 2>/dev/null || true
  fi
done
chown -R opensys:opensys "${OPENSYS_ROOT}/venv" "${OPENSYS_ROOT}/app" || true

# --- 8. ClamAV socket group + drop-ins ---
info "ajustando ClamAV / systemd…"
mkdir -p /etc/systemd/system/clamav-daemon.socket.d
cat > /etc/systemd/system/clamav-daemon.socket.d/opensys.conf <<'EOF'
[Socket]
SocketGroup=opensys-scan
SocketMode=0660
EOF

python3 - <<'PY'
from pathlib import Path
path = Path("/etc/clamav/clamd.conf")
if not path.is_file():
    raise SystemExit(0)
replacements = {
    "LocalSocket": "/var/run/clamav/clamd.ctl",
    "LocalSocketGroup": "opensys-scan",
    "LocalSocketMode": "660",
}
lines = []
seen = set()
for line in path.read_text(encoding="utf-8", errors="replace").splitlines(True):
    body = line.lstrip().split("#", 1)[0].strip()
    if not body:
        lines.append(line)
        continue
    key = body.split(None, 1)[0]
    if key in replacements:
        lines.append(f"{key} {replacements[key]}\n")
        seen.add(key)
    else:
        lines.append(line)
for key, val in replacements.items():
    if key not in seen:
        lines.append(f"{key} {val}\n")
path.write_text("".join(lines), encoding="utf-8")
print("clamd.conf LocalSocket* ok")
PY
# Fuso no guest
if command -v timedatectl >/dev/null 2>&1; then
  timedatectl set-timezone "$TZ" 2>/dev/null || true
fi
ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime 2>/dev/null || true
echo "$TZ" >/etc/timezone 2>/dev/null || true
setfacl -R -m u:opensys:rwx /etc/clamav 2>/dev/null || chmod 775 /etc/clamav || true

mkdir -p /etc/systemd/system/e2guardian.service.d
cat > /etc/systemd/system/e2guardian.service.d/opensys.conf <<'EOF'
[Unit]
After=network-online.target clamav-daemon.service
Wants=clamav-daemon.service
EOF

mkdir -p /etc/systemd/system/opensys-ui.service.d
cat > /etc/systemd/system/opensys-ui.service.d/opensys.conf <<'EOF'
[Unit]
After=network-online.target e2guardian.service clamav-daemon.service
Wants=e2guardian.service clamav-daemon.service
EOF

cat > /etc/systemd/system/opensys.target <<'EOF'
[Unit]
Description=OpenSys Web Guardian appliance stack
Wants=opensys-ui.service e2guardian.service clamav-daemon.service
After=network-online.target
AllowIsolate=yes

[Install]
WantedBy=multi-user.target
EOF

# Garante unit opensys-ui (pacote deve ter instalado)
if [[ ! -f /lib/systemd/system/opensys-ui.service && ! -f /etc/systemd/system/opensys-ui.service ]]; then
  cat > /etc/systemd/system/opensys-ui.service <<'UNIT'
[Unit]
Description=OpenSys Web Guardian Panel
After=network-online.target e2guardian.service
Wants=network-online.target

[Service]
Type=simple
User=opensys
Group=opensys
WorkingDirectory=/opt/opensys/app
EnvironmentFile=-/opt/opensys/panel.env
ExecStart=/opt/opensys/venv/bin/python app.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
fi

# --- 9. Enable + start ---
info "habilitando serviços…"
systemctl daemon-reload
systemctl enable clamav-daemon clamav-freshclam e2guardian opensys-ui opensys.target >/dev/null 2>&1 || true
systemctl restart clamav-daemon || systemctl start clamav-daemon || warn "clamav-daemon não subiu ainda (freshclam pode estar baixando DB)"
systemctl start clamav-freshclam || true
systemctl restart e2guardian || systemctl start e2guardian || warn "e2guardian falhou ao iniciar — confira journalctl -u e2guardian"
systemctl restart opensys-ui || systemctl start opensys-ui || die "opensys-ui não iniciou"

sleep 3
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PANEL_PORT}/login" || true)"
if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "302" ]]; then
  warn "painel respondeu HTTP ${HTTP_CODE:-?} — veja: journalctl -u opensys-ui -n 50"
else
  ok "painel HTTP ${HTTP_CODE} em :${PANEL_PORT}"
fi

date -u +%Y-%m-%dT%H:%M:%SZ >"$FLAG"
IP="$(detect_ip)"
UI_BASE="http://${IP:-127.0.0.1}:${PANEL_PORT}"

echo
ok "OpenSys Web Guardian pronto"
echo "  Runtime : native"
echo "  Painel  : ${UI_BASE}"
echo "  Wizard  : ${UI_BASE}/bem-vindo"
echo "  Creds   : ${CREDS}"
ss -lntp 2>/dev/null | grep -E ":${PANEL_PORT}\b|:8880\b|:8881\b|:8882\b|:8883\b" || true
