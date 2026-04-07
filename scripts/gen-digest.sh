#!/usr/bin/env bash
# =============================================================================
# gen-digest.sh — Generate public/data/digest.json from homelab-infrastructure
#
# Sources:
#   CHANGELOG.md       — structured list of all changes (one-liners + rich entries)
#   docs/ops-log/*.md  — full write-ups for significant entries
#
# Output: public/data/digest.json
#   Each entry: { slug, date, type, title, summary, tags, commit, hasDetail, body? }
# =============================================================================
set -euo pipefail

INFRA_DIR="${INFRA_DIR:-/home/kagiso/homelab-infrastructure}"
OUT="public/data/digest.json"
CHANGELOG="$INFRA_DIR/CHANGELOG.md"
OPS_LOG_DIR="$INFRA_DIR/docs/ops-log"

if [[ ! -f "$CHANGELOG" ]]; then
  echo "[]" > "$OUT"
  exit 0
fi

python3 - "$CHANGELOG" "$OPS_LOG_DIR" <<'PYEOF'
import sys, json, re, os
from pathlib import Path
from datetime import datetime

changelog_path = sys.argv[1]
ops_log_dir    = sys.argv[2]

# ── Build ops-log index: slug → full markdown body ───────────────────────────
ops_log = {}
if os.path.isdir(ops_log_dir):
    for f in sorted(Path(ops_log_dir).glob("*.md")):
        name = f.stem
        # skip non-entry files
        if name in ('README', 'template'):
            continue
        text = f.read_text()
        # Extract metadata from frontmatter-style header lines
        slug = name  # e.g. 2026-03-22-promotion-pipeline-and-prod-grafana
        ops_log[slug] = text

# ── Parse CHANGELOG.md ───────────────────────────────────────────────────────
text = Path(changelog_path).read_text()
lines = text.splitlines()

current_month = None
entries = []

# Regex for a changelog entry line
# e.g. - **[DEPLOY]** some description → [details](docs/ops-log/slug.md) `abc1234`
ENTRY_RE = re.compile(
    r'^\s*-\s+\*\*\[([A-Z]+)\]\*\*\s+(.*?)(?:\s+`([a-f0-9]{7,})`)?$'
)
MONTH_RE = re.compile(r'^##\s+(\d{4}-\d{2})$')
DETAIL_RE = re.compile(r'→\s*\[details?\]\(docs/ops-log/([^)]+?)\.md\)')
COMMIT_RE = re.compile(r'`([a-f0-9]{7,})`')

for line in lines:
    m = MONTH_RE.match(line)
    if m:
        current_month = m.group(1)
        continue

    m = ENTRY_RE.match(line)
    if m and current_month:
        etype   = m.group(1).upper()
        desc    = m.group(2).strip()
        commit  = m.group(3) or ''

        # Extract ops-log slug if present
        detail_m = DETAIL_RE.search(desc)
        ops_slug = None
        if detail_m:
            # slug is the filename stem e.g. 2026-03-22-promotion-pipeline-and-prod-grafana
            ops_slug = Path(detail_m.group(1)).stem
            # Clean the → [details](...) part from the description
            desc = DETAIL_RE.sub('', desc).strip().rstrip('—').strip()

        # Extract commit hash that may be inline in desc (not captured by main RE)
        if not commit:
            cm = COMMIT_RE.search(desc)
            if cm:
                commit = cm.group(1)
                desc = COMMIT_RE.sub('', desc).strip()

        # Clean trailing punctuation
        desc = desc.rstrip(' .-→').strip()

        # Derive slug: use ops-log slug if available, else generate from date+title
        if ops_slug:
            slug = ops_slug
            # Extract date from ops slug prefix
            date_m = re.match(r'^(\d{4}-\d{2}-\d{2})', ops_slug)
            date = date_m.group(1) if date_m else current_month
        else:
            # Generate slug from month + sanitised title
            safe = re.sub(r'[^a-z0-9]+', '-', desc.lower())[:60].strip('-')
            slug = f"{current_month}-{safe}"
            date = current_month

        # Summary: first sentence of description
        summary = desc.split('—')[0].strip() if '—' in desc else desc

        # Tags: type + keywords extracted from components/description
        tags = [etype]

        # Read ops-log body if available
        body = None
        has_detail = False
        if ops_slug and ops_slug in ops_log:
            body = ops_log[ops_slug]
            has_detail = True

        # Only surface meaningful types — skip noisy CONFIG/MAINTENANCE one-liners
        # unless they have a full ops-log write-up
        SURFACE_TYPES = {'DEPLOY', 'INCIDENT', 'HARDWARE', 'FIX', 'SECURITY', 'NETWORK', 'SCALE'}
        if etype not in SURFACE_TYPES and not has_detail:
            continue

        entry = {
            'slug':      slug,
            'date':      date,
            'type':      etype,
            'title':     desc,
            'summary':   summary,
            'commit':    commit,
            'hasDetail': has_detail,
            'tags':      tags,
        }
        if body:
            entry['body'] = body

        entries.append(entry)

# Sort newest first
entries.sort(key=lambda e: e['date'], reverse=True)

# Deduplicate by slug (ops-log entries may appear in multiple months)
seen = set()
deduped = []
for e in entries:
    if e['slug'] not in seen:
        seen.add(e['slug'])
        deduped.append(e)

print(json.dumps(deduped, indent=2))
PYEOF
