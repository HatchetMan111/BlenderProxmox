#!/usr/bin/env python3
"""
Blender Proxmox Manager — lokale Web-UI (0.0.0.0:8080).

- Dashboard: System, GPU, Blender-Version, Service-Status
- Blender installieren / rendern (headless: blender -b)
- VM-/LXC-Installer: generiert (und optional führt aus) pct/qm-Befehle
- GPU/vGPU-Check + manuelle Anleitung (Proxmox Wiki)
- Alles lokal, keine Cloud. Volle Tracebacks bei Fehlern.
"""
from __future__ import annotations

import json
import os
import platform
import shutil
import subprocess
import sys
import traceback
from datetime import datetime
from pathlib import Path

from fastapi import FastAPI, File, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse

APP_NAME = "blender"
APP_PORT = int(os.environ.get("APP_PORT", "8080"))
BASE_DIR = Path(os.environ.get("BASE_DIR", "/opt/blender"))
CONFIG_FILE = BASE_DIR / "config.json"
UPLOAD_DIR = BASE_DIR / "uploads"
JOBS_DIR = BASE_DIR / "jobs"
LOG_FILE = BASE_DIR / "app.log"

BASE_DIR.mkdir(parents=True, exist_ok=True)
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
JOBS_DIR.mkdir(parents=True, exist_ok=True)

DEFAULT_CONFIG = {
    "app_port": APP_PORT,
    "blender_version": "system",  # "system" (apt) oder z.B. "4.2.0"
    "default_mode": "lxc",        # lxc | vm
    "default_cpu": 2,
    "default_ram_mb": 2048,
    "default_disk_gb": 8,
    "default_storage": "local-lvm",
    "default_bridge": "vmbr0",
    "gpu_mode": "none",           # none | passthrough | vgpu
}

app = FastAPI(title="Blender Proxmox Manager")


# ---------- helpers ----------
def log(msg: str) -> None:
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"{datetime.now().isoformat()} {msg}\n")
    except Exception:
        pass


def run(cmd: list[str], timeout: int = 60) -> dict:
    """Führt Kommando aus, gibt stdout/stderr/exit-code zurück (niemals nur letzte Zeile)."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return {"cmd": " ".join(cmd), "exit": p.returncode,
                "stdout": p.stdout[-8000:], "stderr": p.stderr[-8000:]}
    except FileNotFoundError as e:
        return {"cmd": " ".join(cmd), "exit": 127,
                "stdout": "", "stderr": f"nicht gefunden: {e}\n{traceback.format_exc()}"}
    except Exception:
        return {"cmd": " ".join(cmd), "exit": 1,
                "stdout": "", "stderr": traceback.format_exc()}


def err_response(exc: BaseException, ctx: str = "") -> JSONResponse:
    tb = traceback.format_exc()
    log(f"ERROR {ctx}: {exc}\n{tb}")
    return JSONResponse(status_code=500, content={
        "ok": False, "context": ctx, "error": str(exc),
        "traceback": tb, "hint": "Siehe /api/logs und Logdatei.",
    })


def load_config() -> dict:
    if CONFIG_FILE.exists():
        try:
            return {**DEFAULT_CONFIG, **json.loads(CONFIG_FILE.read_text())}
        except Exception:
            log(f"config defekt, nutze defaults\n{traceback.format_exc()}")
    return dict(DEFAULT_CONFIG)


def save_config(cfg: dict) -> None:
    CONFIG_FILE.write_text(json.dumps(cfg, indent=2))


def sys_info() -> dict:
    mem = {}
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                k, _, v = line.partition(":")
                mem[k.strip()] = v.strip()
    except Exception:
        mem = {"error": traceback.format_exc(limit=3)}
    disk = shutil.disk_usage("/")
    return {
        "hostname": platform.node(),
        "os": f"{platform.system()} {platform.release()}",
        "machine": platform.machine(),
        "python": platform.python_version(),
        "cpu_count": os.cpu_count(),
        "mem_total": mem.get("MemTotal", "n/a"),
        "mem_available": mem.get("MemAvailable", "n/a"),
        "disk_total_gb": round(disk.total / 1e9, 1),
        "disk_free_gb": round(disk.free / 1e9, 1),
        "on_proxmox_host": shutil.which("qm") is not None or shutil.which("pct") is not None,
        "in_lxc": Path("/dev/lxc").exists() or os.environ.get("container") == "lxc",
        "time": datetime.now().isoformat(),
    }


def gpu_info() -> dict:
    out = {}
    out["lspci_vga"] = run(["sh", "-c", "lspci 2>/dev/null | grep -i -E 'vga|3d|nvidia' || echo 'kein lspci/nvidia-eintrag'"])
    out["nvidia_smi"] = run(["nvidia-smi", "-L"]) if shutil.which("nvidia-smi") else {
        "cmd": "nvidia-smi -L", "exit": 127, "stdout": "", "stderr": "nvidia-smi nicht gefunden (kein NVIDIA-Treiber im Container)."}
    out["dev_dri_exists"] = Path("/dev/dri").exists()
    out["dev_nvidia_exists"] = any(Path(f"/dev/nvidia{i}").exists() for i in range(8)) or Path("/dev/nvidiactl").exists()
    # vGPU-Hinweis: mdev-Typen gibt es nur auf dem HOST
    mdev = run(["sh", "-c", "ls /sys/bus/mdev/devices 2>/dev/null || ls /sys/bus/pci/devices/*/mdev_supported_types 2>/dev/null || echo 'keine mdev/vGPU auf dieser Maschine sichtbar'"])
    out["vgpu_mdev"] = mdev
    return out


def blender_version() -> dict:
    if not shutil.which("blender"):
        return {"installed": False, "version": None, "detail": "blender nicht im PATH"}
    r = run(["blender", "--version"])
    return {"installed": r["exit"] == 0, "version": (r["stdout"] or r["stderr"])[:500],
            "exit": r["exit"], "stderr": r["stderr"][:2000]}


def service_status() -> dict:
    if not shutil.which("systemctl"):
        return {"active": "unknown", "detail": "kein systemctl"}
    r = run(["systemctl", "is-active", "blender.service"])
    return {"active": r["stdout"].strip() or r["stderr"].strip(), "exit": r["exit"]}


# ---------- API ----------
@app.get("/api/status")
def api_status():
    try:
        return {"ok": True, "system": sys_info(), "gpu": gpu_info(),
                "blender": blender_version(), "service": service_status(),
                "config": load_config()}
    except Exception as e:
        return err_response(e, "GET /api/status")


@app.get("/api/config")
def api_get_config():
    return {"ok": True, "config": load_config()}


@app.post("/api/config")
def api_set_config(payload: dict):
    try:
        cfg = load_config()
        for k, v in payload.items():
            if k in DEFAULT_CONFIG:
                cfg[k] = v
        save_config(cfg)
        return {"ok": True, "config": cfg}
    except Exception as e:
        return err_response(e, "POST /api/config")


@app.get("/api/logs")
def api_logs(lines: int = 200):
    try:
        if LOG_FILE.exists():
            content = LOG_FILE.read_text().splitlines()[-lines:]
        else:
            content = ["(noch keine app.log)"]
        jr = run(["journalctl", "-u", "blender.service", "-n", str(lines), "--no-pager"]) \
            if shutil.which("journalctl") else {"stdout": "(kein journalctl)"}
        return {"ok": True, "app_log": content, "journal": jr.get("stdout", "")[-8000:]}
    except Exception as e:
        return err_response(e, "GET /api/logs")


@app.post("/api/blender/install")
def api_blender_install(payload: dict | None = None):
    """Installiert Blender: apt-Paket oder Release von blender.org (lokal, versionierbar)."""
    try:
        cfg = load_config()
        version = (payload or {}).get("version", cfg.get("blender_version", "system"))
        steps: list[dict] = []
        if version == "system":
            steps.append(run(["apt-get", "update"], timeout=300))
            steps.append(run(["apt-get", "install", "-y", "blender"], timeout=900))
        else:
            # Download von download.blender.org, z.B. 4.2.0
            url = (f"https://download.blender.org/release/Blender{version.split('.')[0]}."
                   f"{version.split('.')[1]}/blender-{version}-linux-x64.tar.xz")
            dest = BASE_DIR / f"blender-{version}.tar.xz"
            steps.append(run(["wget", "-O", str(dest), url], timeout=900))
            steps.append(run(["tar", "-xf", str(dest), "-C", str(BASE_DIR)], timeout=300))
            link = BASE_DIR / "blender-portable"
            if link.is_symlink() or link.exists():
                link.unlink()
            # Verzeichnisname raten
            cands = sorted(BASE_DIR.glob(f"blender-{version}*"))
            if cands:
                link.symlink_to(cands[0], target_is_directory=True)
        cfg["blender_version"] = version
        save_config(cfg)
        steps.append(blender_version())
        ok = blender_version().get("installed", False)
        return {"ok": ok, "version_requested": version, "steps": steps}
    except Exception as e:
        return err_response(e, "POST /api/blender/install")


@app.post("/api/render")
async def api_render(blend: UploadFile = File(...), frames: str = "1", engine: str = "CYCLES"):
    """Lädt .blend hoch und rendert headless: blender -b file --render-frame N."""
    try:
        dest = UPLOAD_DIR / blend.filename
        data = await blend.read()
        dest.write_bytes(data)
        out_dir = JOBS_DIR / f"{dest.stem}_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
        out_dir.mkdir(parents=True, exist_ok=True)
        blender_bin = shutil.which("blender") or str(BASE_DIR / "blender-portable" / "blender")
        cmd = [blender_bin, "-b", str(dest), "-o", str(out_dir / "frame_####"),
               "-E", engine, "-f", frames]
        r = run(cmd, timeout=1800)
        (out_dir / "render.log").write_text(json.dumps(r, indent=2))
        files = [p.name for p in out_dir.iterdir()]
        return {"ok": r["exit"] == 0, "job_dir": str(out_dir), "files": files, "detail": r}
    except Exception as e:
        return err_response(e, "POST /api/render")


@app.post("/api/vm/generate")
def api_vm_generate(payload: dict):
    """Generiert pct/qm-Befehle für LXC oder KVM-VM. Optional execute=1 auf PVE-Host."""
    try:
        mode = payload.get("mode", "lxc")
        vmid = int(payload.get("vmid", 200))
        cpu = int(payload.get("cpu", 2))
        ram = int(payload.get("ram_mb", 2048))
        disk = int(payload.get("disk_gb", 8))
        storage = payload.get("storage", "local-lvm")
        bridge = payload.get("bridge", "vmbr0")
        template = payload.get("template", "local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst")
        iso = payload.get("iso", "local:iso/debian-12-netinst.iso")
        gpu_mode = payload.get("gpu_mode", "none")
        execute = bool(payload.get("execute", False))

        cmds: list[str] = []
        if mode == "lxc":
            cmds.append(
                f"pct create {vmid} {template} --hostname blender-{vmid} "
                f"--cores {cpu} --memory {ram} --rootfs {storage}:{disk} "
                f"--net0 name=eth0,bridge={bridge},ip=dhcp --onboot 1 --start 1")
            if gpu_mode == "passthrough":
                cmds.append(f"# GPU-Passthrough LXC: /dev/dri durchreichen (Host): "
                            f"pct set {vmid} --dev0 /dev/dri/card0 && pct set {vmid} --dev1 /dev/dri/renderD128")
            elif gpu_mode == "vgpu":
                cmds.append(f"# vGPU im LXC wird NICHT automatisch eingerichtet — siehe README (mdev auf Host).")
        else:
            cmds.append(
                f"qm create {vmid} --name blender-{vmid} --cores {cpu} --sockets 1 "
                f"--memory {ram} --net0 virtio,bridge={bridge} "
                f"--scsihw virtio-scsi-pci --scsi0 {storage}:{disk} "
                f"--ide2 {iso},media=cdrom --boot order=scsi0 --ostype l26 --onboot 1")
            if gpu_mode == "passthrough":
                cmds.append(f"# Host: IOMMU prüfen (intel_iommu=on/amd_iommu=on), dann z.B.: "
                            f"qm set {vmid} --hostpci0 0000:01:00,pcie=1")
            elif gpu_mode == "vgpu":
                cmds.append(f"# vGPU (NVIDIA GRID): mdev-Typ auf Host wählen, z.B.: "
                            f"qm set {vmid} --hostpci0 0000:01:00.0,mdev=nvidia-11 "
                            f"# Doku: https://pve.proxmox.com/wiki/NVIDIA_vGPU_on_Proxmox_VE")

        executed: list[dict] = []
        if execute:
            if shutil.which("pct") is None and shutil.which("qm") is None:
                return {"ok": False, "error": "Weder pct noch qm gefunden — kein Proxmox-Host. Befehle nur generiert.",
                        "commands": cmds, "traceback": ""}
            for c in [x for x in cmds if not x.startswith("#")]:
                executed.append(run(c.split(), timeout=300))
        return {"ok": True, "commands": cmds, "executed": executed,
                "note": "vGPU geht NIE vollautomatisch (Treiberlizenz/Host-Kernel) — Details im README + Tab GPU/vGPU."}
    except Exception as e:
        return err_response(e, "POST /api/vm/generate")


@app.get("/healthz")
def healthz():
    return {"ok": True, "time": datetime.now().isoformat()}


# ---------- Web-UI ----------
INDEX_HTML = r"""<!DOCTYPE html><html lang="de"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Blender Proxmox Manager</title>
<style>
body{font-family:system-ui,sans-serif;background:#0f1115;color:#e8e8e8;margin:0}
header{background:#1a1d24;padding:14px 20px;display:flex;justify-content:space-between;align-items:center}
nav button{background:#2a2f3a;color:#fff;border:0;padding:8px 14px;margin-right:6px;border-radius:6px;cursor:pointer}
nav button.active{background:#e87d0d}
main{padding:20px;max-width:1100px;margin:auto}
.card{background:#1a1d24;border-radius:10px;padding:16px;margin-bottom:16px}
pre{background:#0b0d10;padding:12px;border-radius:8px;overflow:auto;max-height:320px;font-size:12px}
input,select{background:#0b0d10;color:#fff;border:1px solid #333;padding:8px;border-radius:6px;margin:4px}
button.go{background:#e87d0d;border:0;padding:9px 16px;border-radius:6px;color:#fff;cursor:pointer}
label{display:inline-block;min-width:170px;margin:4px}
a{color:#e87d0d}
table{border-collapse:collapse;width:100%}td,th{border-bottom:1px solid #333;padding:6px;text-align:left;font-size:14px}
</style></head><body>
<header><h2>🎬 Blender Proxmox Manager <small style="font-weight:normal">lokal · :8080</small></h2>
<nav>
<button data-t="dash" class="active">Dashboard</button><button data-t="render">Blender &amp; Render</button><button data-t="vm">VM / LXC Installer</button><button data-t="gpu">GPU / vGPU</button><button data-t="log">Logs</button>
</nav></header>
<main>
<section id="t-dash" class="card"><h3>Systemstatus</h3><div id="status">lädt…</div>
<h4>Aktionen</h4>
<label>Blender-Version</label><select id="bver"><option value="system">system (apt)</option><option value="4.2.0">4.2.0 (blender.org)</option><option value="4.1.1">4.1.1</option></select>
<button class="go" onclick="installBlender()">Blender installieren</button>
<h4>Einstellungen</h4>
<div id="cfg"></div><button class="go" onclick="saveCfg()">Speichern</button></section>

<section id="t-render" class="card" hidden><h3>Headless rendern (lokal)</h3>
<p>.blend hochladen → <code>blender -b Datei -E CYCLES -f N</code></p>
<input type="file" id="blend" accept=".blend"><label>Frames</label><input id="frames" value="1" size="4">
<label>Engine</label><select id="engine"><option>CYCLES</option><option>BLENDER_EEVEE</option><option>BLENDER_WORKBENCH</option></select>
<button class="go" onclick="doRender()">Rendern</button><pre id="renderOut"></pre></section>

<section id="t-vm" class="card" hidden><h3>Neue Blender LXC / VM erzeugen (pct / qm)</h3>
<p>Läuft die UI <b>auf dem Proxmox-Host-LXC mit pct/qm</b>, kann sie direkt ausführen — sonst Befehle kopieren.</p>
<label>Modus</label><select id="m"><option value="lxc">LXC (leicht)</option><option value="vm">VM/KVM (leistungshungrig + GPU)</option></select><br>
<label>VMID/CTID</label><input id="vmid" value="200" size="5"><label>CPU</label><input id="cpu" value="4" size="3">
<label>RAM MB</label><input id="ram" value="4096" size="6"><label>Disk GB</label><input id="disk" value="20" size="4"><br>
<label>Storage</label><input id="storage" value="local-lvm"><label>Bridge</label><input id="bridge" value="vmbr0"><br>
<label>LXC-Template</label><input id="tmpl" value="local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst" size="45"><br>
<label>VM-ISO</label><input id="iso" value="local:iso/debian-12-netinst.iso" size="45"><br>
<label>GPU</label><select id="gpu"><option value="none">keine</option><option value="passthrough">PCI-Passthrough</option><option value="vgpu">NVIDIA vGPU (manuell!)</option></select>
<label><input type="checkbox" id="exec"> direkt ausführen</label>
<button class="go" onclick="genVM()">Generieren</button><pre id="vmOut"></pre></section>

<section id="t-gpu" class="card" hidden><h3>GPU / vGPU-Status + manueller Weg</h3><div id="gpuBox">lädt…</div>
<ol>
<li><b>Automatisch:</b> Installer reicht <code>/dev/dri</code> durch (LXC) bzw. legt <code>--hostpci0</code> an (VM).</li>
<li><b>Wenn nicht automatisch (vGPU):</b> siehe README — NVIDIA-Treiber + vGPU-Manager auf dem <b>Host</b>, mdev-Typ wählen, <code>qm set VMID --hostpci0 …,mdev=nvidia-XX</code>. LXC kann kein echtes vGPU — dann VM nehmen.</li>
<li>Quellen: <a href="https://pve.proxmox.com/wiki/NVIDIA_vGPU_on_Proxmox_VE">Proxmox vGPU Wiki</a> · <a href="https://www.reddit.com/r/homelab/comments/wfr2sw/blender_on_proxmox/">r/homelab Blender on Proxmox</a> · <a href="https://gist.github.com/zocker-160/0688a4902421158b66f52dff3966058a">vGPU-Gist</a> · <a href="https://www.blender.org">blender.org</a></li>
</ol></section>

<section id="t-log" class="card" hidden><h3>Logs (vollständig)</h3><button class="go" onclick="loadLogs()">Neu laden</button><pre id="logs"></pre></section>
</main>
<script>
const $=id=>document.getElementById(id);
document.querySelectorAll('nav button').forEach(b=>b.onclick=()=>{
 document.querySelectorAll('nav button').forEach(x=>x.classList.remove('active'));b.classList.add('active');
 ['dash','render','vm','gpu','log'].forEach(t=>$('t-'+t).hidden=(t!==b.dataset.t));});
async function j(u,o){const r=await fetch(u,o);const t=await r.text();try{return JSON.parse(t)}catch(e){return {ok:false,raw:t.slice(0,4000)}}}
async function load(){const s=await j('/api/status');
 $('status').innerHTML=`<table><tr><th>Host</th><td>${s.system.hostname} · ${s.system.os} · CPU ${s.system.cpu_count} · RAM ${s.system.mem_total}</td></tr>
 <tr><th>Proxmox-Host-Tools</th><td>${s.system.on_proxmox_host}</td></tr>
 <tr><th>Blender</th><td><pre>${(s.blender.version||'nicht installiert').slice(0,400)}</pre></td></tr>
 <tr><th>Service</th><td>${s.service.active}</td></tr>
 <tr><th>nvidia-smi</th><td><pre>${(s.gpu.nvidia_smi.stdout||s.gpu.nvidia_smi.stderr||'').slice(0,800)}</pre></td></tr></table>`;
 $('gpuBox').innerHTML=`<pre>${JSON.stringify(s.gpu, null, 2).slice(0,4000)}</pre>`;
 const c=s.config;let h='';for(const k of Object.keys(c)){h+=`<label>${k}</label><input id="c_${k}" value="${c[k]}"><br>`}$('cfg').innerHTML=h;}
async function installBlender(){$('status').innerHTML='installiere…';const r=await j('/api/blender/install',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({version:$('bver').value})});alert(JSON.stringify(r).slice(0,2000));load();}
async function saveCfg(){const o={};document.querySelectorAll('#cfg input').forEach(i=>o[i.id.slice(2)]=i.value);await j('/api/config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(o)});load();}
async function doRender(){const f=$('blend').files[0];if(!f){alert('erst .blend wählen');return}const fd=new FormData();fd.append('blend',f);$('renderOut').textContent='rendert… (kann dauern)';const r=await fetch(`/api/render?x=1&frames=${$('frames').value}&engine=${$('engine').value}`,{method:'POST',body:(()=>{const d=new FormData();d.append('blend',f);return d})()});$('renderOut').textContent=(await r.text()).slice(0,6000);}
async function genVM(){const p={mode:$('m').value,vmid:+$('vmid').value,cpu:+$('cpu').value,ram_mb:+$('ram').value,disk_gb:+$('disk').value,storage:$('storage').value,bridge:$('bridge').value,template:$('tmpl').value,iso:$('iso').value,gpu_mode:$('gpu').value,execute:$('exec').checked};const r=await j('/api/vm/generate',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(p)});$('vmOut').textContent=JSON.stringify(r,null,2).slice(0,8000);}
async function loadLogs(){const r=await j('/api/logs?lines=200');$('logs').textContent=(r.app_log||[]).join('\n').slice(-6000)+'\n--- journal ---\n'+(r.journal||'').slice(-4000);}
load();
</script></body></html>"""


@app.get("/", response_class=HTMLResponse)
def index():
    return INDEX_HTML


@app.get("/api/vm/generate", response_class=PlainTextResponse)
def _hint():
    return "POST /api/vm/generate nutzen (siehe Web-UI)."


if __name__ == "__main__":
    import uvicorn
    log(f"start port={APP_PORT} base={BASE_DIR}")
    uvicorn.run(app, host="0.0.0.0", port=APP_PORT)
