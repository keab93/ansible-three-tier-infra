# Architecture and design decisions

## 1. System overview and choice of tools

The environment consists of three virtual machines in Hyper-V with Ubuntu 24.04, connected to the virtual switch VS1.

| VM | Group in the inventory | Services |
|---|---|---|
| keat-controlnode | - | Ansible, clone of the repo |
| keat-node1 | webservers | nginx (:80), Flask with Gunicorn (:8000) |
| keat-node2 | dbservers | MariaDB (:3306) |

### Choice of tool

Compared to other CM tools such as Puppet, Ansible is less resource-intensive on the nodes and is also quicker to set up. The only things needed on the nodes are SSH, Python and a way to reach them over the network from the control node.

### Agentless vs. agent-based

The nodes only need SSH and Python, which Ubuntu has from the start. Ansible connects from the control node over SSH when a playbook runs and doesn't install any agent on the nodes.

The advantage of Ansible in this case is that the nodes are unaffected if the control node goes down. It is also less resource-intensive to run them without an agent.

### Ansible vs. Puppet

How the code reaches the nodes:

- Ansible reaches the nodes with SSH from the control node. It sends Python scripts and runs them, and then they are removed. Nothing installed on the node is related to Ansible.
- Puppet installs an agent on every node and a server on the control node. You set a frequency that decides how often the agent contacts the server to ask for the configuration. If something changes on the node and deviates from the configuration, it is corrected automatically the next time the agent contacts the server. In Ansible this can wait until the next time the playbook runs.

The order the code runs in:

You can't copy a configuration file to a directory that doesn't exist yet. If the task that copies a config file for nginx comes before the task that installs nginx, the playbook can't run in Ansible, and the tasks after it don't run either since the playbook stops at the error. In Puppet the dependency is declared, so Puppet installs nginx before it tries to copy the file. This requires that you know about the dependency though, and if you know about it you hopefully won't put the tasks in the wrong order in Ansible either.

| | Ansible | Puppet |
|---|---|---|
| Architecture | agentless, code is sent from the control node with SSH | an agent on every node with a central server |
| Language | YAML (playbooks), Jinja2 (templates) | Puppet DSL (its own language), Ruby |
| Style | procedural: things are done in the order you write them | declarative: you declare resources and relations |
| When does it run? | when someone runs it | automatically |
| What the nodes need | SSH + Python | Puppet agent + certificate |

- Both are idempotent, which is crucial for what they do.
- Ansible is quicker to set up. You only need SSH and Python on the nodes, which Ubuntu has by default.
- Puppet in some cases has an advantage when it comes to configuration drift, because the agents on the nodes check for changes against the server.
- In Puppet you declare dependencies and other relations, and the order of operations takes them into account. That can make it easier to change long conf files without breaking something.

### Folder and role structure

There is one `ansible.cfg` in the root of the repo that points to `inventory.ini`. The playbooks are run from the root.

```
.
├── ansible.cfg
├── inventory.ini
├── inventory.py
├── group_vars/all/vault.yml
├── host_vars/
├── roles/
│   ├── common/
│   ├── webserver/
│   ├── db/
│   └── flask_app/
├── templates/
├── site.yml
└── report.yml
```

The roles were created with `ansible-galaxy role init`, and I have removed the folders that weren't used:

| Role | Does |
|---|---|
| common | basic tools, the user devops_admin and its SSH key |
| webserver | nginx and a start page from a Jinja2 template |
| db | MariaDB, the database appdb and the user appuser |
| flask_app | the Flask app as a systemd service |

This structure makes it easier to troubleshoot. Every time a playbook runs you can read which tasks run without errors, make a change or end with an error. It is also easier to copy the roles you want to another project.

## 2. Security and secrets management

### Ansible Vault

The database password is in `group_vars/all/vault.yml` and is encrypted with `ansible-vault`. In Git the file starts with `$ANSIBLE_VAULT;1.1;AES256`. The vault password is not in the repo but is given with `--ask-vault-pass` at runtime, and `.gitignore` excludes `.vault_pass`. Tasks that use the password have `no_log: true` so that it isn't shown in Ansible's output. My own `vault.yml` is not in this repo, you create your own (see the README).

A possible security gap I have found is that the password is always encrypted on the control node, but it can be read by anyone with access to the nodes. It is in plain text in `/opt/app/app.py` on node1, in the app's error log and in the bash history. I could clear the history and only use the password when it is available as an environment variable.

### Privilege escalation and SSH

`become: true` is set per play. With `-K` Ansible asks for the sudo password at runtime, so it isn't saved in any file. The control node logs in to the nodes with an ed25519 key. The `common` role creates the user devops_admin with its own key and membership in the group sudo. Private keys are excluded in `.gitignore` (`id_*`, `*.pem`, `devops_admin`).

No file contains a password, and keys are used instead of passwords to log in.

## 3. Scalability and dynamics

### Dynamic vs. static inventories

The static inventory is `inventory.ini` with the groups `[webservers]` and `[dbservers]`. `inventory.py` is a dynamic inventory that answers `--list` and `--host` with JSON and is used with `ansible all -i inventory.py -m ping`. For now it returns the same hosts as `inventory.ini`.

In the static .ini file you have to write in every new node with its address. With a dynamic inventory you could fetch the inventory JSON from a cloud service's API to keep better track of the VMs that are available for configuration.

### Jinja2 and variable separation

- `roles/webserver/templates/index.html.j2` shows hostname and OS from Ansible facts.
- `templates/ci_report.md.j2` creates a report per server. Information that only exists on the Hyper-V host is in `host_vars`.
- `roles/flask_app/templates/app.py.j2` gets the database IP with `hostvars['node2']['ansible_default_ipv4']['address']` and the password from Vault.

This structure makes it much easier to reuse the code. You can for example change the host vars and run the playbook again to create an identical environment that you can use as a development or test environment.

## 4. Operations, optimization and recovery

### Idempotency

Ansible doesn't send `sudo apt install`. It checks if the node has the desired `state`. If the desired state is already reached it does nothing, and you can run the playbook a hundred times without it having any effect, unless the package has been removed.

The second run of the playbook that installs nginx gave `changed=0`. Modules like `apt`, `service`, `user` and `file` describe a desired state and only do something if the node isn't already in that state. Counterexample: my first version of the app started two Python scripts with `shell: nohup ... &`. Every run started a new process, and the process didn't survive a reboot. In this version it is replaced with a systemd service (`state: started`, `enabled: true`).

Idempotency means that you can run the playbook over and over without any negative consequences. The only things that change are new configurations or corrections of configuration drift.

### Troubleshooting and verification

Handlers restart services only when a configuration has changed: `restart nginx` (webserver), `restart mariadb` (db) and `restart app` (flask_app). Tools I used after rollout:

| Command | Shows |
|---|---|
| `curl http://keat-node1.local:8000` | that the app responds and fetches data from node2 |
| `ss -tlnp` | which ports are listening and on which addresses |
| `journalctl -u app` | the app's log and Python errors |
| `my_print_defaults mysqld` | which settings MariaDB reads |

### CMDB

Every server and its properties (CPU, RAM, IP, OS and packages) are CIs. `report.yml` creates the reports from Ansible facts every time it runs, so they show what the servers look like right now. They are saved in Git and work as a simple CMDB. Since they are updated automatically, the risk of configuration drift is lower compared to a CMDB that is updated by hand. If you run `report.yml` again, `git diff` shows what has changed on the servers since the last report.

The information about the virtual hard disk only exists on the Hyper-V host, so it is written by hand in `host_vars`.

Relations between the servers:

| From → To | Via | Impact if To goes down |
|---|---|---|
| Ansible on controlnode → node1, node2 | SSH, mDNS, VS1 | Ansible can't configure the nodes or run any playbook. (If From goes down: node1 and node2 can't be configured anymore, but they keep running with the configuration from the latest playbook run.) |
| controlnode → node2 MariaDB | Vault password and user management | Can't create more users or change existing passwords from the control node |
| browser → node1 | HTTP :80 nginx, :8000 Flask | The site can't be reached |
| node1 Flask app → node2 MariaDB | :3306 | The app can't fetch any data and returns an error |
| all VMs → Hyper-V host / VS1 | virtual hardware + network | Everything stops working. Everything can be restored from disk backups, except possibly the database. The database can be stopped during the backup. |

## 5. The base image (golden image)

All VMs are created from the same disk. I installed Ubuntu Server 24.04 in the VM `ubuntu-base`, updated it and installed avahi-daemon. Then I copied the disk and made it read-only in case I need a fresh image later. `hyper-v/create-vms.ps1` copies the disk once per VM and creates the VMs on VS1.

This is called a golden image: one reference image that all machines are cloned from. All VMs start in the same known state, and from there Ansible takes over. I have kept the image small on purpose. It only has the OS, SSH and avahi, and everything else is done by the playbooks. If you put more into the image the VMs are ready faster, but the image gets old and has to be rebuilt every time something changes. With a small image the configuration is in one place, the playbooks.

### What has to be unique per VM

A clone is an exact copy, so all servers think they are the same server. Everything that has to be unique has to be changed after cloning:

- Hostname: set with `hostnamectl` and replaced in `/etc/hosts`.
- machine-id: `systemd-machine-id-setup` only creates a new ID if `/etc/machine-id` is empty, so the file is emptied first.

Run on each VM after cloning:

```bash
NEW=keat-node1   # keat-node2 and keat-controlnode on the other VMs
sudo hostnamectl set-hostname $NEW
sudo sed -i "s/base/$NEW/g" /etc/hosts
sudo truncate -s 0 /etc/machine-id
sudo systemd-machine-id-setup
sudo reboot
```

It turned out that there were DNS conflicts. There were several hosts called node1 on the network, and I couldn't use Hyper-V's Default Switch since the host runs Windows Server. I could have used static IP addresses outside the DHCP range, but then I wouldn't use mDNS at all. I could also have had two vSwitches, one private switch for mDNS and another one to the internet. Instead I changed the hostname again and put my initials as a prefix, which made the mDNS conflict go away.

### Not solved yet

- The SSH host keys are copied with the disk too, and I haven't created new ones per VM. It can be checked with `ansible all -a "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub" --ask-vault-pass`.
- The base image is made by hand and is the only part of the environment that isn't code. The next step is to build it with Packer, use the same roles as here, and give the image a version so it can be rebuilt when there are new updates.
