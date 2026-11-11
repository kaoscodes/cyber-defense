#!/usr/bin/env bash
# Stops all workers of the endpoint. The next request starts new workers, and
# these use the current template. Usage: ./scripts/restart-workers.sh
# Requests that run during the restart fail. Thus the script stops if workers
# run. To restart them anyway, set FORCE=1. If you wait 5 minutes with no
# requests, the workers stop by themselves and no restart is necessary.
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${ENV_FILE:-.env}"
set -a; . "./$ENV_FILE"; set +a

python3 -I -c '
import json, os, time, urllib.request
e = os.environ
def call(method, body=None):
    req = urllib.request.Request("https://rest.runpod.io/v1/endpoints/" + e["RUNPOD_ENDPOINT_ID"], method=method,
        data=json.dumps(body).encode() if body else None,
        headers={"Authorization": "Bearer " + e["RUNPOD_API_KEY"], "Content-Type": "application/json", "User-Agent": "restart-workers"})
    return json.load(urllib.request.urlopen(req))
def get():
    req = urllib.request.Request("https://rest.runpod.io/v1/endpoints/" + e["RUNPOD_ENDPOINT_ID"] + "?includeWorkers=true",
        headers={"Authorization": "Bearer " + e["RUNPOD_API_KEY"], "User-Agent": "restart-workers"})
    return json.load(urllib.request.urlopen(req))
endpoint = get()
workers = endpoint["workersMax"]
if workers == 0:
    raise SystemExit("workersMax is 0. Nothing to restart.")
running = [w["id"] for w in endpoint.get("workers") or [] if w.get("desiredStatus") == "RUNNING"]
if running and e.get("FORCE") != "1":
    raise SystemExit("%d workers run. Their requests fail if you restart now.\n"
                     "Wait until they stop, or run: FORCE=1 ./scripts/restart-workers.sh" % len(running))
call("PATCH", {"workersMax": 0})
try:
    time.sleep(20)
finally:
    call("PATCH", {"workersMax": workers})
print("restarted; workersMax =", workers)'
