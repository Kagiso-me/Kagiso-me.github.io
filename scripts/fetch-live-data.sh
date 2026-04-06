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

# Prometheus ClusterIP — reachable from varys via k3s cluster network
# TODO: replace with internal DNS name once USG DNS records are configured
PROM="http://10.43.248.50:9090"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── Helper: query Prometheus instant ──────────────────────────────────────────
prom_query() {
  local query="$1"
  curl -sf --max-time 5 \
    "${PROM}/api/v1/query" \
    --data-urlencode "query=${query}" \
    2>/dev/null || echo '{"data":{"result":[]}}'
}

prom_value() {
  local query="$1"
  local default="${2:---}"
  local result
  result=$(prom_query "$query")
  echo "$result" | python3 -c "
import sys, json
try:
  d = json.load(sys.stdin)
  r = d['data']['result']
  print(r[0]['value'][1] if r else '${default}')
except:
  print('${default}')
"
}

# ── Nodes ─────────────────────────────────────────────────────────────────────
build_nodes() {
  local nodes=("tywin:control-plane:10.0.10.11" "tyrion:worker:10.0.10.12" "jaime:worker:10.0.10.13")
  local result="["
  local sep=""

  for entry in "${nodes[@]}"; do
    IFS=':' read -r name role ip <<< "$entry"

    # Node ready status from kubectl
    local kube_status
    kube_status=$(kubectl get node "$name" --no-headers 2>/dev/null | awk '{print $2}' || echo "Unknown")
    local status="crit"
    [[ "$kube_status" == "Ready" ]] && status="ok"

    # CPU usage % (1 - idle)
    local cpu
    cpu=$(prom_value "round((1 - avg(rate(node_cpu_seconds_total{instance=\"${ip}:9100\",mode=\"idle\"}[2m]))) * 100, 0.1)")
    [[ "$cpu" == "--" ]] && cpu="—" || cpu="${cpu}%"

    # Memory usage %
    local mem
    mem=$(prom_value "round((1 - node_memory_MemAvailable_bytes{instance=\"${ip}:9100\"} / node_memory_MemTotal_bytes{instance=\"${ip}:9100\"}) * 100, 0.1)")
    [[ "$mem" == "--" ]] && mem="—" || mem="${mem}%"

    # Uptime
    local uptime_sec
    uptime_sec=$(prom_value "node_time_seconds{instance=\"${ip}:9100\"} - node_boot_time_seconds{instance=\"${ip}:9100\"}")
    local uptime_str="—"
    if [[ "$uptime_sec" != "--" && "$uptime_sec" != "—" ]]; then
      uptime_str=$(python3 -c "
s=int(float('${uptime_sec}'))
d,s=divmod(s,86400); h,s=divmod(s,3600); m,_=divmod(s,60)
print(f'{d}d {h}h' if d else f'{h}h {m}m')
")
    fi

    result="${result}${sep}{\"name\":\"${name}\",\"role\":\"${role}\",\"status\":\"${status}\",\"cpu\":\"${cpu}\",\"memory\":\"${mem}\",\"uptime\":\"${uptime_str}\"}"
    sep=","
  done

  echo "${result}]"
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

# ── Backup status ─────────────────────────────────────────────────────────────
build_backup() {
  local last_ts
  last_ts=$(prom_value "backup_last_success_timestamp{exported_job=\"docker-appdata\"}")
  local age_str="—"
  local status="unknown"

  if [[ "$last_ts" != "--" && "$last_ts" != "—" ]]; then
    age_str=$(python3 -c "
import time
age=time.time()-float('${last_ts}')
h=int(age//3600); m=int((age%3600)//60)
print(f'{h}h {m}m ago' if h else f'{m}m ago')
")
    local age_hours
    age_hours=$(python3 -c "print(int(($(date +%s) - int(float('${last_ts}'))) / 3600))")
    status="ok"
    [[ "$age_hours" -gt 25 ]] && status="warn"
    [[ "$age_hours" -gt 48 ]] && status="crit"
  fi

  echo "{\"age\":\"${age_str}\",\"status\":\"${status}\"}"
}

# ── Velero last backup ─────────────────────────────────────────────────────────
build_velero() {
  local last_backup
  last_backup=$(kubectl get backups -n velero --sort-by=.metadata.creationTimestamp --no-headers 2>/dev/null | tail -1 | awk '{print $1, $2}' || echo "— —")
  local name status_str
  name=$(echo "$last_backup" | awk '{print $1}')
  status_str=$(echo "$last_backup" | awk '{print $2}')
  local status="unknown"
  [[ "$status_str" == "Completed" ]] && status="ok"
  [[ "$status_str" == "Failed" ]]    && status="crit"
  [[ "$status_str" == "PartiallyFailed" ]] && status="warn"

  echo "{\"name\":\"${name}\",\"result\":\"${status_str}\",\"status\":\"${status}\"}"
}

# =============================================================================
# Service endpoints
# TODO: replace IPs with internal DNS names once USG DNS records are configured
#   e.g. sonarr.home, radarr.home, sabnzbd.home, plex.home
# =============================================================================
DOCKER_HOST="10.0.10.20"          # Docker host — all media stack services
SONARR_URL="http://${DOCKER_HOST}:8989"
RADARR_URL="http://${DOCKER_HOST}:7878"
SABNZBD_URL="http://${DOCKER_HOST}:8085"
PLEX_URL="http://${DOCKER_HOST}:32400"
UPTIME_KUMA_URL="http://${DOCKER_HOST}:3001"
# API keys injected as environment variables from GitHub Actions secrets
# Set locally on varys via ~/.bashrc if running the script manually:
#   export SONARR_API_KEY=...
#   export RADARR_API_KEY=...
#   export SABNZBD_API_KEY=...
: "${SONARR_API_KEY:?SONARR_API_KEY env var not set}"
: "${RADARR_API_KEY:?RADARR_API_KEY env var not set}"
: "${SABNZBD_API_KEY:?SABNZBD_API_KEY env var not set}"

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

# ── Service status via Uptime Kuma + enriched sub-labels ──────────────────────
# Uptime Kuma status page slug: "homelab" — adjust if yours differs
build_services() {
  local uk_raw
  uk_raw=$(curl -sf --max-time 5 \
    "${UPTIME_KUMA_URL}/api/status-page/heartbeat/homelab" 2>/dev/null || echo "")

  # Fetch enriched sub-labels from individual service APIs
  local sonarr radarr sabnzbd plex
  sonarr=$(build_sonarr)
  radarr=$(build_radarr)
  sabnzbd=$(build_sabnzbd)
  plex=$(build_plex)

  python3 -c "
import sys, json

uk_raw   = '''${uk_raw}'''
sonarr   = json.loads('''${sonarr}''')
radarr   = json.loads('''${radarr}''')
sabnzbd  = json.loads('''${sabnzbd}''')
plex_d   = json.loads('''${plex}''')

# Base service list: name, ticker tag, optional override label + status
SERVICES = [
  # k3s
  {'name': 'Vaultwarden', 'tag': 'k3s · passwords'},
  {'name': 'Immich',      'tag': 'k3s · photos'},
  {'name': 'Nextcloud',   'tag': 'k3s · files'},
  # Docker — media
  {'name': 'Plex',        'tag': f'docker · {plex_d[\"label\"]}',  'status_override': plex_d['status']},
  {'name': 'SABnzbd',     'tag': f'docker · {sabnzbd[\"label\"]}', 'status_override': sabnzbd['status']},
  {'name': 'Sonarr',      'tag': f'docker · {sonarr[\"label\"]}',  'status_override': sonarr['status']},
  {'name': 'Radarr',      'tag': f'docker · {radarr[\"label\"]}',  'status_override': radarr['status']},
  {'name': 'Lidarr',      'tag': 'docker · music'},
  {'name': 'Navidrome',   'tag': 'docker · music streaming'},
  # Docker — platform
  {'name': 'Uptime Kuma', 'tag': 'docker · monitoring'},
  {'name': 'NPM',         'tag': 'docker · proxy'},
]

# Build status map from Uptime Kuma heartbeats
status_map = {}
try:
  d = json.loads(uk_raw)
  for monitor_id, beats in d.get('heartbeatList', {}).items():
    if not beats:
      continue
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
  # status_override (from direct API) takes priority over Uptime Kuma
  status = svc.get('status_override') or status_map.get(svc['name'].lower(), 'unknown')
  result.append({'name': svc['name'], 'tag': svc['tag'], 'status': status})

print(json.dumps(result))
"
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

BACKUP_AGE=$(echo "$BACKUP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['age'])")
BACKUP_STATUS=$(echo "$BACKUP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'])")

VELERO_RESULT=$(echo "$VELERO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result'])")
VELERO_STATUS=$(echo "$VELERO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'])")

# Count running k8s workloads
RUNNING_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c "Running" || echo "0")
TOTAL_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")

python3 -c "
import json
data = {
  'updated': '${NOW}',
  'cards': [
    {
      'label': 'Workloads',
      'value': '${RUNNING_PODS}/${TOTAL_PODS}',
      'sub': 'pods running',
      'status': 'ok' if '${RUNNING_PODS}' == '${TOTAL_PODS}' else 'warn'
    },
    {
      'label': 'Flux',
      'value': '${FLUX_LABEL}',
      'sub': '${FLUX_SYNC}',
      'status': '${FLUX_STATUS}'
    },
    {
      'label': 'Last Backup',
      'value': '${BACKUP_AGE}',
      'sub': 'docker appdata',
      'status': '${BACKUP_STATUS}'
    },
    {
      'label': 'Velero',
      'value': '${VELERO_RESULT}',
      'sub': 'last cluster backup',
      'status': '${VELERO_STATUS}'
    }
  ],
  'nodes': json.loads('${NODES}'),
  'flux': json.loads('${FLUX}'),
  'services': json.loads('${SERVICES}')
}
print(json.dumps(data, indent=2))
"
