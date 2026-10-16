# 🐳 Docker Command Helper

An interactive, menu-driven Bash tool for the `docker` CLI. Never google
`docker run` flags again.

## Features

- 🛡️ **Safe & interactive**: every command is previewed and confirmed. Destructive ones (rm, prune, `down -v`) default to **No**.
- 🧠 **Learn as you go**: each action explains what it does and shows the exact command.
- ✅ **Input validation**: image names, container names, ports (1-65535), `KEY=VALUE` env vars, volumes, CIDR/IP, memory/CPU limits.
- ⭐ **Favorites**: save any command and replay it later (`~/.docker-helper/saved-commands.tsv`).
- 📝 **Logging**: timestamped history in `~/.docker-helper/docker-helper.log`.
- 🔐 **Smart sudo**: uses `sudo` only if your user can't talk to the daemon.
- 🧪 **Dry-run mode**: `--dry-run` prints commands without running anything.
- 🎯 **Pickers**: choose containers / images / volumes / networks from numbered lists instead of typing names.

## Modules

| Module | What it covers |
|---|---|
| Containers | list, run wizard (ports, env, volumes, restart policy, limits), start/stop/restart, logs, shell, inspect, stats, cp, rename, pause, prune |
| Images | list, pull, build wizard, tag, push, search, history, save/load, rmi, prune |
| Volumes | list, create, inspect, remove, prune |
| Networks | list, create (driver/subnet/gateway), connect/disconnect, inspect, remove, prune |
| Compose | up, rebuild, down, ps, logs, build, pull, restart/stop/start, shell, config (v2 plugin or legacy `docker-compose`) |
| System | disk usage, safe/aggressive prune, login/logout, info, version, events |

## Quick start

```bash
chmod +x docker-helper.sh
./docker-helper.sh            # normal
./docker-helper.sh --dry-run  # just show commands
```

Requires: Bash 4+, Docker CLI (and the daemon running).

## Example: run nginx on port 8080

```
Containers → Run new container
Image: nginx:latest
Name: web
Detached? y     Restart policy: unless-stopped
Port: 8080:80
...
Command to run:
  docker run -d --restart unless-stopped --name web -p 8080:80 nginx:latest
Run it? (Y/n): y
```

## Files

| Path | Purpose |
|---|---|
| `~/.docker-helper/docker-helper.log` | Action log |
| `~/.docker-helper/saved-commands.tsv` | Favorites |

Set `DOCKER_HELPER_HOME` to change the location.

## License

MIT
