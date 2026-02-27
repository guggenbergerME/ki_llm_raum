<a name="top"></a>

# Ollama LLM -- KI fuer Raumbuchungssystem

Lokale LLM-Instanz mit **Ollama** und **Open WebUI** via Docker Compose fuer den Betrieb in einem Proxmox LXC Container. Optimiert fuer die Integration mit dem [Raumbuchungssystem](https://github.com/guggenbergerME/wf_Raum_buchen).

---

## Inhaltsverzeichnis

1. [Funktionen](#funktionen)
2. [Architektur](#architektur)
3. [Proxmox LXC Container erstellen](#proxmox-lxc-container-erstellen)
   - [SSH-Zugang fuer Root aktivieren](#ssh-zugang-fuer-root-aktivieren)
4. [Schnellinstallation](#schnellinstallation)
5. [Repository klonen und einrichten](#repository-klonen-und-einrichten)
6. [Konfiguration](#konfiguration)
7. [Modelle verwalten](#modelle-verwalten)
   - [Serverleistung und Timeouts](#serverleistung-und-timeouts)
8. [API-Nutzung](#api-nutzung)
9. [Integration mit Raumbuchungssystem](#integration-mit-raumbuchungssystem)
10. [Nach der Installation](#nach-der-installation)
    - [DNS-Eintrag (AdGuard Home)](#dns-eintrag-adguard-home)
    - [Nginx Proxy Manager (NPM) einrichten](#nginx-proxy-manager-npm-einrichten)
11. [Nuetzliche Befehle](#nuetzliche-befehle)

---

## Funktionen

- **Lokale LLM-Instanz** - Datenschutzkonform, keine Cloud-Abhaengigkeit
- **Open WebUI** - Webbasierte Oberflaeche fuer Chat und Modellverwaltung
- **REST API** - OpenAI-kompatible API fuer die Integration mit anderen Diensten
- **Modellverwaltung** - Modelle ueber CLI oder WebUI herunterladen und verwalten
- **Multi-Modell** - Mehrere Modelle gleichzeitig verfuegbar (z.B. llama3, mistral, gemma)
- **Raumbuchungs-KI** - Natuerlichsprachliche Buchungsassistenz fuer das Raumbuchungssystem

## Architektur

```
Browser / Raumbuchungssystem
        |
        +--> Open WebUI (:3000)  -- Chat-Oberflaeche
        |         |
        |         +--> Ollama API (:11434)
        |
        +--> Ollama API (:11434)  -- Direkte API-Aufrufe
                  |
                  +--> LLM Modelle (lokal)
```

| Komponente | Technologie |
|---|---|
| LLM Runtime | Ollama |
| Web-Oberflaeche | Open WebUI |
| API | OpenAI-kompatible REST API |
| Deployment | Docker Compose |
| Modelle | Llama 3, Mistral, Gemma u.a. |

[↑ Top](#top)

---

## Proxmox LXC Container erstellen

Auf dem **Proxmox Host** in der Shell ausfuehren (`<CT-ID>` ersetzen, z.B. `210`):

```bash
pct create <CT-ID> local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname ki-llm-raum \
  --storage local-lvm \
  --rootfs local-lvm:30 \
  --cores 4 \
  --memory 8192 \
  --swap 2048 \
  --net0 name=eth0,bridge=vmbr1,ip=[IP]/16,gw=[IP],firewall=1 \
  --nameserver 1.1.1.1 \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --onboot 1 \
  --start 0
```

> **Hinweis:** LLM-Modelle benoetigen mehr Ressourcen als typische Dienste.
> - **30 GB Disk** - Platz fuer Modelle (ein 7B-Modell braucht ca. 4-5 GB)
> - **8 GB RAM** - Minimum fuer 7B-Modelle, 16 GB empfohlen fuer 13B-Modelle
> - **4 Cores** - Mehr Kerne = schnellere Inferenz

Danach die LXC-Konfiguration fuer Docker erweitern:

```bash
cat >> /etc/pve/lxc/<CT-ID>.conf << 'EOF'
lxc.apparmor.profile: unconfined
lxc.cgroup.devices.allow: a
lxc.cap.drop:
lxc.mount.auto: proc:rw sys:rw
EOF
```

Container starten:

```bash
pct start <CT-ID>
```

> Falls der Fehler `sysctl net.ipv4.ip_unprivileged_port_start: permission denied` auftritt,
> im LXC-Container selbst:
> ```bash
> echo "net.ipv4.ip_unprivileged_port_start=0" > /etc/sysctl.d/99-docker.conf
> sysctl --system
> ```

### SSH-Zugang fuer Root aktivieren

Im LXC-Container ausfuehren:

```bash
apt update && apt install -y openssh-server && \
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
systemctl enable ssh && \
systemctl restart ssh
```

Danach per SSH verbinden:

```bash
ssh root@<Container-IP>
```

[↑ Top](#top)

---

## Schnellinstallation

Auf einem frischen **Debian 12** oder **Ubuntu 24.04** LXC Container als root ausfuehren.

Zuerst Locale setzen (verhindert Perl/Locale-Warnungen):

```bash
apt update && apt install -y locales && \
sed -i 's/# de_DE.UTF-8 UTF-8/de_DE.UTF-8 UTF-8/' /etc/locale.gen && \
locale-gen && \
update-locale LANG=de_DE.UTF-8 LC_ALL=de_DE.UTF-8 && \
export LANG=de_DE.UTF-8 LC_ALL=de_DE.UTF-8
```

Danach Pakete, GitHub CLI und Docker installieren:

```bash
apt install -y curl git ca-certificates gnupg && \
install -m 0755 -d /etc/apt/keyrings && \
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] \
  https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list && \
apt update && apt install -y gh && \
curl -fsSL https://get.docker.com | sh && \
systemctl enable docker && \
gh auth login --hostname github.com --git-protocol https --web=false
```

Bei der Authentifizierung wird ein **Personal Access Token (classic)** abgefragt. So wird er erstellt:

1. https://github.com/settings/tokens oeffnen
2. **Generate new token** > **Generate new token (classic)**
3. **Note:** z.B. `LXC ki-llm-raum`
4. **Expiration:** nach Bedarf (z.B. 90 days)
5. **Scopes** ankreuzen: `repo` und `read:org`
6. **Generate token** klicken und den Token kopieren
7. Den Token im Terminal einfuegen wenn `Paste your authentication token:` erscheint

[↑ Top](#top)

---

## Repository klonen und einrichten

```bash
git clone https://github.com/guggenbergerME/ki_llm_raum.git /tmp/ki_llm_raum_setup && \
  bash /tmp/ki_llm_raum_setup/setup/setup.sh
```

### Das Skript fragt folgende Einstellungen ab

| Abfrage | Standard | Beschreibung |
|---------|----------|-------------|
| IP-Adresse | *(automatisch erkannt)* | IP-Adresse fuer den Ollama-Zugriff |
| WebUI Port | `3000` | Externer Port fuer Open WebUI |
| Ollama API Port | `11434` | Port fuer die Ollama REST API |
| Domain | *(leer)* | Domain fuer externen Zugriff (z.B. `ki.deine-firma.info`) |
| Zeitzone | `Europe/Berlin` | Zeitzone |
| Erstes Modell | `mistral` | LLM-Modell das beim Start heruntergeladen wird |

### Das Skript erledigt automatisch

- System aktualisieren
- Docker + Docker Compose installieren
- Docker-Logging konfigurieren (JSON, max 10 MB, 3 Dateien)
- Repository nach `/opt/ki_llm_raum` verschieben
- `.env` mit den abgefragten Einstellungen erstellen
- Datenverzeichnisse fuer Ollama-Modelle und WebUI anlegen
- Docker Stack starten
- Erstes LLM-Modell herunterladen

---

## Konfiguration

| Variable | Standard | Beschreibung |
|----------|----------|-------------|
| `TIMEZONE` | `Europe/Berlin` | Zeitzone |
| `SERVER_IP` | *(automatisch)* | IP-Adresse fuer Port-Binding |
| `WEBUI_PORT` | `3000` | Port fuer Open WebUI |
| `OLLAMA_PORT` | `11434` | Port fuer Ollama API |
| `OLLAMA_DOMAIN` | *(leer)* | Domain fuer externen Zugriff |
| `OLLAMA_MODEL` | `mistral` | Standard-Modell |
| `OLLAMA_KEEP_ALIVE` | `5m` | Wie lange ein Modell im RAM bleibt nach letzter Anfrage |
| `ANONYMIZED_TELEMETRY` | `false` | Telemetrie deaktiviert |

[↑ Top](#top)

---

## Modelle verwalten

### Modell herunterladen

```bash
cd /opt/ki_llm_raum
docker compose exec ollama ollama pull mistral
docker compose exec ollama ollama pull mistral
docker compose exec ollama ollama pull gemma2
```

### Installierte Modelle anzeigen

```bash
docker compose exec ollama ollama list
```

### Modell entfernen

```bash
docker compose exec ollama ollama rm <modellname>
```

### Empfohlene Modelle

| Modell | Groesse | RAM-Bedarf | Beschreibung |
|--------|---------|------------|-------------|
| `mistral` | 2 GB | 4 GB | Schnell, gut fuer einfache Aufgaben |
| `llama3.1:8b` | 4.7 GB | 8 GB | Ausgewogen, gute Qualitaet |
| `mistral` | 4.1 GB | 8 GB | Schnell, gut fuer Deutsch |
| `gemma2` | 5.4 GB | 8 GB | Google-Modell, vielseitig |

### Empfohlenes Modell fuer die Raumbuchung

**`mistral`** (7B) ist die beste Wahl fuer das Raumbuchungssystem:

| Kriterium | Bewertung |
|-----------|-----------|
| Deutsch-Verstaendnis | Sehr gut – franzoesisches Unternehmen, starker Fokus auf europaeische Sprachen |
| Strukturierte Ausgaben | Zuverlaessig beim Extrahieren von Datum, Uhrzeit und Raum aus natuerlicher Sprache |
| Geschwindigkeit | Schnelle Inferenz auf CPU, gut fuer interaktive Nutzung |
| Ressourcenbedarf | Nur 4.1 GB, passt problemlos in 8 GB RAM |

### Serverleistung und Timeouts

Das Raumbuchungssystem sendet Anfragen an Ollama mit einem Timeout von **120 Sekunden**. Wenn der Server zu wenig Ressourcen hat, antwortet das Modell nicht rechtzeitig und die Email-Buchung schlaegt fehl.

**Mindestanforderungen fuer zuverlaessigen Betrieb:**

| Modellgroesse | CPU-Kerne | RAM | Antwortzeit (ca.) |
|---------------|-----------|-----|-------------------|
| 1-3B | 2 Kerne | 4 GB | 5-15 Sekunden |
| 7B | 4 Kerne | 8 GB | 15-60 Sekunden |
| 13B | 6 Kerne | 16 GB | 30-120 Sekunden |

> **Wichtig:** Ohne GPU laeuft die gesamte Inferenz auf der CPU. Bei zu wenig Ressourcen kommt es zu Timeouts und die Raumbuchung per Email funktioniert nicht.

**Ressourcensparende Modelle als Alternative zu `mistral` (7B):**

| Modell | Groesse | RAM-Bedarf | Qualitaet Deutsch | Hinweis |
|--------|---------|------------|-------------------|---------|
| `gemma3:1b` | 0.8 GB | 2 GB | Gut | Sehr schnell, minimale Ressourcen |
| `phi4-mini` | 2.5 GB | 4 GB | Gut | Gutes Verhaeltnis Qualitaet/Geschwindigkeit |
| `gemma3:4b` | 3.3 GB | 4 GB | Sehr gut | Empfehlung fuer schwache Server |
| `mistral` | 4.1 GB | 8 GB | Sehr gut | Standard, braucht aber genuegend CPU/RAM |

Falls der Server zu langsam ist, ein kleineres Modell testen:

```bash
cd /opt/ki_llm_raum
docker compose exec ollama ollama pull gemma3:4b
```

Dann in der `.env` des Raumbuchungssystems das Modell aendern:

```env
OLLAMA_MODEL=gemma3:4b
```

**Modell installieren:**

```bash
cd /opt/ki_llm_raum
docker compose exec ollama ollama pull mistral
```

**Alternativen je nach Situation:**

| Situation | Empfehlung |
|-----------|-----------|
| RAM knapp (< 6 GB) | `mistral` (3B) – schnellste Option, 2 GB |
| Maximale Qualitaet | `llama3.1:8b` – staerker beim Reasoning, braucht 8 GB RAM |
| Allrounder | `gemma2` – vielseitig, gut bei kurzen Antworten |

[↑ Top](#top)

---

## API-Nutzung

Ollama stellt eine **OpenAI-kompatible API** bereit.

### Chat-Anfrage

```bash
curl http://10.100.1.118:11434/api/chat -d '{
  "model": "mistral",
  "messages": [
    {"role": "user", "content": "Welche Raeume sind heute frei?"}
  ],
  "stream": false
}'
```

### Generate-Anfrage

```bash
curl http://10.100.1.118:11434/api/generate -d '{
  "model": "mistral",
  "prompt": "Erstelle eine Zusammenfassung der heutigen Buchungen.",
  "stream": false
}'
```

### OpenAI-kompatibel (fuer bestehende Integrationen)

```bash
curl http://10.100.1.118:11434/v1/chat/completions -d '{
  "model": "mistral",
  "messages": [
    {"role": "user", "content": "Hallo"}
  ]
}'
```

[↑ Top](#top)

---

## Integration mit Raumbuchungssystem

Die Ollama-Instanz kann vom [Raumbuchungssystem](https://github.com/guggenbergerME/wf_Raum_buchen) als KI-Backend genutzt werden.

### Verbindung konfigurieren

In der `.env` des Raumbuchungssystems folgende Variablen setzen:

```env
LLM_API_URL=http://10.100.1.118:11434
LLM_MODEL=mistral
```

### Moegliche KI-Funktionen

| Funktion | Beschreibung |
|----------|-------------|
| Buchungsassistent | Natuerlichsprachliche Raumbuchung ("Buche Raum A morgen von 10 bis 12") |
| Zusammenfassungen | Tages-/Wochenuebersicht der Buchungen |
| Raumvorschlaege | KI schlaegt optimalen Raum basierend auf Teilnehmerzahl und Ausstattung vor |
| Konfliktloesung | KI schlaegt Alternativen bei Buchungskonflikten vor |

[↑ Top](#top)

---

## Nach der Installation

### DNS-Eintrag (AdGuard Home)

In OPNsense > AdGuard Home > DNS-Rewrites:

```
ki.deine-firma.info → [DEINE-IP]
```

### Nginx Proxy Manager (NPM) einrichten

NPM erreichbar unter `http://[NPM-IP]:81`

#### 1. Proxy Host anlegen

| Feld | Wert |
|------|------|
| Domain | `ki.deine-firma.info` |
| Scheme | `http` |
| Forward Host | `10.100.1.118` (die im Setup gewaehlte IP) |
| Forward Port | `3000` (Open WebUI Port) |
| Cache Assets | aktivieren |
| Block Common Exploits | aktivieren |
| Websockets Support | aktivieren |

#### 2. SSL-Zertifikat

Im Tab **SSL** des Proxy Hosts:

| Feld | Wert |
|------|------|
| SSL Certificate | Request a new SSL Certificate |
| Force SSL | aktivieren |
| HTTP/2 Support | aktivieren |
| HSTS Enabled | aktivieren |
| E-Mail fuer Let's Encrypt | `admin@deine-firma.info` |

#### 3. Erweiterte Nginx-Konfiguration

Im Tab **Advanced** folgende Custom Nginx Configuration eintragen:

```nginx
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;

client_max_body_size 512M;
proxy_read_timeout 600;
proxy_connect_timeout 600;
proxy_send_timeout 600;
```

> **Hinweis:** Die Timeouts sind hoeher als ueblich (600s), da LLM-Antworten je nach Modell laenger dauern koennen.

[↑ Top](#top)

---

## Nuetzliche Befehle

```bash
cd /opt/ki_llm_raum
docker compose ps            # Status anzeigen
docker compose logs -f       # Logs verfolgen
docker compose down          # Stack stoppen
docker compose up -d         # Stack starten
```

### Update

```bash
cd /opt/ki_llm_raum
docker compose pull          # Neue Images laden
docker compose up -d         # Stack mit neuen Images starten
```

### Backup

```bash
cd /opt/ki_llm_raum

# Komplettes Verzeichnis sichern (inkl. Modelle)
tar -czf /root/ki_llm_raum_backup_$(date +%Y%m%d).tar.gz \
  /opt/ki_llm_raum/.env \
  /opt/ki_llm_raum/docker-compose.yml

# Nur WebUI-Daten sichern (ohne Modelle, die koennen neu geladen werden)
docker compose exec open-webui tar -czf - /app/backend/data \
  > /root/webui_data_backup_$(date +%Y%m%d).tar.gz
```

### Firewall-Regeln (OPNsense)

| Quelle | Ziel | Port | Aktion |
|--------|------|------|--------|
| VLAN 30 (NPM) | `10.100.1.118` | TCP `3000` | Allow |
| Raumbuchungs-Server | `10.100.1.118` | TCP `11434` | Allow |

[↑ Top](#top)
