#!/usr/bin/env bash
# One-time install of the admin runner for 3gorka72/ops-admin on a fleet host (run as root):
#   bash install.sh <alias>
# Creates user <alias>-admin (nologin, no docker), installs /usr/local/sbin/ops-admin (OIDC-gated
# root wrapper) and a sudoers drop-in allowing only that wrapper, and registers a GitHub runner
# (label admin-<alias>, --disableupdate) whose directory is root-owned except _work/_diag.
set -Eeuo pipefail
die() { echo "ОШИБКА: $*" >&2; exit 1; }
ALIAS="${1:-}"
[[ $ALIAS =~ ^[a-z][a-z0-9-]{1,30}$ ]] || die "укажите имя сервера, например: bash install.sh hub"
[ "$(id -u)" = 0 ] || die "нужен root"
command -v python3 >/dev/null || die "нет python3"
command -v curl >/dev/null || die "нет curl"
command -v visudo >/dev/null || die "нет sudo/visudo"
HERE=$(cd "$(dirname "$0")" && pwd)

# Guard against installing under the wrong alias (2026-11-09: alias "hub" was run on another host).
# The operator confirms alias and FQDN; without --replace a duplicate runner name fails instead of taking it over.
echo "Сервер: $(hostname -f)   имя для установки: $ALIAS"
echo "Если имя сервера выше не соответствует $ALIAS, ответьте n."
if [ "${OPS_CONFIRM:-}" != y ]; then
  read -rp "Верно? Введите y и Enter: " ans </dev/tty
  [ "$ans" = y ] || die "отменено"
fi
U="${ALIAS}-admin"; DIR="/opt/admin-runner-${ALIAS}"; LABEL="admin-${ALIAS}"
RV=2.338.2; RSHA=baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40
UNIT="actions.runner.3gorka72-ops-admin.${LABEL}.service"

# 1. user
CREATED=0
if id "$U" >/dev/null 2>&1; then
  # An existing user is only accepted if it is ours from an earlier run of this installer for the same alias.
  [ "$(cat /etc/ops-admin/host 2>/dev/null)" = "$ALIAS" ] || die "пользователь $U уже есть, но не от этой установки; ничего не трогаю"
else
  [ ! -e "/var/lib/$U" ] || die "/var/lib/$U уже существует; ничего не трогаю"
  # Explicit UID in 59000-59999 (top of the normal range, below systemd's DynamicUser 61184-65519), free in
  # passwd/group, in the process table and outside every /etc/subuid and /etc/subgid range. --system would take
  # 999-990, the UIDs container images (mysql, postgres, redis) run as; a shared UID made a container's mysqld
  # look like a runner process (limes, 2026-11-09).
  NUID=""; USED=$(ps -eo uid= | tr -d ' ' | sort -u)
  SUBF=""; for f in /etc/subuid /etc/subgid; do [ -r "$f" ] && SUBF="$SUBF $f"; done
  # in_sub N: true if N is inside a subordinate range; an awk error counts as inside (fail closed).
  in_sub() { [ -n "$SUBF" ] || return 1; local rc=0
    awk -F: -v n="$1" '$2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && n >= $2 && n < $2 + $3 {f=1} END {exit !f}' $SUBF || rc=$?
    [ "$rc" -ne 1 ]; }
  for n in $(seq 59000 59999); do
    getent passwd "$n" >/dev/null && continue
    getent group "$n" >/dev/null && continue
    grep -qx "$n" <<<"$USED" && continue
    in_sub "$n" && continue
    NUID=$n; break
  done
  [ -n "$NUID" ] || die "нет свободного UID в 59000-59999"
  groupadd --gid "$NUID" "$U"
  useradd --system --uid "$NUID" --gid "$NUID" --create-home --home-dir "/var/lib/$U" --shell /usr/sbin/nologin "$U"; CREATED=1
fi
if id -nG "$U" | tr ' ' '\n' | grep -qx docker; then die "$U в группе docker"; fi
# Nothing the runner user starts may outlive a job: no cron, no at, no linger, no writable home.
for f in /etc/cron.deny /etc/at.deny; do touch "$f"; grep -qx "$U" "$f" || echo "$U" >> "$f"; done
if [ -f /etc/cron.allow ]; then sed -i "/^${U}\$/d" /etc/cron.allow; fi
if [ -f /etc/at.allow ]; then sed -i "/^${U}\$/d" /etc/at.allow; fi
command -v loginctl >/dev/null && loginctl disable-linger "$U" 2>/dev/null || true
# Empty the home only when this run created it (it then holds just /etc/skel copies).
[ "$CREATED" = 1 ] && find "/var/lib/$U" -mindepth 1 -delete
chown root:root "/var/lib/$U"; chmod 0755 "/var/lib/$U"

# 2. wrapper, host file, state, log, sudoers (exact path, no args)
install -o root -g root -m 0755 "$HERE/sbin/ops-admin" /usr/local/sbin/ops-admin
install -d -o root -g root -m 0755 /etc/ops-admin
if [ -e /etc/ops-admin/host ] && [ "$(cat /etc/ops-admin/host)" != "$ALIAS" ]; then
  die "этот сервер уже записан как $(cat /etc/ops-admin/host), а не $ALIAS"
fi
printf '%s\n' "$ALIAS" > /etc/ops-admin/host; chown root:root /etc/ops-admin/host; chmod 0644 /etc/ops-admin/host
install -d -o root -g root -m 0700 /var/lib/ops-admin
touch /var/log/ops-admin.log; chmod 0600 /var/log/ops-admin.log
tmp=$(mktemp)
{ echo "Defaults!/usr/local/sbin/ops-admin !requiretty"
  echo "$U ALL=(root) NOPASSWD: /usr/local/sbin/ops-admin"; } > "$tmp"
visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; die "sudoers"; }
install -o root -g root -m 0440 "$tmp" "/etc/sudoers.d/ops-admin-$ALIAS"; rm -f "$tmp"

# 3. runner (registered once)
if [ -f "$DIR/.runner" ]; then
  echo "Сборщик $LABEL уже зарегистрирован"
else
  # Non-interactive installs (e.g. over ssh by the hands, without a tty) pass the token in RUNNER_TOKEN, read from stdin.
  TOKEN="${RUNNER_TOKEN:-}"; unset RUNNER_TOKEN
  if [ -z "$TOKEN" ]; then read -rsp "Вставьте токен GitHub (ops-admin) и нажмите Enter (символы не видны): " TOKEN </dev/tty; echo; fi
  [ -n "$TOKEN" ] || die "пустой токен"
  install -d -o "$U" -g "$U" -m 0750 "$DIR"
  tgz="/tmp/actions-runner-$RV.tgz"
  curl -fsSL -o "$tgz" "https://github.com/actions/runner/releases/download/v$RV/actions-runner-linux-x64-$RV.tar.gz"
  echo "$RSHA  $tgz" | sha256sum -c - >/dev/null || die "контрольная сумма сборщика не сошлась"
  tar -xzf "$tgz" -C "$DIR"; rm -f "$tgz"; chown -R "$U:$U" "$DIR"
  # The token reaches config.sh through the environment (runner input ACTIONS_RUNNER_INPUT_TOKEN), never argv.
  (cd "$DIR" && export ACTIONS_RUNNER_INPUT_TOKEN="$TOKEN" && sudo --preserve-env=ACTIONS_RUNNER_INPUT_TOKEN -u "$U" -H \
    ./config.sh --unattended --url https://github.com/3gorka72/ops-admin \
    --name "$LABEL" --labels "$LABEL" --no-default-labels --disableupdate >/dev/null)
  unset TOKEN
  (cd "$DIR" && ./svc.sh install "$U" >/dev/null)
fi
# Lock the runner dir: root owns everything, the runner user writes only _work and _diag.
for f in .env .path .runner .credentials; do [ -e "$DIR/$f" ] || die "нет $DIR/$f после регистрации"; done
chown -R root:root "$DIR"; chmod 0755 "$DIR"
install -d -o "$U" -g "$U" -m 0750 "$DIR/_work" "$DIR/_diag"
chown -R "$U:$U" "$DIR/_work" "$DIR/_diag"
for f in .runner .credentials .credentials_rsaparams; do
  [ -e "$DIR/$f" ] && chown root:"$U" "$DIR/$f" && chmod 0640 "$DIR/$f"
done
systemctl restart "$UNIT"
sleep 5
systemctl is-active --quiet "$UNIT" || die "сборщик не запустился: journalctl -u $UNIT -n 30"
echo "ГОТОВО: $LABEL работает. Права root только через проверенную задачу ops-admin."
