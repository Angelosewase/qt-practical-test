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
