# pz-server

A containerised [Project Zomboid](https://projectzomboid.com/) dedicated server that keeps the game process inside a **`screen`** session, so you get a real interactive server console through the container's terminal — over SSH or from a web panel such as Coolify or Portainer. RCON is available on top for remote administration.

Most container images run the server as PID 1, which means `docker exec` drops you into a fresh shell with no way to talk to the game. Running the server inside `screen` bridges that gap.

## Quick start

```bash
cp .env.example .env     # everything has a default; edit what you need
docker compose up -d
```

The first start downloads roughly 7 GB from Steam and takes ten to twenty minutes depending on bandwidth. A restart typically takes one to three minutes: a quick Steam build check (files are only re-downloaded when Steam ships a new build) followed by the game's own boot.

## Deploying with Coolify

Use a **Git-based** resource with the **Docker Compose** build pack: Coolify clones the repository, builds the image from `Dockerfile` and takes ports, volumes, memory limit and `stop_grace_period` straight from `docker-compose.yaml`. The UDP ports are published, RCON stays bound to `127.0.0.1` and the 120 s stop grace period is kept.

1. Project → **New Resource** → **Private Repository (with GitHub App)** → this repository, branch `main`.
2. **Build Pack: Docker Compose**, compose location `/docker-compose.yaml` (the default). Leave **Domains** empty.
3. **Environment Variables**: Coolify lists every `${VAR}` from the compose file with its default. Set `WHITELIST_STEAMID`, `PZ_OPEN=false`, `PZ_RCON_PASSWORD`, `MEMORY=3g` as needed; `ADMIN_PASSWORD` can stay empty.
4. Deploy. The first deployment builds the image and then downloads ~7 GB from Steam, so give it time and watch the container logs, not just the build log. If you set any `PZ_*` variable or `WHITELIST_STEAMID`, the container restarts itself once after that first boot to apply them; Coolify may show it as restarting for a minute.

Notes for Coolify:

- Coolify names the container (`pz-server-<uuid>`) and prefixes the volumes (`<uuid>_pz-data`, `<uuid>_pz-server`) itself, so `docker exec -it pz-server …` from this README becomes that container name. Inside Coolify's **Terminal** for the resource just run `console` or `rcon players`.
- Environment variables set in Coolify are the source of truth on every deploy; a value set there overrides the compose default, an empty one leaves the `.ini` key alone, exactly as described below.
- Every push to `main` triggers a rebuild and redeploy through the GitHub App webhook. The world is on the volume and survives it, but players get disconnected, so push when nobody is playing.
- The **Dockerfile** build pack works too; you then enter the ports, both volumes, the memory limit and the stop grace period (120 s, under Advanced) in Coolify's UI by hand.

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

The game keeps a list of allowed SteamIDs (`allowedsteamid` table) alongside the classic username/password accounts. With `Open=false` the server admits a connection when **any** of these holds: it is the admin account, the connecting SteamID is on the allowed list, or the username already exists. A listed SteamID joining with a new username gets an account created automatically and bound to that Steam account.

Because the SteamID comes from Steam's authentication, not from something the player types, this is the whitelist to use:

```bash
WHITELIST_STEAMID=76561198000000001 76561198000000002
PZ_OPEN=false
```

Before the game starts, the entrypoint inserts every listed id into the `allowedsteamid` table of the server database (`Zomboid/db/<SERVER_NAME>.db`), the same table the `addsteamid` console command writes to. Nothing goes through the console and the list is in force from the first second the server is up. Players then join with **any username and password they like**; nothing has to be handed out.

The database is created by the game on its first boot, so on a first boot with `WHITELIST_STEAMID` set the entrypoint restarts the server once after it comes up; the second start applies the list before launching the game.

**The variable is additive.** It never removes an id, so an entry deleted from `.env` stays allowed until you run `removesteamid "<steamid64>"` in the console or over RCON. This is deliberate: an environment variable that silently regenerated the list would wipe ids added by hand.

Two things to know:

- `PZ_OPEN=false` with an empty allowed list and no accounts admits only `admin`. The entrypoint logs a warning at start when that is the case.
- Username/password accounts are protected **only** by their password: the game does not reject a different Steam account logging into an existing username with the right credentials. Keep `WHITELIST_STEAMID` as the gate and treat account passwords as convenience.

## Mods

Steam Workshop mods are a server-side setting the game handles itself. Two `.ini` keys, both `;`-separated:

```bash
PZ_WORKSHOP_ITEMS=2875848298;2392709985   # Workshop item ids, from the item's page URL (?id=…)
PZ_MODS=ModIdOne;ModIdTwo                  # mod ids from each mod's mod.info; order is load order
```

`PZ_WORKSHOP_ITEMS` and `PZ_MODS` are declarative: the server runs exactly what they list and nothing else. Clear them and the mods are gone, including their files, because anything not listed is deleted from `steamapps/workshop/content/108600/` before the game starts and the server re-downloads only what it needs. Unlike the other `.ini` variables, these two do not need the dash to be cleared.

On start the server downloads the listed Workshop items into the install volume. A player joining is prompted by the game to subscribe to the missing mods and Steam downloads them; nothing is handed out by hand. Mod updates are picked up on the next server start; the update watcher below restarts the server for them, because the game refuses players whose Steam already has a newer version of a mod.

Pick mod versions that match the build your server runs, and mind that a mod's id can differ between builds. Map and overhaul mods raise memory use, so raise `MEMORY` (and `MEM_LIMIT`) when adding them. Mods that are not on the Workshop go into `Zomboid/mods/<name>/` on the data volume and are listed in `PZ_MODS` only.

## Updates

**Every container start checks Steam for a new build** through SteamCMD, so `docker compose restart` doubles as an update. Files are re-downloaded only when Steam ships a new build; otherwise the check is quick and the install volume is left untouched.

`STEAM_VALIDATE=true` makes SteamCMD re-hash all ~7 GB on every start. Use it to repair a corrupted install, not as a default.

`STEAM_REINSTALL=true` goes further and deletes the install before downloading it again. Steam can leave an app in a state that neither an update nor a validate clears, and the symptom reaches players as missing files or checksum kicks rather than anything obvious on the server. Trying one start with this set is worth it when the server looks current but clients disagree. Set it back to `false` afterwards, or every start re-downloads ~7 GB. The world is on the other volume and is not touched.

The update step retries (`UPDATE_ATTEMPTS`, default 3). SteamCMD routinely fails its first invocation in a fresh container because it updates itself first; without a retry the container would fall into a restart loop.

`SKIP_UPDATE=true` skips the step entirely, for example during a Steam outage.

It also turns the update watcher below off, so the pair freezes the server on whatever build it already has: nothing downloads and nothing restarts it. That is the way to stay on a known build, because a Steam branch is not a fixed version and moves whenever the game ships a patch for it.

### Choosing a build

`STEAM_BRANCH` selects which Steam branch is installed and tracked; it defaults to `public`, the current release. Set it to stay on a beta branch or to pin the server to an older build the game still publishes. List what is on offer with:

```bash
docker exec <container> /opt/steamcmd/steamcmd.sh +login anonymous +app_info_print 380870 +quit
```

Switching the branch changes the build on the next start, so the world and the mods must suit it; moving between major builds is a migration, not a setting. To see what is running now, check the version the server logs at boot:

```bash
docker exec <container> grep -m1 -aoE 'version=[0-9.]+' /home/pz/Zomboid/console-screen.log
```

### Updating while the server runs

Nothing restarts the container on its own, so a server left running keeps its build until something restarts it. That matters here: Steam updates players' clients and their Workshop mods automatically, and Project Zomboid refuses a client whose game or mod versions differ from the server's, so a stale server locks everyone out.

Every `UPDATE_CHECK_INTERVAL` seconds (hourly by default) the entrypoint looks for two things: a new build id on the Steam branch it tracks, and, when `PZ_WORKSHOP_ITEMS` is set, Workshop items newer than the installed ones (the game's own `checkModsNeedUpdate`). When either turns up, the server restarts in the least disruptive way:

- **Nobody online:** it quits right away.
- **Players online:** a message in chat every 5 minutes asks them to log out, and the server restarts within half a minute of the last one leaving.
- **Still online after `UPDATE_FORCE_SECONDS`** (default `1800`, 30 minutes): the restart is forced, with a countdown in chat every second for the last 30 seconds.

Each restart is a clean `quit`, so the world is saved; the restart policy brings the container back, the start-up update installs the new build and the game fetches the newer mods. Players are disconnected for the length of one restart, a minute or two. Set `UPDATE_FORCE_SECONDS=0` to restart immediately whoever is online.

The build check is read-only (`app_info_print`) and never touches the install, so it is safe to run alongside the game. Set `UPDATE_CHECK_INTERVAL=0` to keep updating on restart but never automatically, or `SKIP_UPDATE=true` to stop updating altogether.

## Stopping and world saves

`docker compose stop` sends `SIGTERM`. The entrypoint traps it and types `quit` into the console so the game saves the world instead of being killed mid-write, then waits up to `STOP_TIMEOUT` seconds before killing the session.

`stop_grace_period` is set to 120s in compose to leave room for that. Keep it above `STOP_TIMEOUT`.

A process that dies without that `quit` (an OOM kill, a host crash) loses whatever the game had not written yet. `PZ_SAVE_WORLD_EVERY_MINUTES` (default `15`) makes the game save the whole world on a timer, which bounds that loss.

## Backups

The game backs itself up. Each backup is a zip of the world (`Saves/Multiplayer/<SERVER_NAME>/`), the account and whitelist database (`db/`) and the config (`Server/`), written to `Zomboid/backups/`:

| Folder | Taken | Controlled by |
|---|---|---|
| `backups/period/` | every `PZ_BACKUPS_PERIOD` minutes while the server runs (default `60`) | `BackupsPeriod` |
| `backups/startup/` | on every start | `BackupsOnStart` |
| `backups/version/` | when the game version changes | `BackupsOnVersionChange` |

`backup_1.zip` is the newest. Each folder keeps `PZ_BACKUPS_COUNT` zips (the game's default is `5`) and rotates on its own, so restarts never push the hourly ones out. Every zip is about as large as the world, so budget roughly `PZ_BACKUPS_COUNT` × 3 × the size of `Saves/` on disk, and raise the count only if the disk allows.

The backups live on the `pz-data` volume, next to the world they copy. They cover a broken world or a bad mod, not a lost disk or a deleted volume. Copy `backups/` somewhere else, with your panel's volume backup, restic, rclone or similar, and copy the zips rather than the live `Saves/` folder, which the game writes to while it runs.

To restore, stop the container, move the current world aside and unpack a backup over it, as the `pz` user so the files keep their owner:

```bash
docker stop pz-server
docker run --rm -v pz-data:/home/pz/Zomboid --entrypoint bash pz-server:local -c '
  cd ~/Zomboid &&
  mv Saves/Multiplayer/pzserver "Saves/Multiplayer/pzserver.before-restore-$(date +%s)" &&
  unzip -o -q backups/period/backup_1.zip "Saves/*" "db/*"'
docker start pz-server
```

Replace `pzserver` with your `SERVER_NAME` and pick the zip you want. On Coolify the container, volume and image carry the resource's prefix; take them from `docker ps` and `docker volume ls`.

## Configuration

Copy `.env.example` to `.env` and adjust.

| Variable | Default | Purpose |
|---|---|---|
| `ADMIN_PASSWORD` | random | bootstrap `admin` account password; generated when empty, see "Admin account" above |
| `SERVER_NAME` | `pzserver` | server name and config file name |
| `MEMORY` | `3g` | JVM heap; ~3g is a sensible floor for ~6 players |
| `MEM_LIMIT` | `5g` | hard container RAM ceiling, keep above `MEMORY` |
| `GAME_PORT` | `16261` | game port (UDP) |
| `PLAYER_PORT` | `16262` | player port (UDP) |
| `WHITELIST_STEAMID` | — | space-separated SteamID64 list (`;` and `,` also accepted), see above |
| `PZ_RCON_PORT` | `27015` | RCON port (TCP), written to the `.ini` |
| `PZ_RCON_PASSWORD` | — | enables RCON when set |
| `RCON_BIND` | `127.0.0.1` | host interface the RCON port is published on |
| `STEAM_BRANCH` | `public` | Steam branch to install and track |
| `SKIP_UPDATE` | `false` | never update: no start-up update, no watcher |
| `STEAM_VALIDATE` | `false` | re-verify all files on start |
| `STEAM_REINSTALL` | `false` | emergency: delete and re-download the install |
| `UPDATE_ATTEMPTS` | `3` | SteamCMD retries |
| `UPDATE_CHECK_INTERVAL` | `3600` | seconds between game build and mod update checks while running; 0 disables |
| `UPDATE_FORCE_SECONDS` | `1800` | how long an update restart waits for players to leave before it is forced |
| `STOP_TIMEOUT` | `90` | seconds to wait for the world to save |
| `STARTUP_TIMEOUT` | `300` | seconds to wait for `SERVER STARTED` on a first boot before skipping the one-time restart |
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
| `PZ_WORKSHOP_ITEMS` | `WorkshopItems` |
| `PZ_MODS` | `Mods` |
| `PZ_BACKUPS_PERIOD` | `BackupsPeriod` |
| `PZ_BACKUPS_COUNT` | `BackupsCount` |
| `PZ_SAVE_WORLD_EVERY_MINUTES` | `SaveWorldEveryMinutes` |
| `PZ_UPNP` | `UPnP` |

**Leave a variable empty and the key is never touched**, so hand edits to the `.ini` survive restarts. **Set it and the environment wins**, overwriting manual changes on the next start. **Set it to a single dash (`-`) to write the key empty** — for these keys clearing a variable does not clear the key, so this is how you drop a server password or a public name. `PZ_MODS` and `PZ_WORKSHOP_ITEMS` are the exception and always follow the environment. Pick one source of truth per key and stick to it. Values may contain any characters; they are escaped before being written. `PZ_BACKUPS_PERIOD`, `PZ_SAVE_WORLD_EVERY_MINUTES` and `PZ_UPNP` ship with defaults in compose (`60`, `15`, `false`) because the game's own (`0`, `0`, `true`) do not suit a server in a container, so they always count as set: change the value to change the key, `0` turns a timer off. UPnP is off because a container never reaches a router to open ports on, and the search delays every start.

The game creates the `.ini` during its first boot and only reads it at startup. When any of these variables (or `WHITELIST_STEAMID`) is set on a first boot, which with those defaults is always, the entrypoint lets the game create its files, then restarts the server once (a clean `quit`, then the restart policy brings the container back) and applies everything before the second launch, so they are in effect within about a minute.

## Ports

Open **UDP 16261 and 16262** on your firewall (one rule with the range `16261-16262` on a cloud firewall). Players connect to `<host>:16261`; the game uses 16262 for the direct player connection. If only 16261 is open the game still works through the main port, but every client shows a "server port 16262 is closed" warning and connection quality may suffer. Leave the RCON port closed; use the SSH tunnel described above.

## Volumes

```
pz-data     → /home/pz/Zomboid   world, config, database, logs, saves
pz-server   → /opt/pzserver      game install (~7 GB, reproducible)
```

Both are named volumes and persist across restarts, rebuilds and `docker compose down`. Back up `pz-data`, or at least its `backups/` folder (see "Backups"). `pz-server` can be deleted at any time; the next start re-downloads it. Only `docker compose down -v` removes them.

## Architecture

The image is pinned to **`linux/amd64`** because Project Zomboid ships no ARM build. On an x86 host it builds natively; on Apple Silicon Docker builds it under emulation, which is slow.

## Notes

- Project Zomboid's memory use grows with the explored map area. Watch it and raise `MEMORY` deliberately rather than starting high.
- The container log carries the whole game console and is capped by compose at 3 files of 10 MB. The game keeps its own logs in `Zomboid/Logs/` on the data volume.
- The image has a healthcheck: the container turns healthy once the game runs in its `screen` session and has logged `SERVER STARTED`, and unhealthy if that session dies. A first start gets 30 minutes of grace for the download.
- `MEM_LIMIT` protects the rest of the host from a runaway server. It must stay above the JVM heap, or the kernel will kill the process.
- `sqlite3` is included in the image for inspecting the player database: `docker exec pz-server sqlite3 /home/pz/Zomboid/db/<SERVER_NAME>.db 'SELECT * FROM allowedsteamid;'`
