#!/usr/bin/env bash
# =============================================================================
# fetch-live-data.sh — Collect live cluster data and write JSON files
#
# Runs on varys (10.0.10.10) via SSH from the GitHub Actions pipeline.
# Outputs JSON to stdout which the Action writes to public/data/live.json.
#
# Requirements on varys: kubectl, curl
# =============================================================================

set -euo pipefail

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── Nodes ─────────────────────────────────────────────────────────────────────
# All metrics derived from a single kubectl get nodes -o json call.
# No node-exporter, no port-forwarding needed.
build_nodes() {
  local nodes_json pods_json tmp_nodes tmp_pods
  nodes_json=$(kubectl get nodes -o json 2>/dev/null || echo "{}")
  pods_json=$(kubectl get pods -A -o json 2>/dev/null || echo "{}")

  tmp_nodes=$(mktemp)
  tmp_pods=$(mktemp)
  echo "$nodes_json" > "$tmp_nodes"
  echo "$pods_json"  > "$tmp_pods"

  python3 - "$tmp_nodes" "$tmp_pods" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
  try:    nodes = json.load(f)['items']
  except: nodes = []

with open(sys.argv[2]) as f:
  try:    pods = json.load(f)['items']
  except: pods = []

# Build per-node pod resource request totals
# cpu in millicores, memory in bytes
node_cpu_req  = {}
node_mem_req  = {}
node_pod_count = {}

def parse_cpu(s):
  if not s: return 0
  if s.endswith('m'): return int(s[:-1])
  return int(float(s) * 1000)

def parse_mem(s):
  if not s: return 0
  units = {'Ki': 1024, 'Mi': 1024**2, 'Gi': 1024**3, 'Ti': 1024**4}
  for suffix, mult in units.items():
    if s.endswith(suffix): return int(s[:-len(suffix)]) * mult
  return int(s)

for pod in pods:
  node = pod.get('spec', {}).get('nodeName', '')
  phase = pod.get('status', {}).get('phase', '')
  if not node or phase not in ('Running', 'Pending'):
    continue
  node_pod_count[node] = node_pod_count.get(node, 0) + 1
  for container in pod.get('spec', {}).get('containers', []):
    req = container.get('resources', {}).get('requests', {})
    node_cpu_req[node] = node_cpu_req.get(node, 0) + parse_cpu(req.get('cpu', '0'))
    node_mem_req[node] = node_mem_req.get(node, 0) + parse_mem(req.get('memory', '0'))

result = []
for node in nodes:
  name = node['metadata']['name']

  # Ready status + condition flags
  status = 'crit'
  pressure_flags = []
  for cond in node.get('status', {}).get('conditions', []):
    t = cond['type']
    v = cond['status'] == 'True'
    if t == 'Ready' and v:
      status = 'ok'
    if t in ('MemoryPressure', 'DiskPressure', 'PIDPressure') and v:
      pressure_flags.append(t.replace('Pressure', ''))

  # Role
  labels = node['metadata'].get('labels', {})
  role = 'control-plane' if 'node-role.kubernetes.io/control-plane' in labels else 'worker'

  # Allocatable resources
  alloc = node.get('status', {}).get('allocatable', {})
  alloc_cpu_m  = parse_cpu(alloc.get('cpu', '0'))
  alloc_mem_b  = parse_mem(alloc.get('memory', '0'))
  alloc_pods   = int(alloc.get('pods', '110'))

  # Scheduled pods
  pod_count = node_pod_count.get(name, 0)

  # CPU requested %
  cpu_req_m = node_cpu_req.get(name, 0)
  cpu_pct = f'{cpu_req_m * 100 // alloc_cpu_m}%' if alloc_cpu_m > 0 else '—'

  # Memory requested %
  mem_req_b = node_mem_req.get(name, 0)
  mem_pct = f'{mem_req_b * 100 // alloc_mem_b}%' if alloc_mem_b > 0 else '—'

  result.append({
    'name':     name,
    'role':     role,
    'status':   status,
    'pods':     f'{pod_count}/{alloc_pods}',
    'cpu':      cpu_pct,
    'memory':   mem_pct,
    'pressure': pressure_flags,
  })

print(json.dumps(result))
PYEOF
  rm -f "$tmp_nodes" "$tmp_pods"
}

# ── Flux sync status ───────────────────────────────────────────────────────────
build_flux() {
  local ks_raw
  ks_raw=$(kubectl get kustomizations -A --no-headers 2>/dev/null || echo "")

  # Column order: NAMESPACE NAME AGE READY STATUS
  # parts[0]=namespace parts[1]=name parts[2]=age parts[3]=ready parts[4..]=status
  local ready_count total_count last_sync status
  ready_count=$(echo "$ks_raw" | awk '{print $4}' | grep -c "True" || echo "0")
  total_count=$(echo "$ks_raw"  | grep -c . || echo "0")
  last_sync=$(echo "$ks_raw"    | awk '{print $3}' | head -1 || echo "—")
  status="ok"
  [[ "$ready_count" != "$total_count" ]] && status="warn"

  # Build kustomizations array
  local ks_json
  ks_json=$(echo "$ks_raw" | python3 -c "
import sys, json
rows = []
for line in sys.stdin:
    parts = line.split()
    if len(parts) >= 4:
        rows.append({
            'namespace': parts[0],
            'name':      parts[1],
            'age':       parts[2],
            'ready':     parts[3] == 'True',
        })
print(json.dumps(rows))
")

  echo "{\"ready\":${ready_count},\"total\":${total_count},\"last_sync\":\"${last_sync}\",\"status\":\"${status}\",\"kustomizations\":${ks_json}}"
}

# ── Backup age helper ─────────────────────────────────────────────────────────
# Usage: backup_age_json <unix_timestamp>
# Returns JSON {age, status} — warn >25h, crit >48h
backup_age_json() {
  local ts="$1" age_str status
  if [[ -z "$ts" || ! "$ts" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo '{"age":"—","status":"unknown"}'
    return
  fi
  age_str=$(python3 -c "
import time
age=time.time()-float('${ts}')
h=int(age//3600); m=int((age%3600)//60)
print(f'{h}h {m}m ago' if h else f'{m}m ago')
")
  local age_hours
  age_hours=$(python3 -c "print(int(($(date +%s) - int(float('${ts}'))) / 3600))")
  status="ok"
  [[ "$age_hours" -gt 25 ]] && status="warn"
  [[ "$age_hours" -gt 48 ]] && status="crit"
  echo "{\"age\":\"${age_str}\",\"status\":\"${status}\"}"
}

# ── Backup status ─────────────────────────────────────────────────────────────
# bronn: SSH to 10.0.10.20 — reads textfile metric written by backup_docker.sh
# etcd:  SSH to 10.0.10.11 (tywin) — reads mtime from latest snapshot filename
build_backup() {
  # bronn — docker appdata
  local bronn_ts
  bronn_ts=$(ssh -o ConnectTimeout=5 -o BatchMode=yes 10.0.10.20 \
    "grep -m1 'backup_last_success_timestamp{job=\"docker-appdata\"}' \
     /var/lib/node_exporter/textfile_collector/docker_backup.prom 2>/dev/null | awk '{print \$2}'" 2>/dev/null || echo "")
  local bronn_json
  bronn_json=$(backup_age_json "$bronn_ts")

  # etcd — extract unix timestamp from latest snapshot filename (etcd-snapshot-<node>-<ts>)
  local etcd_ts
  etcd_ts=$(ssh -o ConnectTimeout=5 -o BatchMode=yes 10.0.10.11 \
    "sudo ls /var/lib/rancher/k3s/server/db/snapshots/ 2>/dev/null | grep -oP '\d+$' | sort -n | tail -1" 2>/dev/null || echo "")
  local etcd_json
  etcd_json=$(backup_age_json "$etcd_ts")

  echo "{\"bronn\":${bronn_json},\"etcd\":${etcd_json}}"
}

# ── Velero last backup ─────────────────────────────────────────────────────────
build_velero() {
  local last_line name ts phase status age_str
  last_line=$(kubectl get backups -n velero \
    --sort-by=.metadata.creationTimestamp \
    -o custom-columns="NAME:.metadata.name,PHASE:.status.phase,TS:.metadata.creationTimestamp" \
    --no-headers 2>/dev/null | tail -1 || echo "")
  name=$(echo "$last_line"  | awk '{print $1}')
  phase=$(echo "$last_line" | awk '{print $2}')
  ts=$(echo "$last_line"    | awk '{print $3}')
  status="unknown"
  [[ "$phase" == "Completed" ]]       && status="ok"
  [[ "$phase" == "Failed" ]]          && status="crit"
  [[ "$phase" == "PartiallyFailed" ]] && status="warn"

  # Convert ISO timestamp to age string
  age_str="—"
  if [[ -n "$ts" && "$ts" != "<none>" ]]; then
    age_str=$(python3 -c "
import time
from datetime import datetime, timezone
try:
  t = datetime.fromisoformat('${ts}'.replace('Z','+00:00')).timestamp()
  age = time.time() - t
  h = int(age//3600); m = int((age%3600)//60)
  print(f'{h}h {m}m ago' if h else f'{m}m ago')
except:
  print('—')
" 2>/dev/null || echo "—")
  fi

  echo "{\"age\":\"${age_str}\",\"status\":\"${status}\"}"
}

# =============================================================================
# Service endpoints — internal DNS via Pi-hole on hodor (10.0.10.15)
# Docker host services use IP:port (no internal DNS for these yet)
# k3s services use *.local.kagiso.me DNS entries
# =============================================================================
DOCKER_HOST="10.0.10.20"
SONARR_URL="http://${DOCKER_HOST}:8989"
RADARR_URL="http://${DOCKER_HOST}:7878"
SABNZBD_URL="http://${DOCKER_HOST}:8085"
PLEX_URL="http://${DOCKER_HOST}:32400"
LIDARR_URL="http://${DOCKER_HOST}:8686"
NAVIDROME_URL="http://${DOCKER_HOST}:4533"
UPTIME_KUMA_URL="http://${DOCKER_HOST}:3001"
VAULTWARDEN_URL="https://vault.local.kagiso.me"
NEXTCLOUD_URL="https://cloud.local.kagiso.me"
IMMICH_URL="https://photos.local.kagiso.me"
# API keys injected as environment variables from GitHub Actions secrets
# Set locally on varys via ~/.bashrc if running the script manually:
#   export SONARR_API_KEY=...   export RADARR_API_KEY=...
#   export SABNZBD_API_KEY=...  export LIDARR_API_KEY=...
: "${SONARR_API_KEY:?SONARR_API_KEY env var not set}"
: "${RADARR_API_KEY:?RADARR_API_KEY env var not set}"
: "${SABNZBD_API_KEY:?SABNZBD_API_KEY env var not set}"
: "${LIDARR_API_KEY:?LIDARR_API_KEY env var not set}"

# ── Sonarr: series count ───────────────────────────────────────────────────────
build_sonarr() {
  local raw
  raw=$(curl -sf --max-time 5 \
    -H "X-Api-Key: ${SONARR_API_KEY}" \
    "${SONARR_URL}/api/v3/series?includeSeasonImages=false" 2>/dev/null || echo "")

  local count="—"
  local status="unknown"
  if [[ -n "$raw" ]]; then
    count=$(echo "$raw" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo "—")
    status="ok"
  fi
  echo "{\"count\":\"${count}\",\"label\":\"Sonarr: ${count} series\",\"status\":\"${status}\"}"
}

# ── Radarr: movie count ────────────────────────────────────────────────────────
build_radarr() {
  local raw
  raw=$(curl -sf --max-time 5 \
    -H "X-Api-Key: ${RADARR_API_KEY}" \
    "${RADARR_URL}/api/v3/movie" 2>/dev/null || echo "")

  local count="—"
  local status="unknown"
  if [[ -n "$raw" ]]; then
    count=$(echo "$raw" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo "—")
    status="ok"
  fi
  echo "{\"count\":\"${count}\",\"label\":\"Radarr: ${count} movies\",\"status\":\"${status}\"}"
}

# ── SABnzbd: queue size remaining ─────────────────────────────────────────────
build_sabnzbd() {
  local raw
  raw=$(curl -sf --max-time 5 \
    "${SABNZBD_URL}/api?mode=queue&output=json&limit=1&apikey=${SABNZBD_API_KEY}" 2>/dev/null || echo "")

  local label="idle"
  local status="unknown"
  if [[ -n "$raw" ]]; then
    status="ok"
    label=$(echo "$raw" | python3 -c "
import sys, json
try:
  d = json.load(sys.stdin)['queue']
  state = d.get('status', 'Idle').lower()
  mb_left = float(d.get('mbleft', 0))
  if state in ('downloading', 'grabbing') and mb_left > 0:
    if mb_left >= 1024:
      size = f'{mb_left/1024:.1f} GB left'
    else:
      size = f'{mb_left:.0f} MB left'
    print(f'downloading · {size}')
  else:
    print('idle')
except:
  print('idle')
" 2>/dev/null || echo "idle")
  fi
  echo "{\"label\":\"${label}\",\"status\":\"${status}\"}"
}

# ── Plex: active stream count ──────────────────────────────────────────────────
build_plex() {
  local token="${PLEX_TOKEN:-}"
  local status="unknown"

  if [[ -n "$token" ]]; then
    local raw
    raw=$(curl -sf --max-time 5 \
      -H "X-Plex-Token: ${token}" \
      -H "Accept: application/json" \
      "${PLEX_URL}/status/sessions" 2>/dev/null || echo "")

    if [[ -n "$raw" ]]; then
      status="ok"
      echo "$raw" | python3 -c "
import sys, json
try:
  d = json.load(sys.stdin).get('MediaContainer', {})
  size = int(d.get('size', 0))
  if size == 0:
    print(json.dumps({'label': 'idle', 'status': 'ok', 'playing': False}))
  else:
    items = d.get('Metadata', [])
    item = items[0] if items else {}
    title  = item.get('title', '')
    album  = item.get('parentTitle', '')
    artist = item.get('grandparentTitle', '')
    stream_str = f'{size} stream' + ('s' if size != 1 else '')
    label = f'{stream_str} · {title}' if title else stream_str
    print(json.dumps({
      'label': label, 'status': 'ok', 'playing': True,
      'title': title, 'album': album, 'artist': artist,
    }))
except:
  print(json.dumps({'label': 'idle', 'status': 'ok', 'playing': False}))
" 2>/dev/null || echo "{\"label\":\"idle\",\"status\":\"ok\",\"playing\":false}"
      return
    fi
  else
    if curl -sf --max-time 5 "${PLEX_URL}/identity" >/dev/null 2>&1; then
      status="ok"
    fi
  fi
  echo "{\"label\":\"idle\",\"status\":\"${status}\",\"playing\":false}"
}

# ── Lidarr: artist count ──────────────────────────────────────────────────────
build_lidarr() {
  local raw
  raw=$(curl -sf --max-time 5 \
    -H "X-Api-Key: ${LIDARR_API_KEY}" \
    "${LIDARR_URL}/api/v1/artist" 2>/dev/null || echo "")

  local count="—" status="unknown"
  if [[ -n "$raw" ]]; then
    count=$(echo "$raw" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo "—")
    status="ok"
  fi
  echo "{\"label\":\"Lidarr: ${count} artists\",\"status\":\"${status}\"}"
}

# ── Navidrome: now playing via Subsonic API ───────────────────────────────────
# Requires NAVIDROME_USER + NAVIDROME_PASS env vars for Subsonic auth.
# Falls back to idle if creds not set or endpoint unreachable.
build_navidrome() {
  local user="${NAVIDROME_USER:-}" pass="${NAVIDROME_PASS:-}"

  if [[ -n "$user" && -n "$pass" ]]; then
    # Use token auth: salt + md5(password+salt) — more reliable than plaintext
    local salt raw
    salt=$(python3 -c "import random,string; print(''.join(random.choices(string.ascii_lowercase+string.digits,k=8)))")
    local token
    token=$(python3 -c "import hashlib; print(hashlib.md5('${pass}${salt}'.encode()).hexdigest())")
    raw=$(curl -sf --max-time 5 \
      "${NAVIDROME_URL}/rest/getNowPlaying.view?u=${user}&t=${token}&s=${salt}&v=1.16.1&c=homelab&f=json" \
      2>/dev/null || echo "")
    if [[ -n "$raw" ]]; then
      echo "$raw" | python3 -c "
import sys, json
nd_url = '${NAVIDROME_URL}'
nd_user = '${user}'
nd_token = '${token}'
nd_salt = '${salt}'
try:
  entries = json.load(sys.stdin).get('subsonic-response', {}) \
              .get('nowPlaying', {}).get('entry', [])
  count = len(entries)
  if count == 0:
    print(json.dumps({'label': 'idle', 'status': 'ok', 'playing': False}))
  else:
    e = entries[0]
    title    = e.get('title', '')
    album    = e.get('album', '')
    artist   = e.get('artist', '')
    cover_id = e.get('coverArt', '')
    cover_url = f'{nd_url}/rest/getCoverArt.view?u={nd_user}&t={nd_token}&s={nd_salt}&v=1.16.1&c=homelab&id={cover_id}&size=300' if cover_id else ''
    playing_str = f'{count} playing'
    label = f'{playing_str} · {title}' if title else playing_str
    print(json.dumps({
      'label': label, 'status': 'ok', 'playing': True,
      'title': title, 'album': album, 'artist': artist,
      'coverUrl': cover_url,
    }))
except:
  print(json.dumps({'label': 'idle', 'status': 'ok', 'playing': False}))
" 2>/dev/null || echo "{\"label\":\"idle\",\"status\":\"ok\",\"playing\":false}"
      return
    fi
  else
    if curl -sf --max-time 5 "${NAVIDROME_URL}/ping" >/dev/null 2>&1; then
      echo "{\"label\":\"idle\",\"status\":\"ok\",\"playing\":false}"
      return
    fi
  fi
  echo "{\"label\":\"idle\",\"status\":\"unknown\",\"playing\":false}"
}

# ── Vaultwarden: online check ─────────────────────────────────────────────────
build_vaultwarden() {
  local label="offline" status="crit"
  if curl -sf --max-time 5 "${VAULTWARDEN_URL}/alive" >/dev/null 2>&1; then
    label="online"; status="ok"
  fi
  echo "{\"label\":\"${label}\",\"status\":\"${status}\"}"
}

# ── Nextcloud: online check ───────────────────────────────────────────────────
build_nextcloud() {
  local label="offline" status="crit"
  if curl -sf --max-time 5 "${NEXTCLOUD_URL}/status.php" >/dev/null 2>&1; then
    label="online"; status="ok"
  fi
  echo "{\"label\":\"${label}\",\"status\":\"${status}\"}"
}

# ── Immich: online check ──────────────────────────────────────────────────────
build_immich() {
  local label="offline" status="crit"
  if curl -sf --max-time 5 "${IMMICH_URL}/api/server/ping" >/dev/null 2>&1; then
    label="online"; status="ok"
  fi
  echo "{\"label\":\"${label}\",\"status\":\"${status}\"}"
}

# ── Service status via Uptime Kuma + enriched sub-labels ──────────────────────
# Uptime Kuma status page slug: "homelab" — adjust if yours differs
build_services() {
  local uk_raw
  uk_raw=$(curl -sf --max-time 5 \
    "${UPTIME_KUMA_URL}/api/status-page/heartbeat/homelab" 2>/dev/null || echo "")

  # Fetch enriched sub-labels from individual service APIs
  local sonarr radarr sabnzbd plex lidarr navidrome nextcloud immich
  sonarr=$(build_sonarr)
  radarr=$(build_radarr)
  sabnzbd=$(build_sabnzbd)
  plex=$(build_plex)
  lidarr=$(build_lidarr)
  navidrome=$(build_navidrome)
  nextcloud=$(build_nextcloud)
  immich=$(build_immich)

  local tmp_svc
  tmp_svc=$(mktemp)
  python3 -c "import json,sys; print(json.dumps({
    'uk':        sys.argv[1],
    'sonarr':    json.loads(sys.argv[2]),
    'radarr':    json.loads(sys.argv[3]),
    'sabnzbd':   json.loads(sys.argv[4]),
    'plex':      json.loads(sys.argv[5]),
    'lidarr':    json.loads(sys.argv[6]),
    'navidrome': json.loads(sys.argv[7]),
    'nextcloud': json.loads(sys.argv[8]),
    'immich':    json.loads(sys.argv[9]),
  }))" \
    "$uk_raw" "$sonarr" "$radarr" "$sabnzbd" "$plex" \
    "$lidarr" "$navidrome" "$nextcloud" "$immich" > "$tmp_svc"

  python3 - "$tmp_svc" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
  d = json.load(f)

uk_raw    = d['uk']
sonarr    = d['sonarr']
radarr    = d['radarr']
sabnzbd   = d['sabnzbd']
plex_d    = d['plex']
lidarr    = d['lidarr']
navidrome = d['navidrome']
nextcloud = d['nextcloud']
immich    = d['immich']

# Ticker services — media/download stack only, no Plex/Navidrome (they get cards)
# All tags prefixed "Name: value" for readability
def tag(name, label): return f'{name}: {label}'

SERVICES = [
  {'name': 'Immich',    'tag': tag('Immich',    immich['label']),    'status_override': immich['status']},
  {'name': 'Nextcloud', 'tag': tag('Nextcloud', nextcloud['label']), 'status_override': nextcloud['status']},
  {'name': 'SABnzbd',   'tag': tag('SABnzbd',   sabnzbd['label']),   'status_override': sabnzbd['status']},
  {'name': 'Sonarr',    'tag': sonarr['label'],                      'status_override': sonarr['status']},
  {'name': 'Radarr',    'tag': radarr['label'],                      'status_override': radarr['status']},
  {'name': 'Lidarr',    'tag': lidarr['label'],                      'status_override': lidarr['status']},
]

status_map = {}
try:
  uk = json.loads(uk_raw)
  for monitor_id, beats in uk.get('heartbeatList', {}).items():
    if not beats: continue
    latest = beats[-1]
    s = latest.get('status')
    name_key = latest.get('name', '').lower()
    if s == 1:   status_map[name_key] = 'ok'
    elif s == 0: status_map[name_key] = 'crit'
    else:        status_map[name_key] = 'warn'
except Exception:
  pass

result = []
for svc in SERVICES:
  status = svc.get('status_override') or status_map.get(svc['name'].lower(), 'unknown')
  result.append({'name': svc['name'], 'tag': svc['tag'], 'status': status})

# Media player cards — separate from ticker, shown as status cards
def media_card(name, d):
  card = {'name': name, 'label': d.get('label', 'idle'), 'status': d.get('status', 'unknown'), 'playing': d.get('playing', False)}
  for k in ('title', 'album', 'artist', 'coverUrl'):
    if d.get(k): card[k] = d[k]
  return card

media = [
  media_card('Plex',      plex_d),
  media_card('Navidrome', navidrome),
]

print(json.dumps({'services': result, 'media': media}))
PYEOF
  rm -f "$tmp_svc"
}

# ── Assemble live cards ────────────────────────────────────────────────────────
NODES=$(build_nodes)
FLUX=$(build_flux)
BACKUP=$(build_backup)
VELERO=$(build_velero)
SERVICES=$(build_services)

FLUX_STATUS=$(echo "$FLUX" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'])")
FLUX_LABEL=$(echo "$FLUX" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{d['ready']}/{d['total']} synced\")")
FLUX_SYNC=$(echo "$FLUX" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['last_sync'])")

BRONN_BACKUP_AGE=$(echo    "$BACKUP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['bronn']['age'])")
BRONN_BACKUP_STATUS=$(echo "$BACKUP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['bronn']['status'])")
ETCD_BACKUP_AGE=$(echo     "$BACKUP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['etcd']['age'])")
ETCD_BACKUP_STATUS=$(echo  "$BACKUP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['etcd']['status'])")

VELERO_AGE=$(echo    "$VELERO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['age'])")
VELERO_STATUS=$(echo "$VELERO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'])")

# Count running k8s workloads
RUNNING_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c "Running" || echo "0")
TOTAL_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")

# Write JSON via temp files to avoid shell quoting issues
TMP_NODES=$(mktemp); TMP_FLUX=$(mktemp); TMP_SVC_DATA=$(mktemp)
echo "$NODES"    > "$TMP_NODES"
echo "$FLUX"     > "$TMP_FLUX"
echo "$SERVICES" > "$TMP_SVC_DATA"

python3 - "$TMP_NODES" "$TMP_FLUX" "$TMP_SVC_DATA" <<PYEOF
import json, sys

with open(sys.argv[1]) as f: nodes    = json.load(f)
with open(sys.argv[2]) as f: flux     = json.load(f)
with open(sys.argv[3]) as f: svc_data = json.load(f)

running = int('${RUNNING_PODS}')
total   = int('${TOTAL_PODS}')

data = {
  'updated': '${NOW}',
  'cards': [
    {'label': 'Workloads',      'value': f'{running}/{total}',   'sub': 'pods running',       'status': 'ok' if running == total else 'warn'},
    {'label': 'Flux',           'value': '${FLUX_LABEL}',        'sub': '${FLUX_SYNC}',       'status': '${FLUX_STATUS}'},
    {'label': 'Docker Appdata', 'value': '${BRONN_BACKUP_AGE}',  'sub': 'last backup',        'status': '${BRONN_BACKUP_STATUS}'},
    {'label': 'etcd Snapshot',  'value': '${ETCD_BACKUP_AGE}',   'sub': 'last snapshot',      'status': '${ETCD_BACKUP_STATUS}'},
    {'label': 'Velero',         'value': '${VELERO_AGE}',        'sub': 'last cluster backup','status': '${VELERO_STATUS}'},
  ],
  'nodes':    nodes,
  'flux':     flux,
  'services': svc_data['services'],
  'media':    svc_data['media'],
}
print(json.dumps(data, indent=2))
PYEOF

rm -f "$TMP_NODES" "$TMP_FLUX" "$TMP_SVC_DATA"
