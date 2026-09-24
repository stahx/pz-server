# pz-server

A containerised [Project Zomboid](https://projectzomboid.com/) dedicated server (Build 42) that keeps the game process inside a **`screen`** session, so you get a real interactive server console through the container's terminal — over SSH or from a web panel such as Coolify or Portainer. RCON is available on top for remote administration.

Most container images run the server as PID 1, which means `docker exec` drops you into a fresh shell with no way to talk to the game. Running the server inside `screen` bridges that gap.

## Quick start

```bash
cp .env.example .env     # everything has a default; edit what you need
docker compose up -d
```

The first start downloads roughly 7 GB from Steam and takes ten to twenty minutes depending on bandwidth. A restart typically takes one to three minutes: a quick Steam build check (files are only re-downloaded when Steam ships a new build) followed by the game's own boot.

## Deploying with Coolify

Use a **Git-based** resource with the **Dockerfile** build pack. Coolify clones the repository, builds `Dockerfile` (the scripts are copied in during the build) and takes ports, volumes, limits and environment from its own settings. `docker-compose.yaml` is not used by Coolify; it stays in the repository for running the server without a panel.

1. Project → **New Resource** → **Private Repository (with GitHub App)** → this repository, branch `main`.
2. **Build Pack: Dockerfile**. Leave **Domains** empty; set **Ports Exposes** to `16261` (Coolify requires a value, it is only used for its proxy).
3. **Ports Mappings**: `16261:16261/udp, 16262:16262/udp, 127.0.0.1:27015:27015/tcp`
4. **Persistent Storage**: two volumes, mounted at `/home/pz/Zomboid` (world, config, database) and `/opt/pzserver` (game install).
5. **Advanced**: stop grace period `120` seconds, memory limit `5g`, health check disabled (the game exposes no HTTP endpoint).
6. **Environment Variables**: `WHITELIST_STEAMID`, `PZ_OPEN=false`, `PZ_RCON_PASSWORD`, `MEMORY=3g` as needed. Everything else has defaults; `ADMIN_PASSWORD` can stay empty.
7. Deploy. The first deployment builds the image and then downloads ~7 GB from Steam, so give it time and watch the container logs, not just the build log. If you set any `PZ_*` variable, the container restarts itself once after that first boot to apply the `.ini` settings; Coolify may show it as restarting for a minute.

Notes for Coolify:

- Coolify names the container itself, so `docker exec -it pz-server …` from this README becomes the Coolify container name. Inside Coolify's **Terminal** for the resource just run `console` or `rcon players`.
- Environment variables set in Coolify are the source of truth on every deploy; the `.ini` mapping rules above apply unchanged.
- After the first deploy, confirm on the host that the UDP ports are published (`ss -lun | grep 1626`) and that RCON is bound to `127.0.0.1` only.
- Every push to `main` triggers a rebuild and redeploy through the GitHub App webhook. The world is on the volume and survives it, but players get disconnected, so push when nobody is playing.

## Server console

```bash
docker exec -it pz-server console
```

Type Project Zomboid commands directly (`players`, `save`, `quit`, `addsteamid`, `adduser`, `additem`).
**Detach without stopping the server: `Ctrl+A`, then `D`.**

`console` wraps `screen -x pz-server`, a shared attach, so several admins can be in the console at the same time. From a web panel, open the container terminal and run `console`.

> The server runs as the `pz` user. If your panel opens the terminal as root (`docker exec -u root`), `screen` will not find the session — exec as the default user, or `docker exec -u pz`.

## RCON

Set `PZ_RCON_PASSWORD` in `.env` and restart. RCON then listens on `PZ_RCON_PORT` (default `27015`, TCP). All admin commands work over RCON.

From inside the container, a wrapper reads the port and password from the environment:

```bash
docker exec pz-server rcon players
docker exec pz-server rcon 'addsteamid "76561198000000000"'
```

Commands that take a quoted argument (`addsteamid`, `removesteamid`, `banid`) need the quotes to reach the game, so pass the whole command as one single-quoted string as above. Without them the server answers with the command's usage text.

The port is published on `RCON_BIND`, which defaults to `127.0.0.1`, so it is reachable only from the host. **Do not set `RCON_BIND=0.0.0.0`**: the RCON protocol sends the password in clear text and exposed RCON ports get found by scanners within hours. For remote use, tunnel over SSH and run any Source-RCON client, for example [rcon-cli](https://github.com/gorcon/rcon-cli):

```bash
ssh -L 27015:127.0.0.1:27015 user@host
rcon -a 127.0.0.1:27015 -p "$PZ_RCON_PASSWORD" players
```

## Admin account

The game insists on a bootstrap account called `admin` and asks for its password interactively on first boot, so the entrypoint always passes one. When `ADMIN_PASSWORD` is empty it generates a random 32-character password and does not log it.

You do not need that account. RCON and the console run server commands without any account, and in-game admin rights belong to whichever account you grant them to. Join once with your own Steam-bound account, then:

```
setaccesslevel "<your name>" admin
```

Roles, from the game's database: `admin`, `moderator`, `gm`, `observer`, `priority`, `user`. The bootstrap `admin` account is the one login that bypasses `Open=false` and the SteamID list, which is exactly why it should have a password nobody knows. If you ever need it, reset it from the console with `setpassword "admin" <new password>`.

## Whitelist by SteamID

Build 42 keeps a list of allowed SteamIDs (`allowedsteamid` table) alongside the classic username/password accounts. With `Open=false` the server admits a connection when **any** of these holds: it is the admin account, the connecting SteamID is on the allowed list, or the username already exists. A listed SteamID joining with a new username gets an account created automatically and bound to that Steam account.

Because the SteamID comes from Steam's authentication, not from something the player types, this is the whitelist to use:

```bash
WHITELIST_STEAMID=76561198000000001 76561198000000002
PZ_OPEN=false
```

On every start the entrypoint waits for the server to finish booting and sends `addsteamid` for each entry. Players then join with **any username and password they like**; nothing has to be handed out.

**The variable is additive.** It never removes an id, so an entry deleted from `.env` stays allowed until you run `removesteamid "<steamid64>"` in the console or over RCON. This is deliberate: an environment variable that silently regenerated the list would wipe ids added by hand.

Two things to know:

- `PZ_OPEN=false` with an empty allowed list and no accounts admits only `admin`. The entrypoint logs a warning at start when that is the case.
- Username/password accounts are protected **only** by their password: the game does not reject a different Steam account logging into an existing username with the right credentials. Keep `WHITELIST_STEAMID` as the gate and treat account passwords as convenience.

## Updates

**Every container start checks Steam for a new build** through SteamCMD, so `docker compose restart` doubles as an update. Files are re-downloaded only when Steam ships a new build; otherwise the check is quick and the install volume is left untouched.

`STEAM_VALIDATE=true` makes SteamCMD re-hash all ~7 GB on every start. Use it to repair a corrupted install, not as a default.

The update step retries (`UPDATE_ATTEMPTS`, default 3). SteamCMD routinely fails its first invocation in a fresh container because it updates itself first; without a retry the container would fall into a restart loop.

`SKIP_UPDATE=true` skips the step entirely, for example during a Steam outage.

## Stopping and world saves

`docker compose stop` sends `SIGTERM`. The entrypoint traps it and types `quit` into the console so the game saves the world instead of being killed mid-write, then waits up to `STOP_TIMEOUT` seconds before killing the session.

`stop_grace_period` is set to 120s in compose to leave room for that. Keep it above `STOP_TIMEOUT`.

## Configuration

Copy `.env.example` to `.env` and adjust.

| Variable | Default | Purpose |
|---|---|---|
| `ADMIN_PASSWORD` | random | bootstrap `admin` account password; generated when empty, see below |
| `SERVER_NAME` | `pzserver` | server name and config file name |
| `MEMORY` | `3g` | JVM heap; ~3g is a sensible floor for ~6 players |
| `MEM_LIMIT` | `5g` | hard container RAM ceiling, keep above `MEMORY` |
| `GAME_PORT` | `16261` | game port (UDP) |
| `PLAYER_PORT` | `16262` | player port (UDP) |
| `WHITELIST_STEAMID` | — | space-separated SteamID64 list (`;` and `,` also accepted), see above |
| `PZ_RCON_PORT` | `27015` | RCON port (TCP), written to the `.ini` |
| `PZ_RCON_PASSWORD` | — | enables RCON when set |
| `RCON_BIND` | `127.0.0.1` | host interface the RCON port is published on |
| `SKIP_UPDATE` | `false` | skip the Steam update on start |
| `STEAM_VALIDATE` | `false` | re-verify all files on start |
| `UPDATE_ATTEMPTS` | `3` | SteamCMD retries |
| `STOP_TIMEOUT` | `90` | seconds to wait for the world to save |
| `STARTUP_TIMEOUT` | `300` | seconds to wait for `SERVER STARTED` before skipping post-start steps |
| `TZ` | `UTC` | container time zone |

`PZ_RCON_PASSWORD` is passed as an environment variable and the admin password (set or generated) appears on the game's command line, so anyone who can `docker exec` or `docker inspect` the container can read them. That is the norm for game servers; just do not reuse real passwords.

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
| `PZ_RCON_PORT` | `RCONPort` |
| `PZ_RCON_PASSWORD` | `RCONPassword` |

**Leave a variable empty and the key is never touched**, so hand edits to the `.ini` survive restarts. **Set it and the environment wins**, overwriting manual changes on the next start. Pick one source of truth per key and stick to it. Values may contain any characters; they are escaped before being written.

The game creates the `.ini` during its first boot and only reads it at startup. When any of these variables is set on a first boot, the entrypoint waits for the file to appear, writes the values and restarts the server once (a clean `quit`, then the restart policy brings the container back), so they are in effect within about a minute. `WHITELIST_STEAMID` does not depend on the `.ini` and works from the first start.

## Ports

Open **UDP 16261 and 16262** on your firewall. Players connect to `<host>:16261`. Leave the RCON port closed; use the SSH tunnel described above.

## Volumes

```
pz-data     → /home/pz/Zomboid   world, config, database, logs, saves
pz-server   → /opt/pzserver      game install (~7 GB, reproducible)
```

Both are named volumes and persist across restarts, rebuilds and `docker compose down`. Back up `pz-data`. `pz-server` can be deleted at any time; the next start re-downloads it. Only `docker compose down -v` removes them.

## Architecture

The image is pinned to **`linux/amd64`** because Project Zomboid ships no ARM build. On an x86 host it builds natively; on Apple Silicon Docker builds it under emulation, which is slow.

## Notes

- Project Zomboid's memory use grows with the explored map area. Watch it and raise `MEMORY` deliberately rather than starting high.
- `MEM_LIMIT` protects the rest of the host from a runaway server. It must stay above the JVM heap, or the kernel will kill the process.
- `sqlite3` is included in the image for inspecting the player database: `docker exec pz-server sqlite3 /home/pz/Zomboid/db/<SERVER_NAME>.db 'SELECT * FROM allowedsteamid;'`
