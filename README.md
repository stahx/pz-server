# pz-server

A containerised [Project Zomboid](https://projectzomboid.com/) dedicated server that keeps the game process inside a **`screen`** session, so you get a real interactive server console through the container's terminal — over SSH or from a web panel such as Coolify or Portainer.

Most container images run the server as PID 1, which means `docker exec` drops you into a fresh shell with no way to talk to the game. Running the server inside `screen` bridges that gap.

## Quick start

```bash
cp .env.example .env     # set ADMIN_PASSWORD; compose refuses to start without it
docker compose up -d
```

The first start downloads roughly 7 GB from Steam and takes several minutes. Later starts are quick.

## Server console

```bash
docker exec -it pz-server console
```

Type Project Zomboid commands directly (`players`, `save`, `quit`, `adduser`, `additem`).
**Detach without stopping the server: `Ctrl+A`, then `D`.**

`console` is a thin wrapper around `screen -r pz-server`. From a web panel, open the container terminal and run `console`.

> The server runs as the `pz` user. If you exec as root (`docker exec -u root`), `screen` will not find the session — use the default user.

## Updates

**Every container start updates the server** through SteamCMD (`app_update 380870 validate`), so `docker compose restart` doubles as an update.

The update step retries. SteamCMD routinely fails on its first invocation in a fresh container because it updates itself first; without a retry the container would fall into a restart loop.

Set `SKIP_UPDATE=true` to skip it, for example during a Steam outage.

## Stopping and world saves

`docker compose stop` sends `SIGTERM`. The entrypoint traps it and types `quit` into the console so the game saves the world instead of being killed mid-write, then waits up to `STOP_TIMEOUT` seconds.

`stop_grace_period` is set to 120s in compose to leave room for that. Keep it above `STOP_TIMEOUT`.

## Configuration

Copy `.env.example` to `.env` and adjust.

| Variable | Default | Purpose |
|---|---|---|
| `ADMIN_PASSWORD` | — | **required**, admin account password |
| `SERVER_NAME` | `pzserver` | server name and config file name |
| `MEMORY` | `3g` | JVM heap; 3g comfortably handles ~6 players |
| `MEM_LIMIT` | `5g` | hard container RAM ceiling, keep above `MEMORY` |
| `GAME_PORT` | `16261` | game port (UDP) |
| `PLAYER_PORT` | `16262` | player port (UDP) |
| `SKIP_UPDATE` | `false` | skip the Steam update on start |
| `STOP_TIMEOUT` | `90` | seconds to wait for the world to save |

### Server `.ini` settings

These map onto keys in `Zomboid/Server/<SERVER_NAME>.ini` and are applied on **every** start:

| Variable | `.ini` key |
|---|---|
| `PZ_OPEN` | `Open` |
| `PZ_PUBLIC` | `Public` |
| `PZ_PUBLIC_NAME` | `PublicName` |
| `PZ_SERVER_PASSWORD` | `Password` |
| `PZ_MAX_PLAYERS` | `MaxPlayers` |
| `PZ_PAUSE_EMPTY` | `PauseEmpty` |

**Leave a variable empty and the key is never touched**, so hand edits to the `.ini` survive restarts. **Set it and the environment wins**, overwriting manual changes on the next start. Pick one source of truth per key and stick to it.

The `.ini` is created during the first boot, so values apply from the second start onwards.

## Whitelist

Project Zomboid stores accounts in a SQLite database (`Zomboid/db/<SERVER_NAME>.db`), not a flat file, and they survive restarts and updates.

1. Start the server and add accounts from the console: `adduser <name> <password>`
2. Set `PZ_OPEN=false` and restart

Order matters: closing the server before any account exists leaves nobody able to join. The entrypoint logs a warning when `PZ_OPEN=false` while the player database is still empty. The admin account always exists, so you keep a way in.

## Ports

Open **UDP 16261 and 16262** on your firewall. Players connect to `<host>:16261`.

## Volumes

```
pz-data     → /home/pz/Zomboid   world, config, logs, saves
pz-server   → /opt/pzserver      game install (~7 GB, reproducible)
```

Back up `pz-data`. `pz-server` can be deleted at any time; the next start re-downloads it.

## Architecture

The image is pinned to **`linux/amd64`** because Project Zomboid ships no ARM build. On Apple Silicon it builds under emulation (slowly); on an x86 host it builds natively.

## Notes

- Project Zomboid's memory use grows with the explored map area. Watch it and raise `MEMORY` deliberately rather than starting high.
- `MEM_LIMIT` protects the rest of the host from a runaway server. It must stay above the JVM heap, or the kernel will kill the process.
