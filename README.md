# MyDiary: DevOps practical exam (candidate 5)

Work in progress. This README is updated as each task is completed.

## Status

| Task | Status |
|---|---|
| Repo setup, secrets handling, pre-commit guard | Done |
| Task 1: Terraform infrastructure (`iac/`) | Code done. Apply blocked: Proxmox token lacks `VM.Clone` on template 9105 |
| Task 2: Docker Compose (`docker/`) | Not started |
| Task 3: Ansible Kubernetes cluster (`ansible/`) | Not started |
| Task 4: Kubernetes deployment (`k8s/`) | Not started |
| Task 5: Monitoring (`monitoring/`) | Not started |

## Infrastructure creation (Task 1)

Prerequisites: Terraform 1.5 or later (tested with 1.17.2), `make`, and the file `.private/secrets.env` with the Proxmox token. Generate the SSH key once with `ssh-keygen -t ed25519 -f .private/ssh/id_ed25519 -N ''`.

```bash
make setup        # install the pre-commit secret guard
make tf-fmt       # formatting check
make tf-validate  # validate the configuration (no backend, no API calls)
make tf-init      # download the bpg/proxmox provider
make tf-plan      # write iac/tfplan
make tf-apply     # create the four VMs from template 9105
make tf-output    # print each VM's IP and SSH command
```

### VM table

| VM name | Role | IP | SSH user |
|---|---|---|---|
| c3-docker-host | Application host (Docker Compose) | _pending apply_ | `devops` |
| c3-k8s-master | Kubernetes control plane | _pending apply_ | `devops` |
| c3-k8s-worker-1 | Kubernetes worker | _pending apply_ | `devops` |
| c3-k8s-worker-2 | Kubernetes worker | _pending apply_ | `devops` |

### VM login credentials

- SSH user: `devops`
- Password: **[PLACEHOLDER: add the VM password before submission]**
- SSH private key: **[PLACEHOLDER: add the key or the path you want examiners to use before submission]**

Do not write real credentials in this file. Add them only at submission time.
