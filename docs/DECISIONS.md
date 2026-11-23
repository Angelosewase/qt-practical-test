# Decisions

## D1. Template 9105 is Kali Linux, not Ubuntu 24.04 (VERIFIED)

The brief is inconsistent: the header says "Kali Linux" and Task 1 says "Ubuntu 24.04 LTS". The Proxmox API settles it. Read via `GET /nodes/server4/qemu/9105/config` and `.../status/current` (token permissions granted by the exam admin):

| Property | Value | Consequence for the Terraform and Ansible |
|---|---|---|
| name | `kali-linux` | Template is Kali Linux. The brief's "Ubuntu 24.04" is wrong. |
| ostype | `l26` | Linux guest; `operating_system.type = "l26"` in `iac/variables.tf` |
| cloud-init drive | `ide2 = local-lvm:vm-9105-cloudinit` | Cloud-init is present. `initialization` creates the `devops` user and SSH key. |
| template ciuser | `qt` (with a stored template password) | Not used. Our `user_account` block creates `devops` and overrides it. |
| QEMU guest agent | `agent=enabled=1` | Terraform can read IPs from the agent. The 10-minute wait is kept as a safety net. |
| disk | `scsi0 = base-9105-disk-0, size=30G` | The clone size of 30 GB equals the template, so no shrink error occurs. |
| CPU / RAM | 2 cores, 2048 MB | Overridden to 4 vCPU and 4096 MB per VM, as the brief requires. |
| network | `net0 virtio, vmbr0`, `ipconfig0 ip=dhcp` | DHCP on the VM network; IPs come from the guest agent. |
| serial | `serial0 socket`, `vga serial0` | Console available over serial. |

Package manager: Kali is Debian-based, so the Ansible roles use `apt` and the `pkgs.k8s.io` Debian repository. The package and sysctl steps were confirmed on this OS before the full playbook runs (section "Verified on each VM" below).

Action taken: the Terraform files, the Makefile and the README were kept, because the template supports everything they need. The `os_type` default stays `l26`.

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

## Verified on each VM (applied infrastructure, read-only checks)

Applied with `make tf-apply` (4 added, 0 changed, 0 destroyed). Each VM was checked over SSH as `devops` with `.private/ssh/id_ed25519`:

| VM | IP (DHCP) | VM ID | OS | Kernel | vCPU | RAM (free) | Root disk | sudo without password |
|---|---|---|---|---|---|---|---|---|
| c3-docker-host | 192.168.160.11 | 119 | Kali GNU/Linux Rolling | 7.1.5+kali-cloud-amd64 | 4 | 3919 MB of 4096 configured | 30 GB (27 GB free) | yes |
| c3-k8s-master | 192.168.160.17 | 120 | Kali GNU/Linux Rolling | 7.1.5+kali-cloud-amd64 | 4 | 3919 MB of 4096 configured | 30 GB (27 GB free) | yes |
| c3-k8s-worker-1 | 192.168.160.33 | 100 | Kali GNU/Linux Rolling | 7.1.5+kali-cloud-amd64 | 4 | 3919 MB of 4096 configured | 30 GB (27 GB free) | yes |
| c3-k8s-worker-2 | 192.168.160.98 | 121 | Kali GNU/Linux Rolling | 7.1.5+kali-cloud-amd64 | 4 | 3919 MB of 4096 configured | 30 GB (27 GB free) | yes |

Findings for the Kubernetes prerequisites on Kali (checked, not yet applied):

- **Swap:** none (SwapTotal 0, no swap in /etc/fstab). The swap tasks are kept for idempotency. They are no-ops here.
- **Kernel modules:** `overlay` and `br_netfilter` exist as modules for this kernel and are not loaded yet. The role loads them now and persists them in `/etc/modules-load.d/k8s.conf`.
- **Sysctls:** `net.ipv4.ip_forward` is 0 now, and the bridge sysctls appear only once `br_netfilter` is loaded. The role writes `/etc/sysctl.d/99-kubernetes.conf`.
- **containerd:** Kali ships containerd 2.1.9. Its default config has `SystemdCgroup = false` on line 108. The role replaces it with `true`, and a verification task fails the run if the change is missing. The sandbox image is `registry.k8s.io/pause:3.10`, which matches kubeadm 1.32.
- **Kubernetes packages:** `pkgs.k8s.io` v1.32 returns the key and `Release` with HTTP 200. The package index lists kubeadm, kubelet and kubectl at `1.32.5-1.1`. The role pins `1.32.5-*` and holds the packages.
- **systemd 261, iptables 1.8.13 (nf_tables), Python 3.14** on the VMs. Ansible uses `/usr/bin/python3`.
- **Kernel 7.1 risk:** Kubernetes 1.32 is officially tested on LTS kernels. A rolling-kernel 7.1 is newer than that. Expect possible kubelet or cgroup issues. Recorded as a risk; the first kubeadm init will show it.

## D-ANS-1. Ansible roles are written for Kali (Debian family)

Packages come from apt (Kali repo for containerd and base tools, `pkgs.k8s.io` for kubeadm, kubelet and kubectl). Collections are pinned in `ansible/requirements.yml` (`ansible.posix` 2.1.0, `community.general` 12.1.0).

## D-ANS-2. The Kubernetes apt source is written as a deb822 file

The repo is a `.sources` file written with `copy`. `deb822_repository` needs `python3-debian` on the target, which is installed only by a real run. Writing the file directly works the same way and runs in check mode too.

## D-ANS-3. Check mode guards

Some tasks depend on state that check mode does not create: the containerd config file, the containerd and kubelet units, and the packages from the repo (only added in a real run). Those tasks run only when `not ansible_check_mode`. Check mode still covers everything else. Check-mode result on all three k8s nodes and the docker host: `failed=0`.

## D-ANS-4. Inventory is generated from terraform output

`scripts/gen-inventory.sh` writes `ansible/inventory.ini` (gitignored) from `terraform output -json vm_ips`. Nothing is typed by hand, so the IPs can't drift. The file holds IPs and a key path, no secrets.

## D-ANS-5. DHCP addresses

The VMs use DHCP (the template's `ip=dhcp`). The IPs are recorded here, but a DHCP lease can change after a reboot. Before submission, check `make tf-output` again and regenerate the inventory. A static reservation on the router, or static IPs in Terraform, would remove this risk. I did not change this, to keep the VMs as they are.

## D-ANS-6. iothread warning left in place

`terraform apply` warns that `iothread` is ignored on `virtio-scsi-pci`. Setting `iothread = false` made Terraform plan an in-place update on all four VMs. Proxmox ignores the flag on this controller, so it has no effect. Leaving the configuration as it was avoids touching freshly created VMs. The warning is cosmetic.

## D-CL-1. Cluster build: kubeadm, containerd, Flannel

- kubeadm 1.32.5 on a control plane at `192.168.160.17`, with pod CIDR `10.244.0.0/16`, `--node-name` set to the inventory hostname, and `--apiserver-advertise-address` set to the VM's own IP.
- Flannel v0.28.11, vendored into `ansible/files/kube-flannel-v0.28.11.yml` (sha256 `bc9e5462…8133`). The playbook does not download anything at run time, so a rerun cannot pick up a different manifest. Its default network is `10.244.0.0/16`, matching the CIDR.
- containerd 2.1.9 with `SystemdCgroup = true`. kubeadm 1.32 defaults the kubelet to the systemd driver, and Kali runs cgroup v2 (`cgroup2fs`), so the two agree.

## D-CL-2. Kali's containerd config is replaced

Kali's `containerd` package ships a minimal `/etc/containerd/config.toml` (255 bytes). A "creates" guard kept that file, so the cgroup setting was never written. The role now writes the full `containerd config default`, with `SystemdCgroup = true`, and replaces the file only when its content differs. A verification task fails the run if the setting is missing.

## D-CL-3. kubelet reads the real resolver config

Kali's `/etc/resolv.conf` points at the systemd-resolved stub (`127.0.0.53`). Without a fix, CoreDNS would detect a forwarding loop. `/etc/default/kubelet` sets `--resolv-conf=/run/systemd/resolve/resolv.conf`. Verified: CoreDNS logs show zero loop messages.

## D-CL-4. Idempotent join and init

- `kubeadm init` runs only when `/etc/kubernetes/admin.conf` is missing (`stat` guard).
- A worker joins only when `/etc/kubernetes/kubelet.conf` is missing. The join command is requested from the control plane only in that case, with a one-hour token, so rerunning the playbook never creates new tokens.
- Tasks that print tokens use `no_log`, so bootstrap tokens and discovery hashes never reach the logs or the evidence file. Checked: none present.

## D-CL-5. Kernel 7.1 and cgroups: no issue observed

The Kali kernel is 7.1.5, newer than Kubernetes 1.32's tested LTS kernels. The cluster initialised, joined, and reached Ready on all nodes with no kubelet or cgroup errors. The risk is recorded, not an active problem.

## D-CL-6. The devops kubeconfig

`/home/devops/.kube/config` is a copy of the cluster admin config, owned by devops with mode 0600. Verified by logging in as devops over SSH and running `kubectl get nodes`. Copying the admin credential to a login user is acceptable on this single-tenant exam cluster. The tradeoff is that devops has cluster-admin rights, and this is noted.

## D-CL-7. devops password, set through Ansible and verified with PAM

The password step (`roles/vm_access`, tag `vm_access`) reads `VM_PASSWORD` from the environment (`make ansible-run` sources `.private/secrets.env`). It sets the password with `chpasswd`, value on stdin, with `no_log`, so the value never appears in arguments or logs.

Idempotency: Kali hashes passwords with yescrypt (`$y$`). Recomputing a SHA-512 hash, as the first draft did, can never match, so the password was reset on every run (run 8, found and fixed). The current check runs `unix_chkpwd`, the PAM helper that sshd and su use, with the password on stdin terminated by NUL. It returns 0 for the right password and 7 for a wrong one (tested on the VM). The password is set only when the check fails.

Verified: password login as devops works (`Authenticated ... using "password"`), and key login still works with password authentication disabled. Run 9 reported `changed=0` on all hosts, including the password task.

Password login is enabled through `/etc/ssh/sshd_config.d/10-exam-access.conf`, validated with `sshd -t` before reload. Key login stays enabled.

## D-CL-8. Terraform and the password

`TF_VAR_vm_password` is taken from the same `VM_PASSWORD`. Changing that value makes Terraform plan a change to the VMs' cloud-init user settings. The VMs must not be replaced for a password change, so the password is set with Ansible and Terraform is not re-applied for it. Running `make tf-apply` after a password change would plan an update; avoid it.

## D-DH-1. Docker Engine from the official Docker repository, not Kali's package

Kali ships `docker.io` 28.5 and a standalone `docker-compose` v2 binary, but no `docker compose` plugin. The Docker CE repository for Debian trixie (Kali rolling's base, reachable from the VMs) provides `docker-ce`, `docker-compose-plugin` and `docker-buildx-plugin`. The role verifies the signing key fingerprint `9DC858229FC7DD38854AE2D88D81803C0EBFCD88` before the key is trusted, and fails if it does not match. Installed on the VM: Docker 29.10.0, Compose v5.8.0.

## D-DH-2. The devops user is in the docker group

Docker group membership is root-equivalent. This is an accepted tradeoff: devops is the single administrative account on a single-tenant exam VM, and the same user already has passwordless sudo (set by Kali's cloud-init). Ansible needs root only for installation, so this does not change the security picture much. Noted, not hidden.

## D-DH-3. Images are pushed by explicit version tags

Both images are tagged `1.0.0` (never `latest`) and built for `linux/amd64`. Tags were read back from Docker Hub after the push. Digests: api `sha256:54bf67c39569…`, frontend `sha256:24468276db5c…`. The compose file pins the same tags through `API_TAG` and `FRONTEND_TAG`. Third-party images are pinned too: `mongo:7.0.14`, `valkey/valkey:8.1.12-alpine`, `nginx:1.27.5-alpine`.

## D-DH-4. Pushing from a clean Docker config

On this laptop, `docker login` tries to save credentials through a `pass` credential helper that is not initialised. The save fails, and the push goes out unauthenticated, which Docker Hub reports as `insufficient_scope`. `make docker-push` now logs in with a throwaway `DOCKER_CONFIG` in `.tmp/` (gitignored), removed on exit. The host's `~/.docker` is unchanged.

## D-DH-5. The two repositories were created through the Docker Hub API

The push needs the repositories to exist. I created `angelsewase/projecthub-api` and `angelsewase/projecthub-frontend` with the same token (public, description "ProjectHub exam image"). This is an action on the exam Docker Hub account, recorded here so it is not a surprise.

## D-DH-6. The VM runs images from Docker Hub and never builds

The compose file keeps its build sections for local work. On the VM, the Ansible role runs `docker compose pull`, then `up -d --no-build --wait`, so the deployed code is exactly the pushed image. The compose project lives in `/opt/projecthub/docker`, with the compose file, `nginx.conf`, and the `.env`.

## D-DH-7. Secrets reach the VM through no_log and a 0600 file

`docker/.env` (MongoDB, Valkey and JWT secrets) is copied with `no_log`, mode 0600, owned by devops. It is never printed in the run output. Verified: mode 600 on the VM.

## D-DH-8. Bounded container logs

`/etc/docker/daemon.json` sets the json-file driver with 10 MB files, 3 kept per container. The VM has 30 GB of disk, and an unbounded log could fill it during a long exam. `docker compose logs` still works for readable tails.

## D-DH-9. Network exposure is checked on the VM

`ss -tlnH` on the VM shows only ports 22 and 80 listening on the application side (53 and 5355 belong to systemd-resolved). MongoDB and Valkey have no host mapping, and the `data` network is internal. Evidence: `monitoring/task2-evidence.txt`, section 4.

## D-DH-10. The Compose stack is deployed by Ansible, idempotently

The `docker_host` and `compose_app` roles run in the full playbook. A second full run reported `changed=0` on every host. The `compose up --wait` task reports a change only when a container was started or recreated, and the `daemon.json` change restarts docker only when it actually changes.
