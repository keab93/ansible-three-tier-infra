# Infrastructure topology

Three VMs on one Hyper-V host: a control node that configures the others, and two servers that run the application in three tiers.

![Infrastructure topology](topology.drawio.svg)

## Tiers

| Tier | Role | Component | Host |
|---|---|---|---|
| 1 · Presentation | Accepts HTTP from clients, serves static files | nginx :80, reverse proxy, `/facts.html` | node1 |
| 2 · Application | Runs the application logic, reads from the database | Gunicorn + Flask on Localhost:8000 | node1 |
| 3 · Data | Stores the data | MariaDB :3306, database `appdb` | node2 |

The tiers are logical layers, not machines: tiers 1 and 2 share node1. Each tier only talks to the next one 

The control node, Packer, the golden image and GitHub are the management side.

## Connections

| From | To | Port | Purpose |
|---|---|---|---|
| Client | nginx on node1 | 80/tcp | HTTP |
| nginx | Gunicorn on node1 | Localhost:8000 | Reverse proxy, not reachable from the network |
| Gunicorn | MariaDB on node2 | 3306/tcp | Database, accepted only from 10.6.69.76 |
| keat-controlnode | node1, node2 | 22/tcp | Ansible over SSH |
| keat-controlnode | GitHub | 22/tcp | git over SSH |
| All three VMs | VS1 | 5353/udp | mDNS, `.local` names |

