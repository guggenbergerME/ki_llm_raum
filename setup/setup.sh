#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  ki_llm_raum – Ollama + Open WebUI Setup
# ============================================================

INSTALL_DIR="/opt/ki_llm_raum"

# --- Farben ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }

# --- Root-Check ---
if [[ $EUID -ne 0 ]]; then
  echo "Dieses Skript muss als root ausgefuehrt werden." >&2
  exit 1
fi

echo ""
echo "============================================"
echo "  Ollama + Open WebUI – Setup"
echo "  KI-Backend fuer Raumbuchungssystem"
echo "============================================"
echo ""

# --- IP-Adresse ermitteln ---
DEFAULT_IP=$(hostname -I | awk '{print $1}')

read -rp "IP-Adresse [$DEFAULT_IP]: " SERVER_IP
SERVER_IP="${SERVER_IP:-$DEFAULT_IP}"

read -rp "Open WebUI Port [3000]: " WEBUI_PORT
WEBUI_PORT="${WEBUI_PORT:-3000}"

read -rp "Ollama API Port [11434]: " OLLAMA_PORT
OLLAMA_PORT="${OLLAMA_PORT:-11434}"

read -rp "Domain fuer externen Zugriff (leer lassen wenn nicht benoetigt): " OLLAMA_DOMAIN

read -rp "Zeitzone [Europe/Berlin]: " TIMEZONE
TIMEZONE="${TIMEZONE:-Europe/Berlin}"

read -rp "Erstes LLM-Modell [llama3.2]: " OLLAMA_MODEL
OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.2}"

echo ""
info "Konfiguration:"
echo "  IP-Adresse:    $SERVER_IP"
echo "  WebUI Port:    $WEBUI_PORT"
echo "  Ollama Port:   $OLLAMA_PORT"
echo "  Domain:        ${OLLAMA_DOMAIN:-keine}"
echo "  Zeitzone:      $TIMEZONE"
echo "  Erstes Modell: $OLLAMA_MODEL"
echo ""
read -rp "Weiter? [J/n]: " CONFIRM
CONFIRM="${CONFIRM:-J}"
if [[ ! "$CONFIRM" =~ ^[JjYy]$ ]]; then
  echo "Abgebrochen."
  exit 0
fi

# --- System aktualisieren ---
info "System wird aktualisiert..."
apt update && apt upgrade -y
ok "System aktualisiert"

# --- Docker installieren (falls nicht vorhanden) ---
if ! command -v docker &>/dev/null; then
  info "Docker wird installiert..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  ok "Docker installiert"
else
  ok "Docker ist bereits installiert"
fi

# --- Docker-Logging konfigurieren ---
info "Docker-Logging wird konfiguriert..."
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
ok "Docker-Logging konfiguriert"

# --- Repository verschieben ---
info "Repository wird nach $INSTALL_DIR verschoben..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -d "$INSTALL_DIR" ]]; then
  warn "$INSTALL_DIR existiert bereits – wird gesichert nach ${INSTALL_DIR}.bak"
  mv "$INSTALL_DIR" "${INSTALL_DIR}.bak.$(date +%Y%m%d%H%M%S)"
fi

cp -a "$SCRIPT_DIR" "$INSTALL_DIR"
ok "Repository nach $INSTALL_DIR kopiert"

# --- .env erstellen ---
info ".env wird erstellt..."
cat > "$INSTALL_DIR/.env" << ENV
# ============================================================
#  ki_llm_raum – Konfiguration
#  Erstellt am: $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

# --- Netzwerk ---
SERVER_IP=$SERVER_IP
WEBUI_PORT=$WEBUI_PORT
OLLAMA_PORT=$OLLAMA_PORT
OLLAMA_DOMAIN=$OLLAMA_DOMAIN

# --- Zeitzone ---
TIMEZONE=$TIMEZONE
TZ=$TIMEZONE

# --- Ollama ---
OLLAMA_MODEL=$OLLAMA_MODEL
OLLAMA_KEEP_ALIVE=5m

# --- Open WebUI ---
WEBUI_AUTH=true
ANONYMIZED_TELEMETRY=false
ENV
ok ".env erstellt"

# --- Docker Stack starten ---
info "Docker Stack wird gestartet..."
cd "$INSTALL_DIR"
docker compose up -d
ok "Docker Stack laeuft"

# --- Warten bis Ollama bereit ist ---
info "Warte auf Ollama..."
for i in $(seq 1 30); do
  if curl -sf http://localhost:${OLLAMA_PORT}/api/tags >/dev/null 2>&1; then
    ok "Ollama ist bereit"
    break
  fi
  sleep 2
done

# --- Erstes Modell herunterladen ---
info "Modell '$OLLAMA_MODEL' wird heruntergeladen (kann einige Minuten dauern)..."
docker compose exec -T ollama ollama pull "$OLLAMA_MODEL"
ok "Modell '$OLLAMA_MODEL' heruntergeladen"

# --- Fertig ---
echo ""
echo "============================================"
echo "  Installation abgeschlossen!"
echo "============================================"
echo ""
echo "  Open WebUI:   http://${SERVER_IP}:${WEBUI_PORT}"
echo "  Ollama API:   http://${SERVER_IP}:${OLLAMA_PORT}"
echo ""
echo "  Installationsverzeichnis: $INSTALL_DIR"
echo ""
if [[ -n "$OLLAMA_DOMAIN" ]]; then
  echo "  Externer Zugang (nach NPM-Einrichtung):"
  echo "  https://${OLLAMA_DOMAIN}"
  echo ""
fi
echo "  Naechste Schritte:"
echo "  1. Open WebUI aufrufen und Admin-Konto erstellen"
echo "  2. Im Raumbuchungssystem die Ollama-URL eintragen:"
echo "     LLM_API_URL=http://${SERVER_IP}:${OLLAMA_PORT}"
echo "     LLM_MODEL=${OLLAMA_MODEL}"
echo ""
