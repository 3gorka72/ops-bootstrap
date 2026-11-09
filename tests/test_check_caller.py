"""Fake-/proc tests for ops-admin check_caller (cgroup-scoped foreign-process check). Run: python3 -I tests/test_check_caller.py"""
import importlib.machinery, importlib.util, os, sys, tempfile, types, shutil
src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sbin", "ops-admin")
l = importlib.machinery.SourceFileLoader("opsadmin", src); spec = importlib.util.spec_from_loader("opsadmin", l)
m = importlib.util.module_from_spec(spec); l.exec_module(m)
U = 61000; HOST = "limes"; UNIT = "actions.runner.3gorka72-ops-admin.admin-limes.service"
m.pwd = types.SimpleNamespace(getpwnam=lambda n: types.SimpleNamespace(pw_uid=U))
m.subprocess = types.SimpleNamespace(run=lambda *a, **k: None)
killed = []
m.os.kill = lambda p, s: killed.append(p)
def build(extra):
    root = tempfile.mkdtemp()
    rdir = "/opt/admin-runner-%s/bin/" % HOST
    procs = {1: (0, 0, "systemd", None, "/init.scope"),
             100: (1, U, "runsvc.sh", None, "/system.slice/" + UNIT),
             101: (100, U, "node", None, "/system.slice/" + UNIT),
             102: (101, U, "Runner.Listener", rdir + "Runner.Listener", "/system.slice/" + UNIT),
             103: (102, U, "Runner.Worker", rdir + "Runner.Worker", "/system.slice/" + UNIT),
             104: (103, U, "bash", None, "/system.slice/" + UNIT)}
    procs.update(extra)
    for pid, (pp, uid, comm, exe, cg) in procs.items():
        d = os.path.join(root, str(pid)); os.makedirs(d)
        open(os.path.join(d, "status"), "w").write("Name:\t%s\nPPid:\t%d\nUid:\t%d\t%d\t%d\t%d\n" % (comm, pp, uid, uid, uid, uid))
        open(os.path.join(d, "comm"), "w").write(comm + "\n")
        if cg is not None:
            open(os.path.join(d, "cgroup"), "w").write(("0::%s\n" % cg) if cg else "")
        if exe: os.symlink(exe, os.path.join(d, "exe"))
    return root
def run(name, extra, expect_ok, expect_killed, expect_log):
    killed.clear(); log = tempfile.mktemp(); m.LOG = log; open(log, "w").close()
    root = build(extra)
    try:
        m.check_caller(HOST, 104, root=root, kill=True, main_pid=100, unit_cg="/system.slice/" + UNIT); ok = True
    except SystemExit:
        ok = False
    txt = open(log).read()
    res = ok == expect_ok and sorted(killed) == sorted(expect_killed) and all(s in txt for s in expect_log)
    print(("PASS" if res else "FAIL"), name, "ok=%s killed=%s log=%r" % (ok, killed, txt.strip()))
    shutil.rmtree(root); os.unlink(log)
    return res
r = [
 run("clean", {}, True, [], []),
 run("container same uid (limes mysqld)", {200: (1, U, "mysqld", None, "/system.slice/docker-abc.scope")}, True, [], ["AMBER uid-shared pid=200 comm=mysqld cgroup=/system.slice/docker-abc.scope"]),
 run("leftover in unit cgroup", {300: (1, U, "sleep", None, "/system.slice/" + UNIT)}, False, [300], ["RED foreign-process pid=300"]),
 run("user manager of runner uid", {400: (1, U, "systemd", None, "/user.slice/user-%d.slice/user@%d.service/init.scope" % (U, U))}, False, [400], ["RED foreign-process pid=400"]),
 run("unreadable cgroup: refused, not killed", {500: (1, U, "x", None, None)}, False, [], ["RED cgroup-unreadable pid=500"]),
 run("v1 hybrid lines", {600: (1, U, "y", None, "/system.slice/docker-def.scope")}, True, [], ["AMBER uid-shared pid=600"]),
 run("unit name as component elsewhere", {800: (1, U, "z", None, "/other.slice/" + UNIT)}, True, [], ["AMBER uid-shared pid=800"]),
 run("sibling prefix not under unit", {900: (1, U, "w", None, "/system.slice/" + UNIT + "-evil")}, True, [], ["AMBER uid-shared pid=900"]),
 run("child cgroup of unit", {910: (1, U, "v", None, "/system.slice/" + UNIT + "/sub")}, False, [910], ["RED foreign-process pid=910"]),
 run("empty cgroup file: refused, not killed", {920: (1, U, "e", None, "")}, False, [], ["RED cgroup-unreadable pid=920"]),
 run("other uid in unit cgroup ignored", {700: (1, 0, "root-thing", None, "/system.slice/" + UNIT)}, True, [], []),
]
# pid reuse: the leftover is foreign at scan time, then (before the kill) the pid now belongs to a container
orig = m.kill_if_still_foreign
def reuse(root, pid, uid, unit_cg):
    open(os.path.join(root, str(pid), "cgroup"), "w").write("0::/system.slice/docker-new.scope\n")
    return orig(root, pid, uid, unit_cg)
m.kill_if_still_foreign = reuse
r.append(run("pid reused before kill: refused, not killed", {930: (1, U, "sleep", None, "/system.slice/" + UNIT)}, False, [], ["RED foreign-process pid=930 comm=sleep host=limes (not killed)"]))
def reuse_uid(root, pid, uid, unit_cg):
    st = os.path.join(root, str(pid), "status")
    open(st, "w").write(open(st).read().replace("Uid:\t%d\t%d\t%d\t%d" % (U, U, U, U), "Uid:\t0\t0\t0\t0"))
    return orig(root, pid, uid, unit_cg)
m.kill_if_still_foreign = reuse_uid
r.append(run("uid changed before kill: refused, not killed", {940: (1, U, "sleep", None, "/system.slice/" + UNIT)}, False, [], ["(not killed)"]))
m.kill_if_still_foreign = orig
killed.clear(); m.LOG = tempfile.mktemp()
try:
    m.check_caller(HOST, 104, root=build({}), kill=True, main_pid=100, unit_cg=""); nocg = False
except SystemExit:
    nocg = True
print(("PASS" if nocg else "FAIL"), "no unit ControlGroup refuses")
r.append(nocg)
print("ALL PASS" if all(r) else "SOME FAILED")
sys.exit(0 if all(r) else 1)
