#!/usr/bin/env bash
# Blender Proxmox Manager — Community-Scripts-konformer Installer
# Einzeiler (auf dem Proxmox-HOST als root):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/BlenderProxmox/main/install/blender.sh)"
# Varianten:
#   ... blender.sh --vm --vmid 200 --cpu 4 --ram 4096 --disk 20 --gpu passthrough
#   ... blender.sh --ctid 150 --cpu 2 --ram 2048 --disk 8
#   ... blender.sh --uninstall --ctid 150 | --vm --vmid 200
# Debug bei Fehlern: bash -x -c "$(wget -qLO - .../blender.sh)" -- --debug
set -euo pipefail

# ================= Variablen (oben, anpassbar) =================
APP_NAME="blender"
APP_PORT="8080"
MODE="lxc"                 # lxc | vm  (vm = leistungshungrig/KVM + GPU)
CTID="150"
VMID="200"
APP_HOSTNAME="blender"     # bewusst NICHT "HOSTNAME" — kollidiert mit bash-Builtin
CPU="2"
RAM="2048"                 # MB
DISK="8"                   # GB
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"   # exakte Template-Version löst resolve_template() dynamisch auf
BRIDGE="vmbr0"
GPU_MODE="none"            # none | passthrough | vgpu
SKIP_BLENDER=0             # 1 = Blender (apt) überspringen (nur Manager installieren)
VM_ISO="local:iso/debian-12-netinst.iso"  # VM-Modus: fehlende Debian-Netinst-ISO wird automatisch geladen
DEBIAN_ISO_MIRROR="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"
MANAGED_TAG="blender-managed"  # Marker in CT/VM-Beschreibung — Update-Wiedererkennung auch bei gestopptem CT
GITHUB_USER="HatchetMan111"
GITHUB_REPO="BlenderProxmox"
GITHUB_BRANCH="main"
GITHUB_BASE="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"
UNINSTALL=0
DEBUG=0

# ================= Farben/Logging =================
R="\033[31m"; G="\033[32m"; Y="\033[33m"; B="\033[34m"; N="\033[0m"
log(){ echo -e "${B}[${APP_NAME}]${N} $*"; }
ok(){ echo -e "${G}[OK]${N} $*"; }
warn(){ echo -e "${Y}[WARN]${N} $*" >&2; }
die(){ echo -e "${R}[FEHLER]${N} $*" >&2; exit 1; }

# Komplette Fehlermeldungskette (niemals nur letzte Zeile)
on_err(){
  local ec=$? line=${1:-?} cmd=${2:-?}
  echo -e "${R}========== FEHLERKETTE ==========${N}" >&2
  echo "Exit-Code : $ec" >&2
  echo "Zeile     : $line" >&2
  echo "Kommando  : $cmd" >&2
  echo "--- Stack (caller) ---" >&2
  local i=0; while caller $i >&2; do i=$((i+1)); done
  echo "--- Host-Infos ---" >&2
  pveversion 2>&1 | head -5 >&2 || true
  pct status "$CTID" >&2 2>/dev/null || true
  echo "--- letztes CT-Setup-Log (falls vorhanden) ---" >&2
  ls -t /tmp/blender-setup-*.log 2>/dev/null | head -1 | xargs -r tail -n 30 >&2 || true
  echo "Tipp: erneut mit Debug laufen lassen:" >&2
  echo "  bash -x -c \"\$(wget -qLO - ${GITHUB_BASE}/install/blender.sh)\" -- --debug" >&2
  echo "Komplette Mitschrift: ${INSTALL_LOG:-/tmp/${APP_NAME}-install-*.log (neueste)}" >&2
  echo -e "${R}=================================${N}" >&2
}
trap 'on_err $LINENO "$BASH_COMMAND"' ERR
# gibt tee (Prozess-Substitution) Zeit, die letzten Zeilen zu flushen — sonst
# trudeln die finalen Ausgaben erst NACH dem Prompt ein
trap 'sleep 0.2 2>/dev/null || true' EXIT

usage(){
  cat <<EOF
$APP_NAME Installer (Proxmox VE Community-Scripts-Stil)

  bash -c "\$(wget -qLO - ${GITHUB_BASE}/install/blender.sh)"

Optionen:
  --ctid ID        LXC-ID (Default $CTID)
  --vm             statt LXC eine KVM-VM anlegen (für GPU/Renderleistung;
                   lädt fehlende Debian-Netinst-ISO automatisch nach)
  --vmid ID        VM-ID (Default $VMID)
  --cpu N          vCPUs (Default $CPU)
  --ram MB         RAM in MB (Default $RAM)
  --disk GB        Disk in GB (Default $DISK)
  --storage S      Storage (Default $STORAGE)
  --bridge B       Bridge (Default $BRIDGE)
  --gpu MODE       none|passthrough|vgpu (Default $GPU_MODE)
  --skip-blender   Blender (apt) nicht mitinstallieren (nur Manager)
  --uninstall      Container/VM entfernen
  --debug          set -x + volle Logs
  -h|--help        Hilfe

  IDs: Belegte IDs werden automatisch auf die nächste freie ID
       hochgezählt (LXC+VM teilen sich den ID-Raum!). Eigene
       Container (Hostname bzw. Marker "$MANAGED_TAG" in der
       Beschreibung) werden für Updates wiederverwendet.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CTID="${2:?'--ctid braucht eine ID (z. B. --ctid 150)'}"; shift 2;;
    --vm) MODE="vm"; shift;;
    --vmid) VMID="${2:?'--vmid braucht eine ID (z. B. --vmid 200)'}"; shift 2;;
    --cpu) CPU="${2:?'--cpu braucht eine Zahl (z. B. --cpu 2)'}"; shift 2;;
    --ram) RAM="${2:?'--ram braucht MB (z. B. --ram 2048)'}"; shift 2;;
    --disk) DISK="${2:?'--disk braucht GB (z. B. --disk 8)'}"; shift 2;;
    --storage) STORAGE="${2:?'--storage braucht einen Storage-Namen (z. B. local-lvm)'}"; shift 2;;
    --bridge) BRIDGE="${2:?'--bridge braucht eine Bridge (z. B. vmbr0)'}"; shift 2;;
    --gpu) GPU_MODE="${2:?'--gpu braucht none|passthrough|vgpu'}"; shift 2;;
    --skip-blender) SKIP_BLENDER=1; shift;;
    --uninstall) UNINSTALL=1; shift;;
    --debug) DEBUG=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unbekannte Option: $1 (siehe --help)";;
  esac
done
if [[ "$DEBUG" == "1" ]]; then set -x; fi

# Vollständige Host-Mitschrift (geht nie verloren, auch bei Scrollback-Limit)
INSTALL_LOG="/tmp/${APP_NAME}-install-$$.log"
exec > >(tee "$INSTALL_LOG") 2>&1
log "Installations-Mitschrift: $INSTALL_LOG"

[[ $EUID -eq 0 ]] || die "Bitte als root auf dem Proxmox-HOST ausführen."
command -v pct >/dev/null || die "pct nicht gefunden — kein Proxmox-HOST?"
command -v qm >/dev/null || die "qm nicht gefunden — kein Proxmox-HOST?"

# ---------- ID-Automatik (LXC+VM teilen sich den Proxmox-ID-Raum) ----------
id_taken(){
  local id="$1"
  pct status "$id" >/dev/null 2>&1 || qm status "$id" >/dev/null 2>&1
}
next_free_id(){
  local id="$1" tries=0
  while id_taken "$id"; do
    id=$((id+1)); tries=$((tries+1))
    [[ "$tries" -gt 10000 ]] && die "Keine freie ID gefunden (Start: $1)."
    [[ "$id" -gt 999999999 ]] && die "ID-Bereich erschöpft."
  done
  echo "$id"
}
is_ours_lxc(){
  local id="$1" cfg
  cfg=$(pct config "$id" 2>/dev/null || true)
  grep -qE "^hostname: ${APP_HOSTNAME}$" <<<"$cfg" && return 0
  grep -qF "$MANAGED_TAG" <<<"$cfg" && return 0
  pct exec "$id" -- test -f /opt/blender/app/main.py >/dev/null 2>&1
}
is_ours_vm(){
  qm config "$1" 2>/dev/null | grep -qE "^name: ${APP_HOSTNAME}-"
}
resolve_id(){
  # $1 = Modus (lxc|vm), $2 = Wunsch-ID -> gibt die zu nutzende ID aus
  local mode="$1" want="$2" free
  if ! id_taken "$want"; then echo "$want"; return 0; fi
  if [[ "$mode" == "vm" ]] && is_ours_vm "$want"; then
    warn "VM $want ist unsere $APP_NAME-VM — wiederverwenden (Update)."
    echo "$want"; return 0
  fi
  if [[ "$mode" == "lxc" ]] && is_ours_lxc "$want"; then
    warn "CT $want ist unser $APP_NAME-Container — wiederverwenden (Update)."
    echo "$want"; return 0
  fi
  free=$(next_free_id "$want")
  warn "ID $want ist belegt (fremd) — nehme nächste freie ID: $free"
  echo "$free"
}

# ---------- Template-Auflösung (versionstolerant statt hartcodiertem Datum) ----------
resolve_template(){
  # 1) Bereits heruntergeladenes Debian-12-Template wiederverwenden (neuestes)
  local cached avail
  cached=$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -oE 'debian-12-standard_[0-9][^[:space:]]*\.tar\.[a-z0-9]+' | sort -V | tail -1 || true)
  if [[ -n "$cached" ]]; then
    log "Nutze vorhandenes Template: $cached" >&2
    echo "$cached"; return 0
  fi
  # 2) Sonst neuestes verfügbares Debian-12-Template von den Proxmox-Servern
  log "Kein Debian-12-Template lokal — aktualisiere Template-Liste ..." >&2
  pveam update >&2 || warn "pveam update fehlgeschlagen, versuche trotzdem Download."
  avail=$(pveam available --section system 2>/dev/null | grep -oE 'debian-12-standard_[0-9][^[:space:]]*\.tar\.[a-z0-9]+' | sort -V | tail -1 || true)
  if [[ -z "$avail" ]]; then
    echo "Verfügbare Debian-Templates:" >&2
    pveam available --section system 2>&1 | grep -i debian >&2 || true
    die "Kein debian-12-standard-Template gefunden (Storage: $TEMPLATE_STORAGE)."
  fi
  log "Lade Template: $avail ..." >&2
  pveam download "$TEMPLATE_STORAGE" "$avail" >&2
  echo "$avail"
}

# ---------- Uninstall ----------
if [[ "$UNINSTALL" == "1" ]]; then
  if [[ "$MODE" == "vm" ]]; then
    log "Stoppe/entferne VM $VMID ..."
    qm stop "$VMID" 2>/dev/null || true
    qm destroy "$VMID" --purge 2>/dev/null || warn "VM $VMID konnte nicht entfernt werden (existiert sie / gehört sie uns?)."
  else
    log "Stoppe/entferne LXC $CTID ..."
    pct stop "$CTID" 2>/dev/null || true
    pct destroy "$CTID" --purge 2>/dev/null || warn "CT $CTID konnte nicht entfernt werden (existiert er / gehört er uns?)."
  fi
  ok "Deinstalliert."
  exit 0
fi

# ================= VM-PFAD (leistungshungrig) =================
if [[ "$MODE" == "vm" ]]; then
  VMID=$(resolve_id vm "$VMID")
  log "Modus: KVM-VM (ID $VMID, $CPU CPU, ${RAM}MB RAM, ${DISK}G, GPU=$GPU_MODE)"

  # ISO sicherstellen: qm create akzeptiert eine fehlende ISO kommentarlos,
  # aber qm START schlägt dann mit "volume does not exist" fehl — vorher prüfen.
  local_iso_store="${VM_ISO%%:iso/*}"
  iso_name="${VM_ISO#*:iso/}"
  if ! pvesm list "$local_iso_store" --content iso 2>/dev/null | grep -qF "$iso_name"; then
    # Exakter Name fehlt: vorhandene Debian-12-Netinst-ISO wiederverwenden (Punktversion driftet)
    existing_iso=$(pvesm list "$local_iso_store" --content iso 2>/dev/null | grep -oE 'debian-12[0-9.]*-amd64-netinst\.iso' | sort -uV | tail -1 || true)
    if [[ -n "$existing_iso" ]]; then
      warn "ISO '$iso_name' nicht gefunden — nutze vorhandene Debian-Netinst-ISO: $existing_iso"
      VM_ISO="local:iso/${existing_iso}"
    elif [[ "$local_iso_store" == "local" ]]; then
      warn "Kein Debian-12-Netinst-ISO auf Storage 'local' — lade automatisch (${DEBIAN_ISO_MIRROR}) ..."
      iso_page=$(wget -qO- "${DEBIAN_ISO_MIRROR}/" || true)
      iso_dl=$(grep -oE 'debian-12[0-9.]*-amd64-netinst\.iso' <<<"$iso_page" | sort -uV | tail -1 || true)
      if [[ -z "$iso_dl" ]]; then
        die "Konnte Debian-Netinst-ISO nicht automatisch ermitteln. Bitte manuell laden (GUI: local → ISOs → Upload) und VM_ISO oben anpassen."
      fi
      mkdir -p /var/lib/vz/template/iso
      log "Lade ${DEBIAN_ISO_MIRROR}/${iso_dl} (ca. 600 MB, dauert kurz) ..."
      wget -O "/var/lib/vz/template/iso/${iso_dl}" "${DEBIAN_ISO_MIRROR}/${iso_dl}" \
        || die "ISO-Download fehlgeschlagen — bitte manuell laden (GUI: local → ISOs → Upload)."
      VM_ISO="local:iso/${iso_dl}"
      ok "ISO geladen: $VM_ISO"
    else
      die "ISO '$VM_ISO' fehlt auf Storage '$local_iso_store' — bitte vorher hochladen (GUI: Storage → ISOs) oder VM_ISO in blender.sh anpassen."
    fi
  fi
  log "ISO vorhanden: $VM_ISO"

  if qm status "$VMID" >/dev/null 2>&1; then
    warn "VM $VMID existiert bereits (eigene, idempotent) — überspringe create."
  else
    qm create "$VMID" --name "${APP_HOSTNAME}-${VMID}" --cores "$CPU" --sockets 1 \
      --memory "$RAM" --net0 "virtio,bridge=${BRIDGE}" \
      --scsihw virtio-scsi-pci --scsi0 "${STORAGE}:${DISK}" \
      --ide2 "${VM_ISO},media=cdrom" --boot 'order=ide2;scsi0' --ostype l26 --onboot 1 \
      --description "$MANAGED_TAG"
    ok "VM $VMID angelegt (bootet Debian-Installer von ide2, Zieldisk: scsi0)."
  fi
  if [[ "$GPU_MODE" == "passthrough" ]]; then
    warn "PCI-Passthrough MUSS manuell finalisiert werden (IOMMU + Geräte-ID):"
    echo "  1) Host: intel_iommu=on bzw. amd_iommu=on in /etc/default/grub + update-grub + Reboot"
    echo "  2) lspci -nn | grep -i nvidia   # z.B. 0000:01:00"
    echo "  3) qm set $VMID --hostpci0 0000:01:00,pcie=1"
    echo "  4) VM starten, NVIDIA-Treiber in der VM installieren"
  elif [[ "$GPU_MODE" == "vgpu" ]]; then
    warn "vGPU geht NIE vollautomatisch — manueller Weg siehe README + Wiki:"
    echo "  https://pve.proxmox.com/wiki/NVIDIA_vGPU_on_Proxmox_VE"
    echo "  Beispiel: qm set $VMID --hostpci0 0000:01:00.0,mdev=nvidia-11"
  fi
  echo "Nächste Schritte:"
  echo "  1) qm start $VMID   # VM bootet den Debian-Installer von der ISO (ide2)"
  echo "  2) Konsole öffnen, Debian auf scsi0 installieren (Netinst, minimal reicht)"
  echo "  3) Danach IN der VM Blender installieren (apt install blender) bzw. GPU-Treiber;"
  echo "     der Manager (Web UI) läuft separat im LXC (Modus lxc): Tab 'VM / LXC Installer'."
  exit 0
fi

# ================= LXC-PFAD (Standard) =================
ID=$(resolve_id lxc "$CTID")
CTID="$ID"
log "Modus: LXC (CT $ID, $CPU CPU, ${RAM}MB RAM, ${DISK}G, GPU=$GPU_MODE)"
log "Repo: ${GITHUB_BASE}"

# Template sicherstellen (idempotent, versionstolerant — kein hartcodiertes Datum)
TEMPLATE=$(resolve_template)
log "Template: $TEMPLATE"

if pct status "$ID" >/dev/null 2>&1; then
  warn "CT $ID existiert bereits (eigene, idempotent) — nutze vorhandenen Container."
else
  pct create "$ID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$APP_HOSTNAME" --cores "$CPU" --memory "$RAM" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --onboot 1 --start 1 --unprivileged 1 \
    --features nesting=1,keyctl=1 \
    --description "$MANAGED_TAG"
  ok "CT $ID erstellt."
fi

# GPU-Devices durchreichen (nur passthrough automatisch; vgpu bewusst NICHT)
if [[ "$GPU_MODE" == "passthrough" ]]; then
  if [[ -e /dev/dri ]]; then
    pct stop "$ID" 2>/dev/null || true
    # idempotent: vorhandene dev-Einträge erst entfernen
    pct set "$ID" --delete dev0 2>/dev/null || true
    pct set "$ID" --delete dev1 2>/dev/null || true
    # vorhandene Devices automatisch wählen (card0 ist nicht garantiert, z. B. card1/card2)
    card_dev=$(ls /dev/dri/card* 2>/dev/null | head -1 || true)
    render_dev=$(ls /dev/dri/renderD* 2>/dev/null | head -1 || true)
    if [[ -n "$card_dev" ]]; then
      if pct set "$ID" --dev0 "$card_dev" 2>/dev/null; then
        ok "dev0: $card_dev durchgereicht."
      else
        warn "$card_dev konnte nicht durchgereicht werden"
      fi
    else
      warn "Kein /dev/dri/card* gefunden — dev0 übersprungen."
    fi
    if [[ -n "$render_dev" ]]; then
      if pct set "$ID" --dev1 "$render_dev" 2>/dev/null; then
        ok "dev1: $render_dev durchgereicht."
      else
        warn "$render_dev konnte nicht durchgereicht werden"
      fi
    else
      warn "Kein /dev/dri/renderD* gefunden — dev1 übersprungen."
    fi
    ok "GPU /dev/dri durchgereicht."
  else
    warn "Kein /dev/dri auf dem Host — GPU-Passthrough übersprungen (siehe README manueller Weg)."
  fi
elif [[ "$GPU_MODE" == "vgpu" ]]; then
  warn "vGPU im LXC wird NICHT automatisch eingerichtet (kein mdev im Container)."
  warn "Nimm --vm für echtes vGPU oder folge README (Host: vGPU-Manager + mdev + VM)."
fi

if ! pct status "$ID" 2>/dev/null | grep -q "status: running"; then
  log "Starte CT $ID ..."
  pct start "$ID" || die "CT $ID startete nicht — Ursache oben."
fi

# Auf CT-Netz warten (DHCP kann dauern) — sonst stirbt apt-get update im CT
# an "Temporary failure resolving"; NIE blind sleep N und loslegen.
log "Warte auf CT-Netz (DHCP, max. 30s) ..."
CT_IP=""
for i in $(seq 1 30); do
  CT_IP=$(pct exec "$ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
  if [[ -n "$CT_IP" ]]; then break; fi
  sleep 1
done
if [[ -n "$CT_IP" ]]; then
  log "CT-IP: $CT_IP"
else
  warn "CT hat nach 30s keine IP (DHCP?) — Setup läuft trotzdem, braucht aber Netz."
fi

# ---------- Dateien ins CT laden (Mitschrift ins Host-Log für Debugging) ----------
# $1 im CT = SKIP_BLENDER ("0"/"1") — bewusst als Argument statt host-seitiger
# Expansion, damit die Expansionsrichtung eindeutig ist.
SETUP_LOG="/tmp/blender-setup-${ID}.log"
log "Lade App-Code von GitHub ... (Mitschrift: $SETUP_LOG)"
pct exec "$ID" -- bash -c "set -euo pipefail
  echo '[ct] 0/6 Netz/DNS-Check ...'
  net_ok=0
  for i in 1 2 3 4 5; do
    if getent hosts deb.debian.org >/dev/null 2>&1; then net_ok=1; break; fi
    echo \"[ct] DNS/Netz noch nicht bereit (Versuch \$i/5), warte 2s ...\"
    sleep 2
  done
  if [ \"\$net_ok\" != \"1\" ]; then
    echo \"[ct] FEHLER: CT hat kein funktionierendes Netz (DHCP/DNS prüfen: pct exec $ID -- ip a)\"
    exit 1
  fi
  echo '[ct] 1/6 apt-Pakete ...'
  apt_ok=0
  for i in 1 2 3 4 5; do
    if apt-get update; then apt_ok=1; break; fi
    echo \"[ct] apt-get update fehlgeschlagen (Versuch \$i/5), warte 3s ...\"
    sleep 3
  done
  if [ \"\$apt_ok\" != \"1\" ]; then echo '[ct] FEHLER: apt-get update dauerhaft fehlgeschlagen'; exit 1; fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv python3-pip curl wget ca-certificates pciutils lshw
  echo '[ct] 2/6 Verzeichnisse ...'
  mkdir -p /opt/blender/app /opt/blender/uploads /opt/blender/jobs /tmp/app /tmp/systemd
  cd /tmp
  echo '[ct] 3/6 App-Code von GitHub ...'
  for f in 'app/main.py' 'app/requirements.txt' 'systemd/blender.service'; do
    echo \"[ct] hole \$f ...\"
    wget -q --tries=3 --timeout=20 --waitretry=3 -O \"\$f.tmp\" \"${GITHUB_BASE}/\$f\" || { echo \"[ct] FEHLER bei ${GITHUB_BASE}/\$f (URL und Netz im CT prüfen)\"; exit 1; }
  done
  echo '[ct] 4/6 Dateien platzieren + venv ...'
  cp /tmp/app/main.py.tmp /opt/blender/app/main.py
  cp /tmp/app/requirements.txt.tmp /opt/blender/requirements.txt
  cp /tmp/systemd/blender.service.tmp /etc/systemd/system/blender.service
  python3 -m venv /opt/blender/venv
  /opt/blender/venv/bin/pip install --upgrade pip || echo '[ct] Hinweis: pip-Upgrade übersprungen (nicht kritisch)'
  /opt/blender/venv/bin/pip install -r /opt/blender/requirements.txt
  /opt/blender/venv/bin/python -c 'import fastapi, uvicorn' || { echo '[ct] FEHLER: fastapi/uvicorn unvollständig'; exit 1; }
  # python-multipart: import-Name je nach Version 'multipart' oder 'python_multipart'
  /opt/blender/venv/bin/python -c 'import multipart' 2>/dev/null || /opt/blender/venv/bin/python -c 'import python_multipart' || { echo '[ct] FEHLER: python-multipart fehlt (Web-Uploads würden scheitern)'; exit 1; }
  echo '[ct] deps-ok'
  echo '[ct] 5/6 Blender (apt, Upgrade auf 4.x per Web UI möglich) ...'
  if [ \"\$1\" != \"1\" ]; then
    if DEBIAN_FRONTEND=noninteractive apt-get install -y blender; then
      blender --version 2>/dev/null | head -1 || true
    else
      echo '[ct] WARNUNG: apt-Blender fehlgeschlagen — in der Web UI (Dashboard) nachinstallieren.'
    fi
  else
    echo '[ct] Blender übersprungen (--skip-blender).'
  fi
  echo '[ct] 6/6 systemd ...'
  systemctl daemon-reload
  systemctl enable blender.service
  systemctl restart blender.service
  echo APP-SETUP-OK
" bash "$SKIP_BLENDER" 2>&1 | tee "$SETUP_LOG"
# Hinweis: pve-firewall filtert auf dem HOST, nicht im CT — Port 8080 ggf.
# im Datacenter/CT-Firewall-Level freigeben (siehe README §7).

# ---------- Verifikation (Service braucht Anlaufzeit — aktiv pollen) ----------
log "Verifiziere Installation (warte auf Service) ..."
pct exec "$ID" -- bash -c 'set -euo pipefail
  for i in 1 2 3 4 5 6 7 8 9 10; do
    s=$(systemctl is-active blender.service 2>/dev/null || true)
    if [ "$s" = "active" ]; then echo "Service: active"; break; fi
    echo "warte auf Service ... ($i/10, Status: $s)"
    sleep 3
    if [ "$i" = "10" ]; then
      echo "FEHLER: Service nicht active (Status: $s)"
      systemctl status blender.service --no-pager -n 25 || true
      journalctl -u blender.service -n 50 --no-pager || true
      exit 1
    fi
  done
'
BLENDER_V=$(pct exec "$ID" -- blender --version 2>/dev/null | head -1 || true)
if [[ -n "$BLENDER_V" ]]; then
  ok "Blender: $BLENDER_V"
else
  warn "Blender (noch) nicht installiert — Dashboard → Blender installieren (apt oder 4.x-Release)."
fi
pct exec "$ID" -- bash -c "set -euo pipefail
  ok=0
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    for url in http://127.0.0.1:${APP_PORT}/healthz http://localhost:${APP_PORT}/healthz; do
      if curl -fsS -m 5 \"\$url\"; then ok=1; break 2; fi
    done
    echo \"warte auf Web UI ... (\$i/12)\"; sleep 5
  done
  if [ \"\$ok\" = \"1\" ]; then exit 0; fi
  echo '--- DIAGNOSE: Web UI antwortet nicht ---'
  echo '== ss -tlnp (wer hört?) =='; ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || true
  echo '== Prozess =='; ps aux | grep '[m]ain.py' || true
  echo '== curl -v =='; curl -v -m 5 http://127.0.0.1:${APP_PORT}/healthz || true
  echo '== systemctl status =='; systemctl status blender.service --no-pager -n 20 || true
  echo '== journal =='; journalctl -u blender.service -n 60 --no-pager || true
  exit 1
"

CT_IP=$(pct exec "$ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
ok "Service läuft, Web UI antwortet."
echo ""
echo -e "${G}Fertig! Web UI: http://${CT_IP:-<CT-IP>}:${APP_PORT}${N}"
echo "Update:     bash -c \"\$(wget -qLO - ${GITHUB_BASE}/install/blender.sh)\" -- --ctid $ID"
echo "Deinstall:  bash -c \"\$(wget -qLO - ${GITHUB_BASE}/install/blender.sh)\" -- --uninstall --ctid $ID"
echo "VM-Modus:   bash -c \"\$(wget -qLO - ${GITHUB_BASE}/install/blender.sh)\" -- --vm --gpu passthrough"
echo "Logs:       pct exec $ID -- journalctl -u blender.service -n 100 --no-pager"
echo "Setup-Log:  $SETUP_LOG (auf dem Host)"
echo "Mitschrift: $INSTALL_LOG (auf dem Host)"
