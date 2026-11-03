# Architecture

Design decisions, dependencies and known limitations for the environment described in the [README](README.md).

## Golden image

All VMs are created from one golden image: a disk with Ubuntu Server 24.04 installed and updated, plus SSH and avahi-daemon for mDNS. The image is kept read-only. `hyper-v/create-vms.ps1` copies it once per VM and creates Generation 2 VMs on the virtual switch VS1.

The image is kept minimal on purpose. Everything beyond the OS is applied by Ansible, so changes are made in the playbooks and don't require a new image. A larger image would give ready-to-use VMs sooner, but would have to be rebuilt for every change.

A clone is an exact copy, so the values that must be unique per machine are set after cloning. `systemd-machine-id-setup` only generates a new ID when `/etc/machine-id` is empty, so the file is emptied first. Run on each VM:

```bash
NEW=keat-node1   # keat-node2 and keat-controlnode on the other VMs
sudo hostnamectl set-hostname $NEW
sudo sed -i "s/base/$NEW/g" /etc/hosts
sudo truncate -s 0 /etc/machine-id
sudo systemd-machine-id-setup
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

The database tier runs before the web tier so that the database is in place before the app is deployed. The first play gathers facts from all hosts, which the web tier depends on.

| Role | Manages | Handler |
|---|---|---|
| common | curl, vim and tree. The user devops_admin in the sudo group, with the public key `~/.ssh/devops_admin.pub` from the control node | - |
| db | MariaDB and PyMySQL. The database appdb with the table messages, and the user appuser with SELECT and INSERT on appdb. `bind-address = 0.0.0.0` | restart mariadb |
| webserver | nginx and `/var/www/html/index.html` from a template | restart nginx |
| flask_app | Flask, PyMySQL and Gunicorn. `/opt/app/app.py` from a template, and the systemd unit `app.service` that runs Gunicorn on port 8000 as www-data | restart app |

Handlers restart a service only when its configuration has changed.

The tasks use modules that describe a desired state (`apt`, `service`, `user`, `file`, `template`, `systemd`), so the playbook can be run again at any time and only changes what differs. An earlier version started the app with `shell: nohup ... &`, which started a new process on every run and didn't survive a reboot. Running it as a systemd service with `state: started` and `enabled: true` fixed both.

Templates take their values from facts and inventory variables rather than hard-coded values. The start page shows hostname, IP address and OS from facts. `app.py` gets the database address from node2's facts and the password from Vault. The CMDB report uses facts plus the Hyper-V details in `host_vars`. Pointing the inventory at other hosts builds an identical environment, for example for testing.

## Inventory

`inventory.ini` is a static inventory with the groups webservers and dbservers. `inventory.py` is a dynamic inventory that answers `--list` and `--host` with JSON and currently returns the same hosts and groups. It is used with `-i inventory.py`. In a cloud environment the script would get the hosts from the provider's API instead, so new VMs don't have to be added to the inventory by hand.

## Secrets

- The database password is stored as `vault_db_password` in `group_vars/all/vault.yml`, encrypted with Ansible Vault (AES256). The vault password is entered with `--ask-vault-pass`, and `.vault_pass` files are ignored by Git.
- The task that creates the database user runs with `no_log: true`, so the password doesn't show in the output.
- `become: true` is set per play, and the sudo password is entered with `-K`.
- The control node logs in with ed25519 keys. Private keys are ignored by Git (`id_*`, `*.pem`, `devops_admin`).

The repository contains no plain-text passwords. On node1, however, the password ends up in plain text in `/opt/app/app.py` (mode 0600, owner www-data). See [Known limitations](#known-limitations).

## CMDB reports

`report.yml` collects facts and the list of installed packages from all hosts and writes one Markdown file per host to `reports/` on the control node: role, CPU, RAM, IP addresses, OS, uptime, disks and all packages with versions. The Hyper-V details (VHDX path and type, virtual switch) can't be seen from inside a VM, so they are kept in `host_vars/`.

The reports are committed to Git and work as a simple CMDB. Since they are generated from the servers instead of maintained by hand, they are accurate as of the last run, and `git diff` after a new run shows what has changed on the servers.

## Dependencies and failure impact

| Down | Impact |
|---|---|
| Control node | The nodes keep running with the last applied configuration. No configuration changes, new database users or password changes until it is back. |
| mDNS (avahi) | Names under `.local` stop resolving. Ansible can't connect to the nodes and clients can't reach the site by name. node1 still reaches the database, since it connects to node2 by IP address. |
| node1 | The start page and the app are unreachable. |
| node2 | The app returns HTTP 500. The start page on node1 still works. |
| Hyper-V host or VS1 | Everything stops. The VMs are restored from VHDX backups. Stopping MariaDB during the backup gives a consistent copy of the database. |

## Verification and troubleshooting

| Command | Shows |
|---|---|
| `curl http://keat-node1.local:8000` | that the app responds and reads from node2 |
| `ss -tlnp` | listening ports and addresses |
| `journalctl -u app` | the app's log and Python errors |
| `my_print_defaults mysqld` | the settings MariaDB reads |

## Known limitations

- The database password is in plain text in `/opt/app/app.py` on node1 and can show up in the app's error log. It should be passed to the service as an environment variable instead.
- MariaDB listens on all interfaces and appuser can connect from any host. Access should be limited to node1.
- nginx and the app are served on separate ports. nginx should act as a reverse proxy in front of Gunicorn.
- The app gets the database address at deploy time from the facts of the host named `node2`. The web tier can't be run on its own with `--limit webservers`, and if node2 gets a new address from DHCP the playbook has to be run again.
- The golden image is built by hand, and the playbooks don't upgrade packages, so new VMs are only as up to date as the image. Building the image with Packer, using the same roles, would make it reproducible and simple to rebuild with current updates.
- The clone procedure doesn't regenerate the SSH host keys, so the VMs may share host keys. The keys should be removed from the image and generated on first boot.
