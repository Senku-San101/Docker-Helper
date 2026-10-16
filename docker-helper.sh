#!/usr/bin/env bash
# ============================================================================
#  Docker Command Helper - interactive, menu-driven wrapper around `docker`
#
#  * Every command is previewed and confirmed before it runs
#  * Input is validated (names, images, ports, env vars, volumes, CIDR ...)
#  * Everything is logged with timestamps
#  * Smart sudo handling (only used when really needed)
#  * Favorite commands can be saved and replayed later
#  * --dry-run mode prints commands without executing them
# ============================================================================

VERSION="1.0.0"
APP_DIR="${DOCKER_HELPER_HOME:-$HOME/.docker-helper}"
LOG_FILE="$APP_DIR/docker-helper.log"
SAVED_FILE="$APP_DIR/saved-commands.tsv"
DRY_RUN=0
NO_SAVE_PROMPT=0
NOTE=""
SUDO=()
COMPOSE=()
COMPOSE_FILE_ARG=()
PICKED=""
LIST=()

mkdir -p "$APP_DIR" 2>/dev/null || { APP_DIR="/tmp/.docker-helper-$USER"; mkdir -p "$APP_DIR"; LOG_FILE="$APP_DIR/docker-helper.log"; SAVED_FILE="$APP_DIR/saved-commands.tsv"; }
touch "$SAVED_FILE" 2>/dev/null

# ---------------------------------------------------------------- colours ---
if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'
  C_CYAN=$'\e[36m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'; C_RST=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYAN=""; C_BOLD=""; C_DIM=""; C_RST=""
fi

# ---------------------------------------------------------------- output ----
log()  { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >> "$LOG_FILE" 2>/dev/null; }
info() { printf '%s%s%s\n' "$C_BLU" "$*" "$C_RST"; }
ok()   { printf '%s✔ %s%s\n' "$C_GRN" "$*" "$C_RST"; }
warn() { printf '%s⚠ %s%s\n' "$C_YEL" "$*" "$C_RST"; }
err()  { printf '%s✖ %s%s\n' "$C_RED" "$*" "$C_RST" >&2; }
hr()   { printf '%s%s%s\n' "$C_DIM" "------------------------------------------------------------" "$C_RST"; }
header() { echo; hr; printf '%s%s%s\n' "$C_BOLD" "$1" "$C_RST"; hr; }

# ---------------------------------------------------------------- input -----
confirm() { # confirm "prompt" [y|n default]
  local def=${2:-n} hint ans
  [[ $def == y ]] && hint="Y/n" || hint="y/N"
  read -r -p "$1 ($hint): " ans || { echo; exit 0; }
  ans=${ans:-$def}
  [[ $ans =~ ^[Yy]([Ee][Ss])?$ ]]
}

ask() { # ask VAR "prompt" [default]
  local __v=$1 __p=$2 __d=${3:-} __a
  if [[ -n $__d ]]; then
    read -r -p "$__p [$__d]: " __a || { echo; exit 0; }
    __a=${__a:-$__d}
  else
    read -r -p "$__p: " __a || { echo; exit 0; }
  fi
  printf -v "$__v" '%s' "$__a"
}

# ask_valid VAR "prompt" REGEX "error message" [required=1] [default]
ask_valid() {
  local _var=$1 _prm=$2 _rx=$3 _emsg=$4 _rxq=${5:-1} _def=${6:-} _ans
  while true; do
    ask _ans "$_prm" "$_def"
    if [[ -z $_ans ]]; then
      if (( _rxq )); then warn "This value is required."; continue; fi
      printf -v "$_var" ''; return 0
    fi
    if [[ $_ans =~ $_rx ]]; then printf -v "$_var" '%s' "$_ans"; return 0; fi
    warn "$_emsg"
  done
}

pause() { read -r -p "Press Enter to continue..." _ || true; }

# ------------------------------------------------------------ validation ----
RE_NAME='^[a-zA-Z0-9][a-zA-Z0-9_.-]*$'
RE_IMAGE='^[a-zA-Z0-9][a-zA-Z0-9._/:@-]*$'
RE_PORT='^([0-9]{1,3}(\.[0-9]{1,3}){3}:)?[0-9]{1,5}(-[0-9]{1,5})?:[0-9]{1,5}(-[0-9]{1,5})?(/(tcp|udp|sctp))?$'
RE_ENV='^[A-Za-z_][A-Za-z0-9_]*=.*$'
RE_VOL='^[^:[:space:]]+:/[^:]*(:(ro|rw|z|Z))?$'
RE_INT='^[0-9]+$'
RE_MEM='^[0-9]+[bkmgBKMG]?$'
RE_CPUS='^[0-9]+(\.[0-9]+)?$'
RE_CIDR='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'
RE_IP='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
RE_PATH='^[^[:space:]].*$'

valid_port() {
  local s=$1 n
  [[ $s =~ $RE_PORT ]] || return 1
  s=${s%%/*}
  [[ $s =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+: ]] && s=${s#*:}
  for n in ${s//[:-]/ }; do (( 10#$n >= 1 && 10#$n <= 65535 )) || return 1; done
  return 0
}
valid_env() { [[ $1 =~ $RE_ENV ]]; }
valid_vol() { [[ $1 =~ $RE_VOL ]]; }

collect_list() { # collect_list "prompt" validator_fn "error"
  LIST=(); local v
  while true; do
    read -r -p "$1 (blank to finish): " v || { echo; exit 0; }
    [[ -z $v ]] && break
    if "$2" "$v"; then LIST+=("$v"); else warn "$3"; fi
  done
}

# ---------------------------------------------------------------- picker ----
# pick_from_docker "Title" <docker args producing "value|label" lines>
# Sets PICKED. Returns 1 when cancelled.
pick_from_docker() {
  local title=$1; shift
  local -a vals=() labs=()
  local line i choice
  if (( ! DRY_RUN )); then
    while IFS= read -r line; do
      [[ -z $line ]] && continue
      vals+=("${line%%|*}"); labs+=("${line#*|}")
    done < <("${SUDO[@]}" docker "$@" 2>/dev/null)
  fi
  echo
  if (( ${#vals[@]} == 0 )); then
    warn "No $title found automatically."
    ask choice "Type a name/ID manually (blank = cancel)"
    [[ -z $choice ]] && return 1
    PICKED=$choice; return 0
  fi
  info "Select $title:"
  for i in "${!vals[@]}"; do printf '  %s%2d)%s %s\n' "$C_CYAN" "$((i+1))" "$C_RST" "${labs[$i]}"; done
  printf '  %s 0)%s Cancel\n' "$C_CYAN" "$C_RST"
  while true; do
    ask choice "Number (or type a name/ID)"
    [[ -z $choice || $choice == 0 ]] && return 1
    if [[ $choice =~ ^[0-9]+$ ]]; then
      if (( choice >= 1 && choice <= ${#vals[@]} )); then PICKED=${vals[choice-1]}; return 0; fi
      warn "Out of range."; continue
    fi
    PICKED=$choice; return 0
  done
}

pick_container() { # [all|running]
  local -a args=(ps --format '{{.Names}}|{{.Names}}  ({{.Image}} — {{.Status}})')
  [[ ${1:-all} == all ]] && args=(ps -a --format '{{.Names}}|{{.Names}}  ({{.Image}} — {{.Status}})')
  pick_from_docker "container" "${args[@]}"
}
pick_image() {
  pick_from_docker "image" images --format '{{if eq .Tag "<none>"}}{{.ID}}{{else}}{{.Repository}}:{{.Tag}}{{end}}|{{.Repository}}:{{.Tag}}  ({{.Size}}, {{.CreatedSince}})'
}
pick_volume()  { pick_from_docker "volume"  volume ls --format '{{.Name}}|{{.Name}}  ({{.Driver}})'; }
pick_network() { pick_from_docker "network" network ls --format '{{.Name}}|{{.Name}}  ({{.Driver}}, {{.Scope}})'; }

# --------------------------------------------------------------- executor ---
# run_cmd [--danger] docker ...   -> preview, confirm, run, log, offer to save
run_cmd() {
  local danger=0
  if [[ $1 == --danger ]]; then danger=1; shift; fi
  local -a cmd=("$@")
  local pv full rc
  printf -v pv '%q ' "${cmd[@]}"; pv=${pv% }
  full="${SUDO[*]:+${SUDO[*]} }$pv"

  echo
  [[ -n $NOTE ]] && printf '%sWhat it does:%s %s\n' "$C_DIM" "$C_RST" "$NOTE"
  NOTE=""
  printf '%sCommand to run:%s\n  %s%s%s\n' "$C_BOLD" "$C_RST" "$C_CYAN" "$full" "$C_RST"

  if (( DRY_RUN )); then
    warn "[dry-run] not executed."; log DRYRUN "$pv"; return 0
  fi
  if (( danger )); then
    confirm "${C_RED}This is destructive.${C_RST} Proceed?" n || { info "Cancelled."; log CANCEL "$pv"; return 1; }
  else
    confirm "Run it?" y || { info "Cancelled."; log CANCEL "$pv"; return 1; }
  fi

  log RUN "$full"
  trap ':' INT                        # Ctrl+C stops the command, not the helper
  "${SUDO[@]}" "${cmd[@]}"
  rc=$?
  trap 'echo; info "Bye."; exit 0' INT

  if   (( rc == 0 ));   then ok "Done.";                       log OK   "$pv"
  elif (( rc == 130 )); then warn "Interrupted.";              log INT  "$pv"
  else                       err "Exited with code $rc";       log FAIL "($rc) $pv"; fi

  (( rc == 0 && danger == 0 && NO_SAVE_PROMPT == 0 )) && maybe_save "$pv"
  return $rc
}

# run_view docker ... -> read-only: show the command, run it, no confirmation
run_view() {
  local -a cmd=("$@")
  local pv; printf -v pv '%q ' "${cmd[@]}"; pv=${pv% }
  echo
  [[ -n $NOTE ]] && printf '%sWhat it does:%s %s\n' "$C_DIM" "$C_RST" "$NOTE"
  NOTE=""
  printf '%s$ %s%s%s\n' "$C_CYAN" "${SUDO[*]:+${SUDO[*]} }" "$pv" "$C_RST"
  if (( DRY_RUN )); then warn "[dry-run] not executed."; return 0; fi
  log VIEW "$pv"
  trap ':' INT
  "${SUDO[@]}" "${cmd[@]}"
  trap 'echo; info "Bye."; exit 0' INT
  return 0
}

maybe_save() {
  confirm "Save this to your favorites?" n || return 0
  local label; ask label "Short label"
  [[ -z $label ]] && label=$1
  label=${label//$'\t'/ }
  printf '%s\t%s\n' "$label" "$1" >> "$SAVED_FILE"
  ok "Saved to $SAVED_FILE"
}

# -------------------------------------------------------------- setup -------
setup_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    if (( DRY_RUN )); then warn "docker not found (continuing, dry-run)."; return 0; fi
    err "Docker CLI not found. Install it first: https://docs.docker.com/engine/install/"
    exit 1
  fi
  (( DRY_RUN )) && return 0
  if docker info >/dev/null 2>&1; then
    SUDO=()
  elif [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    SUDO=(sudo); warn "Using sudo for docker (add yourself to the 'docker' group to avoid this)."
  else
    err "Cannot reach the Docker daemon. Is it running? (try: sudo systemctl start docker)"
    exit 1
  fi
}

detect_compose() {
  COMPOSE=()
  if "${SUDO[@]}" docker compose version >/dev/null 2>&1; then COMPOSE=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then COMPOSE=(docker-compose)
  elif (( DRY_RUN )); then COMPOSE=(docker compose)
  fi
}

# ============================================================== CONTAINERS ==
container_run_wizard() {
  header "Run a new container"
  local image name detached="" rm_flag="" restart="no" net mem cpus cmdline
  ask_valid image "Image (e.g. nginx:latest)" "$RE_IMAGE" "Invalid image reference."
  ask_valid name  "Container name (optional)" "$RE_NAME" "Use letters, digits, _ . -" 0

  local -a cmd=(docker run)
  if confirm "Run in background (detached)?" y; then detached=1; cmd+=(-d); else cmd+=(-it); fi
  if (( detached )); then
    echo "Restart policy:  1) no   2) always   3) unless-stopped   4) on-failure"
    local r; ask r "Choose" 1
    case $r in 2) restart=always;; 3) restart=unless-stopped;; 4) restart=on-failure;; *) restart=no;; esac
    [[ $restart != no ]] && cmd+=(--restart "$restart")
  else
    confirm "Remove the container when it exits (--rm)?" y && cmd+=(--rm)
  fi
  [[ -n $name ]] && cmd+=(--name "$name")

  collect_list "Port mapping HOST:CONTAINER (e.g. 8080:80)" valid_port "Format: [ip:]host:container[/tcp|udp], ports 1-65535"
  local p; for p in "${LIST[@]}"; do cmd+=(-p "$p"); done
  collect_list "Environment variable KEY=VALUE" valid_env "Format must be KEY=VALUE"
  for p in "${LIST[@]}"; do cmd+=(-e "$p"); done
  collect_list "Volume SRC:/container/path[:ro]" valid_vol "Format: /host/dir:/path or volname:/path[:ro]"
  for p in "${LIST[@]}"; do
    # Docker wants absolute host paths: expand ./dir, ../dir and ~/dir
    case $p in
      ./*|../*) p="$PWD/${p}";;
      "~/"*)    p="$HOME/${p#\~/}";;
    esac
    cmd+=(-v "$p")
  done

  if confirm "Attach to a specific network?" n; then
    pick_network && cmd+=(--network "$PICKED")
  fi
  ask_valid mem  "Memory limit (e.g. 512m, 2g; blank = none)" "$RE_MEM" "Use a number with optional b/k/m/g." 0
  [[ -n $mem ]] && cmd+=(--memory "$mem")
  ask_valid cpus "CPU limit (e.g. 1.5; blank = none)" "$RE_CPUS" "Use a number like 2 or 1.5." 0
  [[ -n $cpus ]] && cmd+=(--cpus "$cpus")

  cmd+=("$image")
  ask cmdline "Override command/args (blank = image default)"
  if [[ -n $cmdline ]]; then local -a extra; read -r -a extra <<<"$cmdline"; cmd+=("${extra[@]}"); fi

  NOTE="Creates and starts a new container from '$image' with the options you chose."
  run_cmd "${cmd[@]}"
}

container_logs() {
  pick_container all || return
  local c=$PICKED tail follow=""
  ask_valid tail "Number of lines (or 'all')" '^([0-9]+|all)$' "Enter a number or 'all'." 1 100
  local -a cmd=(docker logs --tail "$tail")
  confirm "Add timestamps?" n && cmd+=(-t)
  confirm "Follow live output (Ctrl+C to stop)?" n && cmd+=(-f)
  cmd+=("$c")
  NOTE="Prints the output (stdout/stderr) produced by the container."
  run_view "${cmd[@]}"
}

container_shell() {
  pick_container running || return
  local c=$PICKED
  echo "  1) Auto shell (bash, falls back to sh)   2) sh   3) Custom command"
  local m; ask m "Choose" 1
  case $m in
    2) NOTE="Opens an interactive sh session inside the container."
       run_cmd docker exec -it "$c" sh;;
    3) local line; ask line "Command to run inside '$c'"
       [[ -z $line ]] && return
       local -a extra; read -r -a extra <<<"$line"
       local -a cmd=(docker exec)
       confirm "Interactive (-it)?" n && cmd+=(-it)
       NOTE="Runs a one-off command inside the running container."
       run_cmd "${cmd[@]}" "$c" "${extra[@]}";;
    *) NOTE="Opens an interactive shell inside the container (bash if present, else sh)."
       run_cmd docker exec -it "$c" sh -c 'command -v bash >/dev/null 2>&1 && exec bash || exec sh';;
  esac
}

container_inspect() {
  pick_container all || return
  local c=$PICKED
  echo "  1) Full JSON   2) IP address(es)   3) Environment   4) Mounts   5) State/health   6) Port mappings"
  local m; ask m "Choose" 2
  NOTE="Reads low-level details about the container (read-only)."
  case $m in
    1) run_view docker inspect "$c";;
    3) run_view docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c";;
    4) run_view docker inspect -f '{{range .Mounts}}{{.Type}}  {{.Source}} -> {{.Destination}}{{println}}{{end}}' "$c";;
    5) run_view docker inspect -f '{{json .State}}' "$c";;
    6) run_view docker port "$c";;
    *) run_view docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$c";;
  esac
}

container_copy() {
  echo "  1) Host -> container   2) Container -> host"
  local d src dst; ask d "Choose" 1
  pick_container all || return
  local c=$PICKED
  if [[ $d == 2 ]]; then
    ask_valid src "Path inside container" "$RE_PATH" "Path required."
    ask_valid dst "Destination on host" "$RE_PATH" "Path required." 1 "."
    NOTE="Copies files out of the container onto your machine."
    run_cmd docker cp "$c:$src" "$dst"
  else
    ask_valid src "Path on host" "$RE_PATH" "Path required."
    ask_valid dst "Destination inside container" "$RE_PATH" "Path required." 1 "/"
    NOTE="Copies files from your machine into the container."
    run_cmd docker cp "$src" "$c:$dst"
  fi
}

containers_menu() {
  local c
  while true; do
    header "Containers"
    cat <<'EOF'
   1) List running            9) Shell / exec into container
   2) List all (incl. stopped) 10) Inspect (IP, env, mounts, ...)
   3) Run new container (wizard) 11) Live resource usage (stats)
   4) Start                   12) Copy files (docker cp)
   5) Stop                    13) Rename
   6) Restart                 14) Pause / Unpause
   7) Remove                  15) Prune stopped containers
   8) Logs                     0) Back
EOF
    read -r -p "Choose: " c || { echo; exit 0; }
    case $c in
      1) NOTE="Shows containers that are currently running."; run_view docker ps;;
      2) NOTE="Shows every container, running or not."; run_view docker ps -a;;
      3) container_run_wizard;;
      4) pick_container all     && { NOTE="Starts a stopped container."; run_cmd docker start "$PICKED"; };;
      5) pick_container running && {
           local t; ask_valid t "Grace period in seconds" "$RE_INT" "Enter a number." 1 10
           NOTE="Sends SIGTERM, then SIGKILL after the grace period."; run_cmd docker stop -t "$t" "$PICKED"; };;
      6) pick_container all     && { NOTE="Stops and starts the container again."; run_cmd docker restart "$PICKED"; };;
      7) pick_container all     && {
           local -a cmd=(docker rm); local rname=$PICKED
           confirm "Force remove even if running (-f)?" n && cmd+=(-f)
           confirm "Also delete its anonymous volumes (-v)?" n && cmd+=(-v)
           NOTE="Deletes the container (not the image)."; run_cmd --danger "${cmd[@]}" "$rname"; };;
      8) container_logs;;
      9) container_shell;;
      10) container_inspect;;
      11) NOTE="One-time snapshot of CPU / memory / network usage."; run_view docker stats --no-stream;;
      12) container_copy;;
      13) pick_container all && {
            local old=$PICKED new
            ask_valid new "New name" "$RE_NAME" "Use letters, digits, _ . -"
            NOTE="Renames the container."; run_cmd docker rename "$old" "$new"; };;
      14) pick_container running >/dev/null 2>&1 || true
          echo "  1) Pause   2) Unpause"; local pm; ask pm "Choose" 1
          if [[ $pm == 2 ]]; then pick_container all && { NOTE="Resumes a paused container."; run_cmd docker unpause "$PICKED"; }
          else pick_container running && { NOTE="Freezes all processes in the container."; run_cmd docker pause "$PICKED"; }; fi;;
      15) NOTE="Removes ALL stopped containers."; run_cmd --danger docker container prune;;
      0|"") return;;
      *) warn "Invalid choice.";;
    esac
  done
}

# ================================================================== IMAGES ==
image_build() {
  header "Build an image"
  local ctx tag file
  ask_valid ctx "Build context directory" "$RE_PATH" "Path required." 1 "."
  ask_valid tag "Image name:tag (e.g. myapp:1.0)" "$RE_IMAGE" "Invalid image reference."
  ask file "Dockerfile path (blank = <context>/Dockerfile)"
  local -a cmd=(docker build -t "$tag")
  [[ -n $file ]] && cmd+=(-f "$file")
  confirm "Disable cache (--no-cache)?" n && cmd+=(--no-cache)
  confirm "Always pull newer base images (--pull)?" n && cmd+=(--pull)
  collect_list "Build arg KEY=VALUE" valid_env "Format must be KEY=VALUE"
  local a; for a in "${LIST[@]}"; do cmd+=(--build-arg "$a"); done
  cmd+=("$ctx")
  NOTE="Builds an image from the Dockerfile found in the build context."
  run_cmd "${cmd[@]}"
}

images_menu() {
  local c
  while true; do
    header "Images"
    cat <<'EOF'
   1) List images             7) Show layer history
   2) Pull an image           8) Save image to .tar file
   3) Build an image          9) Load image from .tar file
   4) Tag an image           10) Remove an image
   5) Push an image          11) Prune dangling images
   6) Search Docker Hub      12) Prune ALL unused images
                              0) Back
EOF
    read -r -p "Choose: " c || { echo; exit 0; }
    case $c in
      1) NOTE="Lists images stored locally."; run_view docker images;;
      2) local img; ask_valid img "Image to pull (e.g. ubuntu:24.04)" "$RE_IMAGE" "Invalid image reference."
         NOTE="Downloads the image from a registry."; run_cmd docker pull "$img";;
      3) image_build;;
      4) pick_image && { local src=$PICKED dst
           ask_valid dst "New name:tag" "$RE_IMAGE" "Invalid image reference."
           NOTE="Adds an additional name/tag to the same image."; run_cmd docker tag "$src" "$dst"; };;
      5) pick_image && { NOTE="Uploads the image to its registry (you must be logged in)."; run_cmd docker push "$PICKED"; };;
      6) local term; ask term "Search term"; [[ -n $term ]] && { NOTE="Searches Docker Hub."; run_view docker search --limit 15 "$term"; };;
      7) pick_image && { NOTE="Shows how the image was built, layer by layer."; run_view docker history "$PICKED"; };;
      8) pick_image && { local f; ask_valid f "Output file" "$RE_PATH" "Path required." 1 "image.tar"
           NOTE="Exports the image to a tar archive."; run_cmd docker save -o "$f" "$PICKED"; };;
      9) local lf; ask_valid lf "Tar file to load" "$RE_PATH" "Path required."
         NOTE="Imports an image from a tar archive."; run_cmd docker load -i "$lf";;
      10) pick_image && { local -a cmd=(docker rmi); local rimg=$PICKED
            confirm "Force remove (-f)?" n && cmd+=(-f)
            NOTE="Deletes the image from this machine."; run_cmd --danger "${cmd[@]}" "$rimg"; };;
      11) NOTE="Removes untagged (<none>) images."; run_cmd --danger docker image prune;;
      12) NOTE="Removes every image not used by a container."; run_cmd --danger docker image prune -a;;
      0|"") return;;
      *) warn "Invalid choice.";;
    esac
  done
}

# ================================================================= VOLUMES ==
volumes_menu() {
  local c
  while true; do
    header "Volumes"
    cat <<'EOF'
   1) List volumes     4) Remove a volume
   2) Create a volume  5) Prune unused volumes
   3) Inspect a volume 0) Back
EOF
    read -r -p "Choose: " c || { echo; exit 0; }
    case $c in
      1) NOTE="Lists named volumes."; run_view docker volume ls;;
      2) local n; ask_valid n "Volume name" "$RE_NAME" "Use letters, digits, _ . -"
         local -a cmd=(docker volume create)
         local lbl; ask lbl "Label KEY=VALUE (optional)"
         [[ -n $lbl ]] && { valid_env "$lbl" && cmd+=(--label "$lbl") || warn "Ignoring invalid label."; }
         NOTE="Creates persistent storage managed by Docker."; run_cmd "${cmd[@]}" "$n";;
      3) pick_volume && { NOTE="Shows mountpoint, driver and labels."; run_view docker volume inspect "$PICKED"; };;
      4) pick_volume && { NOTE="Deletes the volume and ALL data in it."; run_cmd --danger docker volume rm "$PICKED"; };;
      5) NOTE="Removes every volume not used by any container."; run_cmd --danger docker volume prune;;
      0|"") return;;
      *) warn "Invalid choice.";;
    esac
  done
}

# ================================================================ NETWORKS ==
network_create() {
  local n drv subnet gw
  ask_valid n "Network name" "$RE_NAME" "Use letters, digits, _ . -"
  echo "  1) bridge   2) overlay   3) macvlan   4) ipvlan"
  local d; ask d "Driver" 1
  case $d in 2) drv=overlay;; 3) drv=macvlan;; 4) drv=ipvlan;; *) drv=bridge;; esac
  local -a cmd=(docker network create -d "$drv")
  ask_valid subnet "Subnet CIDR (e.g. 172.28.0.0/16; blank = auto)" "$RE_CIDR" "Format: a.b.c.d/nn" 0
  [[ -n $subnet ]] && cmd+=(--subnet "$subnet")
  if [[ -n $subnet ]]; then
    ask_valid gw "Gateway IP (blank = auto)" "$RE_IP" "Enter a valid IPv4 address." 0
    [[ -n $gw ]] && cmd+=(--gateway "$gw")
  fi
  confirm "Make it internal (no outside access)?" n && cmd+=(--internal)
  NOTE="Creates a virtual network containers can join to talk to each other."
  run_cmd "${cmd[@]}" "$n"
}

networks_menu() {
  local c
  while true; do
    header "Networks"
    cat <<'EOF'
   1) List networks        5) Disconnect container from network
   2) Create a network     6) Remove a network
   3) Inspect a network    7) Prune unused networks
   4) Connect container    0) Back
EOF
    read -r -p "Choose: " c || { echo; exit 0; }
    case $c in
      1) NOTE="Lists Docker networks."; run_view docker network ls;;
      2) network_create;;
      3) pick_network && { NOTE="Shows subnet, gateway and attached containers."; run_view docker network inspect "$PICKED"; };;
      4) pick_network && { local nw=$PICKED; pick_container all && {
           local -a cmd=(docker network connect); local ct=$PICKED ip
           ask_valid ip "Static IP (blank = automatic)" "$RE_IP" "Enter a valid IPv4 address." 0
           [[ -n $ip ]] && cmd+=(--ip "$ip")
           NOTE="Attaches a running container to the network."; run_cmd "${cmd[@]}" "$nw" "$ct"; }; };;
      5) pick_network && { local nw2=$PICKED; pick_container all && {
           NOTE="Detaches a container from the network."; run_cmd docker network disconnect "$nw2" "$PICKED"; }; };;
      6) pick_network && { NOTE="Deletes the network (must have no containers attached)."; run_cmd --danger docker network rm "$PICKED"; };;
      7) NOTE="Removes all networks not used by containers."; run_cmd --danger docker network prune;;
      0|"") return;;
      *) warn "Invalid choice.";;
    esac
  done
}

# ================================================================= COMPOSE ==
compose_select_file() {
  COMPOSE_FILE_ARG=()
  local f
  for f in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
    if [[ -f $f ]]; then info "Found $f in $(pwd)"; return 0; fi
  done
  warn "No compose file found in $(pwd)."
  local p; ask p "Path to compose file (blank = cancel)"
  [[ -z $p ]] && return 1
  if [[ ! -f $p ]] && (( ! DRY_RUN )); then err "File not found: $p"; return 1; fi
  COMPOSE_FILE_ARG=(-f "$p")
}

compose_menu() {
  detect_compose
  if (( ${#COMPOSE[@]} == 0 )); then err "Docker Compose is not installed."; pause; return; fi
  compose_select_file || return
  local c svc
  while true; do
    header "Compose  (${COMPOSE[*]} ${COMPOSE_FILE_ARG[*]})"
    cat <<'EOF'
   1) Up (detached)              8) Pull images
   2) Up + rebuild images        9) Restart services
   3) Down                      10) Stop services
   4) Down + delete volumes     11) Start services
   5) Status (ps)               12) Shell into a service
   6) Logs                      13) Validate / show merged config
   7) Build images               0) Back
EOF
    read -r -p "Choose: " c || { echo; exit 0; }
    local -a base=("${COMPOSE[@]}" "${COMPOSE_FILE_ARG[@]}")
    case $c in
      1) NOTE="Creates and starts all services in the background."; run_cmd "${base[@]}" up -d;;
      2) NOTE="Rebuilds images, then (re)creates the services."; run_cmd "${base[@]}" up -d --build;;
      3) NOTE="Stops and removes containers and networks (volumes are kept)."; run_cmd --danger "${base[@]}" down;;
      4) NOTE="Same as 'down', but ALSO deletes named volumes - data is lost."; run_cmd --danger "${base[@]}" down -v;;
      5) NOTE="Shows state of each service."; run_view "${base[@]}" ps;;
      6) ask svc "Service (blank = all)"
         local -a cmd=("${base[@]}" logs --tail 100)
         confirm "Follow live output (Ctrl+C to stop)?" n && cmd+=(-f)
         [[ -n $svc ]] && cmd+=("$svc")
         NOTE="Prints service logs."; run_view "${cmd[@]}";;
      7) NOTE="Builds images for services that have a build section."; run_cmd "${base[@]}" build;;
      8) NOTE="Downloads the latest images for all services."; run_cmd "${base[@]}" pull;;
      9) ask svc "Service (blank = all)"; NOTE="Restarts containers."; run_cmd "${base[@]}" restart ${svc:+"$svc"};;
      10) ask svc "Service (blank = all)"; NOTE="Stops containers without removing them."; run_cmd "${base[@]}" stop ${svc:+"$svc"};;
      11) ask svc "Service (blank = all)"; NOTE="Starts existing containers."; run_cmd "${base[@]}" start ${svc:+"$svc"};;
      12) ask_valid svc "Service name" "$RE_NAME" "Invalid service name."
          NOTE="Opens a shell inside a running service container."
          run_cmd "${base[@]}" exec "$svc" sh -c 'command -v bash >/dev/null 2>&1 && exec bash || exec sh';;
      13) NOTE="Validates the file and prints the resolved configuration."; run_view "${base[@]}" config;;
      0|"") return;;
      *) warn "Invalid choice.";;
    esac
  done
}

# ================================================================== SYSTEM ==
system_menu() {
  local c
  while true; do
    header "System & Cleanup"
    cat <<'EOF'
   1) Disk usage (docker system df)    5) Docker info
   2) Prune unused data (safe)         6) Docker version
   3) Prune EVERYTHING unused + volumes 7) Live event stream
   4) Registry login / logout          0) Back
EOF
    read -r -p "Choose: " c || { echo; exit 0; }
    case $c in
      1) NOTE="Shows how much space images, containers and volumes use."; run_view docker system df;;
      2) NOTE="Removes stopped containers, unused networks, dangling images and build cache."; run_cmd --danger docker system prune;;
      3) NOTE="Aggressive: also removes ALL unused images AND volumes."; run_cmd --danger docker system prune -a --volumes;;
      4) echo "  1) Login   2) Logout"; local lm srv; ask lm "Choose" 1
         ask srv "Registry (blank = Docker Hub)"
         if [[ $lm == 2 ]]; then run_cmd docker logout ${srv:+"$srv"}; else run_cmd docker login ${srv:+"$srv"}; fi;;
      5) run_view docker info;;
      6) run_view docker version;;
      7) NOTE="Streams Docker daemon events until you press Ctrl+C."; run_view docker events;;
      0|"") return;;
      *) warn "Invalid choice.";;
    esac
  done
}

# ================================================================ FAVORITES ==
favorites_menu() {
  local c
  while true; do
    header "Saved favorites"
    if [[ ! -s $SAVED_FILE ]]; then warn "Nothing saved yet. Say 'y' to 'Save this to your favorites?' after a command."; pause; return; fi
    local -a labels=() cmds=(); local l cm i=0
    while IFS=$'\t' read -r l cm; do
      [[ -z $l ]] && continue
      labels+=("$l"); cmds+=("$cm")
      printf '  %s%2d)%s %s\n      %s%s%s\n' "$C_CYAN" "$((++i))" "$C_RST" "$l" "$C_DIM" "$cm" "$C_RST"
    done < "$SAVED_FILE"
    echo; echo "  r<N>) Run   d<N>) Delete   0) Back   (e.g. r2)"
    read -r -p "Choose: " c || { echo; exit 0; }
    case $c in
      r[0-9]*) local n=${c#r}
               if (( n >= 1 && n <= ${#cmds[@]} )); then
                 local -a arr; eval "arr=(${cmds[n-1]})"
                 NO_SAVE_PROMPT=1; run_cmd "${arr[@]}"; NO_SAVE_PROMPT=0
               else warn "Out of range."; fi;;
      d[0-9]*) local n=${c#d}
               if (( n >= 1 && n <= ${#cmds[@]} )); then
                 confirm "Delete '${labels[n-1]}'?" n && { sed -i "${n}d" "$SAVED_FILE" 2>/dev/null || { grep -v '^$' "$SAVED_FILE" | awk -v k="$n" 'NR!=k' > "$SAVED_FILE.tmp" && mv "$SAVED_FILE.tmp" "$SAVED_FILE"; }; ok "Deleted."; }
               else warn "Out of range."; fi;;
      0|"") return;;
      *) warn "Invalid choice.";;
    esac
  done
}

view_log() {
  header "Activity log ($LOG_FILE)"
  if [[ -s $LOG_FILE ]]; then tail -n 30 "$LOG_FILE"; else info "Log is empty."; fi
  pause
}

cheat_sheet() {
  header "Docker cheat sheet"
  cat <<'EOF'
  docker ps [-a]                     list containers (running / all)
  docker run -d -p 8080:80 nginx     start a container in the background
  docker exec -it NAME bash          open a shell inside a container
  docker logs -f NAME                follow container logs
  docker stop|start|restart NAME     control a container
  docker rm [-f] NAME                delete a container
  docker images / pull / rmi         manage images
  docker build -t name:tag .         build an image from a Dockerfile
  docker volume ls / create / rm     manage persistent data
  docker network ls / create         manage networks
  docker compose up -d / down        run multi-container apps
  docker system df / prune           see usage / clean up
EOF
  pause
}

# ================================================================ MAIN MENU ==
usage() {
  cat <<EOF
Docker Command Helper v$VERSION
Usage: $(basename "$0") [options]
  -n, --dry-run   Show the commands but never execute them
  -v, --version   Print version
  -h, --help      Show this help
Files: log -> $LOG_FILE   favorites -> $SAVED_FILE
EOF
}

main_menu() {
  local c
  while true; do
    header "🐳 Docker Command Helper v$VERSION$( ((DRY_RUN)) && echo '  [DRY-RUN]')"
    if (( ! DRY_RUN )); then
      local running; running=$("${SUDO[@]}" docker ps -q 2>/dev/null | wc -l | tr -d ' ')
      printf '%sRunning containers: %s%s\n' "$C_DIM" "$running" "$C_RST"
    fi
    cat <<'EOF'
   1) 📦 Containers
   2) 🖼️  Images
   3) 💾 Volumes
   4) 🌐 Networks
   5) 🧩 Compose
   6) 🧹 System & cleanup
   7) ⭐ Saved favorites
   8) 📜 View activity log
   9) 📖 Cheat sheet
   0) Exit
EOF
    read -r -p "Choose: " c || { echo; exit 0; }
    case $c in
      1) containers_menu;; 2) images_menu;; 3) volumes_menu;; 4) networks_menu;;
      5) compose_menu;; 6) system_menu;; 7) favorites_menu;; 8) view_log;; 9) cheat_sheet;;
      0|q|Q) info "Bye!"; exit 0;;
      *) warn "Invalid choice.";;
    esac
  done
}

# ================================================================== START ====
for arg in "$@"; do
  case $arg in
    -n|--dry-run) DRY_RUN=1;;
    -v|--version) echo "docker-helper $VERSION"; exit 0;;
    -h|--help)    usage; exit 0;;
    *) err "Unknown option: $arg"; usage; exit 2;;
  esac
done

trap 'echo; info "Bye."; exit 0' INT
setup_docker
log START "docker-helper $VERSION (dry-run=$DRY_RUN)"
main_menu
