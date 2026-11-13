#!/usr/bin/env bash
# Deterministic acceptance seed for the n8n tester-env prospect.
# Creates 3 workflows with fixed names, tags, and active states via the REST API.
# Run once against a fresh deploy (after reset + start). Safe to re-run: existing
# names are skipped.
#
# Usage: ./scripts/seed-tester-env.sh [BASE_URL]
# Env: SEED_EMAIL (default admin@tester.local), SEED_PASSWORD (default password)
set -euo pipefail

BASE_URL="${1:-http://localhost:${PORT:-18567}}"
SEED_EMAIL="${SEED_EMAIL:-admin@tester.local}"
SEED_PASSWORD="${SEED_PASSWORD:-password}"

# Wait for the app to accept logins (fresh SQLite boot needs a few seconds).
for _ in $(seq 1 60); do
	if curl -fsS "$BASE_URL/healthz" >/dev/null 2>&1; then break; fi
	sleep 1
done

python3 - "$BASE_URL" "$SEED_EMAIL" "$SEED_PASSWORD" <<'EOF'
import json, sys, urllib.request, http.cookiejar, urllib.error, time

base, email, password = sys.argv[1], sys.argv[2], sys.argv[3]
jar = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

def call(method, path, data=None):
    req = urllib.request.Request(base + path,
        data=json.dumps(data).encode() if data is not None else None,
        method=method, headers={'Content-Type': 'application/json'})
    try:
        with op.open(req) as r:
            body = r.read().decode() or '{}'
            # While the app boots it answers HTTP 200 with an HTML placeholder
            # ("n8n is starting up. Please wait") instead of JSON. Return the
            # raw text so the retry loops below can wait for real JSON.
            try:
                return r.status, json.loads(body)
            except json.JSONDecodeError:
                return r.status, body
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:1000]

# Owner login may 404/401 (or the startup placeholder) until first boot
# finishes; retry briefly.
for _ in range(60):
    s, b = call('POST', '/rest/login',
                {"emailOrLdapLoginId": email, "password": password})
    if s == 200 and isinstance(b, dict):
        break
    time.sleep(1)
assert s == 200 and isinstance(b, dict), f"login failed: {s} {b}"

_, tags_body = call('GET', '/rest/tags')
tag_ids = {t['name']: t['id'] for t in tags_body['data']}
for name in ("reporting", "support", "inventory"):
    if name not in tag_ids:
        s, b = call('POST', '/rest/tags', {"name": name})
        assert s == 200, f"create tag {name}: {s} {b}"
        tag_ids[name] = b['data']['id']

_, wf_body = call('GET', '/rest/workflows?skip=0&take=100')
existing = {w['name']: w for w in wf_body['data']}

def assignment_type(value):
    # The runtime validates each assignment against its declared type. An
    # assignment without "type" makes Set v3.3+ fail to execute with
    # "Cannot read properties of undefined (reading 'toLowerCase')".
    if isinstance(value, bool):
        return 'boolean'
    if isinstance(value, (int, float)):
        return 'number'
    return 'string'

def set_node(nid, name, assignments, x=240):
    return {"parameters": {"assignments": {"assignments": [
        {"id": f"a{i}", "name": k, "value": v, "type": assignment_type(v)}
        for i, (k, v) in enumerate(assignments)]}, "options": {}},
        "id": nid, "name": name, "type": "n8n-nodes-base.set",
        "typeVersion": 3.4, "position": [x, 0]}

WORKFLOWS = [
    {"name": "Daily Sales Report", "tag": "reporting", "active": True,
     "nodes": [
         {"parameters": {"rule": {"interval": [{"field": "hours", "hoursInterval": 24}]}},
          "id": "sched-0001", "name": "Every Day", "type": "n8n-nodes-base.scheduleTrigger",
          "typeVersion": 1.2, "position": [0, 0]},
         set_node("set-0001", "Summarize Orders", [("totalOrders", 128), ("revenue", 4520)])],
     "connections": {"Every Day": {"main": [[{"node": "Summarize Orders", "type": "main", "index": 0}]]}}},
    {"name": "Support Ticket Triage", "tag": "support", "active": False,
     "nodes": [
         {"parameters": {}, "id": "man-0002", "name": "When clicking 'Execute workflow'",
          "type": "n8n-nodes-base.manualTrigger", "typeVersion": 1, "position": [0, 0]},
         set_node("set-0002", "Label Ticket", [("priority", "high"), ("team", "support")])],
     "connections": {"When clicking 'Execute workflow'": {"main": [[{"node": "Label Ticket", "type": "main", "index": 0}]]}}},
    {"name": "Inventory Low Stock Alert", "tag": "inventory", "active": False,
     "nodes": [
         {"parameters": {}, "id": "man-0003", "name": "When clicking 'Execute workflow'",
          "type": "n8n-nodes-base.manualTrigger", "typeVersion": 1, "position": [0, 0]},
         set_node("set-0003", "Flag Low Stock", [("sku", "ACME-WIDGET-42"), ("stock", 3)])],
     "connections": {"When clicking 'Execute workflow'": {"main": [[{"node": "Flag Low Stock", "type": "main", "index": 0}]]}}},
]

for wf in WORKFLOWS:
    if wf["name"] in existing:
        print(f"skip {wf['name']} (exists)")
        wid, ver = existing[wf["name"]]['id'], None
    else:
        s, b = call('POST', '/rest/workflows', {
            "name": wf["name"], "nodes": wf["nodes"], "connections": wf["connections"],
            "settings": {"executionOrder": "v1"}, "tags": [tag_ids[wf["tag"]]]})
        assert s == 200, f"create {wf['name']}: {s} {b}"
        wid, ver = b['data']['id'], b['data']['versionId']
        print(f"created {wf['name']} id={wid}")
    if wf["active"]:
        if ver is None:
            _, d = call('GET', f"/rest/workflows/{wid}")
            ver, already = d['data']['versionId'], d['data']['active']
            if already:
                print(f"active {wf['name']} (already)");
            else:
                s, b = call('POST', f"/rest/workflows/{wid}/activate", {"versionId": ver})
                assert s == 200, f"activate {wf['name']}: {s} {b}"
                print(f"active {wf['name']}")
        else:
            s, b = call('POST', f"/rest/workflows/{wid}/activate", {"versionId": ver})
            assert s == 200, f"activate {wf['name']}: {s} {b}"
            print(f"active {wf['name']}")

_, final = call('GET', '/rest/workflows?skip=0&take=100')
for w in sorted(final['data'], key=lambda w: w['name']):
    print(f"seed-state name={w['name']!r} active={w['active']} tags={[t['name'] for t in w.get('tags', []) if t]}")
EOF
