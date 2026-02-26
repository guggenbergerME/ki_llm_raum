#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  ki_llm_raum – Automatisches Setup-Skript
#  Fuer Debian 12 / Ubuntu 24.04 LXC Container mit Docker
# ============================================================

INSTALL_DIR="/opt/ki_llm_raum"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ---------- Hilfsfunktionen ----------

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
err()   { echo -e "\033[1;31m[ERR]\033[0m   $*"; exit 1; }

get_default_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1
}

prompt_value() {
  local varname="$1" prompt="$2" default="$3"
  read -rp "  ${prompt} [${default}]: " value
  value="${value:-$default}"
  eval "$varname=\"$value\""
}

# ---------- Root-Check ----------

if [[ $EUID -ne 0 ]]; then
  err "Dieses Skript muss als root ausgefuehrt werden."
fi

echo ""
echo "=============================================="
echo "  Ollama + Open WebUI – Setup"
echo "  KI-Backend fuer Raumbuchungssystem"
echo "=============================================="
echo ""

# ---------- Einstellungen abfragen ----------

DEFAULT_IP=$(get_default_ip)
DEFAULT_WEBUI_PORT="3000"
DEFAULT_OLLAMA_PORT="11434"
DEFAULT_TZ="Europe/Berlin"
DEFAULT_MODEL="mistral"

info "Bitte gib die gewuenschten Einstellungen ein:"
echo ""

prompt_value SERVER_IP     "IP-Adresse"                              "${DEFAULT_IP}"
prompt_value WEBUI_PORT    "Open WebUI Port"                         "${DEFAULT_WEBUI_PORT}"
prompt_value OLLAMA_PORT   "Ollama API Port"                         "${DEFAULT_OLLAMA_PORT}"
prompt_value OLLAMA_DOMAIN "Domain (leer lassen wenn keine)"         ""
prompt_value TIMEZONE      "Zeitzone"                                "${DEFAULT_TZ}"
prompt_value OLLAMA_MODEL  "Erstes LLM-Modell"                      "${DEFAULT_MODEL}"

echo ""
info "Zusammenfassung:"
echo "  IP-Adresse    : ${SERVER_IP}"
echo "  WebUI Port    : ${WEBUI_PORT}"
echo "  Ollama Port   : ${OLLAMA_PORT}"
echo "  Domain        : ${OLLAMA_DOMAIN:-keine}"
echo "  Zeitzone      : ${TIMEZONE}"
echo "  Erstes Modell : ${OLLAMA_MODEL}"
echo ""
read -rp "Weiter? (j/n) [j]: " CONFIRM
CONFIRM="${CONFIRM:-j}"
[[ "$CONFIRM" =~ ^[jJyY]$ ]] || { info "Abgebrochen."; exit 0; }

# ---------- System aktualisieren ----------

info "System wird aktualisiert ..."
apt-get update -qq
apt-get upgrade -y -qq
ok "System aktualisiert."

# ---------- Docker installieren ----------

if ! command -v docker &>/dev/null; then
  info "Docker wird installiert ..."
  apt-get install -y -qq ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  ok "Docker installiert."
else
  ok "Docker ist bereits installiert."
fi

# ---------- Docker-Logging konfigurieren ----------

info "Docker-Logging wird konfiguriert ..."
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'DAEMON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
DAEMON
systemctl restart docker
ok "Docker-Logging konfiguriert."

# ---------- Repository verschieben ----------

if [[ -d "$INSTALL_DIR" ]]; then
  warn "${INSTALL_DIR} existiert bereits – wird gesichert nach ${INSTALL_DIR}.bak"
  mv "$INSTALL_DIR" "${INSTALL_DIR}.bak.$(date +%s)"
fi

info "Repository wird nach ${INSTALL_DIR} verschoben ..."
cp -a "$REPO_DIR" "$INSTALL_DIR"
ok "Repository verschoben."

# ---------- .env erstellen ----------

info ".env wird erstellt ..."

if [[ -n "$OLLAMA_DOMAIN" ]]; then
  FRONTEND_URL="https://${OLLAMA_DOMAIN}"
else
  FRONTEND_URL="http://${SERVER_IP}:${WEBUI_PORT}"
fi

cat > "${INSTALL_DIR}/.env" << EOF
# ============================================================
#  ki_llm_raum – Konfiguration
#  Erstellt am: $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

## ===== Netzwerk =====
SERVER_IP=${SERVER_IP}
WEBUI_PORT=${WEBUI_PORT}
OLLAMA_PORT=${OLLAMA_PORT}
OLLAMA_DOMAIN=${OLLAMA_DOMAIN}

## ===== Zeitzone =====
TIMEZONE=${TIMEZONE}
TZ=${TIMEZONE}

## ===== Ollama =====
OLLAMA_MODEL=${OLLAMA_MODEL}
OLLAMA_KEEP_ALIVE=5m

## ===== Open WebUI =====
WEBUI_AUTH=true
ANONYMIZED_TELEMETRY=false
EOF

ok ".env erstellt."

# ---------- Datenverzeichnisse anlegen ----------

info "Datenverzeichnisse werden angelegt ..."
mkdir -p "${INSTALL_DIR}/data/ollama"
mkdir -p "${INSTALL_DIR}/data/webui"
ok "Datenverzeichnisse erstellt."

# ---------- Docker Stack starten ----------

info "Docker Stack wird gestartet ..."
cd "$INSTALL_DIR"
docker compose up -d
ok "Docker Stack gestartet."

# ---------- Warten bis Ollama bereit ist ----------

info "Warte auf Ollama ..."
for i in $(seq 1 30); do
  if curl -sf http://localhost:${OLLAMA_PORT}/api/tags >/dev/null 2>&1; then
    ok "Ollama ist bereit."
    break
  fi
  if [[ $i -eq 30 ]]; then
    warn "Ollama antwortet noch nicht. Modell-Download wird trotzdem versucht."
  fi
  sleep 2
done

# ---------- Erstes Modell herunterladen ----------

info "Modell '${OLLAMA_MODEL}' wird heruntergeladen (kann einige Minuten dauern) ..."
docker compose exec -T ollama ollama pull "$OLLAMA_MODEL"
ok "Modell '${OLLAMA_MODEL}' heruntergeladen."

# ---------- Fertig ----------

echo ""
echo "=============================================="
echo "  Ollama + Open WebUI wurde erfolgreich"
echo "  installiert!"
echo "=============================================="
echo ""
echo "  Open WebUI : ${FRONTEND_URL}"
echo "  Ollama API : http://${SERVER_IP}:${OLLAMA_PORT}"
echo ""
echo "  Beim ersten Aufruf von Open WebUI wird ein"
echo "  Admin-Konto angelegt (E-Mail + Passwort)."
echo ""
echo "  Verzeichnis : ${INSTALL_DIR}"
echo "  Logs        : cd ${INSTALL_DIR} && docker compose logs -f"
echo ""
if [[ -n "$OLLAMA_DOMAIN" ]]; then
  echo "  Externer Zugang (nach NPM-Einrichtung):"
  echo "  https://${OLLAMA_DOMAIN}"
  echo ""
fi
echo "  Integration mit Raumbuchungssystem:"
echo "  LLM_API_URL=http://${SERVER_IP}:${OLLAMA_PORT}"
echo "  LLM_MODEL=${OLLAMA_MODEL}"
echo ""
