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
# bronn: SSH-reads textfile metric (backup_docker.sh writes it after each run)
# varys: reads local textfile metric (varys-backup.sh writes it after each run)
build_backup() {
  # bronn — docker appdata
  local bronn_ts
  bronn_ts=$(ssh -o ConnectTimeout=5 -o BatchMode=yes 10.0.10.20 \
    "grep -m1 'backup_last_success_timestamp{job=\"docker-appdata\"}' \
     /var/lib/node_exporter/textfile_collector/docker_backup.prom 2>/dev/null | awk '{print \$2}'" 2>/dev/null || echo "")
  local bronn_json
  bronn_json=$(backup_age_json "$bronn_ts")

  # varys — key material backup (local file, no SSH needed)
  local varys_ts
  varys_ts=$(grep -m1 'backup_last_success_timestamp{job="varys-keys"}' \
    /var/lib/node_exporter/textfile_collector/varys_backup.prom 2>/dev/null | awk '{print $2}' || echo "")
  local varys_json
  varys_json=$(backup_age_json "$varys_ts")

  echo "{\"bronn\":${bronn_json},\"varys\":${varys_json}}"
}

# ── Velero last backup ─────────────────────────────────────────────────────────
build_velero() {
  local last_line name phase status_str status
  last_line=$(kubectl get backups -n velero \
    --sort-by=.metadata.creationTimestamp \
    -o custom-columns="NAME:.metadata.name,PHASE:.status.phase" \
    --no-headers 2>/dev/null | tail -1 || echo "")
  name=$(echo "$last_line"  | awk '{print $1}')
  phase=$(echo "$last_line" | awk '{print $2}')
  status_str="${phase:-—}"
  status="unknown"
  [[ "$phase" == "Completed" ]]       && status="ok"
  [[ "$phase" == "Failed" ]]          && status="crit"
  [[ "$phase" == "PartiallyFailed" ]] && status="warn"

  echo "{\"name\":\"${name}\",\"result\":\"${status_str}\",\"status\":\"${status}\"}"
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
  echo "{\"count\":\"${count}\",\"label\":\"${count} series\",\"status\":\"${status}\"}"
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
  echo "{\"count\":\"${count}\",\"label\":\"${count} movies\",\"status\":\"${status}\"}"
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
  # Plex token stored as env var PLEX_TOKEN on varys, falls back to empty (status unknown)
  local token="${PLEX_TOKEN:-}"
  local label="online"
  local status="unknown"

  if [[ -n "$token" ]]; then
    local raw
    raw=$(curl -sf --max-time 5 \
      -H "X-Plex-Token: ${token}" \
      -H "Accept: application/json" \
      "${PLEX_URL}/status/sessions" 2>/dev/null || echo "")

    if [[ -n "$raw" ]]; then
      status="ok"
      label=$(echo "$raw" | python3 -c "
import sys, json
try:
  d = json.load(sys.stdin)
  size = int(d.get('MediaContainer', {}).get('size', 0))
  print(f'{size} stream{\"s\" if size != 1 else \"\"}')
except:
  print('online')
" 2>/dev/null || echo "online")
    fi
  else
    # No token — just check if Plex responds at all
    if curl -sf --max-time 5 "${PLEX_URL}/identity" >/dev/null 2>&1; then
      status="ok"
      label="online"
    fi
  fi
  echo "{\"label\":\"${label}\",\"status\":\"${status}\"}"
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
  echo "{\"label\":\"${count} artists\",\"status\":\"${status}\"}"
}

# ── Navidrome: now playing / idle ─────────────────────────────────────────────
build_navidrome() {
  local label="idle" status="unknown"
  # Navidrome /rest/getNowPlaying requires auth — check /ping first for online status
  if curl -sf --max-time 5 "${NAVIDROME_URL}/ping" >/dev/null 2>&1; then
    status="ok"
    label="online"
  fi
  echo "{\"label\":\"${label}\",\"status\":\"${status}\"}"
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
  local sonarr radarr sabnzbd plex lidarr navidrome vaultwarden nextcloud immich
  sonarr=$(build_sonarr)
  radarr=$(build_radarr)
  sabnzbd=$(build_sabnzbd)
  plex=$(build_plex)
  lidarr=$(build_lidarr)
  navidrome=$(build_navidrome)
  vaultwarden=$(build_vaultwarden)
  nextcloud=$(build_nextcloud)
  immich=$(build_immich)

  local tmp_svc
  tmp_svc=$(mktemp)
  # Write all service data as a single JSON object to avoid shell quoting issues
  python3 -c "import json,sys; print(json.dumps({
    'uk':          sys.argv[1],
    'sonarr':      json.loads(sys.argv[2]),
    'radarr':      json.loads(sys.argv[3]),
    'sabnzbd':     json.loads(sys.argv[4]),
    'plex':        json.loads(sys.argv[5]),
    'lidarr':      json.loads(sys.argv[6]),
    'navidrome':   json.loads(sys.argv[7]),
    'vaultwarden': json.loads(sys.argv[8]),
    'nextcloud':   json.loads(sys.argv[9]),
    'immich':      json.loads(sys.argv[10]),
  }))" \
    "$uk_raw" "$sonarr" "$radarr" "$sabnzbd" "$plex" \
    "$lidarr" "$navidrome" "$vaultwarden" "$nextcloud" "$immich" > "$tmp_svc"

  python3 - "$tmp_svc" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
  d = json.load(f)

uk_raw      = d['uk']
sonarr      = d['sonarr']
radarr      = d['radarr']
sabnzbd     = d['sabnzbd']
plex_d      = d['plex']
lidarr      = d['lidarr']
navidrome   = d['navidrome']
vaultwarden = d['vaultwarden']
nextcloud   = d['nextcloud']
immich      = d['immich']

SERVICES = [
  {'name': 'Vaultwarden', 'tag': vaultwarden['label'], 'status_override': vaultwarden['status']},
  {'name': 'Immich',      'tag': immich['label'],      'status_override': immich['status']},
  {'name': 'Nextcloud',   'tag': nextcloud['label'],   'status_override': nextcloud['status']},
  {'name': 'Plex',        'tag': plex_d['label'],      'status_override': plex_d['status']},
  {'name': 'SABnzbd',     'tag': sabnzbd['label'],     'status_override': sabnzbd['status']},
  {'name': 'Sonarr',      'tag': sonarr['label'],      'status_override': sonarr['status']},
  {'name': 'Radarr',      'tag': radarr['label'],      'status_override': radarr['status']},
  {'name': 'Lidarr',      'tag': lidarr['label'],      'status_override': lidarr['status']},
  {'name': 'Navidrome',   'tag': navidrome['label'],   'status_override': navidrome['status']},
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

print(json.dumps(result))
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
VARYS_BACKUP_AGE=$(echo    "$BACKUP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['varys']['age'])")
VARYS_BACKUP_STATUS=$(echo "$BACKUP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['varys']['status'])")

VELERO_RESULT=$(echo "$VELERO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result'])")
VELERO_STATUS=$(echo "$VELERO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'])")

# Count running k8s workloads
RUNNING_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c "Running" || echo "0")
TOTAL_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")

# Write JSON via temp files to avoid shell quoting issues
TMP_NODES=$(mktemp); TMP_FLUX=$(mktemp); TMP_SERVICES=$(mktemp)
echo "$NODES"    > "$TMP_NODES"
echo "$FLUX"     > "$TMP_FLUX"
echo "$SERVICES" > "$TMP_SERVICES"

python3 - "$TMP_NODES" "$TMP_FLUX" "$TMP_SERVICES" <<PYEOF
import json, sys

with open(sys.argv[1]) as f: nodes    = json.load(f)
with open(sys.argv[2]) as f: flux     = json.load(f)
with open(sys.argv[3]) as f: services = json.load(f)

running = int('${RUNNING_PODS}')
total   = int('${TOTAL_PODS}')

data = {
  'updated': '${NOW}',
  'cards': [
    {'label': 'Workloads',      'value': f'{running}/{total}',          'sub': 'pods running',       'status': 'ok' if running == total else 'warn'},
    {'label': 'Flux',           'value': '${FLUX_LABEL}',               'sub': '${FLUX_SYNC}',       'status': '${FLUX_STATUS}'},
    {'label': 'Docker Appdata', 'value': '${BRONN_BACKUP_AGE}',         'sub': 'bronn backup',       'status': '${BRONN_BACKUP_STATUS}'},
    {'label': 'Varys Keys',     'value': '${VARYS_BACKUP_AGE}',         'sub': 'varys backup',       'status': '${VARYS_BACKUP_STATUS}'},
    {'label': 'Velero',         'value': '${VELERO_RESULT}',            'sub': 'last cluster backup','status': '${VELERO_STATUS}'},
  ],
  'nodes':    nodes,
  'flux':     flux,
  'services': services,
}
print(json.dumps(data, indent=2))
PYEOF

rm -f "$TMP_NODES" "$TMP_FLUX" "$TMP_SERVICES"
