#!/usr/bin/env bash
# One-time install of the fleet-check runner for 3gorka72/ops-admin (run as root):
#   bash install-fleet.sh <alias>
# Creates user fleet-<alias> (nologin, no sudo, no docker), the state dir /var/lib/fleet-hourly (0700, that user), and
# registers a GitHub runner (label fleet-<alias>, --disableupdate) whose directory is root-owned except _work/_diag.
# Its job gate (hooks/fleet-gate) admits only fleet-hourly.yml on main (schedule or manual dispatch). It never touches
# the admin runner, the ops-admin wrapper, /etc/ops-admin or sudoers: this runner has no root path at all.
set -Eeuo pipefail
die() { echo "ОШИБКА: $*" >&2; exit 1; }
ALIAS="${1:-}"
[[ $ALIAS =~ ^[a-z][a-z0-9-]{1,30}$ ]] || die "укажите имя сервера, например: bash install-fleet.sh hub"
[ "$(id -u)" = 0 ] || die "нужен root"
command -v python3 >/dev/null || die "нет python3"
command -v curl >/dev/null || die "нет curl"
HERE=$(cd "$(dirname "$0")" && pwd)

echo "Сервер: $(hostname -f)   имя для установки: $ALIAS"
echo "Если имя сервера выше не соответствует $ALIAS, ответьте n."
if [ "${OPS_CONFIRM:-}" != y ]; then
  read -rp "Верно? Введите y и Enter: " ans </dev/tty
  ans=${ans//$'\r'/}; ans=${ans// /}
  case "$ans" in y|Y|у|У|да|Да|ДА) ;; *) die "отменено (ответ не y)";; esac
fi
# The alias must match the admin runner's record on this host, if there is one.
if [ -e /etc/ops-admin/host ] && [ "$(cat /etc/ops-admin/host)" != "$ALIAS" ]; then
  die "этот сервер записан как $(cat /etc/ops-admin/host), а не $ALIAS"
fi
U="fleet-${ALIAS}"; DIR="/opt/fleet-runner-${ALIAS}"; LABEL="fleet-${ALIAS}"; STATE=/var/lib/fleet-hourly
RV=2.338.2; RSHA=baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40
UNIT="actions.runner.3gorka72-ops-admin.${LABEL}.service"

# 1. user: same UID rules as install.sh (59000-59999, free everywhere, outside subuid/subgid)
CREATED=0
if id "$U" >/dev/null 2>&1; then
  [ -f "$DIR/.fleet-install" ] || die "пользователь $U уже есть, но не от этой установки; ничего не трогаю"
else
  [ ! -e "/var/lib/$U" ] || die "/var/lib/$U уже существует; ничего не трогаю"
  NUID=""; USED=$(ps -eo uid= | tr -d ' ' | sort -u)
  SUBF=""; for f in /etc/subuid /etc/subgid; do [ -r "$f" ] && SUBF="$SUBF $f"; done
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
if id -nG "$U" | tr ' ' '\n' | grep -qxE 'docker|sudo|adm|wheel|lxd'; then die "$U в привилегированной группе"; fi
grep -rqsw -- "$U" /etc/sudoers /etc/sudoers.d && die "$U упомянут в sudoers"
for f in /etc/cron.deny /etc/at.deny; do touch "$f"; grep -qx "$U" "$f" || echo "$U" >> "$f"; done
if [ -f /etc/cron.allow ]; then sed -i "/^${U}\$/d" /etc/cron.allow; fi
if [ -f /etc/at.allow ]; then sed -i "/^${U}\$/d" /etc/at.allow; fi
command -v loginctl >/dev/null && loginctl disable-linger "$U" 2>/dev/null || true
[ "$CREATED" = 1 ] && find "/var/lib/$U" -mindepth 1 -delete
chown root:root "/var/lib/$U"; chmod 0755 "/var/lib/$U"
# 2. state dir: data only (restart counts, last alert); the one place the user may write outside the runner's _work
install -d -o "$U" -g "$U" -m 0700 "$STATE"

# 3. runner (registered once)
if [ -f "$DIR/.runner" ]; then
  echo "Сборщик $LABEL уже зарегистрирован"
else
  TOKEN="${RUNNER_TOKEN:-}"; unset RUNNER_TOKEN
  if [ -z "$TOKEN" ]; then read -rsp "Вставьте токен GitHub (ops-admin) и нажмите Enter (символы не видны): " TOKEN </dev/tty; echo; fi
  TOKEN=${TOKEN//$'\r'/}; TOKEN=${TOKEN// /}
  [ -n "$TOKEN" ] || die "пустой токен"
  install -d -o "$U" -g "$U" -m 0750 "$DIR"
  tgz="/tmp/actions-runner-$RV.tgz"
  curl -fsSL -o "$tgz" "https://github.com/actions/runner/releases/download/v$RV/actions-runner-linux-x64-$RV.tar.gz"
  echo "$RSHA  $tgz" | sha256sum -c - >/dev/null || die "контрольная сумма сборщика не сошлась"
  tar -xzf "$tgz" -C "$DIR"; rm -f "$tgz"; chown -R "$U:$U" "$DIR"
  (cd "$DIR" && export ACTIONS_RUNNER_INPUT_TOKEN="$TOKEN" && sudo --preserve-env=ACTIONS_RUNNER_INPUT_TOKEN -u "$U" -H \
    ./config.sh --unattended --url https://github.com/3gorka72/ops-admin \
    --name "$LABEL" --labels "$LABEL" --no-default-labels --disableupdate >/dev/null)
  unset TOKEN
  (cd "$DIR" && ./svc.sh install "$U" >/dev/null)
fi
for f in .env .path .runner .credentials; do [ -e "$DIR/$f" ] || die "нет $DIR/$f после регистрации"; done
[ "$(cat "$DIR/.service" 2>/dev/null)" = "$UNIT" ] || die "служба сборщика называется не $UNIT; ничего не запускаю"
# Job gate: fail any job that is not fleet-hourly.yml on main before its first step.
install -d -o root -g root -m 0755 /usr/local/lib/ops-admin
G=/usr/local/lib/ops-admin/fleet-gate-$ALIAS
sed "s#@RUNNER_DIR@#$DIR#" "$HERE/hooks/fleet-gate" > "$G.tmp"; install -o root -g root -m 0755 "$G.tmp" "$G"; rm -f "$G.tmp"
printf '#!/bin/bash\nexec /usr/bin/python3 -I %s\n' "$G" > "$G.sh.tmp"; install -o root -g root -m 0755 "$G.sh.tmp" "$G.sh"; rm -f "$G.sh.tmp"
grep -v '^ACTIONS_RUNNER_HOOK_JOB_STARTED=' "$DIR/.env" > "$DIR/.env.tmp" || true
echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=$G.sh" >> "$DIR/.env.tmp"
mv "$DIR/.env.tmp" "$DIR/.env"
touch "$DIR/.fleet-install"
chown -R root:root "$DIR"; chmod 0755 "$DIR"
install -d -o "$U" -g "$U" -m 0750 "$DIR/_work" "$DIR/_diag"
chown -R "$U:$U" "$DIR/_work" "$DIR/_diag"
for f in .runner .credentials .credentials_rsaparams; do
  [ -e "$DIR/$f" ] && chown root:"$U" "$DIR/$f" && chmod 0640 "$DIR/$f"
done
systemctl restart "$UNIT"
sleep 5
systemctl is-active --quiet "$UNIT" || die "сборщик не запустился: journalctl -u $UNIT -n 30"
echo "ГОТОВО: $LABEL работает. Без root и без docker; принимает только fleet-hourly.yml на main."
