#!/usr/bin/env bash
# Deploys and rolls back Edly Docs on the server.
#
# It is the forced command of the SSH key used by the "Edly deploy" workflow,
# and can also be run by hand on the server:
#
#   edly-deploy.sh status
#   edly-deploy.sh deploy sha256:<image digest>
#   edly-deploy.sh rollback
#   edly-deploy.sh log
#   edly-deploy.sh recover   (restores the backup of an interrupted run, used by cron)
#   edly-deploy.sh wait [unix time]  (follows the latest run that started after
#                                     that time and returns its result)
#
# A deploy pulls and checks the new image while the site is still up, takes a
# full backup, switches the image and checks the result. If any step fails it
# restores the backup, so the site is always running the old or the new version
# when the script ends. The work runs detached from the SSH session, so a
# dropped connection or a cancelled workflow cannot stop it halfway.
set -uo pipefail

OUTLINE_DIR="${OUTLINE_DIR:-$HOME/apps/outline}"
STATE_DIR="${STATE_DIR:-$HOME/apps/outline-deploy}"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/apps/outline-backups}"
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/edly-io/outline}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:6885/_health}"
PUBLIC_URL="${PUBLIC_URL:-https://docs.edly.space}"
SUDO="${SUDO-sudo -n}"
KEEP_BACKUPS="${KEEP_BACKUPS:-3}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"
# A restore waits longer than a deploy, there is nothing better to fall back to.
RESTORE_TIMEOUT="${RESTORE_TIMEOUT:-900}"
SOAK_SECONDS="${SOAK_SECONDS:-60}"
MIN_FREE_KB="${MIN_FREE_KB:-3000000}"
ROLLBACK_TARBALL="${ROLLBACK_TARBALL:-$BACKUP_ROOT/outline-1.6.1-image.tar.gz}"

RUNS_DIR="$STATE_DIR/runs"
IN_PROGRESS="$STATE_DIR/in-progress"
CURRENT_SNAPSHOT=""
LOCK_DIR="$STATE_DIR/lock"

# Remembers, also on disk, the snapshot to restore if the site is stopped and
# the run ends before it is running again. An empty value clears it.
set_current() {
  CURRENT_SNAPSHOT="$1"
  if [ -n "$1" ]; then
    echo "$1" > "$IN_PROGRESS"
  else
    rm -f "$IN_PROGRESS"
  fi
}

log() {
  printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"
}

compose() {
  (cd "$OUTLINE_DIR" && docker compose "$@")
}

# The image of the outline service, as written in the compose file.
current_image() {
  compose config --format json 2>/dev/null |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["services"]["outline"]["image"])'
}

# Replaces the image of the outline service in the compose file, leaving every
# other line untouched.
set_image() {
  python3 - "$OUTLINE_DIR/docker-compose.yml" "$1" <<'EOF'
import re, sys
path, image = sys.argv[1], sys.argv[2]
lines = open(path).read().split("\n")
in_outline, replaced = False, False
for i, line in enumerate(lines):
    if re.match(r"^  \S", line):
        in_outline = line.strip() == "outline:"
    elif in_outline and not replaced and re.match(r"^    image:", line):
        lines[i] = f"    image: {image}"
        replaced = True
if not replaced:
    sys.exit("could not find the image of the outline service")
open(path + ".tmp", "w").write("\n".join(lines))
EOF
  mv "$OUTLINE_DIR/docker-compose.yml.tmp" "$OUTLINE_DIR/docker-compose.yml"
}

healthy() {
  curl -sf -m 5 "$HEALTH_URL" 2>/dev/null | grep -q OK
}

wait_healthy() {
  local deadline=$((SECONDS + ${1:-$HEALTH_TIMEOUT}))
  until healthy; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      return 1
    fi
    sleep 2
  done
}

counts() {
  compose exec -T postgres psql -U outline outline -Atc \
    "select (select count(*) from users),(select count(*) from documents),(select count(*) from collections),(select count(*) from attachments),(select count(*) from revisions),(select count(*) from comments),(select count(*) from user_permissions),(select count(*) from shares)"
}

app_version() {
  compose exec -T outline node -p 'require("/opt/outline/package.json").version' 2>/dev/null
}

restarts() {
  docker inspect "$(compose ps -q outline)" --format '{{.RestartCount}}' 2>/dev/null
}

status() {
  log "image:   $(current_image)"
  log "version: $(app_version || echo unknown)"
  if healthy; then log "health:  OK"; else log "health:  NOT HEALTHY"; fi
  compose ps --format '{{.Name}}  {{.Status}}' 2>/dev/null | while read -r line; do log "         $line"; done
  log "backups: $(ls -1d "$BACKUP_ROOT"/deploy-* 2>/dev/null | wc -l | tr -d ' ') deploy snapshot(s) in $BACKUP_ROOT"
}

# Makes sure an image is available locally, also when it was cleaned up since.
ensure_image() {
  local image="$1"
  if docker image inspect "$image" >/dev/null 2>&1; then
    return 0
  fi
  log "image $image is missing locally, fetching it"
  if docker pull -q "$image" >/dev/null 2>&1; then
    return 0
  fi
  if [ -f "$ROLLBACK_TARBALL" ]; then
    gunzip -c "$ROLLBACK_TARBALL" | docker load >/dev/null && docker image inspect "$image" >/dev/null 2>&1
    return $?
  fi
  return 1
}

# Restores a snapshot taken by take_snapshot and starts the site from it.
# Returns 0 when the restored site is healthy.
restore_snapshot() {
  local snapshot="$1"
  log "RESTORING snapshot $snapshot"
  compose stop >/dev/null 2>&1
  cp "$snapshot/docker-compose.yml" "$OUTLINE_DIR/docker-compose.yml"
  cp "$snapshot/env" "$OUTLINE_DIR/env"
  if [ -f "$snapshot/data.complete" ]; then
    log "restoring the database and files"
    $SUDO rsync -a --delete "$snapshot/data/" "$OUTLINE_DIR/data/" || log "WARNING: copying the data back failed"
  else
    log "the data was not changed yet, keeping it as it is"
  fi
  ensure_image "$(cat "$snapshot/image")" || log "WARNING: image $(cat "$snapshot/image") is not available"
  compose up -d redis >/dev/null 2>&1
  sleep 3
  compose exec -T redis redis-cli FLUSHALL >/dev/null 2>&1
  compose up -d >/dev/null 2>&1
  if wait_healthy "$RESTORE_TIMEOUT"; then
    log "restored, the site is healthy again on $(app_version || echo unknown)"
    return 0
  fi
  log "CRITICAL: the restored site is not healthy after ${RESTORE_TIMEOUT}s, check the server by hand"
  return 1
}

# Stops the site and takes a full snapshot: compose file, env, image name, a
# database dump and a copy of the data directory.
take_snapshot() {
  local snapshot="$1"
  mkdir -p "$snapshot"
  current_image > "$snapshot/image"
  cp "$OUTLINE_DIR/docker-compose.yml" "$snapshot/docker-compose.yml"
  cp "$OUTLINE_DIR/env" "$snapshot/env"
  chmod 600 "$snapshot/env"
  compose stop outline >/dev/null 2>&1 || return 1
  log "site stopped, taking a backup"
  counts > "$snapshot/counts" || return 1
  compose exec -T postgres pg_dump -U outline -Fc outline > "$snapshot/outline.dump" || return 1
  local tables
  tables=$(compose exec -T postgres pg_restore -l < "$snapshot/outline.dump" | grep -c "TABLE DATA")
  if [ "${tables:-0}" -lt 30 ]; then
    log "the database dump looks incomplete ($tables tables)"
    return 1
  fi
  compose stop postgres redis >/dev/null 2>&1 || return 1
  $SUDO rsync -a --delete "$OUTLINE_DIR/data/" "$snapshot/data/" || return 1
  touch "$snapshot/data.complete"
  log "backup complete: $snapshot (dump has $tables tables)"
}

# Keeps the newest snapshots of each kind and removes the rest.
# Restores the snapshot of an interrupted run. When the run was a deploy, its
# snapshot is then kept apart like that of any failed deploy.
restore_interrupted() {
  local snapshot="$1"
  if ! restore_snapshot "$snapshot"; then
    return 1
  fi
  set_current ""
  case "$(basename "$snapshot")" in
    deploy-*) mark_failed "$snapshot" ;;
  esac
}

# Keeps the snapshot of a failed deploy apart, so that a rollback undoes the
# last successful deploy rather than the failed one.
mark_failed() {
  $SUDO mv "$1" "$BACKUP_ROOT/failed-$(basename "$1")" 2>/dev/null
  prune_snapshots
}

prune_snapshots() {
  local prefix keep dirs count
  for prefix in deploy:"$KEEP_BACKUPS" failed-deploy:1 pre-rollback:1 rolled-back:1; do
    keep="${prefix#*:}"
    dirs=$(ls -1d "$BACKUP_ROOT/${prefix%%:*}"-* 2>/dev/null | sort)
    count=$(printf '%s\n' "$dirs" | grep -c . || true)
    if [ "$count" -le "$keep" ]; then
      continue
    fi
    printf '%s\n' "$dirs" | grep . | head -n "$((count - keep))" | while read -r dir; do
      log "removing old snapshot $dir"
      $SUDO rm -rf "$dir"
    done
  done
}

# Checks the new version after it started. Every check must pass.
verify() {
  local snapshot="$1" expected_version="$2"
  wait_healthy || { log "check failed: not healthy within ${HEALTH_TIMEOUT}s"; return 1; }
  local version
  version=$(app_version)
  [ "$version" = "$expected_version" ] || { log "check failed: version is '$version', expected '$expected_version'"; return 1; }
  log "check: version $version"
  if compose logs outline 2>&1 | grep -E '"level":"fatal"' >/dev/null; then
    log "check failed: fatal errors in the log"
    compose logs outline 2>&1 | grep -E '"level":"fatal"' | tail -5 | cut -c1-300
    return 1
  fi
  log "check: no fatal errors"
  local after
  after=$(counts)
  [ "$after" = "$(cat "$snapshot/counts")" ] || { log "check failed: counts changed from $(cat "$snapshot/counts") to $after"; return 1; }
  log "check: data counts unchanged ($after)"
  if [ -n "$PUBLIC_URL" ]; then
    curl -sf -m 10 "$PUBLIC_URL/_health" | grep -q OK || { log "check failed: $PUBLIC_URL/_health"; return 1; }
    log "check: $PUBLIC_URL is up"
  fi
  local start_restarts
  start_restarts=$(restarts)
  log "watching the site for ${SOAK_SECONDS}s"
  local deadline=$((SECONDS + SOAK_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 5
    healthy || { log "check failed: became unhealthy while watching"; return 1; }
  done
  [ "$(restarts)" = "$start_restarts" ] || { log "check failed: the container restarted"; return 1; }
  log "check: stayed healthy for ${SOAK_SECONDS}s"
}

do_deploy() {
  local digest="$1"
  local image="$IMAGE_REPO@$digest"
  local previous
  previous=$(current_image) || { log "could not read the compose file"; return 1; }
  log "deploying $image"
  log "currently running $previous"
  if [ "$previous" = "$image" ]; then
    log "this version is already deployed, nothing to do"
    status
    return 0
  fi

  # Everything up to the snapshot happens while the site is still running.
  healthy || { log "the site is not healthy right now, refusing to deploy"; return 1; }
  log "pulling the new image (site still up)"
  docker pull -q "$image" >/dev/null || { log "could not pull $image"; return 1; }
  local arch
  arch=$(docker image inspect "$image" --format '{{.Architecture}}')
  [ "$arch" = "amd64" ] || { log "the image is built for '$arch', not amd64"; return 1; }
  local new_version
  new_version=$(docker run --rm --entrypoint node "$image" -p 'require("/opt/outline/package.json").version' 2>/dev/null) ||
    { log "the new image does not run"; return 1; }
  log "the new image runs Outline $new_version"
  local free
  free=$(df -Pk "$BACKUP_ROOT" | awk 'NR==2 {print $4}')
  [ "$free" -ge "$MIN_FREE_KB" ] || { log "not enough free disk space for a backup ($free KB)"; return 1; }

  local snapshot
  snapshot="$BACKUP_ROOT/deploy-$(date -u +%Y%m%dT%H%M%SZ)"
  local started
  started=$(date +%s)
  set_current "$snapshot"
  if ! take_snapshot "$snapshot"; then
    log "the backup failed"
    restore_snapshot "$snapshot" && set_current ""
    mark_failed "$snapshot"
    return 1
  fi
  if ! set_image "$image"; then
    restore_snapshot "$snapshot" && set_current ""
    mark_failed "$snapshot"
    return 1
  fi
  log "starting the new version"
  if ! compose up -d >/dev/null 2>&1; then
    log "could not start the new version"
    restore_snapshot "$snapshot" && set_current ""
    mark_failed "$snapshot"
    return 1
  fi
  if ! verify "$snapshot" "$new_version"; then
    log "the new version failed its checks, rolling back"
    compose logs --tail 30 outline 2>&1 | cut -c1-300
    restore_snapshot "$snapshot" && set_current ""
    mark_failed "$snapshot"
    return 1
  fi
  set_current ""
  log "DEPLOYED $image (Outline $new_version), downtime about $(( $(date +%s) - started - SOAK_SECONDS ))s"
  prune_snapshots
  return 0
}

do_rollback() {
  local snapshot
  snapshot=$(ls -1d "$BACKUP_ROOT"/deploy-* 2>/dev/null | sort | tail -n 1)
  if [ -z "$snapshot" ]; then
    log "there is no deploy snapshot to roll back to"
    return 1
  fi
  log "rolling back to the snapshot taken before the last deploy: $snapshot"
  log "this restores the database and files as they were at that moment"

  # Keep the current state too, in case the rollback itself is a mistake.
  local safety
  safety="$BACKUP_ROOT/pre-rollback-$(date -u +%Y%m%dT%H%M%SZ)"
  set_current "$safety"
  if ! take_snapshot "$safety"; then
    log "could not back up the current state, not rolling back"
    restore_snapshot "$safety" && set_current ""
    return 1
  fi
  if restore_snapshot "$snapshot"; then
    set_current ""
    $SUDO mv "$snapshot" "$BACKUP_ROOT/rolled-back-$(basename "$snapshot")"
    log "ROLLED BACK. The state from before the rollback is kept in $safety"
    return 0
  fi
  log "the old version did not come up, going back to the state before the rollback"
  restore_snapshot "$safety" && set_current ""
  return 1
}

# Restores the snapshot of a run that ended without finishing, for example when
# the process was killed or the server restarted while the site was stopped.
# Does nothing otherwise. It also runs from cron as a watchdog.
recover() {
  if [ ! -f "$IN_PROGRESS" ]; then
    return 0
  fi
  if [ -f "$LOCK_DIR/pid" ] && kill -0 "$(cat "$LOCK_DIR/pid")" 2>/dev/null; then
    return 0
  fi
  local snapshot
  snapshot=$(cat "$IN_PROGRESS")
  log "a deploy or rollback was interrupted while the site was stopped, recovering"
  rm -rf "$LOCK_DIR"
  mkdir -p "$LOCK_DIR"
  echo $$ > "$LOCK_DIR/pid"
  local code=1
  if [ -d "$snapshot" ] && restore_interrupted "$snapshot"; then
    code=0
  fi
  rm -rf "$LOCK_DIR"
  return "$code"
}

# Runs a deploy or rollback in the background and follows its log, so the work
# continues even if this SSH session ends.
launch() {
  mkdir -p "$RUNS_DIR"
  recover || { log "recovering from an interrupted run failed, not starting a new one"; return 1; }
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -f "$LOCK_DIR/pid" ] && kill -0 "$(cat "$LOCK_DIR/pid")" 2>/dev/null; then
      log "another deploy or rollback is running, try again later"
      return 1
    fi
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" || { log "another deploy or rollback is starting, try again later"; return 1; }
  fi
  echo $$ > "$LOCK_DIR/pid"
  local run
  run="$RUNS_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$1"
  # The worker runs its own copy of this script, so updating the script cannot
  # affect a deploy that is already running.
  cp "$0" "$run.sh"
  chmod 700 "$run.sh"
  env -u SSH_ORIGINAL_COMMAND EDLY_DEPLOY_WORKER=1 nohup "$run.sh" __worker "$run" "$@" > "$run.log" 2>&1 < /dev/null &
  local worker_pid=$!
  echo "$worker_pid" > "$LOCK_DIR/pid"
  ln -sfn "$run.log" "$RUNS_DIR/latest.log"
  ln -sfn "$run.result" "$RUNS_DIR/latest.result"
  touch "$run.started"
  ln -sfn "$run.started" "$RUNS_DIR/latest.started"
  tail -n +1 -f "$run.log" &
  local tail_pid=$!
  while [ ! -f "$run.result" ] && kill -0 "$worker_pid" 2>/dev/null; do
    sleep 1
  done
  sleep 1
  kill "$tail_pid" 2>/dev/null
  if [ ! -f "$run.result" ]; then
    log "the deploy process ended without a result, check the server"
    return 1
  fi
  return "$(cat "$run.result")"
}

# Always runs when the worker ends, also after a crash or a kill signal. If the
# site was stopped and is not healthy, it restores the snapshot first.
worker_exit() {
  local code="${WORKER_CODE:-1}"
  if [ -z "${WORKER_CODE:-}" ]; then
    log "the deploy stopped unexpectedly"
    if [ -n "$CURRENT_SNAPSHOT" ]; then
      restore_interrupted "$CURRENT_SNAPSHOT"
    fi
  fi
  log "final state:"
  status
  rm -rf "$LOCK_DIR"
  echo "$code" > "$RESULT_FILE"
}

# Follows the latest deploy or rollback until it ends and returns its result,
# for when the session that started it was disconnected.
wait_latest() {
  local since="${1:-0}"
  if [ ! -e "$RUNS_DIR/latest.log" ]; then
    log "no runs yet"
    return 3
  fi
  local started
  started=$(python3 -c 'import os, sys; print(int(os.path.getmtime(os.path.realpath(sys.argv[1] + ".started"))))' "$RUNS_DIR/latest" 2>/dev/null || echo 0)
  if [ "$started" -lt "$since" ]; then
    log "no deploy or rollback was started by this run"
    return 3
  fi
  tail -n +1 -f "$RUNS_DIR/latest.log" &
  local tail_pid=$!
  while [ ! -f "$RUNS_DIR/latest.result" ] && [ -d "$LOCK_DIR" ]; do
    sleep 2
  done
  sleep 1
  kill "$tail_pid" 2>/dev/null
  if [ ! -f "$RUNS_DIR/latest.result" ]; then
    log "the last run ended without a result, check the server"
    return 1
  fi
  return "$(cat "$RUNS_DIR/latest.result")"
}

worker() {
  RESULT_FILE="$1.result"
  shift
  trap '' HUP
  trap 'exit 1' INT TERM
  trap worker_exit EXIT
  local code=0
  case "$1" in
    deploy) do_deploy "$2" || code=1 ;;
    rollback) do_rollback || code=1 ;;
  esac
  WORKER_CODE="$code"
}

main() {
  # Through the restricted SSH key the command arrives in SSH_ORIGINAL_COMMAND.
  local args
  if [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
    read -r -a args <<< "$SSH_ORIGINAL_COMMAND"
  else
    args=("$@")
  fi
  case "${args[0]:-}" in
    status) status ;;
    log) cat "$RUNS_DIR/latest.log" 2>/dev/null || log "no runs yet" ;;
    recover) mkdir -p "$STATE_DIR"; recover ;;
    wait)
      if [[ -n "${args[1]:-}" && ! "${args[1]}" =~ ^[0-9]{10}$ ]]; then
        log "usage: wait [unix time]"
        return 2
      fi
      wait_latest "${args[1]:-0}"
      ;;
    rollback) launch rollback ;;
    deploy)
      if [[ ! "${args[1]:-}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        log "usage: deploy sha256:<64 hex characters>"
        return 2
      fi
      launch deploy "${args[1]}"
      ;;
    __worker)
      if [ "${EDLY_DEPLOY_WORKER:-}" != 1 ]; then
        return 2
      fi
      worker "${args[@]:1}"
      ;;
    *)
      log "usage: status | deploy sha256:<digest> | rollback | log | wait [unix time] | recover"
      return 2
      ;;
  esac
}

main "$@"
