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

## D-K8S-15. The MongoDB node label is set by Ansible

The PV's nodeAffinity needs `projecthub/storage=mongo` on one worker. Setting it by hand would break "no manual steps", so the role `k8s_node_labels` labels `k8s_mongo_node` (c3-k8s-worker-1, in `group_vars/all.yml`) and only when the label is missing. Verified: the playbook changed only that label. The PV is Bound, and `mongodb-0` runs on the node.

## D-K8S-16. API init container waits for MongoDB

The first deploy showed the API exiting once: the MongoDB StatefulSet started later than the API's 60-second connect timeout, and the Go API exits when that expires (by design). An init container (`wait-for-mongodb`, pinned alpine 3.21.10) now waits for `mongodb:27017`. The API still retries its own connection. The rollout after this change showed 0 restarts.

## D-K8S-17. Kubeconfig on the laptop

`.private/kubeconfig` is a copy of the control plane's devops kubeconfig (server `https://192.168.160.17:6443`, which is already the right address, so no rewrite was needed). It is gitignored, mode 0600, and never printed. Every Make target and script uses an explicit `KUBECONFIG`, so the stale default context on the laptop is never used.

## D-K8S-18. The resilience proof is a script, not a one-off

`scripts/resilience-demo.sh` runs the same sequence the evidence shows and timestamps every line. It takes its settings from the environment (node IP, NodePort, normal replica count), uses only the seeded test account, and prints no secret. It runs on the laptop or on the control plane (verified on both). The request loop is cleaned up on exit, and the trap signals only a real loop PID. An earlier version signalled PID 0, which signalled the whole process group, including the caller.

## D-RES-1. Why the cache has no persistence

Valkey caches only what MongoDB can rebuild, with TTLs of one to two minutes. Persistence would store disposable data, so the cache runs without `--save` and without `appendonly`, and has no PersistentVolume. The database has the only PersistentVolume. The application degrades gracefully: with the cache down, `/api/health` reports `cache: "down"` with HTTP 200, and reads go to MongoDB.

## D-RES-2. Measured request gap in the loop

The loop sleeps 0.2 s after each request. Each request takes a few tens of milliseconds, so the measured average gap is about 0.26 s. That is reported as measured, not as exactly 0.2 s.

## D-MON-1. metrics-server v0.9.1, vendored, with --kubelet-insecure-tls

`kubectl top` needs metrics-server. Installed by the role `k8s_metrics`, pinned to v0.9.1, the current release (checked against the GitHub API). The manifest is vendored as `ansible/files/metrics-server-v0.9.1-insecure-tls.yaml`: the upstream file with one documented added line. (The first version patched a copy with `lineinfile` on every run, which was not idempotent; see D-ANS-7.) The patch adds `--kubelet-insecure-tls` because kubeadm kubelets serve self-signed certificates. Tradeoff: the kubelet's certificate is not verified for metrics scraping. A production cluster would issue kubelet serving certificates and approve their CSRs. For a single-tenant exam cluster on a private network, the risk is accepted and recorded here. The role waits until `kubectl top nodes` returns three rows.

## D-MON-2. Collection is read-only and runs from the laptop

`scripts/collect.sh` runs on each VM. The laptop-side script `scripts/collect-monitoring.sh` copies it to `/tmp`, runs it, and deletes it. It changes nothing on the VM. The tool reads the hostname from the VM and stops if it does not match the Terraform name, so output cannot be saved under the wrong host. Commands get `</dev/null` so no command can consume the script's input. Every section has a UTC timestamp and the host name, and each tool runs only on the VMs that have it.

## D-MON-3. Valkey statistics come from inside the container

Cache memory, hits and misses, and key counts are read with the container's own `valkey-cli`. The password comes from the container environment (`REDISCLI_AUTH`), so it never appears on a command line or in the saved output. The saved output has no secret values (checked).

## D-MON-4. Screenshots are taken by hand

The brief requires screenshots of the real VMs, the real browser and the real master, so they cannot be generated. The owner took them. They are in `monitoring/screenshots/`, and the README embeds every one with a caption that names the command. The capture checklist that guided them (`monitoring/SCREENSHOTS.md`) was removed before submission (docs/CLEANUP.md).

## D-MON-5. Final verification and IP check

`scripts/verify.sh` ran against both URLs (34 of 34 each at the time; after D-VERIFY-1 the script has 39 checks, and `monitoring/final-verify.txt` holds the 39-of-39 run on all four URLs). For IPs, `make tf-output` reads only the Terraform state, so it cannot show a DHCP change by itself. The check that matters is the address each VM reports for itself. Those match the state exactly (table in WORKLOG), so no IP has changed. `make tf-apply` was not run.

## D-K8S-19. Valkey probes are TCP, not exec

The Valkey readiness probe ran `sh -c 'valkey-cli ping | grep -q PONG'` with a 3-second timeout. An exec probe starts a shell and a client inside the container, and during the disk stalls (D-STOR-1) that exceeded 3 seconds. The pod stayed NotReady for about 10 minutes after the scale-up at 10:52 UTC, and the rollout timed out. Both probes are now `tcpSocket` on port 6379 (timeout 5 s). A new ReplicaSet came up Ready in 12 seconds. Valkey runs with the Recreate strategy, so the change caused a short cache outage, which the cache design tolerates. The MongoDB probes were left alone: changing them restarts the database pod, and no MongoDB probe failure was seen.

## D-DEMO-1. The demo verdict has strict rules

`scripts/resilience-demo.sh` retries every kubectl call up to five times, logs each error, and counts it. Before each phase it waits for `/readyz` to answer `ok` three times in a row (up to 240 s), and it logs a clear `TIMEOUT` line for anything it gives up on. On every exit path (success, failure, Ctrl-C) it restores Valkey to 1 and the API to 2, retrying each step. The verdict is `CLEAN` only when there are zero kubectl errors, zero failed phases, zero failed requests, and the final state is correct. Otherwise it exits 1 and says why.

## D-STOR-1. Root cause: the Proxmox host's storage and memory are overcommitted

Evidence (all from inside the VMs, or read-only from the Proxmox API):

- etcd on the control plane logged 177 `slow fdatasync` warnings (over 1 s each), 13 of them over 10 s, the worst 102.3 s (10:57:35 UTC). The first one was at 09:06, when the cluster was being built. Each `fdatasync` is needed before etcd can commit a write, so a stall blocks every API request.
- During the stalls, the leader-election leases of kube-controller-manager and kube-scheduler could not be renewed. Both exited, and kubelet restarted them 10 times each (CrashLoopBackOff). The API server restarted 5 times.
- The guest is not short of resources: 3.9 GB RAM with 2.9 GB free, no swap, no OOM kill, CPU about 90% idle, load 2.0 at the worst. The kernel log has no block-device errors (only boot messages).
- The master itself wrote only 30 to 86 KB/s during the stalls (Proxmox RRD for VM 120). The stalls are the storage queue backing up, not this VM's own write load.
- The same stalls appear on a worker, under synthetic load (see D-STOR-2): fsync maximum 22 to 30 s with and without `discard`, against 0.9 ms when idle.
- Host `server4` (Proxmox API, read-only): memory 112.9 of 125.8 GiB used, swap 7.95 of 8.0 GiB used, host I/O wait up to 33% (10:59 UTC) and 28% (11:04 UTC), load average up to 64. The node runs 48 VMs, including other candidates' VMs in pools `exam-c6` and `exam-c7`. The storage is shared, so the exam VMs wait behind other workloads. Which VM causes the contention cannot be seen from the pool we have access to.

## D-STOR-2. Things tested and ruled out, or only partly helpful

- **Online discard** (`discard` in fstab and `discard=on` in Terraform). Tested on a worker: remounting without it did not remove the stalls. The count of fsyncs over 100 ms was 96 and 165 without discard, against 48 with it. Not the cause, and not changed.
- **Smaller dirty-page limits** (`vm.dirty_bytes` 64 MB, `vm.dirty_background_bytes` 16 MB). Lowered the worst stall from 30 s to 4 s, but raised the number of stalls over 100 ms from 29 to 297 and worsened p99 (186 to 337 ms). A trade-off, not a fix. Not applied.
- **More RAM for the VM.** The guest has 2.9 GB free, so the VM does not need more. Adding RAM would increase the host's overcommit, the very thing causing the stalls.
- **Exec probes in the application** (Valkey). Their timeouts made the stalls look worse. Fixed (D-K8S-19), but this only removed an amplifier.

## D-STOR-3. Proposals for the exam administrator (NOT applied, per the instruction not to change Terraform)

These are ordered by how much they should help. None was applied.

1. **Move the four c3 VMs to a less loaded Proxmox node, or to dedicated storage.** This is the only change that addresses the root cause. It needs the exam administrator, because the pool `exam-c5` gives no access to the host. Evidence to show: D-STOR-1.
2. **Master disk cache mode `writeback`** (Terraform: `cache = "writeback"` on `scsi0` of `c3-k8s-master`). The host's page cache absorbs fsync and would hide much of the stall. Risk: if the host crashes, the most recent etcd writes could be lost. Acceptable for a disposable exam cluster. Not verified in this environment. It is a disk setting change, so it needs a Terraform plan and may cause an in-place update of the VM.
3. **Separate virtual disk for `/var/lib/etcd`.** Keeps etcd's fsyncs apart from container image and log writes on the root disk. It does not remove host-side contention, so it helps less than item 1 or 2.
4. **Do not add RAM to the VMs** until the host is less overcommitted. The guest needs about 1 GB of its 4 GB.
5. **`discard = "off"`** on the disk: no measurable benefit in testing, so it is not recommended as a fix.

If the storage cannot be changed, a guest-side mitigation exists but was not applied: raise the leader-election lease and renew durations of kube-controller-manager and kube-scheduler (static pod manifests, through Ansible) so that brief etcd stalls do not kill them. That reduces the crash-loops but does not reduce the stalls, and it slows failover. Decision for the user.

## D-STOR-4. The monitoring snapshot now records storage pressure

`scripts/collect.sh` records `/proc/pressure/io` and `/proc/pressure/memory` on every VM, and on the control plane counts the etcd `slow fdatasync` warnings in the last 5,000 log lines. Future incidents can be traced from `monitoring/<host>/collect-*.txt` without re-deriving the timeline.

## D-CORS-1. Root cause of the 403 on login through the NodePort: an unlisted browser Origin, not the Host

The browser's login POST carries `Origin: http://192.168.160.17:30080`. The API uses `gin-contrib/cors` v1.7.2 (`applyCors`). That library treats a request as same-origin only when `Origin == "http://" + Request.Host`, and it refuses any other origin that is not in the configured list, with a 403, for every method. The configured list was never set: neither deployment defined `CORS_ORIGINS`, so the code default `http://localhost:5173` applied.

The two deployments differ in the Host the API receives. nginx's `$host` variable has no port, so the API sees `192.168.160.17` on the NodePort but `192.168.160.11` on Compose (port 80 is implied). Compose therefore passed the same-origin shortcut by accident. The NodePort failed on the port in its Origin. Controlled matrix (`monitoring/origin-bug/repro-matrix.txt`): an Origin with the port returns 403, the same origin without the port returns 200, and no Origin returns 200. `verify.sh` never failed because curl sends no Origin.

Not a gateway bug and not a frontend bug: the page loaded, and the request reached the API. Application code was not changed, because the existing configuration mechanism is enough.

## D-CORS-2. Fix: an explicit origin list in both deployments, no wildcard

`CORS_ORIGINS` is set to exactly four origins: `http://192.168.160.11` (Compose), and `http://192.168.160.17:30080`, `http://192.168.160.33:30080`, `http://192.168.160.98:30080` (the NodePort on each node). Scheme, host and port must match what the browser sends. The check stays on: an unlisted origin is still refused, and this is now tested (`http://evil.example` returns 403 in `verify.sh`). Set in the Kubernetes ConfigMap `api-config` (`k8s/10-config.yaml`) and in the Compose file (`docker/docker-compose.yml`, with `docker/.env.example`). After the fix, the NodePort origins return 200 with `Access-Control-Allow-Origin` echoed, and the preflight returns 204.

Compose: the same list is set explicitly. Its own origin still passes through the same-origin shortcut, so Compose behaviour is unchanged and the explicit entry only matters if the host name changes.

## D-CORS-3. Config changes roll the pods

A ConfigMap change does not restart a pod, so the API would have kept the old list. `scripts/k8s-render.sh` now puts `sha256(k8s/10-config.yaml)` into a `checksum/config` annotation on the API and gateway pod templates. A configuration change therefore changes the pod template and triggers a normal rolling update, with `maxUnavailable: 0`. Verified: the rollout created new API and gateway pods, and the new pods report the new `CORS_ORIGINS`.

## D-CORS-4. No image rebuild

The fault is in configuration only. Neither app image was rebuilt or re-tagged, so `angelsewase/projecthub-api:1.0.0` and `angelsewase/projecthub-frontend:1.0.0` on Docker Hub are unchanged.

## D-VERIFY-1. verify.sh now tests what a browser does

- Every API request sends a browser User-Agent and `Accept`. Every write also sends the page's `Origin` and `Referer`, as a browser does.
- Page checks: `/`, `/login`, `/register`, `/dashboard`, and a deep route `/projects/123` must return 200 with `text/html`. A static script named in `index.html` must return 200 with `application/javascript` (the correct MIME type; I first wrote `text/javascript` and corrected the expectation).
- Negative check: a login from an unlisted origin must return 403, so the origin rule is proven to be on.
- Result: 39 of 39 on `http://192.168.160.11`, `http://192.168.160.17:30080`, `http://192.168.160.33:30080` and `http://192.168.160.98:30080` (`monitoring/origin-bug/verify-browser-after-fix.txt`).

## D-VERIFY-2. The resilience demo checks the SPA route

Phase d now requests `/login` with a browser User-Agent on each cache-down health sample, and a non-200 counts as a failed phase. The check is one extra request per sample. Confirmed in the run: `SPA /login: HTTP 200` on all three samples.

## D-ANS-7. Metrics-server is idempotent (correction of an earlier role)

The role `k8s_metrics` copied the unpatched manifest and then patched it with `lineinfile`, so every run changed the file and reapplied it. It now uses one vendored file that carries the single documented change (`--kubelet-insecure-tls`), so the copy is idempotent. `kubectl apply` also prints `configured` when only its stored last-applied text differs. Verified: `generation` and `resourceVersion` stayed the same, so nothing on the cluster changed. The role therefore gates the apply on `kubectl diff` (exit 0 = no change, 1 = change). Playbook runs after the fix report `changed=0` on every host.

## D-K8S-20. GOMEMLIMIT stands in for the brief's JVM heap rule

The brief asks that the Spring Boot JVM heap fit within its container limit. The API is Go, which has no fixed heap size, but it has the same kind of soft limit: `GOMEMLIMIT`. It is set to `400MiB` on the API container, about 80% of its 512Mi memory limit. The garbage collector works harder as the heap approaches that value, so it frees memory before the kernel OOM-kills the pod, and the rest leaves room for goroutine stacks and runtime overhead. The value is set in `k8s/40-api.yaml` next to the limit it depends on, not in the ConfigMap, so a change to it only rolls the API. Compose was not changed: the brief states the heap rule only for Kubernetes, and changing Compose would mean redeploying the Docker host for no functional gain.

## D-SEC-1. The secret scan also covers the generated app secrets

`scripts/secret-scan.sh` originally compared files only against the four values in `.private/secrets.env`. The application secrets (`MONGO_ROOT_PASSWORD`, `VALKEY_PASSWORD`, `JWT_SECRET`) are generated into `docker/.env` and feed the Kubernetes Secret. The Helm release uses them too. The scan now loads those three values when `docker/.env` exists, so a value copied into a chart, a log or a doc is caught before commit.

## D-DOC-1. Submission cleanup

Before submission the repo was checked file by file against the Makefile, the scripts and the docs. Superseded snapshots and the owner's capture checklist were removed, and five screenshots were renamed so their names match their content. Every remaining screenshot is embedded in the README. The full list with reasons is in `docs/CLEANUP.md`. The tag `v1-required` marks the state before cleanup.

## D-HELM-1. One chart, proven equal to k8s/

The chart in `k8s/helm/projecthub` is a templated copy of `k8s/`, not a new design. With default values it renders the same 14 objects as `scripts/k8s-render.sh`. `scripts/helm-parity.py` compares them field by field. It ignores only `metadata.labels`, because Helm adds `managed-by` and `helm.sh/chart` (selectors and pod labels are in `spec` and are compared). It also ignores the `checksum/config` annotation, whose input differs. `make helm-lint` runs the parity check every time, so `k8s/` and the chart cannot drift apart unnoticed. The Namespace object is not in the chart: Helm installs into a namespace, and the Secret step creates it first.

## D-HELM-2. Secrets stay out of the chart and out of the release

The chart has no Secret template and no secret values. It references `existingSecret: app-secrets`, which `make helm-deploy` creates from `docker/.env` with the same `scripts/k8s-secrets.sh` as Task 4 (namespace via `K8S_NAMESPACE`). The other option, `--set` with secret values, would store them in Helm's release record inside the cluster and in shell history. The secret scan also checks these values (D-SEC-1).

## D-HELM-3. A second copy next to the plain deployment

The release runs in `qt-spring-app-helm` on NodePort 30081 and leaves the main deployment on 30080 untouched. PersistentVolumes are cluster-scoped, so the copy has its own PV (`projecthub-helm-mongo-data`, storage class `projecthub-helm-local`, host path `/srv/projecthub-helm/mongo`). It is pinned by `kubernetes.io/hostname` to `c3-k8s-worker-2`, the worker that does not hold the main MongoDB volume, so no new node label is needed. CORS origins for port 30081 are set in the override file (D-CORS-1 applies to every port). `k8s-policy-check.py` takes the namespace and NodePort from the environment, with defaults unchanged, so the same rules apply to both copies.

## D-GW-1. Gateway API not attempted

The condition for this bonus was a calm cluster after the Helm install. The install (about 15 objects and 8 pods) caused 11 etcd `slow fdatasync` warnings in 43 s, the worst 6.4 s. The scheduler and the controller-manager lost their leases and restarted once each (13:26 UTC). Both recovered within a minute, but that is the instability described in D-STOR-1. A Gateway API install means vendored CRDs, a controller with its own leader election, and a Gateway and HTTPRoutes. It adds steady and burst load on the same etcd, so it was skipped. NodePort 30080 stays the main URL, served by the nginx gateway Deployment.

