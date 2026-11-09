"""Tests for hooks/job-gate (ops-admin runner job-started hook). Run: python3 -I tests/test_job_gate.py"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = open(os.path.join(HERE, "..", "hooks", "job-gate")).read()
OK_REF = "3gorka72/ops-admin/.github/workflows/admin.yml@refs/heads/main"


def run(event, env_event="workflow_dispatch", wref=OK_REF, write_event=True):
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


GOOD = {"repository": {"full_name": "3gorka72/ops-admin"}, "ref": "refs/heads/main",
        "workflow": ".github/workflows/admin.yml"}
cases = [
    ("admin.yml on main", GOOD, {}, 0),
    ("branch ref", dict(GOOD, ref="refs/heads/x"), {"wref": "3gorka72/ops-admin/.github/workflows/admin.yml@refs/heads/x"}, 1),
    ("branch ref, env claims main", dict(GOOD, ref="refs/heads/x"), {}, 1),
    ("other workflow", dict(GOOD, workflow=".github/workflows/evil.yml"), {}, 1),
    ("other repo", dict(GOOD, repository={"full_name": "x/y"}), {}, 1),
    ("push event", GOOD, {"env_event": "push"}, 1),
    ("workflow ref mismatch", GOOD, {"wref": "3gorka72/ops-admin/.github/workflows/evil.yml@refs/heads/main"}, 1),
    ("no event file", GOOD, {"write_event": False}, 1),
    ("garbage event", "not json", {}, 1),
]
ok = True
for name, ev, kw, want in cases:
    rc, out = run(ev, **kw)
    good = (rc == 0) == (want == 0)
    ok &= good
    print(("PASS" if good else "FAIL"), name, "rc=%d" % rc, out)
print("ALL PASS" if ok else "SOME FAILED")
sys.exit(0 if ok else 1)
