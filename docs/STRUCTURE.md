# Repository structure

```
qt-practical-test/
├── README.md              Overview, URLs, VM table, step-by-step reproduction
├── Makefile               Single entry point for every automation step
├── .gitignore             Keeps secrets, state, plans and scratch files out of git
├── .dockerignore          Default-deny build context for both app images
├── iac/                   Task 1: Terraform for the four Proxmox VMs
│   ├── provider.tf        Proxmox provider (bpg/proxmox ~> 0.69)
│   ├── variables.tf       All inputs, including the per-VM sizing map
│   ├── main.tf            One full clone of template 9105 per VM (for_each)
│   ├── outputs.tf         vm_ips and vms (role, IP, SSH command)
│   ├── terraform.tfvars.example   Non-secret overrides template
│   └── .terraform.lock.hcl        Pinned provider versions (committed)
├── ansible/               Task 3: inventory, playbooks, roles (next step)
├── docker/                Task 2: Dockerfiles, nginx configs, docker-compose.yml, .env.example
├── k8s/                   Task 4: Kubernetes manifests (next step)
├── app/                   ProjectHub source (the code behind the brief's "MyDiary"), copied without .git
│   ├── backend/           Go 1.23 API (Gin, MongoDB, Valkey cache)
│   └── frontend/          React 18 + Vite SPA
├── monitoring/            Evidence files and screenshots (Task 5)
├── scripts/
│   ├── pre-commit         Git hook: blocks commits that contain a secret value
│   ├── secret-scan.sh     Scans staged changes, the working tree, or git history
│   ├── gen-env.sh         Creates docker/.env with generated secrets
│   └── verify.sh          End-to-end functional checks against any base URL
├── docs/
│   ├── WORKLOG.md         Running log: what was done, what broke, how it was fixed
│   ├── DECISIONS.md       Choices and trade-offs, including template findings
│   ├── STRUCTURE.md       This file
│   └── RUNBOOK.md         Redeploy, rollback, rotate secrets, tear down (later)
└── .private/              LOCAL ONLY, gitignored, chmod 700
    ├── secrets.env        Credentials (chmod 600). Never committed.
    ├── ssh/               VM SSH keypair (id_ed25519 + .pub)
    └── brief.docx         Copy of the exam brief
```

## Why these directories

- **iac/**, **ansible/**, **docker/**, **k8s/**, **app/**, **monitoring/** match the layout the exam brief requires exactly.
- **scripts/** holds helpers that are not tied to one task: the secret guard and, later, the evidence collectors.
- **docs/** keeps long-form decisions out of the README so the README stays a runbook for examiners.
- **.private/** is where local secrets live. It sits inside the repo tree so relative paths work, but `.gitignore` excludes it and the secret scanner refuses commits that contain its values.
- **app/** is the source code, copied from the GitLab clone without its `.git` so it is not committed as a submodule. The original nested clone was removed after the copy was verified identical; a backup is in `.tmp/` (gitignored).

## Terraform state

`iac/terraform.tfstate` and `iac/tfplan` contain the VM password and are gitignored. Keep them local until the exam is over.
