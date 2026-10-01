#!/usr/bin/env python3
import json
import pathlib
import sys


config = json.load(sys.stdin)
assert set(config["services"]) == {"vaultwarden"}, config["services"]
service = config["services"]["vaultwarden"]
assert service["image"] == "vaultwarden/server:1.37.3", service.get("image")
assert service["ports"] == [
    {
        "mode": "ingress",
        "host_ip": "127.0.0.1",
        "target": 80,
        "published": "8080",
        "protocol": "tcp",
    }
], service["ports"]
assert service["environment"]["SIGNUPS_ALLOWED"] == "false"
assert service["environment"]["SIGNUPS_VERIFY"] == "false"
assert service["environment"]["SIGNUPS_DOMAINS_WHITELIST"] == ""
assert service["environment"]["INVITATIONS_ALLOWED"] == "false"
assert len(service["volumes"]) == 1
assert service["volumes"][0]["type"] == "bind"
assert service["volumes"][0]["target"] == "/data"
assert pathlib.Path(service["volumes"][0]["source"]).name == "vw-data"
assert service["volumes"][0]["source"].rstrip("/").endswith("/vw-data")
assert "3012" not in json.dumps(service)
assert "WEBSOCKET_ENABLED" not in service["environment"]
print("Compose configuration checks passed")
