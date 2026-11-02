# Ansible three-tier infrastructure

This project uses Ansible to configure an app in three tiers on three Hyper-V VMs: nginx, a Flask app and a MariaDB database. Everything is configured from a central control node, and nothing related to Ansible is installed on the servers.

## Description

I have built the app step by step. I started with passwordless SSH and ad hoc commands, then added playbooks, roles, Jinja2 templates, Ansible Vault, a simple CMDB and a dynamic inventory. In the end there is a Flask app on node1 that fetches data from MariaDB on node2. While building it I learned about the architecture and best practices used in configuration management today.

The only things not set up with Ansible are the VMs themselves and the SSH connection the control node has to the two nodes.

| VM | Group in the inventory | Services |
|---|---|---|
| keat-controlnode | - | Ansible, clone of this repo |
| keat-node1 | webservers | nginx (:80), Flask with Gunicorn (:8000) |
| keat-node2 | dbservers | MariaDB (:3306) |

The VMs run Ubuntu 24.04, are connected to the virtual switch VS1 and find each other with mDNS (`keat-node1.local`).

Why I built it this way, and the weaknesses I know about, are in [ARCHITECTURE.md](ARCHITECTURE.md).

```
.
├── ansible.cfg
├── inventory.ini          static inventory
├── inventory.py           dynamic inventory
├── site.yml               configures all servers
├── report.yml             CMDB report per server
├── requirements.yml
├── group_vars/all/        vault.yml (you create it, see below)
├── host_vars/             Hyper-V info that only exists on the host
├── roles/
│   ├── common/            basic tools, the user devops_admin and its SSH key
│   ├── webserver/         nginx and a start page from a Jinja2 template
│   ├── db/                MariaDB, the database appdb and the user appuser
│   └── flask_app/         the Flask app as a systemd service
├── templates/             template for the CMDB report
├── reports/               generated reports
└── hyper-v/
    └── create-vms.ps1
```

## How do you run it?

### Dependencies

To run the playbooks you need 3 VMs that are connected to each other with mDNS. You can create the VMs with Hyper-V, and I go through how I created them below. The nodes only need SSH and Python, which Ubuntu has from the start.

### 1. Create the VMs

I installed Ubuntu Server 24.04 in the VM `ubuntu-base`, updated it, and installed and started avahi-daemon. Then I copied the disk and made the copy read-only in case I need a fresh image later. The disk is named `base.vhdx` and is in Hyper-V's default folder for virtual hard disks.

Run on the Hyper-V host:

```powershell
.\hyper-v\create-vms.ps1
```

The script creates `controlnode`, `node1` and `node2` with their own copy of the same disk. The problem now is that all servers think they are the same server, so each VM needs a new hostname and a new machine-id. Run on each VM:

```bash
NEW=keat-node1   # keat-node2 and keat-controlnode on the other VMs
sudo hostnamectl set-hostname $NEW
sudo sed -i "s/base/$NEW/g" /etc/hosts
sudo truncate -s 0 /etc/machine-id
sudo systemd-machine-id-setup
sudo reboot
```

`keat` is my initials. There were several hosts called node1 on the network I was on, which caused mDNS conflicts, so I added a prefix. If you use your own prefix, change `inventory.ini` and `inventory.py` too.

### 2. SSH and Ansible on the control node

```bash
ssh-keygen -t ed25519 -C "ansible@controlnode"
ssh-copy-id keat-node1.local
ssh-copy-id keat-node2.local
ssh-keygen -t ed25519 -f ~/.ssh/devops_admin
sudo apt install -y ansible git
git clone https://github.com/keab93/ansible-three-tier-infra.git
cd ansible-three-tier-infra
ansible all -m ping
```

The second key is for the user devops_admin, which the `common` role creates on the nodes. The `ansible` package in Ubuntu includes the collections the roles use. If you only have `ansible-core`, run `ansible-galaxy collection install -r requirements.yml`.

### 3. Create the vault

The database password is encrypted with Ansible Vault. Create the file and write the password in it:

```bash
ansible-vault create group_vars/all/vault.yml
```

```yaml
vault_db_password: <your password>
```

When the file exists every command needs `--ask-vault-pass`, since Ansible reads `group_vars/all` for all hosts.

### 4. Run the playbooks

Run everything from the root of the repo.

| What | Command | Check |
|---|---|---|
| Configure all servers | `ansible-playbook site.yml -K --ask-vault-pass` | `curl http://keat-node1.local` then `curl http://keat-node1.local:8000` |
| Log in as devops_admin | `ssh -i ~/.ssh/devops_admin devops_admin@keat-node1.local` | |
| Check the database user | `ansible dbservers -K -b -a "mysql -e 'SELECT user,host FROM mysql.user;'" --ask-vault-pass` | `appuser` is in the list |
| CMDB report | `ansible-playbook report.yml --ask-vault-pass` | `reports/<host>_inventory_report.md` |
| Listening ports | `ansible all -K -b -a "ss -tlnp" --ask-vault-pass` | |
| Dynamic inventory | `ansible-inventory -i inventory.py --list --ask-vault-pass` then `ansible all -i inventory.py -m ping --ask-vault-pass` | |
| Disk space and OS | `ansible all -a "df -h /" --ask-vault-pass` then `ansible all -m setup -a "filter=ansible_lsb" --ask-vault-pass` | |

The start page on port 80 shows the hostname, IP address and OS of node1 from Ansible facts. The app on port 8000 fetches its data from the database on node2:

```
$ curl http://keat-node1.local:8000
<h1>Data from the database</h1><p>Hello from MariaDB on node2!</p>
```

## Next steps

- nginx as a reverse proxy in front of Gunicorn, so all traffic to the app goes through port 80
- Build the base image with Packer instead of by hand
- Get the database password out of `app.py` on node1
