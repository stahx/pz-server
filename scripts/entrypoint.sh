#!/bin/bash
set -euo pipefail

SCREEN_NAME="${SCREEN_NAME:-pz-server}"
STEAMCMD_DIR="${STEAMCMD_DIR:-/opt/steamcmd}"
SERVER_DIR="${SERVER_DIR:-/opt/pzserver}"
ZOMBOID_DIR="${ZOMBOID_DIR:-/home/pz/Zomboid}"
STEAM_APP_ID="${STEAM_APP_ID:-380870}"

SERVER_NAME="${SERVER_NAME:-pzserver}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
MEMORY="${MEMORY:-3g}"
SKIP_UPDATE="${SKIP_UPDATE:-false}"
STEAM_VALIDATE="${STEAM_VALIDATE:-false}"
UPDATE_ATTEMPTS="${UPDATE_ATTEMPTS:-3}"
STOP_TIMEOUT="${STOP_TIMEOUT:-90}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-300}"
WHITELIST="${WHITELIST:-}"

SCREEN_LOG="${ZOMBOID_DIR}/console-screen.log"
INI_FILE="${ZOMBOID_DIR}/Server/${SERVER_NAME}.ini"
DB_FILE="${ZOMBOID_DIR}/db/${SERVER_NAME}.db"

log() {
  echo "[entrypoint] $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
}

update_server() {
  if [ "$SKIP_UPDATE" = "true" ]; then
    log "SKIP_UPDATE=true, skipping update"
    return 0
  fi

  local validate_arg=""
  if [ "$STEAM_VALIDATE" = "true" ]; then
    validate_arg="validate"
    log "STEAM_VALIDATE=true, steamcmd will re-verify every file (slow)"
  fi

  local attempt=1
  while [ "$attempt" -le "$UPDATE_ATTEMPTS" ]; do
    log "updating server (app ${STEAM_APP_ID}), attempt ${attempt}/${UPDATE_ATTEMPTS}"

    # shellcheck disable=SC2086
    "${STEAMCMD_DIR}/steamcmd.sh" \
      +force_install_dir "$SERVER_DIR" \
      +login anonymous \
      +app_update "$STEAM_APP_ID" $validate_arg \
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

  log "ERROR: update failed after ${UPDATE_ATTEMPTS} attempts"
  return 1
}

apply_memory_limit() {
  local config="${SERVER_DIR}/ProjectZomboid64.json"
  [ -f "$config" ] || return 0

  log "setting JVM heap to ${MEMORY}"
  sed -i -E "s/\"-Xmx[^\"]*\"/\"-Xmx${MEMORY}\"/; s/\"-Xms[^\"]*\"/\"-Xms${MEMORY}\"/" "$config"
}

# Escapes a value for use on the right-hand side of a sed s|||-expression.
sed_escape() {
  printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

apply_ini_settings() {
  if [ ! -f "$INI_FILE" ]; then
    log "${INI_FILE} not found; it is created on first boot, settings apply from the next start"
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
    "PZ_RCON_PORT:RCONPort"
    "PZ_RCON_PASSWORD:RCONPassword"
  )

  local entry env_name ini_key value escaped
  for entry in "${mappings[@]}"; do
    env_name="${entry%%:*}"
    ini_key="${entry##*:}"
    value="${!env_name:-}"

    [ -z "$value" ] && continue

    escaped="$(sed_escape "$value")"
    if grep -q "^${ini_key}=" "$INI_FILE"; then
      sed -i "s|^${ini_key}=.*|${ini_key}=${escaped}|" "$INI_FILE"
    else
      printf '%s=%s\n' "$ini_key" "$value" >> "$INI_FILE"
    fi

    if [ "$ini_key" = "RCONPassword" ]; then
      log "ini: ${ini_key}=<set>"
    else
      log "ini: ${ini_key}=${value}"
    fi
  done
}

# With Open=false only the admin, listed SteamIDs and existing accounts can join.
# Warn when none of the latter two exist, so a closed server does not lock everyone out.
warn_if_locked_out() {
  [ "${PZ_OPEN:-}" = "false" ] || return 0
  [ -z "$WHITELIST" ] || return 0

  local allowed=0 accounts=0
  if [ -s "$DB_FILE" ]; then
    allowed="$(sqlite3 "$DB_FILE" 'SELECT COUNT(*) FROM allowedsteamid;' 2>/dev/null || echo 0)"
    accounts="$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM whitelist WHERE username <> 'admin';" 2>/dev/null || echo 0)"
  fi

  if [ "$allowed" = "0" ] && [ "$accounts" = "0" ]; then
    log "WARNING: PZ_OPEN=false with no allowed SteamIDs and no player accounts: only 'admin' can join."
    log "WARNING: set WHITELIST=<steamid64>;<steamid64> or run in the console: addsteamid \"<steamid64>\""
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
  screen -S "$SCREEN_NAME" -X logfile flush 1
}

send_console() {
  screen -S "$SCREEN_NAME" -p 0 -X stuff "$1$(printf '\r')"
}

wait_for_server_started() {
  local waited=0
  while ! grep -aq 'SERVER STARTED' "$SCREEN_LOG"; do
    if ! screen -list | grep -q "$SCREEN_NAME"; then
      log "ERROR: server exited during startup"
      return 1
    fi
    if [ "$waited" -ge "$STARTUP_TIMEOUT" ]; then
      log "WARNING: no 'SERVER STARTED' after ${STARTUP_TIMEOUT}s, skipping post-start steps"
      return 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
  log "server started after ~${waited}s"
}

# WHITELIST is additive: every listed SteamID64 is sent as `addsteamid`, nothing is ever removed.
apply_whitelist() {
  [ -n "$WHITELIST" ] || return 0

  local id sent=0 skipped=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if [[ "$id" =~ ^[0-9]{17}$ ]]; then
      send_console "addsteamid \"${id}\""
      sent=$((sent + 1))
      sleep 0.5
    else
      log "WHITELIST: skipping '${id}', expected a 17-digit SteamID64"
      skipped=$((skipped + 1))
    fi
  done < <(printf '%s\n' "$WHITELIST" | tr ';,' '\n\n' | tr -d ' \t\r')

  sleep 3
  log "WHITELIST: sent addsteamid for ${sent} id(s), skipped ${skipped}"
  grep -aoE 'SteamID [0-9]{17} .*' "$SCREEN_LOG" | tail -n "$sent" | sed 's/^/[whitelist] /' || true
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

if [ -z "$ADMIN_PASSWORD" ]; then
  log "ERROR: ADMIN_PASSWORD is empty. Set it in the environment and restart."
  sleep 30
  exit 1
fi

update_server
apply_memory_limit
apply_ini_settings
warn_if_locked_out
start_server

if wait_for_server_started; then
  apply_whitelist
fi

log "ready. Console: docker exec -it <container> console   RCON: docker exec <container> rcon players"

tail -n +1 -F "$SCREEN_LOG" &
TAIL_PID=$!

while screen -list | grep -q "$SCREEN_NAME"; do
  sleep 5 &
  wait $! || true
done

log "screen session disappeared, exiting so the restart policy can bring the container back"
kill "$TAIL_PID" 2>/dev/null || true
exit 1
