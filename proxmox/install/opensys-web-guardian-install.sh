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
# P8 — nunca deixar CT em opensys-ui antigo (piloto 1.3.0). Bump com cada release canônica.
OPENSYS_UI_MIN_VERSION="${OPENSYS_UI_MIN_VERSION:-1.4.12}"

die() { echo "ERRO: $*" >&2; exit 1; }
info() { echo "→ $*" >&2; }
ok() { echo "✓ $*" >&2; }
warn() { echo "AVISO: $*" >&2; }

[[ "$(id -u)" -eq 0 ]] || die "execute como root"

if [[ -f "$FLAG" ]]; then
  ok "já inicializado ($FLAG) — reexecutando etapas idempotentes"
fi

export DEBIAN_FRONTEND=noninteractive
export TZ
# apt não interativo / sem prompts de config
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=a

rand_hex() { openssl rand -hex "${1:-24}"; }
rand_pass() { openssl rand -base64 18 | tr -d '/+=' | head -c 20; }

detect_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

download() {
  local url="$1" dest="$2"
  info "download $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 2 "$url" -o "$dest"
  else
    wget -O "$dest" "$url"
  fi
}

wait_apt_lock() {
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 \
     || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
    if (( waited == 0 )); then
      info "aguardando lock do apt (primeiro boot do Debian costuma atualizar sozinho)…"
    fi
    sleep 5
    waited=$((waited + 5))
    if (( waited >= 600 )); then
      die "timeout 10 min esperando lock do apt — veja: ps aux | grep apt"
    fi
    if (( waited % 30 == 0 )); then
      info "ainda aguardando apt lock… (${waited}s)"
    fi
  done
}

# --- 1. Base OS ---
info "atualizando apt e pacotes base…"
wait_apt_lock
apt-get update
wait_apt_lock
apt-get install -y \
  curl wget ca-certificates gnupg openssl \
  python3 python3-venv python3-pip \
  acl sudo systemd coreutils \
  clamav clamav-daemon clamav-freshclam

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

wait_apt_lock
apt-get update || warn "apt update no registry OpenSys falhou — tentando continuar"

# --- 3. Pacotes produto ---
install_opensys_ui_min() {
  # P8: apt-get install opensys-ui sozinho pode pegar índice/cache antigo (ex.: 1.3.0).
  info "instalando opensys-ui (mínimo ${OPENSYS_UI_MIN_VERSION})…"
  wait_apt_lock
  apt-mark unhold opensys-ui 2>/dev/null || true
  wait_apt_lock
  if ! apt-get install -y opensys-ui; then
    die "falha ao instalar opensys-ui do registry — verifique rede até packages.buildkite.com"
  fi
  wait_apt_lock
  apt-get install -y --only-upgrade opensys-ui || true
  local ver
  ver="$(dpkg-query -W -f='${Version}' opensys-ui 2>/dev/null || true)"
  [[ -n "$ver" ]] || die "opensys-ui não ficou instalado"
  if ! dpkg --compare-versions "$ver" ge "$OPENSYS_UI_MIN_VERSION"; then
    # Tenta candidato explícito do cache
    wait_apt_lock
    apt-get update || true
    wait_apt_lock
    apt-get install -y --only-upgrade opensys-ui || true
    ver="$(dpkg-query -W -f='${Version}' opensys-ui 2>/dev/null || true)"
  fi
  if ! dpkg --compare-versions "$ver" ge "$OPENSYS_UI_MIN_VERSION"; then
    die "opensys-ui ${ver} < mínimo ${OPENSYS_UI_MIN_VERSION}. Publique/indexe a versão no Buildkite e rode apt-get update no CT."
  fi
  ok "opensys-ui ${ver} (≥ ${OPENSYS_UI_MIN_VERSION})"
}
install_opensys_ui_min

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
# clamd may chown LocalSocketGroup; keep clamav in e2guardian for non-socket-activation paths
usermod -aG e2guardian clamav 2>/dev/null || true

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
if [[ -f "${OPENSYS_ROOT}/app/appliance/sudoers/90-opensys-logs" ]]; then
  if visudo -cf "${OPENSYS_ROOT}/app/appliance/sudoers/90-opensys-logs" >/dev/null 2>&1; then
    install -m 440 "${OPENSYS_ROOT}/app/appliance/sudoers/90-opensys-logs" /etc/sudoers.d/90-opensys-logs
  fi
fi
# Retenção de logs do filtro + journal (evita encher o disco do CT)
if [[ -x "${OPENSYS_ROOT}/bin/opensys-logs" ]]; then
  "${OPENSYS_ROOT}/bin/opensys-logs" retention-ensure-defaults --json >/dev/null 2>&1 || true
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

# P10 — listas *phraselist ausentes + filter0 inválido derrubam o proxy
repair_e2g_lists_and_ipgroups() {
  info "reparando listas de grupo / ipgroups (P10)…"
  local lists=/etc/e2guardian/lists
  local src=""
  local cand dest f name need ipg
  for cand in example.group group2.group group3.group; do
    if [[ -f "${lists}/${cand}/bannedphraselist" && -f "${lists}/${cand}/weightedphraselist" ]]; then
      src="${lists}/${cand}"
      break
    fi
  done
  if [[ -z "$src" ]]; then
    warn "sem template de listas — pulando cópia (e2guardian pode falhar)"
  else
    for dest in "${lists}"/*.group; do
      [[ -d "$dest" ]] || continue
      [[ "$dest" -ef "$src" ]] && continue
      while IFS= read -r -d '' f; do
        name=$(basename "$f")
        if [[ ! -e "${dest}/${name}" ]]; then
          cp -a "$f" "${dest}/${name}"
        fi
      done < <(find "$src" -maxdepth 1 -type f -print0 2>/dev/null)
      for need in bannedphraselist exceptionphraselist weightedphraselist; do
        if [[ ! -f "${dest}/${need}" ]]; then
          printf '# OpenSys scaffold %s\n' "$need" >"${dest}/${need}"
        fi
      done
    done
  fi
  for ipg in \
    "${lists}/authplugins/ipgroups" \
    /etc/e2guardian/authplugins/ipgroups
  do
    [[ -f "$ipg" ]] || continue
    # NÃO remapear filter0→filter1: filter0 = Sem proxy (BYPASS_GROUP_ID) no painel.
    # Painel (user opensys) precisa ler/escrever — root:600 quebra /dashboard e /api/agent/policy
    chown opensys:e2guardian "$ipg" 2>/dev/null || chown opensys:opensys "$ipg" 2>/dev/null || true
    chmod 664 "$ipg" 2>/dev/null || true
  done
  mkdir -p "${lists}/authplugins"
  chown -R e2guardian:e2guardian "${lists}" 2>/dev/null || true
  chmod -R g+rwX "${lists}" 2>/dev/null || true
  setfacl -R -m u:opensys:rwx /etc/e2guardian 2>/dev/null || true
  for ipg in "${lists}/authplugins/ipgroups" /etc/e2guardian/authplugins/ipgroups; do
    [[ -f "$ipg" ]] || continue
    chown opensys:e2guardian "$ipg" 2>/dev/null || chown opensys:opensys "$ipg" || true
    chmod 664 "$ipg" || true
  done
  ok "listas/ipgroups ok"
}
repair_e2g_lists_and_ipgroups

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
# e2guardian drops root→e2guardian without initgroups(); use primary group
# on the socket (not opensys-scan) or ClamAV scans fail-open.
info "ajustando ClamAV / systemd…"
mkdir -p /etc/systemd/system/clamav-daemon.socket.d
cat > /etc/systemd/system/clamav-daemon.socket.d/opensys.conf <<'EOF'
[Socket]
SocketGroup=e2guardian
SocketMode=0660
EOF

python3 - <<'PY'
from pathlib import Path
path = Path("/etc/clamav/clamd.conf")
if not path.is_file():
    raise SystemExit(0)
replacements = {
    "LocalSocket": "/var/run/clamav/clamd.ctl",
    "LocalSocketGroup": "e2guardian",
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
# Reparo final antes de subir o filtro (seed pode ter corrido antes do pacote UI)
repair_e2g_lists_and_ipgroups
systemctl restart e2guardian || systemctl start e2guardian || warn "e2guardian falhou ao iniciar — confira journalctl -u e2guardian"
systemctl restart opensys-ui || systemctl start opensys-ui || die "opensys-ui não iniciou"

sleep 3
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PANEL_PORT}/login" || true)"
if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "302" ]]; then
  warn "painel respondeu HTTP ${HTTP_CODE:-?} — veja: journalctl -u opensys-ui -n 50"
else
  ok "painel HTTP ${HTTP_CODE} em :${PANEL_PORT}"
fi

# --- 10. Checklist pós-install (bugs piloto P1–P10) ---
verify_pilot_accept() {
  info "checklist pós-install…"
  local ver fail=0
  ver="$(dpkg-query -W -f='${Version}' opensys-ui 2>/dev/null || echo '?')"
  if ! dpkg --compare-versions "$ver" ge "$OPENSYS_UI_MIN_VERSION"; then
    warn "P8 FAIL: opensys-ui=${ver} < ${OPENSYS_UI_MIN_VERSION}"; fail=1
  else
    ok "P8 opensys-ui ${ver}"
  fi
  if [[ -x "${OPENSYS_ROOT}/bin/opensys-net" && -x "${OPENSYS_ROOT}/bin/opensys-logs" ]]; then
    ok "P1 helpers opensys-net/logs"
  else
    warn "P1 FAIL: helpers ausentes em ${OPENSYS_ROOT}/bin"; fail=1
  fi
  if [[ -f /etc/sudoers.d/90-opensys-services ]]; then
    ok "P5 sudoers 90-opensys-services"
  else
    warn "P5 FAIL: /etc/sudoers.d/90-opensys-services ausente"; fail=1
  fi
  if [[ -f "${OPENSYS_ROOT}/app/static/OpenWebFence.msi" ]]; then
    ok "P6 MSI OpenWebFence embutido"
  else
    warn "P6 FAIL: MSI ausente em static/OpenWebFence.msi"; fail=1
  fi
  if [[ -f /etc/e2guardian/lists/example.group/bannedphraselist ]] \
     || [[ -f /etc/e2guardian/lists/group2.group/bannedphraselist ]]; then
    ok "P10 phraselist presente"
  else
    warn "P10 FAIL: bannedphraselist ausente nos grupos"; fail=1
  fi
  if systemctl is-active --quiet e2guardian; then
    ok "e2guardian active"
  else
    warn "e2guardian NÃO está active — journalctl -u e2guardian -n 40"; fail=1
  fi
  if systemctl is-active --quiet opensys-ui; then
    ok "opensys-ui active"
  else
    warn "opensys-ui NÃO está active"; fail=1
  fi
  # AV: filtro dropa root→e2guardian sem initgroups — socket deve ser group e2guardian
  local sock="/var/run/clamav/clamd.ctl"
  local sock_grp
  sock_grp="$(stat -c '%G' "$sock" 2>/dev/null || true)"
  if [[ "$sock_grp" == "e2guardian" ]]; then
    ok "AV socket group e2guardian"
  else
    warn "AV FAIL: ${sock} group=${sock_grp:-?} (esperado e2guardian)"; fail=1
  fi
  if [[ -S "$sock" ]] && runuser -u e2guardian -- python3 -c "
import socket
s = socket.socket(socket.AF_UNIX)
s.settimeout(3)
s.connect('${sock}')
s.close()
print('ok')
" >/dev/null 2>&1; then
    ok "AV ClamD acessível como e2guardian"
  else
    warn "AV FAIL: e2guardian não conecta em ${sock}"; fail=1
  fi
  if [[ "$fail" -ne 0 ]]; then
    die "checklist pós-install falhou — corrija antes de entregar o CT ao cliente"
  fi
  ok "checklist pós-install OK"
}
verify_pilot_accept

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
