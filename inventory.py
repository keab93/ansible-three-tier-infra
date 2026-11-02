#!/usr/bin/env python3
import json
import sys

inventory = {
        "_meta": {
            "hostvars": {
                "node1": {"ansible_host": "keat-node1.local"},
                "node2": {"ansible_host": "keat-node2.local"}
                        }
                    },
        "webservers": {"hosts": ["node1"]},
        "dbservers": {"hosts": ["node2"]},
        "all": {"children": ["webservers", "dbservers"]}
                        }

if sys.argv[1] == "--list":
    print(json.dumps(inventory))
elif sys.argv[1] == "--host":
    print(json.dumps({}))
