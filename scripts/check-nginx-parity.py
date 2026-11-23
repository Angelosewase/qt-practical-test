#!/usr/bin/env python3
"""Fails if the Kubernetes gateway config drifts from docker/nginx.conf.

The two files may differ only in the resolver line and in the fully qualified upstream names
(*.qt-spring-app.svc.cluster.local), because Kubernetes DNS and Docker DNS differ.
"""
import pathlib
import re
import sys
import yaml

root = pathlib.Path(__file__).resolve().parent.parent
docker_conf = (root / "docker" / "nginx.conf").read_text()
k8s_doc = next(d for d in yaml.safe_load_all((root / "k8s" / "10-config.yaml").read_text())
               if d and d.get("metadata", {}).get("name") == "gateway-nginx")
k8s_conf = k8s_doc["data"]["default.conf"]

def normalise(text):
    text = re.sub(r"^\s*resolver .*$", "", text, flags=re.M)
    text = text.replace(".qt-spring-app.svc.cluster.local", "")
    lines = [re.sub(r"\s+", " ", l).strip() for l in text.splitlines()]
    return [l for l in lines if l and not l.startswith("#")]

a, b = normalise(docker_conf), normalise(k8s_conf)
if a != b:
    import difflib
    print("nginx parity: FAILED (docker/nginx.conf and k8s gateway-nginx differ beyond the allowed lines)")
    print("\n".join(difflib.unified_diff(a, b, "docker/nginx.conf", "k8s/10-config.yaml", lineterm="")))
    sys.exit(1)
print(f"nginx parity: OK ({len(a)} shared directives)")
