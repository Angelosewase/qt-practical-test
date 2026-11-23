# Decisions

## D1. Template 9105: what it is (UNVERIFIED)

The brief is inconsistent: the header says "Kali Linux", the Task 1 text says "Ubuntu 24.04 LTS", and Task 1 requires Ubuntu. I could not inspect the template because the API token lacks `VM.Audit` on `/vms/9105`:

| Check | Result |
|---|---|
| `GET nodes/server4/qemu/9105/config` | 403, Permission check failed (VM.Audit) |
| `GET nodes/server4/qemu/9105/status/current` | 403 |
| `GET nodes/server4/qemu/9105/agent/get-osinfo` | 403 (needs VM.GuestAgent.Audit) |
| Terraform clone of 9105 | 403, VM.Clone |

Consequences until the template is inspected:
- Package manager and user creation: the Terraform side uses cloud-init (`initialization` block), which is distribution-neutral. Ansible will branch on `ansible_os_family` (Debian for both Kali and Ubuntu) and should work either way. Kali is Debian-based, so `apt` applies to both.
- Cloud-init: bpg/proxmox attaches a cloud-init drive to the clone automatically. If the template has no cloud-init package, the `devops` user and SSH key will not be created. Verify SSH after apply.
- Guest agent: `agent.enabled = true` makes Terraform wait for IP addresses from the agent, up to `guest_agent_timeout` (10 m). If the template has no `qemu-guest-agent`, apply fails at that wait. Fallback: set `guest_agent_timeout`, use static IPs in `ip_config`, or install the agent via Ansible and re-apply.
- Disk size: the disk is set to 30 GB. A clone cannot shrink its disk. If the template disk is larger than 30 GB, apply fails. Fallback: raise `disk_gb` to match the template, and record that as a deviation.

Action: once the token can read `/vms/9105`, run `GET nodes/server4/qemu/9105/config` and `GET .../agent/get-osinfo` and record the results here.

## D2. Terraform (OpenTofu not needed)

Terraform 1.17.2, with `required_version >= 1.5.0` and bpg/proxmox `~> 0.69`. The resolved provider is 0.123.1, recorded in `iac/.terraform.lock.hcl` and committed so the build is reproducible.

## D3. Variables, not literals

Every value that could change lives in `variables.tf`. The four VMs are one map (`var.vms`) keyed by hostname, with role, cores, memory and disk. Adding a VM means adding a map entry. `for_each` keeps each VM's state separate.

## D4. Secrets never in tracked files

- Secrets reach Terraform only as `TF_VAR_*` environment variables. The Makefile exports them from `.private/secrets.env` at run time.
- `terraform.tfvars` is gitignored. Only `terraform.tfvars.example` is tracked, with no secret values.
- The VM password and token are `sensitive` variables. The state and plan files still contain the VM password, so they are gitignored and must stay local.

## D5. Access model

- One user, `devops`, created by cloud-init with the key from `.private/ssh/id_ed25519.pub` and the VM password. Examiners get the password or key via the README placeholder.
- The API token is used with the least privilege Proxmox allows. Its permissions are not ours to change.

## D6. insecure = true

The Proxmox endpoint uses a self-signed certificate, as the brief's provider snippet specifies. It is a variable (`proxmox_insecure`) so it can be turned off if a trusted CA is available.

## D7. Full clones, not linked clones

`clone.full = true`. Linked clones depend on the template's disk and cannot be moved or resized independently. The exam needs four independent VMs.

## D8. Pool membership

All four VMs go in pool `exam-c5` (`pool_id`), as the brief requires.

## D-APP-1. Service names follow the real stack, not the brief

The brief names `nextjs`, `springboot`, `postgres` and `redis`. The code is a Vite SPA, a Go API, MongoDB and Valkey. The services are named for what they really are: `nginx`, `frontend`, `api`, `mongodb`, `valkey`. There are still five services, with the same roles and the same routing rule (`/` to the frontend, `/api/` to the API). The names are the same in Compose and Kubernetes, so one `nginx.conf` serves both. Needs the user's confirmation (see the report).

## D-APP-2. Seed accounts stay enabled

The upstream README says `SEED_ENABLED=false` outside the exam. The brief requires test accounts for examiners, so `SEED_ENABLED=true` in both deployments.

## D-APP-3. No search: the functional test uses list and visibility instead

The brief asks to "create and search entries". The app has no search endpoint or UI. `scripts/verify.sh` tests create, list and get, plus the isolation rules. Adding search would mean changing application code, which is out of scope for the DevOps exam. Needs the user's decision.

## D-APP-4. Keep Valkey instead of swapping in Redis

The brief says Redis. The code's README says Valkey 8+, and it uses the `valkey-go` client. Valkey speaks the Redis protocol, so the behaviour is the same. The official `valkey/valkey` image is used. The cache holds only rebuildable data, so it has no volume and runs with persistence off.

## D-DOCKER-1. Build context is the repository root, with a default-deny `.dockerignore`

Both images need files from `app/` and from `docker/`, so the context is the repo root. The root `.dockerignore` starts with `*` and re-allows only `app/backend`, `app/frontend` and `docker/frontend-nginx.conf`. It also excludes `.env*` files, `.private/`, `.tmp/`, `.git`, `node_modules` and `dist`. This keeps the local credentials out of every image. Verified: no `.env`, `node_modules` or secret file exists in either image.

## D-DOCKER-2. Multi-stage builds with pinned, verified tags

- API: `golang:1.23.12-alpine3.21` builds a static binary (`CGO_ENABLED=0`, `-trimpath`, stripped). Runtime `alpine:3.21.10`, uid 10001, `GIN_MODE=release`. About 30 MB.
- Frontend: `node:20.19.6-alpine3.21` runs `npm ci` and `vite build`. Runtime `nginxinc/nginx-unprivileged:1.27.5-alpine` on port 8080 as uid 101. About 75 MB.
- Every tag was pulled once to confirm it exists. Floating tags such as `latest` or `1.27` are not used anywhere.
- Mongo `7.0.14`, Valkey `8.1.12-alpine`, and the gateway `nginx:1.27.5-alpine` are official Docker Hub images, as the brief requires.

## D-DOCKER-3. The gateway is the official nginx image and runs as root

Port 80 needs root unless the port is remapped, and the official image's master process runs as root while the workers run as `nginx`. The brief asks for official NGINX images, so the gateway uses `nginx:1.27.5-alpine`. The app containers are non-root. The unprivileged alternative listens on 8080 and would require mapping the host port to 8080.

## D-DOCKER-4. Health checks and dependencies

- `api`: `GET /api/health`, which is 200 while MongoDB answers and 503 otherwise. Cache status never fails it.
- `frontend`: `GET /`. `nginx`: `GET /` (which proves the gateway and the frontend upstream).
- `mongodb`: `mongosh` ping. `valkey`: `valkey-cli ping`.
- `api` waits for `mongodb` to be healthy. It only waits for `valkey` to start, because the cache is optional. Proven: with Valkey stopped, `/api/health` returns 200 with `cache: "down"` and all 34 verify checks pass.

## D-DOCKER-5. Network isolation

Two networks. `edge` carries nginx, frontend and api. `data` is `internal: true` and carries api, mongodb and valkey. Only nginx publishes a host port, so MongoDB and Valkey are not reachable from the host.

## D-DOCKER-6. nginx re-resolves upstream names

`resolver 127.0.0.11 valid=10s` plus `set $api_upstream` makes nginx look up the upstream name at request time. Proven: restarting the API container (new IP) was reachable through nginx without restarting nginx.

## D-DOCKER-7. Secrets

`docker/.env` is generated by `scripts/gen-env.sh` with random values (`openssl rand`, chmod 600) and is gitignored. Only `docker/.env.example` (placeholders) is committed. Valkey reads its password from the environment and gets it through `REDISCLI_AUTH` for the health check, so the password is not passed as a command-line argument to `valkey-cli`.

## D-DOCKER-8. Persistence

Only MongoDB has a named volume (`projecthub-mongo-data`). Valkey has none. Verified: after `docker compose restart mongodb`, the API became healthy again with its data.

## D-K8S-1. Manifest layout and namespace

Seven numbered files in `k8s/` (`00-namespace.yaml` to `60-gateway.yaml`) plus `secret.example.yaml`. The numbers set the apply order, so the namespace comes first. Everything is in namespace `qt-spring-app`, as the brief requires.

## D-K8S-2. Configuration and credentials are split

- `ConfigMap api-config`: non-secret settings, including `MONGO_HOST=mongodb:27017`. The brief asks for a ConfigMap holding the datasource, and this is its non-secret part.
- `Secret app-secrets`: `MONGO_ROOT_USER`, `MONGO_ROOT_PASSWORD`, `VALKEY_PASSWORD`, `JWT_SECRET`.
- `MONGO_URI` is assembled inside the pod from those pieces with Kubernetes `$(VAR)` expansion. The password never appears in a ConfigMap or in the rendered manifests.

## D-K8S-3. The Secret is generated at deploy time

`scripts/k8s-secrets.sh` reads `docker/.env` and passes it to `kubectl create secret --from-env-file` through a temporary file (`.tmp/`, mode 600, removed on exit). Values are never on the command line and never printed. The script refuses placeholder values. Only `k8s/secret.example.yaml`, which holds placeholders, is committed.

## D-K8S-4. MongoDB: StatefulSet, one replica, PV pinned to a node

- kubeadm has no default storage class, so the PV is a `hostPath` at `/srv/projecthub/mongo`, pinned by `nodeAffinity` to nodes labelled `projecthub/storage=mongo` (the label is set by hand once, documented in the README). The PVC binds to it by name.
- Reclaim policy `Retain`, so deleting the namespace does not delete data.
- Trade-off: data lives on one node and is not replicated. Acceptable for the exam, and called out as a risk.
- An init container runs `chown 999:999` on the directory, because hostPath directories are created root-owned and the MongoDB process runs as uid 999.

## D-K8S-5. Probes

- API readiness: `GET /api/health` (200 only while MongoDB answers). Liveness uses the same path with a longer window (6 failures × 15 s). Reason: a MongoDB outage should not restart the API in a loop. Restarting does not repair the database.
- Frontend and gateway: `GET /`. MongoDB and Valkey: `mongosh` ping and `valkey-cli ping`.
- Valkey has no HTTP endpoint, so its probes are exec probes.

## D-K8S-6. Resources

Every container has requests and limits, enforced by `scripts/k8s-policy-check.py`. The API limit is 512 MiB (Go with GOGC defaults uses far less), and MongoDB gets 1 GiB. The four VMs have 4 GB each, so a full pod set fits on two workers.

| Workload | Requests (cpu / mem) | Limits (cpu / mem) |
|---|---|---|
| api (×2) | 100m / 128Mi | 1 / 512Mi |
| frontend (×2) | 50m / 64Mi | 200m / 128Mi |
| gateway (×2) | 50m / 64Mi | 200m / 128Mi |
| mongodb | 250m / 512Mi | 1 / 1Gi |
| valkey | 50m / 64Mi | 500m / 256Mi |

The brief's JVM-heap rule does not apply: the API is a Go binary with no JVM. The equivalent is that the Go runtime is well under its memory limit.

## D-K8S-7. Security context

API and frontend run as non-root with numeric UIDs (10001, 101), `allowPrivilegeEscalation: false`, all capabilities dropped, and a read-only root filesystem. The frontend gets emptyDir volumes for `/tmp` and nginx's cache. The gateway runs the official nginx image, which needs root for port 80 (see D-DOCKER-3). The MongoDB and Valkey images start as root and drop privileges themselves.

## D-K8S-8. Rolling updates with no downtime

`maxUnavailable: 0`, `maxSurge: 1` on api, frontend and gateway, so a rollout never removes the last ready pod. Needed for the brief's "delete a pod while requests continue" test.

## D-K8S-9. NodePort 30080 goes to the gateway

The brief asks for a NodePort on 30080. The gateway, not the frontend, is exposed, so `/` and `/api/` are routed exactly as in Compose. One exposed service is enough, and it keeps the two deployments comparable.

## D-K8S-10. Gateway upstreams are fully qualified

nginx's `resolver` does not apply the pod's DNS search domains, so the bare name `frontend` never resolves in Kubernetes. Found in testing: the probe timed out (HTTP 499) until the upstreams were changed to `frontend.qt-spring-app.svc.cluster.local` and `api.qt-spring-app.svc.cluster.local`. `scripts/check-nginx-parity.py` now fails if the two gateway configs differ beyond the resolver and those names.

## D-K8S-11. Validation method

The brief asks for `kubectl apply --dry-run=client`. In kubectl 1.37 that command needs a reachable API server for schema discovery, even with `--validate=false`. Without a cluster it fails with "connection refused". So `scripts/k8s-validate.sh` runs:

1. render and policy (`k8s-policy-check.py`),
2. nginx parity,
3. offline strict schema validation with `kubeconform` against Kubernetes 1.32.5,
4. `kubectl apply --dry-run=client` and `--dry-run=server` when `KUBECONFIG` reaches a cluster.

Step 4 ran against the kind cluster and passed. The server dry-run needs the namespace to exist first, because a dry-run does not persist it, so the script creates the namespace (idempotent).

## D-K8S-12. Explicit kubeconfig

The default kubeconfig on this machine points to `kind-argocd-cluster` (`127.0.0.1:43929`, not running). It is not ours and is never used. The Makefile requires `KUBECONFIG` to be set explicitly, defaulting to `.private/kubeconfig`.

## D-K8S-13. Kubernetes version

v1.32.5, pinned for the kind test cluster and for schema validation. The kubeadm version on the VMs (Task 3) should match.

## D-K8S-14. Local test cluster

kind cluster `projecthub-local` (v1.32.5, one control plane, two workers, NodePort 30080 mapped to the host), kubeconfig in `.tmp/kind-kubeconfig`. It exists only to test the manifests on this machine and is separate from the exam cluster.
