#!/bin/bash
set -euo pipefail

SCREEN_NAME="${SCREEN_NAME:-pz-server}"
STEAMCMD_DIR="${STEAMCMD_DIR:-/opt/steamcmd}"
SERVER_DIR="${SERVER_DIR:-/opt/pzserver}"
ZOMBOID_DIR="${ZOMBOID_DIR:-/home/pz/Zomboid}"
STEAM_APP_ID="${STEAM_APP_ID:-380870}"

SERVER_NAME="${SERVER_NAME:-pzserver}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-changeme}"
MEMORY="${MEMORY:-3g}"
SKIP_UPDATE="${SKIP_UPDATE:-false}"
STOP_TIMEOUT="${STOP_TIMEOUT:-90}"

SCREEN_LOG="${ZOMBOID_DIR}/console-screen.log"

log() {
  echo "[entrypoint] $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
}

update_server() {
  if [ "$SKIP_UPDATE" = "true" ]; then
    log "SKIP_UPDATE=true, skipping update"
    return 0
  fi

  local attempt=1
  local max_attempts="${UPDATE_ATTEMPTS:-3}"

  while [ "$attempt" -le "$max_attempts" ]; do
    log "updating server (app ${STEAM_APP_ID}), attempt ${attempt}/${max_attempts}"

    "${STEAMCMD_DIR}/steamcmd.sh" \
      +force_install_dir "$SERVER_DIR" \
      +login anonymous \
      +app_update "$STEAM_APP_ID" validate \
      +quit || true

    # steamcmd exit codes are unreliable, so check for the actual artifact.
    if [ -x "${SERVER_DIR}/start-server.sh" ]; then
      log "update complete"
      return 0
    fi

    log "steamcmd did not produce start-server.sh, retrying in 10s"
    attempt=$((attempt + 1))
    sleep 10
  done

  log "ERROR: update failed after ${max_attempts} attempts"
  return 1
}

apply_memory_limit() {
  local config="${SERVER_DIR}/ProjectZomboid64.json"
  [ -f "$config" ] || return 0

  log "setting JVM heap to ${MEMORY}"
  sed -i -E "s/\"-Xmx[^\"]*\"/\"-Xmx${MEMORY}\"/; s/\"-Xms[^\"]*\"/\"-Xms${MEMORY}\"/" "$config"
}

apply_ini_settings() {
  local ini="${ZOMBOID_DIR}/Server/${SERVER_NAME}.ini"

  if [ ! -f "$ini" ]; then
    log "${ini} not found; it is created on first boot, settings apply from the next start"
    return 0
  fi

  # Each entry maps ENV_VAR:ini_key. An empty env var leaves the key untouched.
  local mappings=(
    "PZ_OPEN:Open"
    "PZ_PUBLIC:Public"
    "PZ_PUBLIC_NAME:PublicName"
    "PZ_SERVER_PASSWORD:Password"
    "PZ_MAX_PLAYERS:MaxPlayers"
    "PZ_PAUSE_EMPTY:PauseEmpty"
  )

  local entry env_name ini_key value
  for entry in "${mappings[@]}"; do
    env_name="${entry%%:*}"
    ini_key="${entry##*:}"
    value="${!env_name:-}"

    [ -z "$value" ] && continue

    if grep -qE "^${ini_key}=" "$ini"; then
      sed -i -E "s|^${ini_key}=.*|${ini_key}=${value}|" "$ini"
    else
      echo "${ini_key}=${value}" >> "$ini"
    fi
    log "ini: ${ini_key}=${value}"
  done
}

warn_if_whitelist_empty() {
  [ "${PZ_OPEN:-}" = "false" ] || return 0

  local db="${ZOMBOID_DIR}/db/${SERVER_NAME}.db"
  if [ ! -s "$db" ]; then
    log "WARNING: PZ_OPEN=false (whitelist mode) but no player database exists yet."
    log "WARNING: only the admin account can join. Add players from the console: adduser <name> <password>"
  fi
}

start_server() {
  mkdir -p "$ZOMBOID_DIR"
  : > "$SCREEN_LOG"

  log "starting server in screen session '${SCREEN_NAME}'"
  screen -dmS "$SCREEN_NAME" -L -Logfile "$SCREEN_LOG" \
    bash -c "cd '${SERVER_DIR}' && exec ./start-server.sh -servername '${SERVER_NAME}' -adminpassword '${ADMIN_PASSWORD}'"

  sleep 3
  if ! screen -list | grep -q "$SCREEN_NAME"; then
    log "ERROR: screen session failed to start"
    cat "$SCREEN_LOG" 2>/dev/null || true
    exit 1
  fi
}

send_console() {
  screen -S "$SCREEN_NAME" -p 0 -X stuff "$1$(printf '\r')"
}

graceful_stop() {
  log "SIGTERM received, sending 'quit' to the console so the world is saved"
  send_console "quit"

  local waited=0
  while screen -list | grep -q "$SCREEN_NAME"; do
    if [ "$waited" -ge "$STOP_TIMEOUT" ]; then
      log "timed out after ${STOP_TIMEOUT}s, killing the session"
      screen -S "$SCREEN_NAME" -X quit || true
      break
    fi
    sleep 2
    waited=$((waited + 2))
  done

  log "server stopped after ${waited}s"
  exit 0
}

trap graceful_stop SIGTERM SIGINT

update_server
apply_memory_limit
apply_ini_settings
warn_if_whitelist_empty
start_server

log "ready. Attach to the console with: docker exec -it <container> console"

tail -n +1 -F "$SCREEN_LOG" &
TAIL_PID=$!

while screen -list | grep -q "$SCREEN_NAME"; do
  sleep 5 &
  wait $! || true
done

log "screen session disappeared, exiting so the restart policy can bring the container back"
kill "$TAIL_PID" 2>/dev/null || true
exit 1
