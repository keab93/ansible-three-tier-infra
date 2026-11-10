# Architecture

Design decisions, dependencies and known limitations for the environment described in the [README](README.md). The [infrastructure topology](docs/infrastructure-topology-graph.md) shows the tiers and connections as a diagram.

## Golden image

All VMs are created from one golden image: a disk with Ubuntu Server 24.04 installed and updated, plus SSH and avahi-daemon for mDNS. The image is built with Packer from `packer/` (see its [README](packer/README.md)): an unattended install from the Ubuntu ISO, a package upgrade, and a sealing step that empties the machine-id and removes the SSH host keys. Rebuilding it is how new VMs get current updates. The image is kept read-only. `hyper-v/create-vms.ps1` copies it once per VM and creates Generation 2 VMs on the virtual switch VS1.

The image is kept minimal on purpose. Everything beyond the OS is applied by Ansible, so changes are made in the playbooks and don't require a new image. A larger image would give ready-to-use VMs sooner, but would have to be rebuilt for every change.

A clone is an exact copy, so the values that must be unique per machine are set after cloning: hostname, machine-id and SSH host keys. `systemd-machine-id-setup` only generates a new ID when `/etc/machine-id` is empty, so the file is emptied first. Run on each VM:

```bash
NEW=keat-node1   # keat-node2 and keat-controlnode on the other VMs
sudo hostnamectl set-hostname $NEW
sudo sed -i "s/base/$NEW/g" /etc/hosts
sudo truncate -s 0 /etc/machine-id
sudo systemd-machine-id-setup
sudo rm -f /etc/ssh/ssh_host_*
sudo ssh-keygen -A
sudo reboot
```

VS1 connects the VMs to a network shared with other machines, where other hosts were already called `node1`. That caused mDNS conflicts, so the hostnames have the prefix `keat-`. Static IP addresses or a separate private switch for mDNS would also have worked, but a unique prefix solved it without changing the network.

## Configuration management

Ansible is used instead of an agent-based tool such as Puppet. The nodes only need SSH and Python, which Ubuntu ships with, so no agent has to be installed or maintained on them, and they keep running unaffected if the control node is down. The trade-off is that drift is only corrected when the playbook is run, while a Puppet agent checks in on a schedule and corrects it automatically. Ansible also runs tasks in the order they are written instead of working out the order from declared dependencies, so the task order matters.

`ansible.cfg` in the repository root points to `inventory.ini`, and the playbooks are run from the root. `site.yml` runs three plays:

| Play | Hosts | Roles |
|---|---|---|
| Base config for all servers | all | common |
| Database tier | dbservers | db |
| Web tier | webservers | webserver, flask_app |

The database tier runs before the web tier so that the database is in place before the app is deployed. The database play gathers node1's facts itself with `delegate_to` and `delegate_facts`, since it needs node1's address for the database account and the firewall rule. That way it also works with `--limit dbservers`.

| Role | Manages | Handler |
|---|---|---|
| common | curl, vim, tree and ufw. The user devops_admin in the sudo group, with the public key `~/.ssh/devops_admin.pub` from the control node. The firewall: SSH and mDNS allowed, everything else incoming denied | - |
| db | MariaDB and PyMySQL. The database appdb with the table messages, and the user appuser with SELECT and INSERT on appdb, allowed to log in from node1's address only. `bind-address = 0.0.0.0`, with port 3306 opened in the firewall for node1 only | Restart mariadb |
| webserver | nginx as a reverse proxy: `app.conf` forwards port 80 to Gunicorn on `127.0.0.1:{{ app_port }}`, the default site is disabled, and `/facts.html` is a page from a template. `nginx -t` runs before the reload. Port 80 opened in the firewall | Reload nginx |
| flask_app | Flask, PyMySQL and Gunicorn. `/opt/app/app.py`, the environment file `/etc/app.env` with the database settings, and the systemd unit `app.service` that runs Gunicorn on `127.0.0.1:8000` as www-data | Restart app |

Handlers restart or reload a service only when its configuration has changed.

The tasks use modules that describe a desired state (`apt`, `service`, `user`, `file`, `template`, `systemd`), so the playbook can be run again at any time and only changes what differs. The check after every change is to run `site.yml` twice in a row: the second run on unchanged servers must end with `changed=0` on both nodes. An earlier version started the app with `shell: nohup ... &`, which started a new process on every run and didn't survive a reboot. Running it as a systemd service with `state: started` and `enabled: true` fixed both.

Templates take their values from facts and inventory variables rather than hard-coded values. The facts page shows hostname, IP address and OS from facts. The app's environment file gets the database name, user and host name from `group_vars/all/vars.yml`, where the host name is node2's `ansible_host` from the inventory, and the password from Vault. The CMDB report uses facts plus the Hyper-V details in `host_vars`. Pointing the inventory at other hosts builds an identical environment, for example for testing.

## Inventory

`inventory.ini` is a static inventory with the groups webservers and dbservers. `inventory.py` is a dynamic inventory that answers `--list` and `--host` with JSON and currently returns the same hosts and groups. It is used with `-i inventory.py`. In a cloud environment the script would get the hosts from the provider's API instead, so new VMs don't have to be added to the inventory by hand.

## Secrets

- The database password is stored as `vault_db_password` in `group_vars/all/vault.yml`, encrypted with Ansible Vault (AES256). The vault password is entered with `--ask-vault-pass`, and `.vault_pass` files are ignored by Git.
- The task that creates the database user runs with `no_log: true`, so the password doesn't show in the output.
- `become: true` is set per play, and the sudo password is entered with `-K`.
- The control node logs in with ed25519 keys. Private keys are ignored by Git (`id_*`, `*.pem`, `devops_admin`).

Access to the database is limited in three layers: the account `appuser` only exists for node1's address, ufw on node2 only accepts port 3306 from node1, and ufw on every node denies all other incoming traffic except SSH, mDNS and the node's own service. MariaDB still listens on all interfaces, because binding it to node2's DHCP address would stop MariaDB from starting if that address changed.

The repository contains no plain-text passwords. On node1 the password is in `/etc/app.env`, owned by root with mode 0600. systemd reads the file as root and passes the values to the app's environment, so `app.py` holds no secrets and a traceback in the log shows the variable name, not the password. The task that writes the file has `no_log: true`.

## CMDB reports

`report.yml` collects facts and the list of installed packages from all hosts and writes one Markdown file per host to `reports/` on the control node: role, CPU, RAM, IP addresses, OS, uptime, disks and all packages with versions. The Hyper-V details (VHDX path and type, virtual switch) can't be seen from inside a VM, so they are kept in `host_vars/`.

The reports are committed to Git and work as a simple CMDB. Since they are generated from the servers instead of maintained by hand, they are accurate as of the last run, and `git diff` after a new run shows what has changed on the servers.

## Dependencies and failure impact

| Down | Impact |
|---|---|
| Control node | The nodes keep running with the last applied configuration. No configuration changes, new database users or password changes until it is back. |
| mDNS (avahi) | Names under `.local` stop resolving. Ansible can't connect to the nodes, clients can't reach the site by name, and the app can't reach the database, since it connects to `keat-node2.local`. |
| node1 | The site is unreachable. |
| node2 | The app returns HTTP 500. `/facts.html` on node1 still works. |
| Hyper-V host or VS1 | Everything stops. The VMs are restored from VHDX backups. Stopping MariaDB during the backup gives a consistent copy of the database. |

## Verification and troubleshooting

| Command | Shows |
|---|---|
| `curl http://keat-node1.local` | that nginx forwards to the app and the app reads from node2 |
| `nginx -t` | whether the nginx config is valid |
| `ss -tlnp` | listening ports and addresses |
| `ufw status verbose` | the firewall rules in force |
| `journalctl -u app` | the app's log and Python errors |
| `my_print_defaults mysqld` | the settings MariaDB reads |

## Known limitations

- The database account and the firewall rule on node2 are tied to node1's IP address. If node1 gets a new address from DHCP, `site.yml` has to be run again, and the account and rule for the old address stay until they are removed by hand. A DHCP reservation or a static address would remove this.
- The playbooks don't upgrade packages, so a VM is only as up to date as the image it was cloned from. Rebuild the image to get current updates.
