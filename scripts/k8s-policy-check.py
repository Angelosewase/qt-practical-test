#!/usr/bin/env python3
"""Checks the rendered manifests against the exam rules. Reads YAML from stdin, exits 1 on any violation.

Rules: every container has CPU and memory requests and limits; no image uses the latest tag or no tag;
the API and frontend have liveness and readiness probes; the namespace is qt-spring-app; exactly one
NodePort service exposes port 30080; nothing runs with a privileged container.
"""
import sys
import yaml

problems = []
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
kinds = {}
for d in docs:
    kinds.setdefault(d["kind"], []).append(d)

def label(d):
    return f'{d["kind"]}/{d["metadata"]["name"]}'

for d in docs:
    if d["kind"] in ("Deployment", "StatefulSet"):
        spec = d["spec"]["template"]["spec"]
        for c in spec.get("containers", []) + spec.get("initContainers", []):
            res = c.get("resources", {})
            for part in ("requests", "limits"):
                for r in ("cpu", "memory"):
                    if r not in res.get(part, {}):
                        problems.append(f'{label(d)}/{c["name"]}: missing {part}.{r}')
            img = c.get("image", "")
            tag = img.rsplit(":", 1)[1] if ":" in img.rsplit("/", 1)[-1] else ""
            if tag in ("", "latest"):
                problems.append(f'{label(d)}/{c["name"]}: image "{img}" has no pinned tag')
            if c.get("securityContext", {}).get("privileged"):
                problems.append(f'{label(d)}/{c["name"]}: privileged container')
        if d["metadata"]["name"] in ("api", "frontend"):
            for c in spec["containers"]:
                for probe in ("readinessProbe", "livenessProbe"):
                    if probe not in c:
                        problems.append(f'{label(d)}/{c["name"]}: missing {probe}')
    if "namespace" in d.get("metadata", {}) and d["metadata"]["namespace"] != "qt-spring-app":
        problems.append(f'{label(d)}: namespace is {d["metadata"]["namespace"]}, expected qt-spring-app')

node_ports = [p for s in kinds.get("Service", []) if s["spec"].get("type") == "NodePort"
              for p in s["spec"]["ports"] if p.get("nodePort") == 30080]
if len(node_ports) != 1:
    problems.append(f"expected exactly one NodePort service on 30080, found {len(node_ports)}")

for name in ("Namespace", "Deployment", "StatefulSet", "Service", "ConfigMap", "PersistentVolume", "PersistentVolumeClaim"):
    if name not in kinds:
        problems.append(f"no {name} in the rendered manifests")

if problems:
    print("policy: FAILED")
    for p in problems:
        print("  - " + p)
    sys.exit(1)
print(f"policy: OK ({len(docs)} objects, {sum(len(v) for v in kinds.values())} checked)")
