#!/usr/bin/env python3
"""
fetch-cves.py — Query OSV.dev for CVEs affecting the homelab stack.

Reads:  scripts/stack.json  (component version registry)
Writes: JSON to stdout      → redirect to public/data/cve.json

Discord alerts: set DISCORD_CVE_WEBHOOK env var to post a message when
new CRITICAL or HIGH CVEs are found that weren't in the previous run.
Compare against previous cve.json at PUBLIC_DATA_DIR/cve.json (default: public/data/).
"""

import json
import math
import os
import sys
import urllib.request
import urllib.error
import datetime

SCRIPT_DIR     = os.path.dirname(os.path.abspath(__file__))
STACK_FILE     = os.path.join(SCRIPT_DIR, "stack.json")
OSV_BATCH_URL  = "https://api.osv.dev/v1/querybatch"
DISCORD_WEBHOOK = os.environ.get("DISCORD_CVE_WEBHOOK", "")
PUBLIC_DATA_DIR = os.path.join(SCRIPT_DIR, "..", "public", "data")
PREV_CVE_FILE   = os.path.join(PUBLIC_DATA_DIR, "cve.json")

SEVERITY_ORDER = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3, "UNKNOWN": 4}


def cvss3_score(vector: str) -> float | None:
    """Calculate CVSS v3.x base score from a vector string."""
    try:
        if not vector.startswith("CVSS:3"):
            return None
        parts = dict(p.split(":") for p in vector.split("/")[1:])

        av = {"N": 0.85, "A": 0.62, "L": 0.55, "P": 0.2}[parts["AV"]]
        ac = {"L": 0.77, "H": 0.44}[parts["AC"]]
        s  = parts["S"]
        pr = {"N": 0.85, "L": 0.62 if s == "U" else 0.50, "H": 0.27 if s == "U" else 0.50}[parts["PR"]]
        ui = {"N": 0.85, "R": 0.62}[parts["UI"]]
        ci = {"N": 0.0, "L": 0.22, "H": 0.56}[parts["C"]]
        ii = {"N": 0.0, "L": 0.22, "H": 0.56}[parts["I"]]
        ai = {"N": 0.0, "L": 0.22, "H": 0.56}[parts["A"]]

        exploit  = 8.22 * av * ac * pr * ui
        isc_base = 1 - (1 - ci) * (1 - ii) * (1 - ai)

        if s == "U":
            impact = 6.42 * isc_base
        else:
            impact = 7.52 * (isc_base - 0.029) - 3.25 * (isc_base - 0.02) ** 15

        if impact <= 0:
            return 0.0

        raw = min(impact + exploit, 10)
        return math.ceil(raw * 10) / 10
    except (KeyError, ValueError, IndexError):
        return None


def severity_label(score: float | None, db_specific: dict) -> str:
    # GitHub Advisory DB often has a pre-computed severity string
    ghsa_sev = db_specific.get("severity", "")
    if isinstance(ghsa_sev, str) and ghsa_sev:
        mapping = {"critical": "CRITICAL", "high": "HIGH", "moderate": "MEDIUM", "low": "LOW"}
        label = mapping.get(ghsa_sev.lower())
        if label:
            return label

    if score is None:
        return "UNKNOWN"
    if score >= 9.0:
        return "CRITICAL"
    if score >= 7.0:
        return "HIGH"
    if score >= 4.0:
        return "MEDIUM"
    return "LOW"


def parse_vuln(v: dict) -> dict:
    score = None
    for sev in v.get("severity", []):
        if sev.get("type") in ("CVSS_V3", "CVSS_V3_1"):
            score = cvss3_score(sev.get("score", ""))
            if score is not None:
                break

    db = v.get("database_specific", {})
    sev = severity_label(score, db)

    aliases = v.get("aliases", [])
    cve_id  = next((a for a in aliases if a.startswith("CVE-")), v.get("id", ""))

    refs = [r["url"] for r in v.get("references", []) if r.get("url")][:3]

    return {
        "id":        v.get("id", ""),
        "aliases":   aliases,
        "cve_id":    cve_id,
        "summary":   v.get("summary", "No summary available."),
        "severity":  sev,
        "cvss":      score,
        "published": v.get("published", ""),
        "modified":  v.get("modified", ""),
        "refs":      refs,
    }



def send_discord_alert(all_vulns: list, total_counts: dict) -> None:
    print(f"Discord: webhook set={bool(DISCORD_WEBHOOK)}, vulns={len(all_vulns)}", file=sys.stderr)
    if not DISCORD_WEBHOOK:
        print("Discord: no webhook URL, skipping.", file=sys.stderr)
        return
    if not all_vulns:
        print("Discord: no vulns, skipping.", file=sys.stderr)
        return

    crit = [v for v in all_vulns if v["severity"] == "CRITICAL"]
    high = [v for v in all_vulns if v["severity"] == "HIGH"]

    if not crit and not high:
        return

    lines = []
    lines.append(f"🚨 **Homelab CVE digest — {len(crit)} CRITICAL, {len(high)} HIGH**\n")

    if crit:
        lines.append(f"**CRITICAL ({len(crit)})**")
        for v in crit[:5]:
            ref = v["refs"][0] if v["refs"] else ""
            score_str = f" · CVSS {v['cvss']}" if v["cvss"] else ""
            lines.append(f"• `{v['cve_id'] or v['id']}` **{v['component']}** {v['component_version']}{score_str}")
            lines.append(f"  {v['summary'][:120]}")
            if ref:
                lines.append(f"  <{ref}>")

    if high:
        lines.append(f"\n**HIGH ({len(high)})**")
        for v in high[:5]:
            ref = v["refs"][0] if v["refs"] else ""
            score_str = f" · CVSS {v['cvss']}" if v["cvss"] else ""
            lines.append(f"• `{v['cve_id'] or v['id']}` **{v['component']}** {v['component_version']}{score_str}")
            lines.append(f"  {v['summary'][:120]}")
            if ref:
                lines.append(f"  <{ref}>")

    total_new = len(crit) + len(high)
    lines.append(f"\n[View all CVEs on kagiso.me/security](https://kagiso.me/security)")

    content = "\n".join(lines)
    if len(content) > 1900:
        content = content[:1900] + "\n…"

    payload = json.dumps({"content": content, "username": "homelab-cve-bot"}).encode()
    req = urllib.request.Request(
        DISCORD_WEBHOOK,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=10)
        print(f"Discord alert sent for {total_new} new CRITICAL/HIGH CVEs.", file=sys.stderr)
    except Exception as e:
        print(f"Discord alert failed: {e}", file=sys.stderr)


def main():
    with open(STACK_FILE) as f:
        stack = json.load(f)
    components = stack["components"]

    queries = [
        {"version": c["version"], "package": {"name": c["package"], "ecosystem": c["ecosystem"]}}
        for c in components
    ]

    payload = json.dumps({"queries": queries}).encode()
    req = urllib.request.Request(
        OSV_BATCH_URL,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "User-Agent": "homelab-cve-fetch/1.0 (github.com/kagiso-me/homelab-infrastructure)",
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            osv_resp = json.loads(r.read())
    except urllib.error.HTTPError as e:
        print(f"OSV API error {e.code}: {e.read().decode()}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"OSV request failed: {e}", file=sys.stderr)
        sys.exit(1)

    results = osv_resp.get("results", [])

    # Collect unique vuln IDs with their associated component(s)
    id_to_comps: dict[str, list] = {}
    for i, result in enumerate(results):
        comp = components[i]
        for v in result.get("vulns", []):
            vid = v.get("id", "")
            if vid:
                id_to_comps.setdefault(vid, []).append(comp)

    # Fetch full vuln details for each ID
    all_vulns: list[dict] = []
    for vid, comps in id_to_comps.items():
        try:
            req = urllib.request.Request(
                f"https://api.osv.dev/v1/vulns/{vid}",
                headers={"User-Agent": "homelab-cve-fetch/1.0"},
            )
            with urllib.request.urlopen(req, timeout=15) as r:
                v = json.loads(r.read())
        except Exception as e:
            print(f"Failed to fetch {vid}: {e}", file=sys.stderr)
            continue

        parsed = parse_vuln(v)
        # Associate with the first matched component (most specific match)
        comp = comps[0]
        parsed["component"]         = comp["display"]
        parsed["component_version"] = comp["version"]
        all_vulns.append(parsed)

    # Deduplicate: GO-* entries are often lower-quality duplicates of GHSA-* entries.
    # If a vuln's aliases include an ID already present with known severity, drop it.
    seen_ids: set[str] = set()
    deduped: list[dict] = []

    # First pass: collect all known IDs from entries that have severity data
    for v in all_vulns:
        if v["severity"] != "UNKNOWN":
            seen_ids.add(v["id"])
            seen_ids.update(v.get("aliases", []))

    # Second pass: keep UNKNOWN entries only if none of their aliases are already seen
    for v in all_vulns:
        if v["severity"] != "UNKNOWN":
            deduped.append(v)
        elif v["id"] not in seen_ids and not any(a in seen_ids for a in v.get("aliases", [])):
            deduped.append(v)

    all_vulns = deduped
    all_vulns.sort(key=lambda x: (SEVERITY_ORDER.get(x["severity"], 4), -(x["cvss"] or 0)))

    counts: dict[str, int] = {"CRITICAL": 0, "HIGH": 0, "MEDIUM": 0, "LOW": 0, "UNKNOWN": 0}
    for v in all_vulns:
        counts[v["severity"]] = counts.get(v["severity"], 0) + 1

    if   counts["CRITICAL"] > 0: status = "crit"
    elif counts["HIGH"]     > 0: status = "warn"
    elif counts["MEDIUM"]   > 0: status = "warn"
    elif counts["LOW"]      > 0: status = "ok"
    else:                         status = "clean"

    # Strip internal dedup field before output
    for v in all_vulns:
        v.pop("aliases", None)

    output = {
        "fetched_at":      datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "status":          status,
        "counts":          counts,
        "total":           len(all_vulns),
        "tracked":         len(components),
        "vulnerabilities": all_vulns,
    }

    print(json.dumps(output, indent=2))

    # Daily digest: alert whenever CRITICAL/HIGH CVEs exist
    send_discord_alert(all_vulns, counts)


if __name__ == "__main__":
    main()
