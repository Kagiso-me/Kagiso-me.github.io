#!/usr/bin/env python3
"""
sync-stack-versions.py — Pin stack.json versions to what the cluster actually runs.

The CVE feed queries OSV.dev against the versions declared in stack.json. If that
file drifts behind the deployed pods, OSV is asked about versions you no longer run
and reports already-patched CVEs as live. This script closes that gap: it reads the
running container image tags from the cluster and rewrites the `version` field of
every component that carries an `image` matcher, in place.

Components without an `image` field (Docker-host apps not in k3s) are left untouched
and stay hand-maintained.

Requires: kubectl with cluster access (runs on the bran-site runner, same as fetch-cves).
Edits stack.json in place. Idempotent — a no-op when already in sync. Exit 0 always
(a sync failure must not block the CVE fetch; it just runs against the last-known versions).
"""

import json
import os
import re
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
STACK_FILE = os.path.join(SCRIPT_DIR, "stack.json")

# Sentinel matcher: k3s version comes from the node, not a container image.
K3S_SENTINEL = "k3s-node-version"


def log(msg):
    print(f"sync-stack-versions: {msg}", file=sys.stderr)


def normalize_version(tag: str) -> str | None:
    """Extract a bare semver-ish version from an image tag.

    v3.6.15          -> 3.6.15
    1.36.0-alpine    -> 1.36.0
    33.0.5-apache    -> 33.0.5
    2026.2.2         -> 2026.2.2
    latest / pg17    -> None  (no usable version)
    """
    if not tag or tag == "latest":
        return None
    m = re.match(r"v?(\d+\.\d+(?:\.\d+)?(?:\.\d+)?)", tag)
    return m.group(1) if m else None


def repo_path(image: str) -> str:
    """Strip registry host and tag/digest, leaving the repo path.

    docker.io/library/nextcloud:33.0.5-apache -> library/nextcloud
    quay.io/jetstack/cert-manager-controller:v1.20.2 -> jetstack/cert-manager-controller
    crowdsecurity/crowdsec:v1.7.8 -> crowdsecurity/crowdsec
    """
    ref = image.split("@", 1)[0]              # drop digest
    if ":" in ref.rsplit("/", 1)[-1]:         # drop tag (only if in last segment)
        ref = ref.rsplit(":", 1)[0]
    parts = ref.split("/")
    # A leading segment with a dot or port is a registry host — drop it.
    if len(parts) > 1 and ("." in parts[0] or ":" in parts[0]):
        parts = parts[1:]
    return "/".join(parts)


def image_tag(image: str) -> str:
    ref = image.split("@", 1)[0]
    last = ref.rsplit("/", 1)[-1]
    return last.rsplit(":", 1)[1] if ":" in last else ""


def version_key(v: str):
    return tuple(int(x) for x in re.findall(r"\d+", v))


def cluster_image_versions() -> dict[str, str]:
    """Map repo_path -> highest running version across all pods."""
    try:
        out = subprocess.run(
            ["kubectl", "get", "pods", "-A", "-o",
             "jsonpath={range .items[*]}{range .spec.containers[*]}{.image}{'\\n'}{end}{end}"],
            capture_output=True, text=True, timeout=30, check=True,
        ).stdout
    except Exception as e:
        log(f"kubectl get pods failed: {e}")
        return {}

    versions: dict[str, str] = {}
    for image in filter(None, (l.strip() for l in out.splitlines())):
        ver = normalize_version(image_tag(image))
        if not ver:
            continue
        path = repo_path(image)
        if path not in versions or version_key(ver) > version_key(versions[path]):
            versions[path] = ver
    return versions


def k3s_version() -> str | None:
    """k3s version from the first node, e.g. v1.34.6+k3s1 -> 1.34.6."""
    try:
        out = subprocess.run(
            ["kubectl", "get", "nodes", "-o",
             "jsonpath={.items[0].status.nodeInfo.kubeletVersion}"],
            capture_output=True, text=True, timeout=15, check=True,
        ).stdout.strip()
    except Exception as e:
        log(f"kubectl get nodes failed: {e}")
        return None
    return normalize_version(out)


def main():
    with open(STACK_FILE) as f:
        stack = json.load(f)

    images = cluster_image_versions()
    k3s_ver = k3s_version()

    changes = []
    for comp in stack["components"]:
        matcher = comp.get("image")
        if not matcher:
            continue

        new = k3s_ver if matcher == K3S_SENTINEL else images.get(matcher)
        if not new:
            log(f"no cluster version found for {comp['name']} (matcher: {matcher}) — left at {comp['version']}")
            continue

        if new != comp["version"]:
            changes.append((comp["display"], comp["version"], new))
            comp["version"] = new

    if not changes:
        log("already in sync — no changes")
        return

    import datetime
    stack["_updated"] = datetime.date.today().isoformat()

    with open(STACK_FILE, "w") as f:
        json.dump(stack, f, indent=2)
        f.write("\n")

    for display, old, new in changes:
        log(f"updated {display}: {old} -> {new}")


if __name__ == "__main__":
    # Never let a sync failure block the CVE fetch.
    try:
        main()
    except Exception as e:
        log(f"unexpected error, leaving stack.json untouched: {e}")
    sys.exit(0)
