#!/usr/bin/env bash
# OpenSys Web Guardian — cria CT LXC no Proxmox e instala o stack nativo (Fase B).
#
# Uso no host Proxmox (root):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/darlanpicetti/opensys-proxmox/main/proxmox/ct/opensys-web-guardian.sh)"
#
# Checkout local:
#   sudo bash proxmox/ct/opensys-web-guardian.sh
#
# Variáveis: ver proxmox/defaults.env (ou export antes de rodar).
set -euo pipefail

APP_NAME="OpenSys Web Guardian"
PANEL_PORT_DEFAULT=5001

die() { echo "ERRO: $*" >&2; exit 1; }
info() { echo "→ $*" >&2; }
ok() { echo "✓ $*" >&2; }
warn() { echo "AVISO: $*" >&2; }

[[ "$(id -u)" -eq 0 ]] || die "execute como root no host Proxmox"
command -v pct >/dev/null 2>&1 || die "pct não encontrado — este script roda no host Proxmox VE"
command -v pvesm >/dev/null 2>&1 || die "pvesm não encontrado — Proxmox VE incompleto?"

# --- origem dos arquivos (curl one-liner vs checkout) ---
SCRIPT_PATH="${BASH_SOURCE[0]:-}"
LOCAL_CT_DIR=""
LOCAL_PROXMOX_DIR=""
if [[ -n "$SCRIPT_PATH" && "$SCRIPT_PATH" != "-" && -f "$SCRIPT_PATH" ]]; then
  LOCAL_CT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
  LOCAL_PROXMOX_DIR="$(cd "${LOCAL_CT_DIR}/.." && pwd)"
fi

# Repo público só de instalação (produto e2guardian-ui permanece privado)
REPO_RAW="${OPENSYS_REPO_RAW:-https://raw.githubusercontent.com/darlanpicetti/opensys-proxmox/main}"
if [[ -n "${OPENSYS_PROXMOX_BASE:-}" ]]; then
  PROXMOX_BASE="$OPENSYS_PROXMOX_BASE"
elif [[ -n "$LOCAL_PROXMOX_DIR" && -f "${LOCAL_PROXMOX_DIR}/install/opensys-web-guardian-install.sh" ]]; then
  PROXMOX_BASE="file://${LOCAL_PROXMOX_DIR}"
else
  PROXMOX_BASE="${REPO_RAW}/proxmox"
fi

fetch_to() {
  local url="$1" dest="$2"
  if [[ "$url" == file://* ]]; then
    local src="${url#file://}"
    cp -a "$src" "$dest"
    return
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url"
  else
    die "curl ou wget necessário para baixar $url"
  fi
}

load_defaults() {
  local tmp
  tmp="$(mktemp)"
  if [[ "$PROXMOX_BASE" == file://* ]]; then
    local def="${PROXMOX_BASE#file://}/defaults.env"
    [[ -f "$def" ]] && cp "$def" "$tmp" || true
  else
    fetch_to "${PROXMOX_BASE}/defaults.env" "$tmp" 2>/dev/null || true
  fi
  if [[ -s "$tmp" ]]; then
    # shellcheck disable=SC1090
    set -a
    # shellcheck disable=SC1091
    source "$tmp"
    set +a
  fi
  rm -f "$tmp"
}

load_defaults

HOSTNAME="${HOSTNAME:-opensys-wg}"
OSTEMPLATE="${OSTEMPLATE:-debian-12-standard_12.7-1_amd64.tar.zst}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"
CORE_COUNT="${CORE_COUNT:-2}"
RAM_MB="${RAM_MB:-2048}"
SWAP_MB="${SWAP_MB:-512}"
DISK_GB="${DISK_GB:-32}"
PRIVILEGED="${PRIVILEGED:-1}"
TZ="${TZ:-America/Sao_Paulo}"
PANEL_PORT="${PANEL_PORT:-$PANEL_PORT_DEFAULT}"
LICENSE_SERVER_URL="${LICENSE_SERVER_URL:-https://licensewg.opensys.com.br}"

next_ctid() {
  local id=100
  while pct status "$id" >/dev/null 2>&1; do
    id=$((id + 1))
  done
  echo "$id"
}

CTID="${CTID:-$(next_ctid)}"

prompt_if_tty() {
  [[ -t 0 ]] || return 0
  if ! command -v whiptail >/dev/null 2>&1; then
    info "whiptail ausente — usando defaults (CTID=$CTID HOST=$HOSTNAME BRIDGE=$BRIDGE)"
    return 0
  fi
  local ans
  ans="$(whiptail --title "$APP_NAME" --inputbox "CTID" 8 50 "$CTID" 3>&1 1>&2 2>&3)" || exit 1
  CTID="$ans"
  ans="$(whiptail --title "$APP_NAME" --inputbox "Hostname" 8 50 "$HOSTNAME" 3>&1 1>&2 2>&3)" || exit 1
  HOSTNAME="$ans"
  ans="$(whiptail --title "$APP_NAME" --inputbox "Bridge" 8 50 "$BRIDGE" 3>&1 1>&2 2>&3)" || exit 1
  BRIDGE="$ans"
  ans="$(whiptail --title "$APP_NAME" --inputbox "Storage (rootfs)" 8 50 "$STORAGE" 3>&1 1>&2 2>&3)" || exit 1
  STORAGE="$ans"
  ans="$(whiptail --title "$APP_NAME" --inputbox "RAM (MB)" 8 50 "$RAM_MB" 3>&1 1>&2 2>&3)" || exit 1
  RAM_MB="$ans"
  ans="$(whiptail --title "$APP_NAME" --inputbox "Disco (GB)" 8 50 "$DISK_GB" 3>&1 1>&2 2>&3)" || exit 1
  DISK_GB="$ans"
  if whiptail --title "$APP_NAME" --yesno "Criar CT privilegiado? (recomendado para proxy/ClamAV)" 10 60; then
    PRIVILEGED=1
  else
    PRIVILEGED=0
    warn "CT unprivileged — piloto não validado; pode falhar em portas/serviços"
  fi
}

prompt_if_tty

[[ "$CTID" =~ ^[0-9]+$ ]] || die "CTID inválido: $CTID"
pct status "$CTID" >/dev/null 2>&1 && die "CT $CTID já existe"

ensure_template() {
  local tpl="${OSTEMPLATE:-}"
  local volid=""
  local found=""

  # Se o pin não existir no storage, resolve o debian-12 amd64 mais recente disponível
  resolve_latest_debian12() {
    pveam available --section system 2>/dev/null \
      | awk '/debian-12-standard.*amd64\.tar\.zst/ {print $NF}' \
      | sort -V \
      | tail -1
  }

  if [[ -n "$tpl" ]] && pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -qF "$tpl"; then
    volid="${TEMPLATE_STORAGE}:vztmpl/${tpl}"
    ok "template presente: $volid" >&2
    printf '%s\n' "$volid"
    return 0
  fi

  if [[ -z "$tpl" ]] || ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -qF "$tpl"; then
    found="$(resolve_latest_debian12 || true)"
    if [[ -n "$found" ]]; then
      tpl="$found"
    fi
  fi
  [[ -n "$tpl" ]] || die "não encontrou template debian-12 — rode: pveam update && pveam available"

  volid="${TEMPLATE_STORAGE}:vztmpl/${tpl}"
  if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -qF "$tpl"; then
    ok "template presente: $volid" >&2
    printf '%s\n' "$volid"
    return 0
  fi

  info "baixando template $tpl em $TEMPLATE_STORAGE…"
  # Importante: progresso do pveam NÃO pode ir para stdout (sujaria TEMPLATE_VOL)
  if ! pveam download "$TEMPLATE_STORAGE" "$tpl" >&2; then
    found="$(resolve_latest_debian12 || true)"
    [[ -n "$found" ]] || die "falha ao baixar template — rode: pveam update && pveam available"
    tpl="$found"
    volid="${TEMPLATE_STORAGE}:vztmpl/${tpl}"
    info "tentando $tpl…"
    pveam download "$TEMPLATE_STORAGE" "$tpl" >&2 || die "falha ao baixar $tpl"
  fi
  ok "template: $volid" >&2
  printf '%s\n' "$volid"
}

TEMPLATE_VOL="$(ensure_template)"
# Sanitiza: só a última linha no formato storage:vztmpl/arquivo
TEMPLATE_VOL="$(printf '%s\n' "$TEMPLATE_VOL" | tr -d '\r' | grep -E '^[A-Za-z0-9_-]+:vztmpl/' | tail -1)"
[[ -n "$TEMPLATE_VOL" ]] || die "ostemplate inválido após ensure_template"
[[ ${#TEMPLATE_VOL} -le 255 ]] || die "ostemplate longo demais (${#TEMPLATE_VOL}): $TEMPLATE_VOL"
info "ostemplate=$TEMPLATE_VOL"
info "criando CT $CTID ($HOSTNAME) — privileged=$PRIVILEGED …"
CREATE_ARGS=(
  "$CTID"
  "$TEMPLATE_VOL"
  --hostname "$HOSTNAME"
  --cores "$CORE_COUNT"
  --memory "$RAM_MB"
  --swap "$SWAP_MB"
  --rootfs "${STORAGE}:${DISK_GB}"
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp"
  --unprivileged "$([[ "$PRIVILEGED" == "1" ]] && echo 0 || echo 1)"
  --onboot 1
  --start 0
  --description "OpenSys Web Guardian (native) — painel :${PANEL_PORT}"
)

# --timezone só em PVE recentes; TZ é aplicada no guest pelo install
if pct create --help 2>&1 | grep -q -- '--timezone'; then
  CREATE_ARGS+=(--timezone "$TZ")
fi

pct create "${CREATE_ARGS[@]}"
ok "CT $CTID criado"

info "iniciando CT $CTID…"
pct start "$CTID"
# aguarda rede/DHCP
for i in $(seq 1 30); do
  if pct exec "$CTID" -- bash -c 'hostname -I 2>/dev/null | grep -qE "[0-9]+\.[0-9]+"'; then
    break
  fi
  sleep 2
done

GUEST_IP="$(pct exec "$CTID" -- bash -c 'hostname -I 2>/dev/null | awk "{print \$1}"' 2>/dev/null || true)"
info "IP do CT: ${GUEST_IP:-ainda sem DHCP}"

WORK="$(mktemp -d /tmp/opensys-px-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

INSTALL_LOCAL="${WORK}/opensys-web-guardian-install.sh"
if [[ "$PROXMOX_BASE" == file://* ]]; then
  fetch_to "${PROXMOX_BASE}/install/opensys-web-guardian-install.sh" "$INSTALL_LOCAL"
else
  fetch_to "${PROXMOX_BASE}/install/opensys-web-guardian-install.sh" "$INSTALL_LOCAL"
fi
chmod +x "$INSTALL_LOCAL"

info "enviando instalador para o CT…"
pct push "$CTID" "$INSTALL_LOCAL" /root/opensys-web-guardian-install.sh
pct exec "$CTID" -- chmod +x /root/opensys-web-guardian-install.sh

info "instalando OpenSys Web Guardian dentro do CT (pode levar vários minutos)…"
pct exec "$CTID" -- env \
  OPENSYS_REPO_RAW="$REPO_RAW" \
  OPENSYS_UPDATES_REGISTRY_ORG="${OPENSYS_UPDATES_REGISTRY_ORG:-darlanpicetti}" \
  OPENSYS_UPDATES_REGISTRY_SLUG="${OPENSYS_UPDATES_REGISTRY_SLUG:-opensys-web-guardian}" \
  OPENSYS_UPDATES_REPO_URI="${OPENSYS_UPDATES_REPO_URI:-https://packages.buildkite.com/darlanpicetti/opensys-web-guardian/any/}" \
  OPENSYS_UPDATES_REPO_SUITE="${OPENSYS_UPDATES_REPO_SUITE:-any}" \
  OPENSYS_UPDATES_REPO_COMPONENTS="${OPENSYS_UPDATES_REPO_COMPONENTS:-main}" \
  OPENSYS_UPDATES_REPO_KEYRING="${OPENSYS_UPDATES_REPO_KEYRING:-/usr/share/keyrings/opensys-buildkite-archive-keyring.gpg}" \
  E2GUARDIAN_DEB_URL="${E2GUARDIAN_DEB_URL:-https://e2guardian.numsys.eu/v5.6/e2debian_bookworm_V5.6.1_20260330.deb}" \
  TZ="$TZ" \
  PANEL_PORT="$PANEL_PORT" \
  LICENSE_SERVER_URL="$LICENSE_SERVER_URL" \
  UI_BASE_URL_HINT="${GUEST_IP:+http://${GUEST_IP}:${PANEL_PORT}}" \
  bash /root/opensys-web-guardian-install.sh

# re-lê IP após install (rede estável)
GUEST_IP="$(pct exec "$CTID" -- bash -c 'hostname -I 2>/dev/null | awk "{print \$1}"' 2>/dev/null || true)"
URL="http://${GUEST_IP:-<IP-do-CT>}:${PANEL_PORT}"

echo
ok "$APP_NAME instalado no CT $CTID"
echo "  Hostname : $HOSTNAME" >&2
echo "  IP       : ${GUEST_IP:-veja pct exec $CTID -- hostname -I}" >&2
echo "  Painel   : $URL" >&2
echo "  Wizard   : ${URL}/bem-vindo" >&2
echo >&2
echo "Próximo: abra o wizard, defina admin/rede/licença. Ctrl+F5 no browser." >&2
echo "Credenciais iniciais: /opt/opensys/var/firstboot-credentials.txt (dentro do CT)" >&2

# Também imprime URL limpa em stdout para automação
echo "$URL"
