# ProjectHub on Proxmox: DevOps practical exam (candidate 5)

This repository builds four Kali Linux VMs on Proxmox with Terraform. It deploys the application in `app/` with
Docker Compose on one VM. Ansible builds a three-node kubeadm cluster from the laptop, and the same application then
runs on that cluster with plain manifests. The command-line monitoring evidence is in `monitoring/`. The application is
**ProjectHub**: a Go API, a React SPA, MongoDB and a Valkey cache. The brief calls it "MyDiary" on Next.js, Spring Boot,
PostgreSQL and Redis, which does not match the code (see [The brief and the real application](#the-brief-and-the-real-application)).
Both deployments are running and pass the same 39 functional checks.

## Quick facts

**URLs**

| Deployment | URL |
|---|---|
| Docker Compose on c3-docker-host | http://192.168.160.11 |
| Kubernetes NodePort (any node) | http://192.168.160.17:30080, http://192.168.160.33:30080, http://192.168.160.98:30080 |

**VMs** (Proxmox node `server4`, pool `exam-c5`, cloned from template 9105; each has 4 vCPU, 4 GB RAM and a 30 GB disk; IPs from DHCP, confirm with `make tf-output`)

| VM | Role | IP | Proxmox VM ID |
|---|---|---|---|
| c3-docker-host | Docker Compose host | 192.168.160.11 | 119 |
| c3-k8s-master | Kubernetes control plane | 192.168.160.17 | 120 |
| c3-k8s-worker-1 | Kubernetes worker (holds the MongoDB volume) | 192.168.160.33 | 100 |
| c3-k8s-worker-2 | Kubernetes worker | 192.168.160.98 | 121 |

**VM login**

- The SSH username and password for the four VMs are sent to the examiners separately with the submission. They are not stored in this repository.

**Application test accounts** (created on the first start of an empty database)

| Role | Email | Password |
|---|---|---|
| admin | `admin@qt.rw` | `Admin@123` |
| manager | `manager@qt.rw` | `Manager@123` |
| member | `member@qt.rw` | `Member@123` |

**Images** (both deployments run exactly these; the app images are public on Docker Hub)

| Image | Tag | Built from |
|---|---|---|
| `angelsewase/projecthub-api` | `1.0.0` | `docker/api.Dockerfile` (multi-stage: `golang:1.23.12-alpine3.21` → `alpine:3.21.10`, uid 10001) |
| `angelsewase/projecthub-frontend` | `1.0.0` | `docker/frontend.Dockerfile` (multi-stage: `node:20.19.6-alpine3.21` → `nginxinc/nginx-unprivileged:1.27.5-alpine`, uid 101) |
| `nginx` | `1.27.5-alpine` | official |
| `mongo` | `7.0.14` | official |
| `valkey/valkey` | `8.1.12-alpine` | official |

## How this maps to the brief

The full requirement-by-requirement table, with the file and the evidence for each line, is in
**[docs/GRADING-MAP.md](docs/GRADING-MAP.md)**. Summary:

| Brief section | Weight | Where | Status |
|---|---|---|---|
| Task 1: Terraform VMs | 20% | `iac/` | done |
| Task 2: Docker Compose | 15% | `docker/` | done |
| Task 3: Kubernetes cluster with Ansible | 20% | `ansible/` | done |
| Task 4: Kubernetes deployment and resilience | 20% | `k8s/`, `scripts/resilience-demo.sh` | done |
| Task 5: Monitoring | 10% | `monitoring/` | done |
| Documentation and structure | 10% | this README, `docs/` | done |
| Application functionality | 5% | `scripts/verify.sh` | done, except search: the app has no search feature |
| Bonus: Helm | +5 | `k8s/helm/`, see [Bonus](#bonus) | done (second copy on NodePort 30081) |
| Bonus: Gateway API | +5 | see [Bonus](#bonus) | not attempted (the control plane is not stable enough) |

## Repository layout

- [`iac/`](iac/): Task 1. Terraform for the four VMs (`provider.tf`, `variables.tf`, `main.tf`, `outputs.tf`).
- [`ansible/`](ansible/): Task 3, and the Compose deployment of Task 2. `site.yml`, the roles, the pinned Flannel and metrics-server manifests in `files/`, and an inventory template.
- [`docker/`](docker/): Task 2. The two Dockerfiles, the nginx configs, `docker-compose.yml` and `.env.example`.
- [`k8s/`](k8s/): Task 4. The manifests, numbered in apply order, plus `secret.example.yaml` (a template only). `k8s/helm/` holds the Helm chart (bonus).
- [`app/`](app/): the application source (`backend/` Go, `frontend/` React), copied from the exam GitLab without its `.git`.
- [`monitoring/`](monitoring/): Task 5 screenshots in `screenshots/`, per-VM text snapshots in `<vm>/`, and the evidence files listed in each task section.
- [`scripts/`](scripts/): helpers called by the Makefile (functional test, resilience demo, collectors, render and validate, secret scan).
- [`docs/`](docs/): [GRADING-MAP.md](docs/GRADING-MAP.md), [APP-ANALYSIS.md](docs/APP-ANALYSIS.md) (what the code really is), [DECISIONS.md](docs/DECISIONS.md) (choices and trade-offs), [WORKLOG.md](docs/WORKLOG.md) (what was done and what broke), [STRUCTURE.md](docs/STRUCTURE.md) (the full tree) and [CLEANUP.md](docs/CLEANUP.md) (what was removed before submission).
- [`Makefile`](Makefile): every step has a target. Run `make help` to list them.

Secrets (Proxmox token, VM password, Docker Hub token, the SSH key, the kubeconfig) are kept in `.private/`, which is
gitignored. `make secret-scan` checks the working tree and the full git history for their values and for token-shaped
strings. `make setup` installs it as a pre-commit hook.

## Architecture

### Docker Compose (c3-docker-host)

```mermaid
flowchart LR
    client([Browser on LAN]) -->|HTTP :80| nginx
    subgraph edge [network: edge]
      nginx[nginx 1.27.5<br/>reverse proxy]
      frontend[frontend<br/>React SPA on unprivileged nginx :8080]
      api[api<br/>Go 1.23 / Gin :8080]
    end
    subgraph data [network: data, internal]
      mongodb[(mongodb 7.0.14<br/>volume projecthub-mongo-data)]
      valkey[(valkey 8.1.12<br/>cache, password, no volume)]
    end
    nginx -->|"/"| frontend
    nginx -->|"/api/"| api
    api --> mongodb
    api -. optional, fails open .-> valkey
```

Only nginx publishes a host port (80). MongoDB and Valkey sit on an `internal` network with no host ports.

### Kubernetes (namespace `qt-spring-app`)

```mermaid
flowchart TB
    user([Browser]) -->|"http://NODE_IP:30080"| svc_gw[Service gateway<br/>NodePort 30080]
    subgraph ns [namespace qt-spring-app]
      svc_gw --> gw[Deployment gateway x2<br/>nginx 1.27.5]
      gw -->|"/"| svc_fe[Service frontend :8080] --> fe[Deployment frontend x2]
      gw -->|"/api/"| svc_api[Service api :8080] --> api[Deployment api x2<br/>Go API]
      api --> svc_db[Service mongodb :27017] --> db[(StatefulSet mongodb<br/>PVC mongo-data → PV on worker-1)]
      api -. optional .-> svc_vk[Service valkey :6379] --> vk[(Deployment valkey<br/>no volume)]
      cm[ConfigMaps api-config, gateway-nginx] -.-> api
      sec[Secret app-secrets<br/>created at deploy time] -.-> api
      sec -.-> db
      sec -.-> vk
    end
```

The gateway uses the same nginx routing as Compose. `scripts/check-nginx-parity.py` keeps the two configs in step.

## The brief and the real application

The brief describes "MyDiary": Next.js, Spring Boot, PostgreSQL and Redis, with diary entries and search. The code
in the exam repository is **ProjectHub**: a Vite/React SPA, a Go 1.23 API (Gin), MongoDB 7 and Valkey 8, which is a
Redis-compatible fork. It has projects, tasks, three roles (admin, manager, member) and per-project membership. It has
**no search**. This repository deploys the code as it is and does not change the application. The analysis is in
[docs/APP-ANALYSIS.md](docs/APP-ANALYSIS.md). The brief's components map as follows:

| Brief | Here | Notes |
|---|---|---|
| Next.js frontend (`/`) | `frontend` (static SPA) | Same role behind nginx |
| Spring Boot API (`/api`) | `api` (Go) | Health at `/api/health`. JVM heap rule → `GOMEMLIMIT` under the container limit |
| PostgreSQL | `mongodb` | Database with persistent storage |
| Redis cache with password | `valkey` | Same protocol, `--requirepass` |
| Write and search diary entries | Create projects and tasks; list them | No search exists in the code |
| Users see only their own diary | Non-members get an empty project list and 404 | Tested by `scripts/verify.sh` |

The brief also says the template is Ubuntu 24.04. Template 9105 is Kali Linux (read from the Proxmox API,
`monitoring/task1-evidence.txt` §1). The roles are written for Kali, which is Debian-based.

## Known limitation: the Proxmox host is overloaded

The control plane is sometimes briefly unstable, and the cause is outside the cluster. etcd on c3-k8s-master logged 177 `slow fdatasync`
warnings, the worst at 102 s. During the stalls the controller-manager and scheduler lost their leases and
restarted. The guest itself is mostly idle (about 1 GB of 4 GB used, CPU about 90% idle). The Proxmox node `server4` is
overcommitted: swap 7.95 of 8 GiB used, host I/O wait up to 33%, load up to 64, and 48 VMs on shared storage
(read-only from the Proxmox API). The full analysis, what was ruled out and the proposals for the administrator are in
[docs/DECISIONS.md](docs/DECISIONS.md) D-STOR-1 to D-STOR-3.

What was done about it inside the exam's limits: the Valkey probes were changed from exec to TCP (D-K8S-19). The
resilience demo now waits for `/readyz` before each phase and retries kubectl calls. It prints `RESULT: CLEAN` only
when nothing at all went wrong. The proof is honest about both outcomes:

- Clean runs: [monitoring/resilience-evidence.txt](monitoring/resilience-evidence.txt) (laptop, 302 requests, 0 failed) and [monitoring/resilience-master-run.txt](monitoring/resilience-master-run.txt) (on the master, 394 requests, 0 failed). The screenshots below are from a third clean run on the master (387 requests, 0 failed).
- Runs that were not clean, kept on purpose: [monitoring/resilience-attempts/](monitoring/resilience-attempts/). In both, every request still succeeded. The verdict was `NOT CLEAN` because `/readyz` reported `etcd failed` during a host stall.

## Task 1: Infrastructure with Terraform

**What.** `iac/` clones template 9105 four times (full clones, `for_each` over a sizing map in `variables.tf`) with the
`bpg/proxmox` provider (`~> 0.69`, locked at 0.123.1). Cloud-init creates the `devops` user with a password and an
SSH key. `outputs.tf` prints each VM's IP (`vm_ips`) and a `vms` map with role, IP, VM ID and SSH command. No
credential is written in the Terraform files: the Makefile reads them from `.private/secrets.env` into `TF_VAR_*`.

**Reproduce** (needs the Proxmox token in `.private/secrets.env` and a key in `.private/ssh/`):

```bash
make tf-fmt tf-validate   # formatting and validation, no API calls
make tf-init tf-plan      # provider download, plan written to iac/tfplan
make tf-apply             # creates the four VMs
make tf-output            # VM names, IPs, SSH commands
```

**Evidence.** [monitoring/task1-evidence.txt](monitoring/task1-evidence.txt): template check, plan, apply (`4 added`), output, Proxmox
config, and an SSH login with OS and resources on each VM. SSH login as `devops` on each VM:

![SSH login to c3-docker-host](monitoring/screenshots/c3-docker-host-login.png)
*`ssh devops@192.168.160.11`: login as devops; the prompt and the window title show `c3-docker-host`.*

![SSH login to c3-k8s-master](monitoring/screenshots/c3-k8s-master.png)
*`ssh devops@192.168.160.17`: login on `c3-k8s-master`.*

![SSH login to c3-k8s-worker-1](monitoring/screenshots/c3-k8s-worker-1.png)
*`ssh devops@192.168.160.33`: login on `c3-k8s-worker-1`.*

![SSH login to c3-k8s-worker-2](monitoring/screenshots/c3-k8s-worker-2.png)
*`ssh devops@192.168.160.98`: login on `c3-k8s-worker-2`.*

## Task 2: Docker Compose on c3-docker-host

**What.** Five services in [docker/docker-compose.yml](docker/docker-compose.yml): `nginx` (port 80, routes `/` to
the frontend and `/api/` to the API), `frontend`, `api`, `mongodb` (named volume `projecthub-mongo-data`) and
`valkey` (password required, no persistence). Both app images use multi-stage builds, are pushed to Docker Hub, and
the VM only pulls them. It never builds. Every service has a health check, and the API waits for a healthy MongoDB.
The stack is deployed by the Ansible roles `docker_host` (Docker CE from Docker's repository) and `compose_app`
(copies `docker/` to `/opt/projecthub/docker` and the generated `.env` with mode 0600, then runs `docker compose up`).

**Reproduce:**

```bash
make env                         # docker/.env with generated secrets (gitignored, mode 0600)
make hadolint compose-config     # lint the Dockerfiles, validate the Compose file
make docker-push                 # build and push both images (Docker Hub token from .private/secrets.env)
make inventory                   # ansible/inventory.ini from terraform output
make ansible-run                 # includes the docker_host play: installs Docker and starts the stack
make verify BASE_URL=http://192.168.160.11
```

On the VM: `cd /opt/projecthub/docker && docker compose ps`, `docker compose logs --tail=50 api`.

**Evidence.** [monitoring/task2-evidence.txt](monitoring/task2-evidence.txt) (registry tags, `docker compose ps`, host sockets, health,
idempotent Ansible rerun). [monitoring/grading-checks.txt](monitoring/grading-checks.txt) §1 to §4 (multi-stage `FROM` lines, only nginx
publishes a port, the cache answers `NOAUTH` without the password). [monitoring/final-verify.txt](monitoring/final-verify.txt) (39 of 39).

## Task 3: Kubernetes cluster with Ansible

**What.** [ansible/site.yml](ansible/site.yml) runs from the laptop against the inventory that `make inventory`
generates from `terraform output`. Plays, in order:

1. `vm_access` on all four VMs: the devops password (hashed, `no_log`, verified with PAM) and SSH settings.
2. `common`, `kubernetes_prereqs`, `containerd`, `kubernetes_packages` on the three cluster nodes: swap off, kernel modules and sysctls, containerd 2.1 with the systemd cgroup driver, and kubeadm, kubelet and kubectl 1.32.5 (packages held).
3. `k8s_control_plane`: `kubeadm init` (pod CIDR `10.244.0.0/16`), a kubeconfig for `devops`, and Flannel v0.28.11 (vendored in `ansible/files/`).
4. `k8s_worker`: joins both workers with a fresh token.
5. `k8s_node_labels`, `k8s_metrics`, `k8s_verify`: labels the MongoDB node, installs metrics-server v0.9.1 (vendored, with `--kubelet-insecure-tls` because kubeadm kubelets use self-signed certificates), and waits for three Ready nodes.
6. `docker_host`, `compose_app` on c3-docker-host (Task 2).

Every step is idempotent. A second full run reports `changed=0` on every host.

**Reproduce:**

```bash
make ansible-deps ansible-lint ansible-syntax ansible-ping
make ansible-run                  # same as: make ansible
scp -i .private/ssh/id_ed25519 devops@192.168.160.17:.kube/config .private/kubeconfig   # kubectl from the laptop (server is https://192.168.160.17:6443)
```

**Evidence.** [monitoring/task3-evidence.txt](monitoring/task3-evidence.txt) (nodes Ready, kubelet and containerd state, CoreDNS, the
`changed=0` reruns, password and key login checks). Screenshots `c3-k8s-master-kubectl-get-nodes.png` and
`c3-k8s-master-kubectl-get-pods-A.png` in [Monitoring](#monitoring).

## Task 4: Kubernetes application deployment

**What.** The manifests in [k8s/](k8s/) are applied in file order:

| File | Objects |
|---|---|
| `00-namespace.yaml` | Namespace `qt-spring-app` |
| `10-config.yaml` | ConfigMaps `api-config` (database host and name, CORS origins, cache settings) and `gateway-nginx` |
| `20-mongodb.yaml` | PersistentVolume (10Gi, pinned to the node labelled `projecthub/storage=mongo`), PVC, Service, StatefulSet |
| `30-valkey.yaml` | Deployment and Service for the cache (password from the Secret, TCP probes) |
| `40-api.yaml` | Deployment (2 replicas, probes on `/api/health`, `GOMEMLIMIT=400MiB` under a 512Mi limit) and Service |
| `50-frontend.yaml` | Deployment (2 replicas, probes on `/`) and Service |
| `60-gateway.yaml` | nginx Deployment and the NodePort Service on 30080 |

The Secret `app-secrets` (database user and password, cache password, JWT secret) is created at deploy time from
`docker/.env` by `scripts/k8s-secrets.sh` and is never stored in the repository. `k8s/secret.example.yaml` only shows
its shape. Every container, init containers included, has CPU and memory requests and limits.
`scripts/k8s-policy-check.py` enforces that, plus probes and pinned tags, before every deploy.

**Reproduce:**

```bash
export KUBECONFIG=$PWD/.private/kubeconfig
make k8s-validate                 # render, policy, nginx parity, kubeconform strict, server dry-run
make k8s-deploy                   # Secret from docker/.env, apply, wait for every rollout
make k8s-status
make k8s-verify K8S_URL=http://192.168.160.17:30080
```

**Evidence.** [monitoring/task4-evidence.txt](monitoring/task4-evidence.txt) (labels, PV and PVC, pod placement, NodePort on every node).
[monitoring/grading-checks.txt](monitoring/grading-checks.txt) §5 to §8 (every resource kind, requests and limits per container, probes,
heap limit, the cache refuses unauthenticated clients). [monitoring/final-verify.txt](monitoring/final-verify.txt) (39 of 39 on all three node IPs).

### Resilience proof

`scripts/resilience-demo.sh` runs a request loop (`GET /api/health` through the NodePort every 0.2 s) while it:
a) records the starting state; b) scales the API to 3; c) deletes one API pod; d) scales Valkey to 0, checks that
health says `"cache":"down"` and that login and listing still work, then brings Valkey back; e) scales the API back to 2.
It restores the normal state on every exit path and prints a strict verdict.

```bash
KUBECONFIG=.private/kubeconfig scripts/resilience-demo.sh        # from the laptop
scp scripts/resilience-demo.sh devops@192.168.160.17:   # then on the master: bash resilience-demo.sh
```

| Phase | Result (clean run on the master, 11:30 UTC, screenshots below) |
|---|---|
| a. before | API 2/2, Valkey 1/1, MongoDB on worker-1, health `{"status":"ok","database":"up","cache":"up"}` |
| b. API to 3 | 3 of 3 Ready, 93 requests, 0 failed |
| c. delete a pod | replacement Ready, 175 requests, 0 failed |
| d. Valkey to 0 | `"cache":"down"`, login and project list HTTP 200, 100 requests, 0 failed; Valkey back, `"cache":"up"` |
| e. API to 2 | 2 of 2 Ready, 31 requests, 0 failed |
| verdict | 387 requests, 0 failed, 0 kubectl errors, `RESULT: CLEAN` |

### Why the cache has no persistent storage

Valkey holds only data the API can rebuild from MongoDB: dashboard counts and short-lived user lookups, each with a
TTL of one to two minutes. When the cache is empty or down, the API reads MongoDB. That is slower, but still correct,
and phase d above shows it. So Valkey runs with persistence off (`--save ''`, `--appendonly no`) and has no volume. A
volume would only keep disposable data, and it would add one more thing to recover in the failure that matters least.
MongoDB is the source of truth, and it has the PersistentVolume.

## Application functionality

`scripts/verify.sh <base-url>` acts like a browser (page routes, a browser User-Agent, an `Origin` header on every
write) and checks: pages and SPA routes load; health; register two users; login with a good and a bad password; `/auth/me`; a member
cannot create a project (403); a manager creates a project and a task; a non-member sees an empty list and gets 404 on
the project and its tasks; sharing grants access only to the added user; admin sees everything; requests without a token get 401;
an unlisted origin is refused. Result: 39 of 39 on all four URLs ([monitoring/final-verify.txt](monitoring/final-verify.txt)).

There is no search feature in the application, so the brief's "search diary entries" cannot be shown.

## Monitoring

Every screenshot below was taken on the real VM (the prompt and the window title show `devops@<vm>`) while both
deployments were running. The same data is also saved as text with UTC timestamps by
`make collect-monitoring` (read-only) in `monitoring/<vm>/collect-20261123T112333Z.txt`. `kubectl top` uses
metrics-server, installed by the `k8s_metrics` role.

### Every VM: processes, disk, memory, load, ports

| VM | `top -b -n 1 \| head -n 25` | `ps aux --sort=-%cpu \| head -n 25` | `vmstat -w 1 5` | `df -h` | `free -h` | `uptime` | `sudo ss -tulpn` |
|---|---|---|---|---|---|---|---|
| c3-docker-host | [top](monitoring/screenshots/c3-docker-host-top.png) | [ps](monitoring/screenshots/c3-docker-host-ps.png) | [vmstat](monitoring/screenshots/c3-docker-host-vmstat.png) | [df](monitoring/screenshots/c3-docker-host-df.png) | [free](monitoring/screenshots/c3-docker-host-free.png) | [uptime](monitoring/screenshots/c3-docker-host-uptime.png) | [ss](monitoring/screenshots/c3-docker-host-ss.png) |
| c3-k8s-master | [top](monitoring/screenshots/c3-k8s-master-top.png) | [ps](monitoring/screenshots/c3-k8s-master-ps.png) | [vmstat](monitoring/screenshots/c3-k8s-master-vmstat.png) | [df](monitoring/screenshots/c3-k8s-master-df.png) | [free](monitoring/screenshots/c3-k8s-master-free.png) | [uptime](monitoring/screenshots/c3-k8s-master-uptime.png) | [ss](monitoring/screenshots/c3-k8s-master-ss.png) |
| c3-k8s-worker-1 | [top](monitoring/screenshots/c3-k8s-worker-1-top.png) | [ps](monitoring/screenshots/c3-k8s-worker-1-ps.png) | [vmstat](monitoring/screenshots/c3-k8s-worker-1-vmstat.png) | [df](monitoring/screenshots/c3-k8s-worker-1-df.png) | [free](monitoring/screenshots/c3-k8s-worker-1-free.png) | [uptime](monitoring/screenshots/c3-k8s-worker-1-uptime.png) | [ss](monitoring/screenshots/c3-k8s-worker-1-ss.png) |
| c3-k8s-worker-2 | [top](monitoring/screenshots/c3-k8s-worker-2-top.png) | [ps](monitoring/screenshots/c3-k8s-worker-2-ps.png) | [vmstat](monitoring/screenshots/c3-k8s-worker-2-vmstat.png) | [df](monitoring/screenshots/c3-k8s-worker-2-df.png) | [free](monitoring/screenshots/c3-k8s-worker-2-free.png) | [uptime](monitoring/screenshots/c3-k8s-worker-2-uptime.png) | [ss](monitoring/screenshots/c3-k8s-worker-2-ss.png) |

What each one shows: **top**: CPU split, memory, task counts, load average and the busiest processes. **ps**: every
process with its CPU and memory share, sorted by CPU (first 25 lines). **vmstat**: run queue, memory, swap, block I/O
in and out (`bi`, `bo`), interrupts, context switches and CPU split including I/O wait (`wa`), once a second for 5 s. **df -h**:
space per partition. **free -h**: total, used and available memory (no swap, as Kubernetes expects). **uptime**:
time since boot and the 1, 5 and 15 minute load averages. **ss -tulpn**: listening TCP and UDP ports and the process behind each.

#### c3-docker-host (192.168.160.11)

![c3-docker-host top](monitoring/screenshots/c3-docker-host-top.png)
*`top`: CPU, memory, load and the busiest processes on the Docker host.*

![c3-docker-host ps](monitoring/screenshots/c3-docker-host-ps.png)
*`ps aux --sort=-%cpu | head -n 25`: processes by CPU and memory on the Docker host: mongod, dockerd, containerd, the Go API (uid 10001) and valkey-server.*

![c3-docker-host vmstat](monitoring/screenshots/c3-docker-host-vmstat.png)
*`vmstat -w 1 5`: virtual memory, block I/O and CPU on the Docker host: no swap, almost no block I/O, CPU 94 to 100% idle.*

![c3-docker-host df](monitoring/screenshots/c3-docker-host-df.png)
*`df -h`: disk space per partition.*

![c3-docker-host free](monitoring/screenshots/c3-docker-host-free.png)
*`free -h`: total, used and available memory.*

![c3-docker-host uptime](monitoring/screenshots/c3-docker-host-uptime.png)
*`uptime`: 1, 5 and 15 minute load averages.*

![c3-docker-host ss](monitoring/screenshots/c3-docker-host-ss.png)
*`sudo ss -tulpn`: besides SSH (22) and the local resolver, only port 80 (docker-proxy for nginx) listens. MongoDB and Valkey have no host port.*

#### c3-k8s-master (192.168.160.17)

![c3-k8s-master top](monitoring/screenshots/c3-k8s-master-top.png)
*`top`: CPU, memory, load and the busiest processes on the control plane.*

![c3-k8s-master ps](monitoring/screenshots/c3-k8s-master-ps.png)
*`ps aux --sort=-%cpu | head -n 25`: processes by CPU and memory on the control plane: kube-apiserver, kubelet, etcd, kube-controller-manager, kube-scheduler, CoreDNS and Flannel.*

![c3-k8s-master vmstat](monitoring/screenshots/c3-k8s-master-vmstat.png)
*`vmstat -w 1 5`: virtual memory, block I/O and CPU on the control plane: no swap, small block writes (`bo`), CPU 91 to 98% idle, I/O wait 6% on the first sample only.*

![c3-k8s-master df](monitoring/screenshots/c3-k8s-master-df.png)
*`df -h`: disk space per partition.*

![c3-k8s-master free](monitoring/screenshots/c3-k8s-master-free.png)
*`free -h`: memory.*

![c3-k8s-master uptime](monitoring/screenshots/c3-k8s-master-uptime.png)
*`uptime`: load averages.*

![c3-k8s-master ss](monitoring/screenshots/c3-k8s-master-ss.png)
*`sudo ss -tulpn`: kube-apiserver 6443, etcd 2379/2380, kubelet 10250, kube-proxy 10256, Flannel VXLAN UDP 8472. NodePort 30080 has no socket: kube-proxy forwards it with iptables rules.*

#### c3-k8s-worker-1 (192.168.160.33)

![c3-k8s-worker-1 top](monitoring/screenshots/c3-k8s-worker-1-top.png)
*`top`: CPU, memory, load and the busiest processes on worker-1.*

![c3-k8s-worker-1 ps](monitoring/screenshots/c3-k8s-worker-1-ps.png)
*`ps aux --sort=-%cpu | head -n 25`: processes by CPU and memory on the worker-1: kubelet, containerd, mongod (the main MongoDB), two API pods and kube-proxy.*

![c3-k8s-worker-1 vmstat](monitoring/screenshots/c3-k8s-worker-1-vmstat.png)
*`vmstat -w 1 5`: virtual memory, block I/O and CPU on the worker-1: no swap, little block I/O, CPU 90 to 98% idle.*

![c3-k8s-worker-1 df](monitoring/screenshots/c3-k8s-worker-1-df.png)
*`df -h`: disk space per partition (the MongoDB volume is under `/srv/projecthub/mongo` on this node).*

![c3-k8s-worker-1 free](monitoring/screenshots/c3-k8s-worker-1-free.png)
*`free -h`: memory.*

![c3-k8s-worker-1 uptime](monitoring/screenshots/c3-k8s-worker-1-uptime.png)
*`uptime`: load averages.*

![c3-k8s-worker-1 ss](monitoring/screenshots/c3-k8s-worker-1-ss.png)
*`sudo ss -tulpn`: kubelet 10250, kube-proxy 10256, Flannel VXLAN UDP 8472 and SSH.*

#### c3-k8s-worker-2 (192.168.160.98)

![c3-k8s-worker-2 top](monitoring/screenshots/c3-k8s-worker-2-top.png)
*`top`: CPU, memory, load and the busiest processes on worker-2.*

![c3-k8s-worker-2 ps](monitoring/screenshots/c3-k8s-worker-2-ps.png)
*`ps aux --sort=-%cpu | head -n 25`: processes by CPU and memory on the worker-2: kubelet, containerd, mongod (the Helm copy's MongoDB), API and Valkey pods, and metrics-server.*

![c3-k8s-worker-2 vmstat](monitoring/screenshots/c3-k8s-worker-2-vmstat.png)
*`vmstat -w 1 5`: virtual memory, block I/O and CPU on the worker-2: no swap, little block I/O, CPU 83 to 99% idle.*

![c3-k8s-worker-2 df](monitoring/screenshots/c3-k8s-worker-2-df.png)
*`df -h`: disk space per partition.*

![c3-k8s-worker-2 free](monitoring/screenshots/c3-k8s-worker-2-free.png)
*`free -h`: memory.*

![c3-k8s-worker-2 uptime](monitoring/screenshots/c3-k8s-worker-2-uptime.png)
*`uptime`: load averages.*

![c3-k8s-worker-2 ss](monitoring/screenshots/c3-k8s-worker-2-ss.png)
*`sudo ss -tulpn`: kubelet 10250, kube-proxy 10256, Flannel VXLAN UDP 8472 and SSH.*

The same data, with `ps` also sorted by memory, is in the text snapshot of each VM: [docker host](monitoring/c3-docker-host/collect-20261123T112333Z.txt),
[master](monitoring/c3-k8s-master/collect-20261123T112333Z.txt), [worker-1](monitoring/c3-k8s-worker-1/collect-20261123T112333Z.txt),
[worker-2](monitoring/c3-k8s-worker-2/collect-20261123T112333Z.txt). The snapshots also record I/O pressure (PSI).

### Docker host: containers, logs, cache, health

![docker ps](monitoring/screenshots/c3-docker-host-docker-ps.png)
*`docker ps`: the five containers, all `healthy`.*

![docker stats](monitoring/screenshots/c3-docker-host-docker-stats.png)
*`docker stats --no-stream`: CPU, memory, network and block I/O per container.*

![API log](monitoring/screenshots/c3-docker-host-api-logs.png)
*`docker compose logs --tail=50 api`: the last 50 lines of the API log.*

![Valkey cache](monitoring/screenshots/c3-docker-host-valkey-cache.png)
*Valkey (`valkey-cli info memory`, `info stats`, key scan): memory used, keyspace hits and misses, number of cached keys.*

![health through nginx](monitoring/screenshots/c3-docker-host-health.png)
*`curl http://127.0.0.1/api/health` on the Docker host: database and cache up.*

### Control plane: nodes, pods, metrics, health

![kubectl get nodes](monitoring/screenshots/c3-k8s-master-kubectl-get-nodes.png)
*`kubectl get nodes -o wide`: three nodes Ready, v1.32.5, containerd.*

![kubectl get pods -A](monitoring/screenshots/c3-k8s-master-kubectl-get-pods-A.png)
*`kubectl get pods -A -o wide`: every pod with its status, restarts and node.*

![kubectl top nodes](monitoring/screenshots/c3-k8s-master-kubectl-top-nodes.png)
*`kubectl top nodes`: CPU and memory per node from metrics-server.*

![health through the NodePort](monitoring/screenshots/c3-k8s-master-health.png)
*`curl http://127.0.0.1:30080/api/health` on the master: the Kubernetes deployment through the NodePort.*

### Resilience demo on the master (one clean run, 11:30 to 11:32 UTC)

![start](monitoring/screenshots/resilience-demo-start.png)
*The script is copied to the master, then run there as devops.*

![SSH and phase a](monitoring/screenshots/resilience-demo-ssh-and-phase-a.png)
*Full window: SSH to the master and phase a (pods before, health with the cache up).*

![phase a](monitoring/screenshots/resilience-demo-initial-state.png)
*Phase a: API 2/2, frontend 2/2, gateway 2/2, Valkey 1/1, health `cache: up`.*

![phase b](monitoring/screenshots/resilience-demo-scale-pods.png)
*Phase b: the API scaled to 3; three API pods Ready on both workers.*

![phase c](monitoring/screenshots/resilience-demo-pod-delete.png)
*Phase c: one API pod deleted while the request loop runs; a replacement becomes Ready.*

![phase d](monitoring/screenshots/resilience-demo-cache-down.png)
*Phase d: Valkey scaled to 0; three health samples report `"cache":"down"`, login as the manager works and the project list returns HTTP 200; Valkey comes back and health reports `"cache":"up"`.*

![phase e](monitoring/screenshots/resilience-demo-cache-down-restore-to-the-initial-state.png)
*Phase e: the API back to 2 replicas, Valkey back to 1. The pod in `Completed` is a replica shutting down normally.*

![summary](monitoring/screenshots/resilience-demo-summary.png)
*Verdict: 387 requests, 0 failed, per-phase counts, final state correct, `RESULT: CLEAN`.*

### The application in a browser

![Compose login](monitoring/screenshots/app-compose-login.png)
*Docker Compose, http://192.168.160.11: the login page.*

![Compose dashboard](monitoring/screenshots/docker-deployed-dashboard.png)
*Docker Compose: the dashboard after logging in as admin (project and task counts).*

![Compose project list](monitoring/screenshots/app-compose-project.png)
*Docker Compose: the project list after login.*

![Compose project page](monitoring/screenshots/docker-deployed-project-page.png)
*Docker Compose: a project with its team and tasks by status.*

![Compose new project form](monitoring/screenshots/docker-deployed-create-project-page.png)
*Docker Compose: a manager opens the new-project form.*

![Compose users page](monitoring/screenshots/docker-deployed-users-page.png)
*Docker Compose: the admin-only user list.*

![Compose 403 page](monitoring/screenshots/docker-deployed-403-page.png)
*Docker Compose: a manager who opens `/users` gets 403. This is the role check working (only admins may see users).*

![Kubernetes login](monitoring/screenshots/app-k8s-login.png)
*Kubernetes, http://192.168.160.17:30080: the login page.*

![Kubernetes project](monitoring/screenshots/app-k8s-project.png)
*Kubernetes: editing a project after login as admin.*

![Kubernetes users page](monitoring/screenshots/K8s-deployed-users-page.png)
*Kubernetes: the admin-only user list through the NodePort.*

## Bonus

### Helm chart (done)

[k8s/helm/projecthub/](k8s/helm/projecthub/) packages the same stack. Its default values render **the same 14 objects
as `k8s/`**: `scripts/helm-parity.py` compares them field by field and ignores only labels and the config-hash
annotation. [values.yaml](k8s/helm/projecthub/values.yaml) holds the images and tags, the replica counts, the requests and limits of every container,
the NodePort, the CORS origins and the PersistentVolume placement. The chart contains **no secret and no Secret
template**: it reads the existing Secret `app-secrets`, which `make helm-deploy` creates from `docker/.env` just
before the install (the same `scripts/k8s-secrets.sh` as Task 4).

The release runs as a second copy next to the plain deployment, with
[k8s/helm/values-qt-spring-app-helm.yaml](k8s/helm/values-qt-spring-app-helm.yaml): namespace `qt-spring-app-helm`, NodePort **30081**,
and its own PersistentVolume `projecthub-helm-mongo-data` pinned by hostname to `c3-k8s-worker-2`.

```bash
make helm-lint        # helm lint, helm template, policy check, kubeconform strict, parity with k8s/
make helm-deploy      # Secret from docker/.env, then helm upgrade --install --wait
make k8s-verify K8S_URL=http://192.168.160.17:30081
make helm-uninstall   # removes the release, the namespace and the PV (the data directory stays on worker-2)
```

URL: http://192.168.160.17:30081 (also .33 and .98). `verify.sh`: 39 of 39 on all three node IPs.
Evidence: [monitoring/bonus-evidence.txt](monitoring/bonus-evidence.txt). The main URL stays NodePort 30080.

![Helm release objects](monitoring/screenshots/c3-k8s-master-helm-objects.png)
*`kubectl -n qt-spring-app-helm get pods,svc,pvc -o wide` on the master: every pod Running, the gateway on NodePort 30081, and the claim bound to `projecthub-helm-mongo-data` (MongoDB on worker-2).*

![Helm copy login](monitoring/screenshots/app-helm-login.png)
*http://192.168.160.17:30081/login: the Helm copy's login page, signing in as the member account.*

![Helm copy dashboard](monitoring/screenshots/app-helm-dashboard.png)
*The Helm copy after login as a member: the dashboard lists only the tasks assigned to that user.*

![Helm copy projects](monitoring/screenshots/app-helm-projects.png)
*The Helm copy, Projects page for the member: only the one project the member belongs to is listed.*

During the install, etcd stalled for up to 6.4 s and the scheduler and controller-manager restarted once each. This
is the host limitation described above. Both recovered within a minute, and both deployments kept passing every check.

### Gateway API (not attempted)

This bonus was to be attempted only if the Helm install left the cluster calm. It did not: a short burst of API writes
was enough to restart two control-plane components. A Gateway API controller and its CRDs add more writes to the
same etcd, so this bonus was skipped to keep the required deployments safe. The reasoning is in
[docs/DECISIONS.md](docs/DECISIONS.md) D-GW-1.

## Troubleshooting

- Health: `curl http://<host>/api/health` returns 200 with `database` and `cache`, or 503 when MongoDB is down.
- Logs: on the Docker host `cd /opt/projecthub/docker && docker compose logs --tail=50 api`. On the cluster `kubectl -n qt-spring-app logs deploy/api --tail=50`.
- Pods not Ready: `kubectl -n qt-spring-app describe pod <name>` and `kubectl -n qt-spring-app get events --sort-by=.lastTimestamp`.
- Login returns 403 in a browser: the page's origin is not in `CORS_ORIGINS` (`k8s/10-config.yaml` and `docker/docker-compose.yml`). Add the exact origin (scheme, host, port) and redeploy. Background: [docs/DECISIONS.md](docs/DECISIONS.md) D-CORS-1.
- kubectl timeouts or `etcdserver: request timed out`: see [Known limitation](#known-limitation-the-proxmox-host-is-overloaded). Wait for `kubectl get --raw=/readyz` to return `ok`.
