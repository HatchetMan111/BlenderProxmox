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
HOSTNAME="blender-proxmox"
CPU="2"
RAM="2048"                 # MB
DISK="8"                   # GB
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
TEMPLATE="debian-12-standard_12.2-1_amd64.tar.zst"
BRIDGE="vmbr0"
GPU_MODE="none"            # none | passthrough | vgpu
VM_ISO="local:iso/debian-12-netinst.iso"
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
  pct status "$CTID" 2>&1 >&2 || true
  echo "Tipp: erneut mit Debug laufen lassen:" >&2
  echo "  bash -x -c \"\$(wget -qLO - ${GITHUB_BASE}/install/blender.sh)\" -- --debug" >&2
  echo -e "${R}=================================${N}" >&2
}
trap 'on_err $LINENO "$BASH_COMMAND"' ERR

usage(){
  cat <<EOF
$APP_NAME Installer (Proxmox VE Community-Scripts-Stil)

  bash -c "\$(wget -qLO - ${GITHUB_BASE}/install/blender.sh)"

Optionen:
  --ctid ID        LXC-ID (Default $CTID)
  --vm             statt LXC eine KVM-VM anlegen (für GPU/Renderleistung)
  --vmid ID        VM-ID (Default $VMID)
  --cpu N          vCPUs (Default $CPU)
  --ram MB         RAM in MB (Default $RAM)
  --disk GB        Disk in GB (Default $DISK)
  --storage S      Storage (Default $STORAGE)
  --bridge B       Bridge (Default $BRIDGE)
  --gpu MODE       none|passthrough|vgpu (Default $GPU_MODE)
  --uninstall      Container/VM entfernen
  --debug          set -x + volle Logs
  -h|--help        Hilfe

  IDs: Belegte IDs werden automatisch auf die nächste freie ID
       hochgezählt (LXC+VM teilen sich den ID-Raum!). Eigene
       Container (Hostname bzw. Blender-Marker) werden für
       Updates wiederverwendet.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CTID="$2"; shift 2;;
    --vm) MODE="vm"; shift;;
    --vmid) VMID="$2"; shift 2;;
    --cpu) CPU="$2"; shift 2;;
    --ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --storage) STORAGE="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --gpu) GPU_MODE="$2"; shift 2;;
    --uninstall) UNINSTALL=1; shift;;
    --debug) DEBUG=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unbekannte Option: $1 (siehe --help)";;
  esac
done
[[ "$DEBUG" == "1" ]] && set -x

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
  local id="$1"
  pct config "$id" 2>/dev/null | grep -qE "^hostname: ${HOSTNAME}$" && return 0
  pct exec "$id" -- test -f /opt/blender/app/main.py >/dev/null 2>&1
}
is_ours_vm(){
  qm config "$1" 2>/dev/null | grep -qE "^name: ${HOSTNAME}-"
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

# ---------- Uninstall ----------
if [[ "$UNINSTALL" == "1" ]]; then
  if [[ "$MODE" == "vm" ]]; then
    log "Stoppe/entferne VM $VMID ..."
    qm stop "$VMID" 2>/dev/null || true
    qm destroy "$VMID" 2>/dev/null || warn "VM $VMID existierte nicht."
  else
    log "Stoppe/entferne LXC $CTID ..."
    pct stop "$CTID" 2>/dev/null || true
    pct destroy "$CTID" 2>/dev/null || warn "CT $CTID existierte nicht."
  fi
  ok "Deinstalliert."
  exit 0
fi

# ================= VM-PFAD (leistungshungrig) =================
if [[ "$MODE" == "vm" ]]; then
  VMID=$(resolve_id vm "$VMID")
  log "Modus: KVM-VM (ID $VMID, $CPU CPU, ${RAM}MB RAM, ${DISK}G, GPU=$GPU_MODE)"
  if qm status "$VMID" >/dev/null 2>&1; then
    warn "VM $VMID existiert bereits (eigene, idempotent) — überspringe create."
  else
    qm create "$VMID" --name "${HOSTNAME}-${VMID}" --cores "$CPU" --sockets 1 \
      --memory "$RAM" --net0 "virtio,bridge=${BRIDGE}" \
      --scsihw virtio-scsi-pci --scsi0 "${STORAGE}:${DISK}" \
      --ide2 "${VM_ISO},media=cdrom" --boot order=scsi0 --ostype l26 --onboot 1
    ok "VM $VMID angelegt."
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
  echo "  1) qm start $VMID  # falls noch nicht gestartet"
  echo "  2) Debian via Konsole installieren, dann IN der VM den LXC-Einzeiler-Variante laufen lassen"
  echo "     oder Web-UI-LXC (Modus lxc) als Manager nutzen: Tab 'VM / LXC Installer'."
  echo "  3) Manager-UI (LXC) auf http://<LXC-IP>:${APP_PORT}"
  exit 0
fi

# ================= LXC-PFAD (Standard) =================
ID=$(resolve_id lxc "$CTID")
CTID="$ID"
log "Modus: LXC (CT $ID, $CPU CPU, ${RAM}MB RAM, ${DISK}G, GPU=$GPU_MODE)"
log "Repo: ${GITHUB_BASE}"

# Template sicherstellen (idempotent)
if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
  log "Template $TEMPLATE fehlt — update + download ..."
  pveam update
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

if pct status "$ID" >/dev/null 2>&1; then
  warn "CT $ID existiert bereits (eigene, idempotent) — nutze vorhandenen Container."
else
  pct create "$ID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME" --cores "$CPU" --memory "$RAM" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --onboot 1 --start 1 --unprivileged 1 \
    --features nesting=1,keyctl=1
  ok "CT $ID erstellt."
fi

# GPU-Devices durchreichen (nur passthrough automatisch; vgpu bewusst NICHT)
if [[ "$GPU_MODE" == "passthrough" ]]; then
  if [[ -e /dev/dri ]]; then
    pct stop "$ID" 2>/dev/null || true
    # idempotent: vorhandene dev-Einträge erst entfernen
    pct set "$ID" --delete dev0 2>/dev/null || true
    pct set "$ID" --delete dev1 2>/dev/null || true
    pct set "$ID" --dev0 /dev/dri/card0 2>/dev/null || warn "/dev/dri/card0 konnte nicht durchgereicht werden"
    [[ -e /dev/dri/renderD128 ]] && pct set "$ID" --dev1 /dev/dri/renderD128 2>/dev/null || true
    ok "GPU /dev/dri durchgereicht."
  else
    warn "Kein /dev/dri auf dem Host — GPU-Passthrough übersprungen (siehe README manueller Weg)."
  fi
elif [[ "$GPU_MODE" == "vgpu" ]]; then
  warn "vGPU im LXC wird NICHT automatisch eingerichtet (kein mdev im Container)."
  warn "Nimm --vm für echtes vGPU oder folge README (Host: vGPU-Manager + mdev + VM)."
fi

pct start "$ID" 2>/dev/null || true
sleep 3

CT_IP=$(pct exec "$ID" -- hostname -I 2>/dev/null | awk '{print $1}')
log "CT-IP (falls leer: DHCP abwarten): ${CT_IP:-n/a}"

# ---------- Dateien ins CT laden ----------
log "Lade App-Code von GitHub ..."
pct exec "$ID" -- bash -c "set -euo pipefail
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv python3-pip curl wget ca-certificates pciutils lshw
  mkdir -p /opt/blender/app /opt/blender/uploads /opt/blender/jobs
  cd /tmp
  for f in 'app/main.py' 'app/requirements.txt' 'systemd/blender.service'; do
    echo \"hole \$f ...\"
    wget -qO \"\$f.tmp\" \"${GITHUB_BASE}/\$f\" || { echo \"FEHLER beim Laden ${GITHUB_BASE}/\$f\"; echo \"Prüfe GITHUB_USER/REPO/BRANCH oben im Script.\"; exit 1; }
  done
  cp /tmp/app/main.py.tmp /opt/blender/app/main.py
  cp /tmp/app/requirements.txt.tmp /opt/blender/requirements.txt
  cp /tmp/systemd/blender.service.tmp /etc/systemd/system/blender.service
  python3 -m venv /opt/blender/venv
  /opt/blender/venv/bin/pip install --upgrade pip
  /opt/blender/venv/bin/pip install -r /opt/blender/requirements.txt
  systemctl daemon-reload
  systemctl enable blender.service
  systemctl restart blender.service
  echo APP-SETUP-OK
"

# Firewall im LXC (falls pve-firewall aktiv): Port öffnen
pct exec "$ID" -- bash -c "iptables -C INPUT -p tcp --dport ${APP_PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport ${APP_PORT} -j ACCEPT 2>/dev/null || true"

# ---------- Verifikation ----------
log "Verifiziere Installation ..."
pct exec "$ID" -- systemctl is-active blender.service
pct exec "$ID" -- bash -c "for i in 1 2 3 4 5 6; do curl -fsS -m 5 http://localhost:${APP_PORT}/healthz && exit 0; sleep 3; done; echo '--- journal ---'; journalctl -u blender.service -n 50 --no-pager; exit 1"

CT_IP=$(pct exec "$ID" -- hostname -I 2>/dev/null | awk '{print $1}')
ok "Service läuft, Web UI antwortet."
echo ""
echo -e "${G}Fertig! Web UI: http://${CT_IP:-<CT-IP>}:${APP_PORT}${N}"
echo "Update:     bash -c \"\$(wget -qLO - ${GITHUB_BASE}/install/blender.sh)\" -- --ctid $ID"
echo "Deinstall:  bash -c \"\$(wget -qLO - ${GITHUB_BASE}/install/blender.sh)\" -- --uninstall --ctid $ID"
echo "VM-Modus:   bash -c \"\$(wget -qLO - ${GITHUB_BASE}/install/blender.sh)\" -- --vm --vmid $VMID --gpu passthrough"
echo "Logs:       pct exec $ID -- journalctl -u blender.service -n 100 --no-pager"
