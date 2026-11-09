# ops-bootstrap

Installer for the `admin-<alias>` GitHub runner used by the private `3gorka72/ops-admin` repo.

- `install.sh <alias>`: creates the user `<alias>-admin` (nologin, no docker). Installs `/usr/local/sbin/ops-admin` with a
  sudoers drop-in that allows only that path. Registers a runner (label `admin-<alias>`, `--disableupdate`). The runner
  directory is root-owned, except `_work/` and `_diag/`.
- `sbin/ops-admin`: runs a command as root **only** after verifying the job's GitHub Actions OIDC token. The token must
  be signed by GitHub and carry these claims: repository `3gorka72/ops-admin`, workflow
  `admin.yml@refs/heads/main`, event `workflow_dispatch`, a self-hosted runner, audience `admin-<alias>`, fresh, not
  replayed. Every accepted command is logged to `/var/log/ops-admin.log` and journald (`ops-admin` tag) with its
  sha256, run id and actor.

Knowing this code grants nothing. A command runs only from the protected main branch of the private repo.

## Install (as root on the host)

The owner receives the exact two lines, with the commit sha and the tarball sha256 pinned.

## Revoke on one host (each step stands alone)

1. Immediately: `rm /etc/sudoers.d/ops-admin-<alias>`
2. Stop the runner: `cd /opt/admin-runner-<alias> && ./svc.sh stop && ./svc.sh uninstall`
3. Remove it in GitHub: ops-admin → Settings → Actions → Runners → `admin-<alias>` → Remove.
