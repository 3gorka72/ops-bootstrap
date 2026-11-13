"""Tests for hooks/fleet-gate (fleet-<alias> runner job-started hook). Run: python3 -I tests/test_fleet_gate.py"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = open(os.path.join(HERE, "..", "hooks", "fleet-gate")).read()
OK_REF = "3gorka72/ops-admin/.github/workflows/fleet-hourly.yml@refs/heads/main"


def run(event, env_event="schedule", wref=OK_REF, write_event=True):
    d = tempfile.mkdtemp()
    gate = os.path.join(d, "gate.py")
    open(gate, "w").write(SRC.replace("@RUNNER_DIR@", d))
    if write_event:
        os.makedirs(os.path.join(d, "_work", "_temp", "_github_workflow"))
        with open(os.path.join(d, "_work", "_temp", "_github_workflow", "event.json"), "w") as f:
            f.write(event if isinstance(event, str) else json.dumps(event))
    env = {"PATH": "/usr/bin:/bin", "GITHUB_EVENT_NAME": env_event, "GITHUB_WORKFLOW_REF": wref}
    r = subprocess.run([sys.executable, "-I", gate], env=env, capture_output=True, text=True)
    return r.returncode, (r.stdout + r.stderr).strip()


REPO = {"full_name": "3gorka72/ops-admin"}
SCHED = {"repository": REPO, "schedule": "41 * * * *"}
DISP = {"repository": REPO, "ref": "refs/heads/main", "workflow": ".github/workflows/fleet-hourly.yml"}
ADMIN_REF = "3gorka72/ops-admin/.github/workflows/admin.yml@refs/heads/main"
cases = [
    ("schedule on main", SCHED, {}, 0),
    ("schedule payload with main ref", dict(SCHED, ref="refs/heads/main"), {}, 0),
    ("manual dispatch on main", DISP, {"env_event": "workflow_dispatch"}, 0),
    ("dispatch on a branch", dict(DISP, ref="refs/heads/x"),
     {"env_event": "workflow_dispatch", "wref": OK_REF.replace("main", "x")}, 1),
    ("dispatch on a branch, env claims main", dict(DISP, ref="refs/heads/x"), {"env_event": "workflow_dispatch"}, 1),
    ("admin.yml is not allowed here", dict(DISP, workflow=".github/workflows/admin.yml"),
     {"env_event": "workflow_dispatch", "wref": ADMIN_REF}, 1),
    ("admin.yml workflow ref on schedule", SCHED, {"wref": ADMIN_REF}, 1),
    ("channel-feed on schedule", SCHED, {"wref": OK_REF.replace("fleet-hourly", "channel-feed")}, 0),
    ("channel-feed manual dispatch", dict(DISP, workflow=".github/workflows/channel-feed.yml"),
     {"env_event": "workflow_dispatch", "wref": OK_REF.replace("fleet-hourly", "channel-feed")}, 0),
    ("schedule payload naming another workflow", dict(SCHED, workflow=".github/workflows/evil.yml"), {}, 1),
    ("schedule payload with branch ref", dict(SCHED, ref="refs/heads/x"), {}, 1),
    ("schedule without schedule key", {"repository": REPO}, {}, 1),
    ("other repo", dict(SCHED, repository={"full_name": "x/y"}), {}, 1),
    ("push event", DISP, {"env_event": "push"}, 1),
    ("pull_request event", DISP, {"env_event": "pull_request"}, 1),
    ("no event file", SCHED, {"write_event": False}, 1),
    ("garbage event", "not json", {}, 1),
    ("event is a list", "[]", {}, 1),
]
ok = True
for name, ev, kw, want in cases:
    rc, out = run(ev, **kw)
    good = (rc == 0) == (want == 0)
    ok &= good
    print(("PASS" if good else "FAIL"), name, "rc=%d" % rc, out)
print("ALL PASS" if ok else "SOME FAILED")
sys.exit(0 if ok else 1)
