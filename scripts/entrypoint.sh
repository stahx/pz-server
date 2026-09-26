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
UPDATE_CHECK_INTERVAL="${UPDATE_CHECK_INTERVAL:-0}"
UPDATE_ANNOUNCE_SECONDS="${UPDATE_ANNOUNCE_SECONDS:-60}"
WHITELIST_STEAMID="${WHITELIST_STEAMID:-}"

SCREEN_LOG="${ZOMBOID_DIR}/console-screen.log"
INI_FILE="${ZOMBOID_DIR}/Server/${SERVER_NAME}.ini"
DB_FILE="${ZOMBOID_DIR}/db/${SERVER_NAME}.db"

# Each entry maps ENV_VAR:ini_key. An empty env var leaves the key untouched.
INI_MAPPINGS=(
  "PZ_OPEN:Open"
  "PZ_PUBLIC:Public"
  "PZ_PUBLIC_NAME:PublicName"
  "PZ_SERVER_PASSWORD:Password"
  "PZ_MAX_PLAYERS:MaxPlayers"
  "PZ_PAUSE_EMPTY:PauseEmpty"
  "PZ_RCON_PORT:RCONPort"
  "PZ_RCON_PASSWORD:RCONPassword"
  "PZ_WORKSHOP_ITEMS:WorkshopItems"
  "PZ_MODS:Mods"
)

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

installed_buildid() {
  awk -F'"' '/"buildid"/ {print $4; exit}' \
    "${SERVER_DIR}/steamapps/appmanifest_${STEAM_APP_ID}.acf" 2>/dev/null
}

# Build id of the public branch on Steam; read-only, does not touch the install.
latest_buildid() {
  "${STEAMCMD_DIR}/steamcmd.sh" \
    +login anonymous \
    +app_info_update 1 \
    +app_info_print "$STEAM_APP_ID" \
    +quit 2>/dev/null \
    | tr -d '\r' \
    | awk '/"public"/ {found=1} found && /"buildid"/ {gsub(/"/, "", $2); print $2; exit}'
}

# Polls Steam and, when a new build appears, asks the game to quit. The main loop
# then exits, the restart policy brings the container back and the start-up update
# installs the new build.
update_watcher() {
  local installed latest
  while true; do
    sleep "$UPDATE_CHECK_INTERVAL"
    screen_alive || return 0

    installed="$(installed_buildid)"
    latest="$(latest_buildid)"
    [ -n "$installed" ] && [ -n "$latest" ] || continue
    [ "$installed" != "$latest" ] || continue

    log "update available: build ${installed} -> ${latest}"
    if [ "$UPDATE_ANNOUNCE_SECONDS" -gt 0 ]; then
      send_console "servermsg \"Server update available, restarting in ${UPDATE_ANNOUNCE_SECONDS} seconds\""
      sleep "$UPDATE_ANNOUNCE_SECONDS"
      screen_alive || return 0
    fi

    log "restarting to install build ${latest}"
    send_console "quit"
    return 0
  done
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

has_ini_overrides() {
  local entry env_name
  for entry in "${INI_MAPPINGS[@]}"; do
    env_name="${entry%%:*}"
    [ -n "${!env_name:-}" ] && return 0
  done
  return 1
}

apply_ini_settings() {
  [ -f "$INI_FILE" ] || return 0

  local entry env_name ini_key value escaped
  for entry in "${INI_MAPPINGS[@]}"; do
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

    if [ "$ini_key" = "RCONPassword" ] || [ "$ini_key" = "Password" ]; then
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
  [ -z "$WHITELIST_STEAMID" ] || return 0

  local allowed=0 accounts=0
  if [ -s "$DB_FILE" ]; then
    allowed="$(sqlite3 "$DB_FILE" 'SELECT COUNT(*) FROM allowedsteamid;' 2>/dev/null || echo 0)"
    accounts="$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM whitelist WHERE username <> 'admin';" 2>/dev/null || echo 0)"
  fi

  if [ "$allowed" = "0" ] && [ "$accounts" = "0" ]; then
    log "WARNING: PZ_OPEN=false with no allowed SteamIDs and no player accounts: only 'admin' can join."
    log "WARNING: set WHITELIST_STEAMID=\"<steamid64> <steamid64>\" or run in the console: addsteamid \"<steamid64>\""
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

screen_alive() {
  screen -list | grep -q "$SCREEN_NAME"
}

wait_for_server_started() {
  local waited=0
  while ! grep -aq 'SERVER STARTED' "$SCREEN_LOG"; do
    if ! screen_alive; then
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

# WHITELIST_STEAMID is additive: every listed SteamID64 is inserted into the game's
# allowedsteamid table before the server starts; nothing is ever removed.
# Ids may be separated by spaces, semicolons or commas.
apply_whitelist() {
  [ -n "$WHITELIST_STEAMID" ] || return 0
  [ -s "$DB_FILE" ] || return 0

  if [ "$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='allowedsteamid';")" != "1" ]; then
    log "WARNING: table allowedsteamid missing in ${DB_FILE}, whitelist not applied"
    return 0
  fi

  local id added=0 present=0 skipped=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if [[ "$id" =~ ^[0-9]{17}$ ]]; then
      if [ "$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM allowedsteamid WHERE steamid='${id}';")" = "0" ]; then
        sqlite3 "$DB_FILE" "INSERT INTO allowedsteamid (steamid) VALUES ('${id}');"
        added=$((added + 1))
      else
        present=$((present + 1))
      fi
    else
      log "WHITELIST_STEAMID: skipping '${id}', expected a 17-digit SteamID64"
      skipped=$((skipped + 1))
    fi
  done < <(printf '%s\n' "$WHITELIST_STEAMID" | tr ';, \t' '\n\n\n\n' | tr -d '\r')

  log "WHITELIST_STEAMID: ${added} added, ${present} already present, ${skipped} skipped"
}

# Sends `quit` so the game saves the world, then waits up to STOP_TIMEOUT for it to exit.
stop_server() {
  send_console "quit"

  local waited=0
  while screen_alive; do
    if [ "$waited" -ge "$STOP_TIMEOUT" ]; then
      log "timed out after ${STOP_TIMEOUT}s, killing the session"
      screen -S "$SCREEN_NAME" -X quit || true
      break
    fi
    sleep 2
    waited=$((waited + 2))
  done

  log "server stopped after ${waited}s"
}

graceful_stop() {
  log "SIGTERM received, sending 'quit' to the console so the world is saved"
  kill "${WATCHER_PID:-}" 2>/dev/null || true
  stop_server
  exit 0
}

trap graceful_stop SIGTERM SIGINT

# The game insists on a bootstrap 'admin' account. Nobody needs to log in with it:
# grant admin to your own Steam-bound account instead (setaccesslevel "<name>" admin).
if [ -z "$ADMIN_PASSWORD" ]; then
  ADMIN_PASSWORD="$(head -c 512 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-32)"
  log "ADMIN_PASSWORD not set: generated a random one for the bootstrap admin account (not logged)"
fi

update_server
apply_memory_limit

FIRST_BOOT=false
if [ -f "$INI_FILE" ]; then
  apply_ini_settings
  apply_whitelist
else
  FIRST_BOOT=true
  log "${INI_FILE} not found: first boot, the game will create its config and database"
fi

warn_if_locked_out
start_server

# The game creates the .ini and the database during its first boot and only reads
# them at startup, so after a first boot the server is restarted once; the second
# start then applies the .ini settings and the whitelist before launching the game.
if wait_for_server_started && [ "$FIRST_BOOT" = true ]; then
  if has_ini_overrides || [ -n "$WHITELIST_STEAMID" ]; then
    log "first boot: restarting once so the .ini settings and the whitelist take effect"
    stop_server
    log "exiting for the restart policy to bring the container back"
    exit 0
  fi
fi

log "ready. Console: docker exec -it <container> console   RCON: docker exec <container> rcon players"

WATCHER_PID=""
if [ "$UPDATE_CHECK_INTERVAL" -gt 0 ]; then
  update_watcher &
  WATCHER_PID=$!
  log "update watcher: checking Steam every ${UPDATE_CHECK_INTERVAL}s"
fi

tail -n +1 -F "$SCREEN_LOG" &
TAIL_PID=$!

while screen_alive; do
  sleep 5 &
  wait $! || true
done

log "screen session disappeared, exiting so the restart policy can bring the container back"
kill "$TAIL_PID" "$WATCHER_PID" 2>/dev/null || true
exit 1
