# 🎬 Blender Proxmox Manager

Lokale Blender-Verwaltung auf Proxmox VE im Stil der **Proxmox VE Community Scripts**
(`community-scripts.github.io/ProxmoxVE`): **Einzeiler → LXC (Standard) oder KVM-VM (leistungshungrig/GPU) → Web-UI auf Port 8080.**

- **App:** Python/FastAPI, läuft vollständig lokal, keine Cloud
- **Web-UI:** `http://<LXC-IP>:8080` — Dashboard, Blender-Install, Headless-Render, **VM-/LXC-Installer mit Weboberfläche** (alles einstellbar: CPU/RAM/Disk/Storage/Bridge/GPU), GPU/vGPU-Status, Logs
- **Blender-Quelle:** https://www.blender.org
- **Repo-Layout (GitHub-first):** `app/` · `install/blender.sh` · `systemd/blender.service`

> ✅ Repo: `HatchetMan111/BlenderProxmox` (Variablen oben in `install/blender.sh`: `GITHUB_USER`, `GITHUB_REPO`, `GITHUB_BRANCH`).

## 1. Einzeiler (auf dem Proxmox-HOST als root)

**Standard (LXC, 2 CPU / 2 GB / 8 GB):**
```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/BlenderProxmox/main/install/blender.sh)"
```

**Angepasst:**
```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/BlenderProxmox/main/install/blender.sh)" -- --ctid 150 --cpu 2 --ram 2048 --disk 8 --gpu none
```

**Leistungshungrig als VM (KVM + GPU-Passthrough/vGPU):**
```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/BlenderProxmox/main/install/blender.sh)" -- --vm --vmid 200 --cpu 4 --ram 4096 --disk 20 --gpu passthrough
```

**Debug (volle Fehlerkette, `bash -x`):**
```bash
bash -x -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/BlenderProxmox/main/install/blender.sh)" -- --debug
```

**Update (idempotent, gleicher Einzeiler):**
```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/BlenderProxmox/main/install/blender.sh)" -- --ctid 150
```

**Deinstall:**
```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/BlenderProxmox/main/install/blender.sh)" -- --uninstall --ctid 150
# VM: ... -- --uninstall --vm --vmid 200
```

## 2. Was der Installer tut

1. Prüft root + `pct`/`qm` (Proxmox-Host), parst Args, löst die ID auf: **fremd belegte ID → nächste freie ID** (LXC+VM teilen sich den Proxmox-ID-Raum), **eigene** Container (Hostname `blender`, Marker `blender-managed` in der Beschreibung oder `/opt/blender/app/main.py`) werden für Updates wiederverwendet. `set -euo pipefail` + `trap ERR` mit **Fehlerkette** (Exit-Code, Zeile, Kommando, Stack, `pveversion`, CT-Status) + komplette Mitschrift in `/tmp/blender-install-*.log`.
2. **LXC:** wählt automatisch das neueste Debian-12-Standard-Template (lokal vorhandenes wird wiederverwendet, sonst `pveam update/download` — versionstolerant, kein hartcodiertes Datum), `pct create … --onboot 1 --unprivileged 1 --features nesting=1,keyctl=1`, optional `/dev/dri`-Passthrough, wartet aktiv auf CT-Netz (DHCP, max. 30 s) statt blind `sleep`.
   **VM:** prüft/lädt die Debian-Netinst-ISO **automatisch nach** (`qm start` würde bei fehlender ISO sonst mit "volume does not exist" scheitern), `qm create … --boot 'order=ide2;scsi0' --onboot 1` (VM bootet den Debian-Installer von ide2), gibt GPU-Hinweise aus (siehe §4).
3. Installiert im CT (mit DNS-Check + `apt-get update`-Retries): Python3, venv, `app/requirements.txt` (FastAPI/uvicorn/python-multipart), kopiert `app/main.py` + `systemd/blender.service` von GitHub (wget mit 3 Versuchen), installiert **Blender per apt** (Opt-out: `--skip-blender`; Upgrade auf 4.x jederzeit per Web-UI), `systemctl enable` + `restart`.
4. **Verifiziert** aktiv: `systemctl is-active` (10 × 3 s Poll) + `curl localhost:8080/healthz` (12 × 5 s, 127.0.0.1 + localhost), bei Fehler volle Diagnose (`ss`, `journalctl`), druckt finale URL + CT-IP.

Erwartete Ausgabe:
```
[blender] Modus: LXC (CT 150, ...)
[OK] CT 150 erstellt.
[OK] Service läuft, Web UI antwortet.
Fertig! Web UI: http://192.168.1.50:8080
```

## 3. Web-UI (alles einstellbar)

| Tab | Funktion |
|---|---|
| Dashboard | System/GPU/Blender/Service, Blender installieren (`apt` oder Release von blender.org), Config speichern |
| Blender & Render | `.blend` hochladen → `blender -b … -E CYCLES -f N`, Job-Ordner unter `/opt/blender/jobs` |
| **VM / LXC Installer** | Formular: Modus, ID, CPU, RAM, Disk, Storage, Bridge, Template/ISO, GPU-Modus → generiert `pct`/`qm`-Befehle, optional **direkt ausführen** (wenn UI auf Host-LXC mit Tools läuft) |
| GPU / vGPU | `lspci`, `nvidia-smi`, `/dev/dri`, mdev-Check + Anleitung |
| Logs | `app.log` + `journalctl` vollständig |

Bind: `0.0.0.0:8080` (`APP_PORT`/`BASE_DIR` via Env), systemd `Restart=always`, `After=network-online.target`, CT `onboot: 1` → **reboot-sicher**.

## 4. GPU / vGPU — automatischer vs. manueller Weg

**Automatisch (Script/Web-UI):**
- LXC + `--gpu passthrough`: reicht `/dev/dri/card0` + `renderD128` durch (`pct set … --dev0/--dev1`). Geht nur wenn Host `/dev/dri` hat; der systemd-Service läuft als root, daher ist der Standard-Mode (0660) ausreichend.
- VM + `--gpu passthrough`: lädt bei Bedarf die Debian-Netinst-ISO automatisch (`cdimage.debian.org` → Storage `local`), legt VM mit Boot-Order `ide2;scsi0` an, druckt `qm set VMID --hostpci0 …` Vorlage.

**Wenn es NICHT automatisch geht (vGPU) — manueller Weg im README:**
1. Host-Treiber: NVIDIA Host-Treiber + **vGPU Manager** installieren (Proxmox Wiki beachten, Kernel kompatibel halten).
   Doku: https://pve.proxmox.com/wiki/NVIDIA_vGPU_on_Proxmox_VE
2. Prüfen: `lspci -nn | grep -i nvidia`, `ls /sys/bus/pci/devices/*/mdev_supported_types`, `dmesg | grep -i nvidia`.
3. mdev-Typ wählen (z.B. `nvidia-11`), an VM hängen:
   ```bash
   qm set 200 --hostpci0 0000:01:00.0,mdev=nvidia-11
   ```
4. VM starten, **Guest-Treiber (GRID)** in der VM installieren, in Blender *Edit → Preferences → System → Cycles Render Devices → CUDA/OptiX* aktivieren.
5. LXC kann **kein echtes vGPU** — für vGPU immer **VM-Modus** nehmen.

Hintergrund:
- https://www.reddit.com/r/homelab/comments/wfr2sw/blender_on_proxmox/ (Blender on Proxmox, PCIe-Passthrough-Erfahrungen)
- https://gist.github.com/zocker-160/0688a4902421158b66f52dff3966058a (vGPU-Script-Sammlung)
- https://www.blender.org (offizielle Releases, falls `apt`-Version zu alt ist → Web-UI → Version 4.2.0)

**IOMMU für Passthrough (Host, einmalig):**
```bash
# Intel: intel_iommu=on iommu=pt | AMD: amd_iommu=on iommu=pt  in /etc/default/grub → GRUB_CMDLINE_LINUX_DEFAULT
update-grub && reboot
dmesg | grep -e IOMMU -e DMAR
```

## 5. Testdurchlauf (Installation → Reboot → UI erreichbar)

```bash
# 1) Syntax
bash -n install/blender.sh && echo SYNTAX-OK
python3 -m py_compile app/main.py && echo PY-OK
systemd-analyze verify systemd/blender.service || true

# 2) App lokal testen (ohne Proxmox)
python3 -m venv /tmp/bl-test && /tmp/bl-test/bin/pip install -q -r app/requirements.txt
BASE_DIR=/tmp/bl-test-data APP_PORT=8080 /tmp/bl-test/bin/python app/main.py &
sleep 6
curl -fsS http://localhost:8080/healthz
curl -fsS http://localhost:8080/api/status | head -c 500

# 3) Auf Proxmox-Host: installieren, rebooten, prüfen
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/BlenderProxmox/main/install/blender.sh)" -- --ctid 150
pct exec 150 -- systemctl is-active blender.service
pct reboot 150; sleep 15
pct exec 150 -- systemctl is-active blender.service
curl -fsS http://<CT-IP>:8080/healthz
```

## 6. Dateien

```
install/blender.sh       Proxmox-Installer (Variablen oben, set -euo pipefail, idempotent)
app/main.py              FastAPI-App + Web-UI (0.0.0.0:8080)
app/requirements.txt     fastapi + uvicorn
systemd/blender.service  Restart=always, After=network-online.target
README.md                diese Datei
```

## 7. Debugging

- Installer gibt bei Fehlern eine **volle Fehlerkette** aus (Exit-Code, Zeile, Kommando, Caller-Stack, `pveversion`, CT-Status) + `bash -x`-Hinweis; die komplette Mitschrift landet in `/tmp/blender-install-<PID>.log` (Neueste: `ls -t /tmp/blender-install-*.log | head -1`), das CT-Setup in `/tmp/blender-setup-<ID>.log`.
- **Firewall:** Die pve-firewall filtert auf dem **Host**, nicht im CT — läuft sie aktiv (Datacenter/Node/CT `firewall=1`), Port 8080 dort freigeben. Der Installer setzt keine Firewall-Regeln.
- **Kein DHCP im Netz?** Dann `--net0` in blender.sh auf statische IP umstellen (Variable/Zeile `net0 … ip=dhcp`), sonst bleibt das CT ohne Netz und das Setup bricht beim DNS-Check ab.
- App gibt JSON mit `traceback` zurück; zusätzlich `/api/logs` und `pct exec <ID> -- journalctl -u blender.service -n 100 --no-pager`.
