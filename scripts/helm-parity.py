#!/usr/bin/env python3
"""Proves the Helm chart renders the same objects as the plain manifests in k8s/.

Usage: helm-parity.py <k8s-render output> <helm template output (default values, namespace qt-spring-app)>
Ignored on purpose: metadata.labels (Helm adds managed-by and chart labels; selectors and pod labels are in spec and
are compared), the checksum/config annotation (the hash input differs), and the Namespace object (Helm installs into
a namespace instead of creating one). Everything else must be identical. Exit 1 on any difference.
"""
import json
import sys
import yaml


def load(path):
    out = {}
    with open(path) as fh:
        for d in yaml.safe_load_all(fh):
            if not d or d["kind"] == "Namespace":
                continue
            d["metadata"].pop("labels", None)
            ann = d.get("spec", {}).get("template", {}).get("metadata", {}).get("annotations", {})
            ann.pop("checksum/config", None)
            out[(d["kind"], d["metadata"].get("namespace", ""), d["metadata"]["name"])] = d
    return out


plain, chart = load(sys.argv[1]), load(sys.argv[2])
problems = []
for key in sorted(set(plain) | set(chart)):
    if key not in chart:
        problems.append(f"only in k8s/: {key}")
    elif key not in plain:
        problems.append(f"only in the chart: {key}")
    elif json.dumps(plain[key], sort_keys=True) != json.dumps(chart[key], sort_keys=True):
        import difflib
        a = yaml.safe_dump(plain[key], sort_keys=True).splitlines()
        b = yaml.safe_dump(chart[key], sort_keys=True).splitlines()
        problems.append(f"differs: {key}\n" + "\n".join(difflib.unified_diff(a, b, "k8s/", "chart", lineterm="")))
if problems:
    print("helm parity: FAILED")
    print("\n".join(problems))
    sys.exit(1)
print(f"helm parity: OK ({len(plain)} objects identical apart from labels and the config hash)")
