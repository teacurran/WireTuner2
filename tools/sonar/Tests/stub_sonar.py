"""A stateful stand-in for the SonarQube Web API endpoints configure-gates.sh calls.

    python3 stub_sonar.py <port-file> <request-log> <expected-token>

Binds an ephemeral port on 127.0.0.1 and writes it to <port-file>.  Every request is appended to
<request-log> as "METHOD path key=value&..." (never the token).  A request whose Authorization
header is not "Bearer <expected-token>" gets 401, as the real server does with force-auth on.
State lives in memory, so a second run of the script sees what the first one created.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qsl, urlsplit

port_file, log_file, expected_token = sys.argv[1:4]
projects = {}
gates = {}  # name -> list of conditions
selected = {}  # project -> gate name
next_id = [1]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body=None):
        data = json.dumps(body if body is not None else {}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self, method):
        url = urlsplit(self.path)
        if method == "POST":
            length = int(self.headers.get("Content-Length") or 0)
            params = dict(parse_qsl(self.rfile.read(length).decode()))
        else:
            params = dict(parse_qsl(url.query))
        with open(log_file, "a") as log:
            log.write(f"{method} {url.path} {'&'.join(f'{k}={v}' for k, v in sorted(params.items()))}\n")
        if self.headers.get("Authorization") != f"Bearer {expected_token}":
            return self.reply(401, {"errors": [{"msg": "Unauthorized"}]})
        route = (method, url.path)
        if route == ("GET", "/api/projects/search"):
            keys = params.get("projects", "").split(",")
            return self.reply(200, {"components": [{"key": k, "name": projects[k]} for k in keys if k in projects]})
        if route == ("POST", "/api/projects/create"):
            if params["project"] in projects:
                return self.reply(400, {"errors": [{"msg": "already exists"}]})
            projects[params["project"]] = params["name"]
            return self.reply(200, {"project": {"key": params["project"]}})
        if route == ("GET", "/api/qualitygates/show"):
            if params["name"] not in gates:
                return self.reply(404, {"errors": [{"msg": "No quality gate"}]})
            return self.reply(200, {"name": params["name"], "conditions": gates[params["name"]]})
        if route == ("POST", "/api/qualitygates/create"):
            gates[params["name"]] = []
            return self.reply(200, {"name": params["name"]})
        if route == ("POST", "/api/qualitygates/create_condition"):
            condition = {"id": str(next_id[0]), "metric": params["metric"], "op": params["op"], "error": params["error"]}
            next_id[0] += 1
            gates[params["gateName"]].append(condition)
            return self.reply(200, condition)
        if route == ("POST", "/api/qualitygates/update_condition"):
            for conditions in gates.values():
                for condition in conditions:
                    if condition["id"] == params["id"]:
                        condition.update(metric=params["metric"], op=params["op"], error=params["error"])
                        return self.reply(204)
            return self.reply(404)
        if route == ("GET", "/api/qualitygates/get_by_project"):
            if params["project"] not in projects:
                return self.reply(404)
            return self.reply(200, {"qualityGate": {"name": selected.get(params["project"], "Sonar way"), "default": params["project"] not in selected}})
        if route == ("POST", "/api/qualitygates/select"):
            selected[params["projectKey"]] = params["gateName"]
            return self.reply(204)
        # Test hooks: seed a drifted condition and an extra hand-added one.
        if route == ("POST", "/test/drift"):
            for condition in gates["wiretuner-server"]:
                if condition["metric"] == "branch_coverage":
                    condition["error"] = "80"
            gates["wiretuner-server"].append({"id": "99", "metric": "new_violations", "op": "GT", "error": "0"})
            return self.reply(204)
        if route == ("GET", "/test/state"):
            return self.reply(200, {"projects": projects, "gates": gates, "selected": selected})
        return self.reply(500, {"errors": [{"msg": f"stub has no route {method} {url.path}"}]})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")


server = HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
