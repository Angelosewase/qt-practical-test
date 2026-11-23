#!/usr/bin/env bash
# Live checks for brief requirements without a dedicated evidence file. Prints no secret values.
set -uo pipefail
cd "${1:-$(git rev-parse --show-toplevel)}"
export KUBECONFIG=$PWD/.private/kubeconfig
SSH="ssh -i .private/ssh/id_ed25519 -o BatchMode=yes -o ConnectTimeout=10"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
h() { echo; echo "## $*"; }
echo "# Grading checks (generated $(ts) by the laptop, read-only). No secret values are printed."
h "1. Multi-stage Dockerfiles (FROM lines)"
grep -n '^FROM' docker/api.Dockerfile docker/frontend.Dockerfile
h "2. Docker Hub tags (read back from the registry)"
for r in projecthub-api projecthub-frontend; do
  echo "angelsewase/$r: $(curl -s -m 15 "https://hub.docker.com/v2/repositories/angelsewase/$r/tags?page_size=20" | python3 -c 'import sys,json; print(", ".join(t["name"] for t in json.load(sys.stdin)["results"]))')"
done
h "3. Compose on c3-docker-host: images, state and published ports (only nginx publishes a host port)"
$SSH devops@192.168.160.11 'hostname; cd /opt/projecthub/docker && docker compose ps --format "table {{.Service}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"; echo; echo "named volumes:"; docker volume ls --format "{{.Name}}" | grep projecthub'
h "4. Compose cache requires a password (ping without credentials, then with them)"
$SSH devops@192.168.160.11 'cd /opt/projecthub/docker && echo -n "no password:   "; docker compose exec -T valkey env -u REDISCLI_AUTH valkey-cli ping 2>&1; echo -n "with password: "; docker compose exec -T valkey valkey-cli ping 2>&1'
h "5. Kubernetes: resource kinds in namespace qt-spring-app (Secret names only, no data)"
kubectl get ns qt-spring-app
kubectl -n qt-spring-app get deploy,statefulset,svc,configmap,pvc
kubectl -n qt-spring-app get secret -o name
kubectl get pv projecthub-mongo-data -o custom-columns='PV:.metadata.name,CAPACITY:.spec.capacity.storage,CLAIM:.spec.claimRef.name,NODE-LABEL:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].key'
h "6. Kubernetes: requests and limits on every container (init containers included)"
kubectl -n qt-spring-app get deploy,statefulset -o json | python3 -c '
import sys,json
for o in json.load(sys.stdin)["items"]:
    s=o["spec"]["template"]["spec"]
    for kind,cs in (("init",s.get("initContainers",[])),("main",s["containers"])):
        for c in cs:
            r=c.get("resources",{})
            n=o["metadata"]["name"]; print("%-9s %-4s %-17s requests=%s limits=%s" % (n, kind, c["name"], r.get("requests"), r.get("limits")))'
h "7. Kubernetes: probes on the API and frontend, and the API heap limit"
kubectl -n qt-spring-app get deploy api frontend -o json | python3 -c '
import sys,json
for o in json.load(sys.stdin)["items"]:
    c=o["spec"]["template"]["spec"]["containers"][0]
    for p in ("readinessProbe","livenessProbe"):
        print(o["metadata"]["name"], p, c[p].get("httpGet"))
    for e in c.get("env",[]):
        if e["name"]=="GOMEMLIMIT": print(o["metadata"]["name"], "GOMEMLIMIT", e["value"], "(memory limit", c["resources"]["limits"]["memory"]+")")'
h "8. Kubernetes cache requires a password"
echo -n "no password:   "; kubectl -n qt-spring-app exec deploy/valkey -- env -u REDISCLI_AUTH valkey-cli ping 2>&1
echo -n "with password: "; kubectl -n qt-spring-app exec deploy/valkey -- valkey-cli ping 2>&1
h "9. Health on both deployments"
for u in http://192.168.160.11 http://192.168.160.17:30080 http://192.168.160.33:30080 http://192.168.160.98:30080; do echo "$u/api/health -> $(curl -s -m 10 $u/api/health)"; done
echo; echo "# end $(ts)"
