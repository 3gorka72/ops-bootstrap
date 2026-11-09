# ops-bootstrap

Installer for the `admin-<alias>` GitHub runner used by the private `3gorka72/ops-admin` repo.

- `install.sh <alias>`: shows the alias and the host FQDN and asks for `y` (or OPS_CONFIRM=y), then creates the user `<alias>-admin` (nologin, no docker). Installs `/usr/local/sbin/ops-admin` with a
  sudoers drop-in that allows only that path. Registers a runner (label `admin-<alias>`, `--disableupdate`). The runner
  directory is root-owned, except `_work/` and `_diag/`.
- `sbin/ops-admin`: runs a command as root **only** after verifying the job's GitHub Actions OIDC token. The token must
  be signed by GitHub and carry these claims: repository `3gorka72/ops-admin`, workflow
  `admin.yml@refs/heads/main`, event `workflow_dispatch`, a self-hosted runner, audience `admin-<alias>`, fresh, not
  replayed. Every accepted command is logged to `/var/log/ops-admin.log` and journald (`ops-admin` tag) with its
  sha256, run id and actor, the host's canonical FQDN (`hostname=`, as `hostname -f`) and a 12-hex hash of
  `/etc/machine-id` (`mid=`), so a wrong alias on a host shows up in the log.

The wrapper also checks its caller. The call must come from a `Runner.Worker` under `Runner.Listener`, and every process
of `<alias>-admin` in the runner unit's cgroup or in `user-<uid>.slice` must belong to that runner tree. Anything left
behind by an earlier job (a job cannot leave the unit cgroup without root) is logged as `RED foreign-process`, the call
is refused, and the process is killed only if a re-read through a pidfd still shows the runner uid and the runner
cgroup. A process whose cgroup cannot be read is logged as `RED cgroup-unreadable` and refuses the call, but is
never killed. A process that only shares the numeric UID but runs in another cgroup, such as a container's
mysqld or postgres, is logged as `AMBER uid-shared` and left alone. New users get a UID from 59000-59999 that is free
in passwd, group and the process table and outside /etc/subuid and /etc/subgid, so they do not collide with container
UIDs (999 and nearby) or systemd DynamicUser (61184-65519). The installer denies cron and at, disables linger, and makes the user's
home root-owned, so nothing a job starts can outlive the job.

Knowing this code grants nothing. A command runs only from the protected main branch of the private repo.

## Install (as root on the host)

The owner receives the exact two lines, with the commit sha and the tarball sha256 pinned.

## What VPS SECURITY checks

- ops-admin ruleset `protect-main` is active on main: PR required, no force-push, no deletion.
- `/etc/sudoers.d/ops-admin-<alias>` sha256, content exactly the wrapper path, 0440 root.
- `/usr/local/sbin/ops-admin` sha256 equals this repo at the installed commit.
- `/opt/admin-runner-<alias>` is root-owned except `_work/` and `_diag/`. `/var/lib/<alias>-admin` is root-owned.
- `<alias>-admin` is listed in `cron.deny` and `at.deny`, has no linger, and is not in the docker group.
- `/var/log/ops-admin.log` reconciles with the ops-admin Actions runs. Any `RED foreign-process` line is an incident.

## Revoke on one host (each step stands alone)

1. Immediately: `rm /etc/sudoers.d/ops-admin-<alias>`
2. Stop the runner: `cd /opt/admin-runner-<alias> && ./svc.sh stop && ./svc.sh uninstall`
3. Remove it in GitHub: ops-admin → Settings → Actions → Runners → `admin-<alias>` → Remove.
