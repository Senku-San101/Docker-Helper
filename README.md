# 🐳 Docker Command Helper (v2)

An interactive, menu-driven Bash tool for the `docker` CLI. Never google
`docker run` flags again.

## What's new in v2

- **Dashboard screens**: the terminal is cleared and redrawn on every menu, so nothing stacks up.
  The main screen shows live counts (running / stopped / images / volumes / networks) and your running containers.
- **Box tables with status dots**: containers, images, volumes, networks, stats, disk usage, history, favorites, log.
  Green = running, yellow = paused/starting, red = exited with error or unhealthy, grey = created / clean exit.
- **Grouped menus**: options are laid out in columns (View / Control / Change) instead of one long wall of text.
- **Readable commands**: long commands are shown one option per line, like a real shell script.
- **Edit an existing container** (Containers → Edit settings):
  - *Instant (no restart):* restart policy, memory limit, CPU limit, rename
  - *Needs rebuild:* ports, environment variables, volumes, edited in small tables (`a` add, `e N` edit, `d N` delete)
  - Rebuild is done safely: old container is renamed to `NAME-backup-HHMMSS`, new one is created,
    and if it fails to start the old one is **restored automatically**.

## Features carried over

- Every command is previewed and confirmed. Destructive ones default to **No**.
- Input validation (names, images, ports 1-65535, `KEY=VALUE`, volumes, CIDR/IP, memory/CPU).
- Timestamped log, smart `sudo`, saved favorites, `--dry-run`.

## Quick start

```bash
chmod +x docker-helper.sh
./docker-helper.sh              # normal
./docker-helper.sh --dry-run    # show commands, never execute
./docker-helper.sh --no-clear   # don't clear the screen between menus
```

Requires Bash 4.3+ (macOS: `brew install bash`) and the Docker CLI.
`DH_KEEP_SCROLLBACK=1` keeps terminal scrollback when clearing.

## Editing a container: what is carried over on rebuild

Image, name, restart policy, ports, env vars (only the ones you set, not image defaults), volumes/bind mounts,
network, memory, CPUs, user, workdir, entrypoint/command overrides, TTY/stdin flags.

**Not carried over** (you get a warning before applying): privileged mode, added capabilities, devices, custom DNS,
extra hosts, security options, ulimits, multiple networks, Compose-managed containers (edit the compose file instead).

## Files

| Path | Purpose |
|---|---|
| `~/.docker-helper/docker-helper.log` | Action log |
| `~/.docker-helper/saved-commands.tsv` | Favorites |

Set `DOCKER_HELPER_HOME` to change the location. License: MIT.
