#!/bin/bash
# Send a command to the server over RCON from inside the container.
# Usage: rcon players
#        rcon 'addsteamid "76561198000000000"'   (quotes must reach the game, so wrap the whole command)
if [ -z "${PZ_RCON_PASSWORD:-}" ]; then
  echo "RCON is disabled: set PZ_RCON_PASSWORD in .env and restart the container" >&2
  exit 1
fi
exec rcon-cli -a "127.0.0.1:${PZ_RCON_PORT:-27015}" -p "$PZ_RCON_PASSWORD" "$@"
