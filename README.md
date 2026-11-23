# ProjectHub on Proxmox: DevOps practical exam (candidate 5)

This repository deploys **ProjectHub** (the application in `app/`) three ways: Terraform VMs on Proxmox,
Docker Compose on one VM, and Kubernetes on a three-node kubeadm cluster.

> **The brief describes the stack wrongly.** It says "MyDiary", Next.js, Spring Boot, PostgreSQL and Redis.
> The code is **ProjectHub**: a Vite/React SPA, a Go 1.23 API (Gin), MongoDB 7 and Valkey 8 (optional cache).
> It has projects and tasks, not diary entries, and no search. The code is correct; this repo deploys the
> code as it is. Details: [docs/APP-ANALYSIS.md](docs/APP-ANALYSIS.md).

## Status

| Task | Status |
|---|---|
| Repo layout, secrets handling, pre-commit secret guard | Done |
| Task 1: Terraform VMs (`iac/`) | **Applied.** Four Kali VMs running, verified over SSH as `devops`. Evidence in `monitoring/task1-evidence.txt` |
| Task 3: Kubernetes cluster (`ansible/`) | **Built and verified**: kubeadm 1.32.5 control plane, Flannel, two workers, three Ready nodes. Second cluster run changed nothing. The devops password step is written but **waits for `VM_PASSWORD`** |
| App analysis and move into `app/` | Done |
| Task 2: Docker images and Compose (`docker/`) | Built and tested on this machine (34 of 34 functional checks, cache and database outages). **Not pushed:** Docker Hub credentials are placeholders |
| Task 3: Ansible Kubernetes cluster (`ansible/`) | Not started (needs the VMs) |
| Task 4: Kubernetes manifests (`k8s/`) | Validated, and deployed and tested on a **local kind cluster** (34 of 34). Not yet on the exam cluster |
| Task 5: Monitoring (`monitoring/`) | Not started |

## Architecture

### Docker Compose deployment (c3-docker-host)

```mermaid
flowchart LR
    client([Browser on LAN]) -->|HTTP :80| nginx
    subgraph edge [network: edge]
      nginx[nginx 1.27.5<br/>gateway]
      frontend[frontend<br/>Vite SPA on unprivileged nginx :8080]
      api[api<br/>Go 1.23 / Gin :8080]
    end
    subgraph data [network: data, internal]
      mongodb[(mongodb 7.0.14<br/>volume projecthub-mongo-data)]
      valkey[(valkey 8.1.12<br/>cache, no volume)]
    end
    nginx -->|"/"| frontend
    nginx -->|"/api/"| api
    api --> mongodb
    api -. optional, fails open .-> valkey
```

Only nginx publishes a host port (80). MongoDB and Valkey are on an internal network with no host ports.

### Kubernetes deployment (namespace `qt-spring-app`)

```mermaid
flowchart TB
    user([Browser]) -->|"http://NODE_IP:30080"| svc_gw[Service gateway<br/>NodePort 30080]
    subgraph ns [namespace qt-spring-app]
      svc_gw --> gw[Deployment gateway x2<br/>nginx 1.27.5]
      gw -->|"/"| svc_fe[Service frontend :8080] --> fe[Deployment frontend x2]
      gw -->|"/api/"| svc_api[Service api :8080] --> api[Deployment api x2<br/>Go API]
      api --> svc_db[Service mongodb :27017] --> db[(StatefulSet mongodb<br/>PVC mongo-data to PV on worker-1)]
      api -. optional .-> svc_vk[Service valkey :6379] --> vk[(Deployment valkey<br/>no volume)]
      cm[ConfigMaps api-config, gateway-nginx] -.-> api
      sec[Secret app-secrets<br/>created from docker/.env] -.-> api
      sec -.-> db
      sec -.-> vk
    end
```

## Infrastructure creation (Task 1)

Prerequisites: Terraform 1.5 or later (tested with 1.17.2), `make`, the Proxmox token in `.private/secrets.env`,
and the SSH key in `.private/ssh/` (create it with `ssh-keygen -t ed25519 -N '' -f .private/ssh/id_ed25519`).

The brief says Ubuntu 24.04 for the VMs. The template is actually **Kali Linux** (verified through the Proxmox API,
see `docs/DECISIONS.md` D1).

```bash
make setup         # install the pre-commit secret guard
make tf-fmt        # formatting check
make tf-validate   # validate the configuration (no API calls)
make tf-init       # download the bpg/proxmox provider
make tf-plan       # write iac/tfplan
make tf-apply      # create the four VMs from template 9105
make tf-output     # print each VM's IP and SSH command
make inventory     # write ansible/inventory.ini from the IPs (gitignored)
```

### VM table

Created by `make tf-apply` on Proxmox node `server4`, pool `exam-c5`, from template 9105 (`kali-linux`, Kali GNU/Linux Rolling).

| VM name | Role | IP (DHCP) | VM ID | SSH user |
|---|---|---|---|---|
| c3-docker-host | Application host (Docker Compose) | 192.168.160.11 | 119 | `devops` |
| c3-k8s-master | Kubernetes control plane | 192.168.160.17 | 120 | `devops` |
| c3-k8s-worker-1 | Kubernetes worker (also holds the MongoDB volume) | 192.168.160.33 | 100 | `devops` |
| c3-k8s-worker-2 | Kubernetes worker | 192.168.160.98 | 121 | `devops` |

The IPs come from DHCP. Run `make tf-output` to confirm them, then `make inventory` to regenerate `ansible/inventory.ini`.

### VM login credentials

- SSH user: `devops`
- Password: **[PLACEHOLDER: add the VM password before submission]**
- SSH private key: **[PLACEHOLDER: add the key path or key to share with examiners before submission]**

Do not write real credentials in this file.

## Kubernetes cluster via Ansible (Task 3)

Run from the laptop. The playbook prepares every node, initialises the control plane, installs Flannel, joins the
workers, and checks for three Ready nodes.

```bash
make setup          # pre-commit secret guard (once)
make tf-output      # confirm the IPs
make inventory      # write ansible/inventory.ini from them (gitignored)
make ansible-lint   # production profile
make ansible-syntax # syntax check
make ansible-ping   # reachability
make ansible-run    # full playbook (sources .private/secrets.env for VM_PASSWORD)
```

The cluster-side checks are saved to `monitoring/task3-evidence.txt`. Running `make ansible-run` again is safe:
the second run reports `changed=0` on every host.

Cluster versions: Kubernetes v1.32.5 (kubeadm, kubelet, kubectl, packages held), containerd 2.1.9, Flannel v0.28.11
(vendored in `ansible/files/`), pod network `10.244.0.0/16`, OS Kali GNU/Linux Rolling with kernel 7.1.5.

Kubectl access: the control plane has `/home/devops/.kube/config` (copy of the admin kubeconfig, mode 0600).
From the laptop, copy it to `.private/kubeconfig` and point `KUBECONFIG` at it for `make k8s-deploy`.

## Docker Compose deployment (Task 2)

Images are built from source by multi-stage Dockerfiles and pushed to Docker Hub. Compose runs them.

```bash
make env                 # create docker/.env with generated secrets (chmod 600, gitignored)
make compose-config      # validate docker-compose.yml
make hadolint            # lint the Dockerfiles
make docker-build        # build both app images (tags from docker/.env)
make compose-up          # start the five services; nginx serves on port 80
make verify              # functional checks through http://localhost
make docker-push         # log in to Docker Hub and push api and frontend (needs real credentials)
```

On c3-docker-host, set `DOCKERHUB_USER` and the tags in `docker/.env`, then run `docker compose -f docker/docker-compose.yml pull && ... up -d`.

Images and tags:

| Image | Tag | Base (pinned) |
|---|---|---|
| `<dockerhub-user>/projecthub-api` | `1.0.0` | `golang:1.23.12-alpine3.21` build, `alpine:3.21.10` runtime, uid 10001 |
| `<dockerhub-user>/projecthub-frontend` | `1.0.0` | `node:20.19.6-alpine3.21` build, `nginxinc/nginx-unprivileged:1.27.5-alpine` runtime, uid 101 |
| `nginx` | `1.27.5-alpine` | official |
| `mongo` | `7.0.14` | official |
| `valkey/valkey` | `8.1.12-alpine` | official |

Replace `<dockerhub-user>` with your Docker Hub account: **[PLACEHOLDER]**.

## Kubernetes deployment (Task 4)

```bash
make env                                     # docker/.env (the Secret is built from it)
make k8s-render                              # render k8s/ to stdout (placeholders filled)
make k8s-validate                            # render, policy, nginx parity, strict schema, cluster dry-run
export KUBECONFIG=$PWD/.private/kubeconfig   # the exam cluster (copy from the master node)
kubectl label node c3-k8s-worker-1 projecthub/storage=mongo   # the MongoDB volume lives on this node
make k8s-deploy                              # create the Secret, apply everything, wait for rollout
make k8s-status                              # pods, services, volume claim
make k8s-verify K8S_URL=http://<node-ip>:30080
```

Access: `http://<any-node-ip>:30080`. Kubernetes NodePort is reachable on every node.

Validation without a cluster is limited: `kubectl apply --dry-run=client` needs a reachable API server in
kubectl 1.37 (for discovery). `k8s-validate` therefore runs offline checks first (kubeconform in strict mode
and a policy script that enforces requests, limits and probes) and the kubectl dry-runs when `KUBECONFIG`
points at a cluster. The local kind cluster used for testing ran all of it.

### Local test cluster (not the exam cluster)

Kubernetes v1.32.5 in kind (`projecthub-local`, one control plane, two workers), kubeconfig in
`.tmp/kind-kubeconfig`. Results: `make k8s-verify` against `http://127.0.0.1:30080` gave 34 of 34 passed.

## Functional test

`scripts/verify.sh <base-url>` checks, against any deployment:

- reachability: `/` returns 200 and `/projects/123` returns 200 (SPA fallback);
- health: `/api/health` reports `database` and `cache`;
- register two users, login (good and bad password), `/auth/me`;
- role rule: a member cannot create a project (403);
- a manager creates a project and a task, then lists them;
- isolation: a user who is not a member gets an empty project list and 404 on the project, its tasks and its tasks' status;
- sharing: adding the user to the project gives access; a second non-member still gets 404;
- admin sees all projects; unauthenticated requests get 401; the test project is deleted at the end.

Test accounts (created on the first start of an empty database, `SEED_ENABLED=true`):

| Role | Email | Password |
|---|---|---|
| admin | `admin@qt.rw` | `Admin@123` |
| manager | `manager@qt.rw` | `Manager@123` |
| member | `member@qt.rw` | `Member@123` |

The app has no diary entries and no search. The "create and search" requirement is covered by create and list.

## Resilience and failure behaviour (tested locally)

| Scenario | Result |
|---|---|
| Stop Valkey | `/api/health` returns 200 with `"cache":"down"`; all 34 checks still pass |
| Stop MongoDB | `/api/health` returns 503 with `"database":"down"`; recovers when MongoDB returns |
| Restart the API (new IP) | nginx reaches it without a reload (resolver with runtime lookup) |

Redis-style cache: the cache holds only rebuildable data (dashboard figures and user lookups), so it has no
persistent volume. Without it the API reads MongoDB directly and works, only slower.

## Troubleshooting and logs

- Compose logs: `make compose-logs` or `make compose-logs SERVICE=api`; `docker compose -f docker/docker-compose.yml logs -f --tail=50 api`.
- Kubernetes logs: `kubectl -n qt-spring-app logs deploy/api --tail=50`; `kubectl -n qt-spring-app logs statefulset/mongodb`.
- Health: `curl http://<host>/api/health`.
- Pods not ready: `kubectl -n qt-spring-app describe pod <name>` and `kubectl -n qt-spring-app get events --sort-by=.lastTimestamp`.
- nginx 502 or 504: check the upstream pod with `kubectl -n qt-spring-app get endpoints api`.

## Repository layout

See [docs/STRUCTURE.md](docs/STRUCTURE.md) for the full tree. Decisions are in [docs/DECISIONS.md](docs/DECISIONS.md),
the running log is in [docs/WORKLOG.md](docs/WORKLOG.md), and operations steps are in [docs/RUNBOOK.md](docs/RUNBOOK.md) (later).

## Still to do before submission

- Apply Task 1 (needs the Proxmox permission fix) and fill the VM table above.
- Ansible cluster setup (Task 3), then the cluster-wide deploy and resilience proof (Task 4).
- Push both images to Docker Hub with real credentials (Task 2).
- Monitoring evidence and screenshots (Task 5), and the bonus items if time allows.
- Credential placeholders above: VM password, SSH key, Docker Hub user.
