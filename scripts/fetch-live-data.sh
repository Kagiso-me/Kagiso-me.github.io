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

PROM="http://10.0.10.20:9090"
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

  local ready_count total_count last_sync status
  ready_count=$(echo "$ks_raw" | grep -c "True" || echo "0")
  total_count=$(echo "$ks_raw"  | grep -c . || echo "0")
  last_sync=$(echo "$ks_raw"    | awk '{print $5}' | head -1 || echo "—")
  status="ok"
  [[ "$ready_count" != "$total_count" ]] && status="warn"

  # Build kustomizations array
  local ks_json
  ks_json=$(echo "$ks_raw" | python3 -c "
import sys, json
rows = []
for line in sys.stdin:
    parts = line.split()
    if len(parts) >= 5:
        rows.append({
            'namespace': parts[0],
            'name':      parts[1],
            'ready':     parts[2] == 'True',
            'age':       parts[4] if len(parts) > 4 else '—'
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

# ── SABnzbd ───────────────────────────────────────────────────────────────────
build_sabnzbd() {
  local api_key
  api_key=$(grep "^api_key" /dev/null 2>/dev/null || echo "")
  # Check if SABnzbd is reachable
  local speed="—"
  local queue="—"
  local status="unknown"

  local sabnzbd_status
  sabnzbd_status=$(curl -sf --max-time 3 "http://10.0.10.20:8085/api?mode=queue&output=json&limit=1" 2>/dev/null || echo "")

  if [[ -n "$sabnzbd_status" ]]; then
    speed=$(echo "$sabnzbd_status" | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  print(d['queue']['speed'] or '0 B/s')
except: print('—')
")
    queue=$(echo "$sabnzbd_status" | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  print(d['queue']['noofslots'])
except: print('—')
")
    status="ok"
  fi

  echo "{\"speed\":\"${speed}\",\"queue\":\"${queue}\",\"status\":\"${status}\"}"
}

# ── Assemble live cards ────────────────────────────────────────────────────────
NODES=$(build_nodes)
FLUX=$(build_flux)
BACKUP=$(build_backup)
VELERO=$(build_velero)

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
  'flux': json.loads('${FLUX}')
}
print(json.dumps(data, indent=2))
"
