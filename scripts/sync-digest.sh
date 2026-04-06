#!/usr/bin/env bash
# =============================================================================
# sync-digest.sh — Build digest.json from homelab-infrastructure ops-log
#
# Reads all ops-log markdown files, extracts metadata from the header,
# and writes a JSON index to public/data/digest.json.
#
# Run from the kagiso-me.github.io repo root.
# Expects homelab-infrastructure to be checked out at ../homelab-infrastructure
# =============================================================================

set -euo pipefail

OPS_LOG_DIR="${1:-../homelab-infrastructure/docs/ops-log}"
OUTPUT="public/data/digest.json"

python3 - <<'PYEOF'
import os, sys, re, json

ops_log_dir = sys.argv[1] if len(sys.argv) > 1 else "../homelab-infrastructure/docs/ops-log"

entries = []

for fname in sorted(os.listdir(ops_log_dir), reverse=True):
    if not fname.endswith(".md") or fname in ("README.md", "template.md"):
        continue

    fpath = os.path.join(ops_log_dir, fname)
    with open(fpath) as f:
        content = f.read()

    # Extract date from filename: YYYY-MM-DD-slug.md
    m = re.match(r"(\d{4}-\d{2}-\d{2})-(.+)\.md", fname)
    if not m:
        continue
    date, slug = m.group(1), fname[:-3]

    # Extract title from first H1
    title_m = re.search(r"^#\s+\d{4}-\d{2}-\d{2}\s+[—–-]+\s+(.+)$", content, re.MULTILINE)
    title = title_m.group(1).strip() if title_m else slug.replace("-", " ").title()

    # Extract type
    type_m = re.search(r"\*\*Type:\*\*\s+`([^`]+)`", content)
    tag = type_m.group(1) if type_m else "OPS"

    # Extract components
    comp_m = re.search(r"\*\*Components:\*\*\s+(.+)$", content, re.MULTILINE)
    components = comp_m.group(1).strip() if comp_m else ""

    # Extract first paragraph after the header block as excerpt
    lines = content.split("\n")
    excerpt = ""
    in_header = True
    for line in lines:
        if in_header and line.startswith("**") and ":**" in line:
            continue
        if in_header and line.startswith("#"):
            continue
        if in_header and line.strip() == "":
            if excerpt:
                in_header = False
            continue
        if not in_header and line.strip() and not line.startswith("#") and not line.startswith("**"):
            excerpt = line.strip()[:200]
            break

    entries.append({
        "slug": slug,
        "date": date,
        "title": title,
        "tag": tag,
        "components": components,
        "excerpt": excerpt,
    })

with open("public/data/digest.json", "w") as f:
    json.dump(entries, f, indent=2)

print(f"Written {len(entries)} entries to public/data/digest.json")
PYEOF
