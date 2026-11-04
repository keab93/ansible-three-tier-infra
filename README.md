# ansible-three-tier-infra

Ansible configuration for a web application in three tiers (nginx, Flask, MariaDB) on Hyper-V. All servers are configured from one control node over SSH. Nothing is installed on the managed nodes besides what the application needs.

## Environment

| Host | Inventory group | Services |
|---|---|---|
| keat-controlnode | - | Ansible |
| keat-node1 | webservers | nginx :80, Flask with Gunicorn :8000 |
| keat-node2 | dbservers | MariaDB :3306 |

Ubuntu Server 24.04 on Hyper-V, virtual switch VS1. The hosts find each other with mDNS (`.local`). If you use other hostnames, update `inventory.ini` and `inventory.py`.

## How it is built

All VMs are cloned from a golden image, a read-only disk where Ubuntu Server 24.04 is already installed and updated, with SSH and avahi added. A new VM can be deployed quickly without installing Ubuntu every time, and all configuration after that is done with Ansible, so the image doesn't have to be rebuilt for every change. After cloning, each VM gets its own hostname and machine-id.

`site.yml` applies the roles in this order: base config, database tier, web tier.

| Role | Purpose |
|---|---|
| common | base packages, the admin user devops_admin and its SSH key |
| db | MariaDB, the database appdb and the application user |
| webserver | nginx with a start page generated from Ansible facts |
| flask_app | the Flask application as a systemd service |

The database password is encrypted with Ansible Vault. Vault and sudo passwords are entered at runtime and are not stored in the repository.

Every push and pull request is checked with ansible-lint in GitHub Actions.

`report.yml` writes a report per server from Ansible facts to `reports/`. Committed to Git, the reports work as a simple CMDB, and `git diff` shows what has changed between runs. `inventory.py` is a dynamic inventory that returns the same hosts as `inventory.ini`.

Design decisions are described in [ARCHITECTURE.md](ARCHITECTURE.md).

## Usage

Requirements: a Hyper-V host, the base image as `base.vhdx` and Ansible on the control node. The Ubuntu `ansible` package includes the collections the roles use. With only `ansible-core`, install them from `requirements.yml`.

1. Create the VMs with `hyper-v/create-vms.ps1` and give each one a unique hostname and machine-id (see [ARCHITECTURE.md](ARCHITECTURE.md#golden-image)).
2. Set up SSH from the control node:
   ```bash
   ssh-keygen -t ed25519
   ssh-copy-id keat-node1.local
   ssh-copy-id keat-node2.local
   ssh-keygen -t ed25519 -f ~/.ssh/devops_admin
   ```
3. Create the vault with the variable `vault_db_password`:
   ```bash
   ansible-vault create group_vars/all/vault.yml
   ```
4. Run the playbook:
   ```bash
   ansible-playbook site.yml -K --ask-vault-pass
   ```

`curl http://keat-node1.local:8000` should return the data stored in MariaDB on node2. Once the vault exists, all commands need `--ask-vault-pass`, including `ansible-playbook report.yml` and `ansible-inventory -i inventory.py --list`.

## Known limitations

- MariaDB listens on all interfaces, and the application user can connect from any host.
- nginx and the application are served on separate ports. nginx is not yet a reverse proxy.
- The golden image is built by hand.
