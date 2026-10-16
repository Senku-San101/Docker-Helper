#!/usr/bin/env bash
# ============================================================================
#  Docker Command Helper v2 - interactive, menu-driven wrapper around `docker`
#
#  * Dashboard-style screens: the terminal is redrawn on every menu (no stacking)
#  * Box tables with status dots for containers, images, volumes, networks
#  * Every command is previewed and confirmed before it runs
#  * Edit an existing container: restart policy, memory, CPU, name (live)
#    and ports, env vars, volumes (safe recreate with automatic rollback)
#  * Input validation, logging, smart sudo, saved favorites, --dry-run
#
#  Requires Bash 4.3+ and the docker CLI.
# ============================================================================

VERSION="2.0.0"
APP_DIR="${DOCKER_HELPER_HOME:-$HOME/.docker-helper}"
LOG_FILE="$APP_DIR/docker-helper.log"
SAVED_FILE="$APP_DIR/saved-commands.tsv"
DRY_RUN=0
NO_CLEAR=0
KEEP_SCROLLBACK="${DH_KEEP_SCROLLBACK:-0}"
NO_SAVE_PROMPT=0
NOTE=""
FLASH=""
SUDO=()
COMPOSE=()
COMPOSE_FILE_ARG=()
PICKED=""
LIST=()
CHOICE=""
SC=""
TERM_ROWS=24
TERM_COLS=80

mkdir -p "$APP_DIR" 2>/dev/null || {
  APP_DIR="/tmp/.docker-helper-$USER"; mkdir -p "$APP_DIR"
  LOG_FILE="$APP_DIR/docker-helper.log"; SAVED_FILE="$APP_DIR/saved-commands.tsv"
}
touch "$SAVED_FILE" 2>/dev/null

# ------------------------------------------------------ terminal & glyphs ---
UI_TTY=0; [[ -t 1 ]] && UI_TTY=1
UTF8=0
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) UTF8=1;; esac

if (( UTF8 )); then
  G_H='─'; G_V='│'; G_TL='┌'; G_TR='┐'; G_BL='└'; G_BR='┘'
  G_TJ='┬'; G_BJ='┴'; G_LJ='├'; G_RJ='┤'; G_X='┼'
  G_DOT='●'; G_ODOT='○'; G_ARR='›'; G_PROMPT='▸'; G_ELL='…'; G_WARN='⚠'; G_OK='✔'; G_ERR='✖'; G_PEN='✎'
else
  G_H='-'; G_V='|'; G_TL='+'; G_TR='+'; G_BL='+'; G_BR='+'
  G_TJ='+'; G_BJ='+'; G_LJ='+'; G_RJ='+'; G_X='+'
  G_DOT='*'; G_ODOT='o'; G_ARR='>'; G_PROMPT='>'; G_ELL='~'; G_WARN='!'; G_OK='+'; G_ERR='x'; G_PEN='*'
fi

if (( UI_TTY )); then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'
  C_CYAN=$'\e[36m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'; C_RST=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYAN=""; C_BOLD=""; C_DIM=""; C_RST=""
fi

refresh_term_size() {
  TERM_ROWS=24; TERM_COLS=80
  if (( UI_TTY )); then
    local r c
    if read -r r c < <(stty size 2>/dev/null </dev/tty) && [[ $r =~ ^[0-9]+$ && $c =~ ^[0-9]+$ ]] && (( r > 0 && c > 0 )); then
      TERM_ROWS=$r; TERM_COLS=$c
    fi
  else
    TERM_COLS=${COLUMNS:-80}; TERM_ROWS=${LINES:-24}
  fi
  (( TERM_COLS > 130 )) && TERM_COLS=130
  (( TERM_COLS < 50 ))  && TERM_COLS=50
}

rep() { local n=$2 s; (( n < 1 )) && return; printf -v s '%*s' "$n" ''; printf '%s' "${s// /$1}"; }
sp()  { (( $1 > 0 )) && printf '%*s' "$1" ''; return 0; }
join_by() { local sep=$1; shift; local out="" x; for x in "$@"; do out+="${out:+$sep}$x"; done; printf '%s' "$out"; }

# ---------------------------------------------------------------- output ----
log()   { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >> "$LOG_FILE" 2>/dev/null; }
info()  { printf '  %s%s%s\n' "$C_BLU" "$*" "$C_RST"; }
ok()    { printf '  %s%s %s%s\n' "$C_GRN" "$G_OK" "$*" "$C_RST"; }
warn()  { printf '  %s%s %s%s\n' "$C_YEL" "$G_WARN" "$*" "$C_RST"; }
err()   { printf '  %s%s %s%s\n' "$C_RED" "$G_ERR" "$*" "$C_RST" >&2; }
flash() { FLASH="  ${C_YEL}${G_WARN} $1${C_RST}"; }
section() { printf '\n  %s%s%s\n' "$C_BOLD" "$1" "$C_RST"; }
hr()    { printf '  %s' "$C_DIM"; rep "$G_H" $((TERM_COLS - 4)); printf '%s\n' "$C_RST"; }

screen() { # screen "Crumb › Trail"  -> clears the terminal and draws the title bar
  refresh_term_size
  if (( UI_TTY && ! NO_CLEAR )); then
    printf '\033[H\033[2J'
    (( KEEP_SCROLLBACK )) || printf '\033[3J'
  fi
  printf '\n  %sDocker Helper%s' "$C_BOLD" "$C_RST"
  [[ -n $1 ]] && printf '  %s%s%s  %s%s%s' "$C_DIM" "$G_ARR" "$C_RST" "$C_BOLD" "$1" "$C_RST"
  (( DRY_RUN )) && printf '   %s[dry-run]%s' "$C_YEL" "$C_RST"
  printf '\n'; hr
  if [[ -n $FLASH ]]; then printf '%s\n' "$FLASH"; FLASH=""; fi
}

pause() { printf '\n  %sPress Enter to continue%s ' "$C_DIM" "$C_RST"; read -r _ || true; }

# ---------------------------------------------------------------- input -----
confirm() { # confirm "prompt" [y|n default]
  local def=${2:-n} hint ans
  [[ $def == y ]] && hint="Y/n" || hint="y/N"
  read -r -p "  $1 ($hint): " ans || { echo; exit 0; }
  ans=${ans:-$def}
  [[ $ans =~ ^[Yy]([Ee][Ss])?$ ]]
}

ask() { # ask VAR "prompt" [default]
  local __v=$1 __p=$2 __d=${3:-} __a
  if [[ -n $__d ]]; then
    read -r -p "  $__p [$__d]: " __a || { echo; exit 0; }
    __a=${__a:-$__d}
  else
    read -r -p "  $__p: " __a || { echo; exit 0; }
  fi
  printf -v "$__v" '%s' "$__a"
}

# ask_valid VAR "prompt" REGEX "error message" [required=1] [default]
ask_valid() {
  local _var=$1 _prm=$2 _rx=$3 _emsg=$4 _must=${5:-1} _def=${6:-} _ans
  while true; do
    ask _ans "$_prm" "$_def"
    if [[ -z $_ans ]]; then
      if (( _must )); then warn "This value is required."; continue; fi
      printf -v "$_var" ''; return 0
    fi
    if [[ $_ans =~ $_rx ]]; then printf -v "$_var" '%s' "$_ans"; return 0; fi
    warn "$_emsg"
  done
}

prompt_choice() { echo; read -r -p "  Choose $G_PROMPT " CHOICE || { echo; exit 0; }; }

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

abs_vol() { # docker needs absolute host paths: expand ./dir ../dir ~/dir
  case $1 in
    ./*)     printf '%s' "$PWD/${1#./}";;
    ../*)    printf '%s' "$PWD/$1";;
    "~/"*)    printf '%s' "$HOME/${1#\~/}";;
    *)        printf '%s' "$1";;
  esac
}

collect_list() { # collect_list "prompt" validator_fn "error"  -> LIST
  LIST=(); local v
  while true; do
    read -r -p "  $1 (blank to finish): " v || { echo; exit 0; }
    [[ -z $v ]] && break
    if "$2" "$v"; then LIST+=("$v"); else warn "$3"; fi
  done
}

# ================================================================ TABLES ====
status_color() { # sets SC from a docker status text
  case $1 in
    *unhealthy*)                                   SC=$C_RED;;
    *Paused*|*paused*|*Restarting*|*restarting*|*starting*) SC=$C_YEL;;
    "Exited (0)"*)                                 SC=$C_DIM;;
    Exited*|Dead*|exited*|dead*)                   SC=$C_RED;;
    Created*|created*)                             SC=$C_DIM;;
    Up*|running*|*[Hh]ealthy*)                     SC=$C_GRN;;
    *)                                             SC="";;
  esac
}

_tb_border() { # left mid right   (uses table_draw's locals)
  local c
  printf '  %s%s' "$C_DIM" "$1"
  for ((c = 0; c < ncol; c++)); do
    rep "$G_H" $((w[c] + 2 * pad))
    if (( c < ncol - 1 )); then printf '%s' "$2"; else printf '%s' "$3"; fi
  done
  printf '%s\n' "$C_RST"
}

# table_draw "H1|H2|.." [numbered 0|1] [status_col 0|N]   (rows on stdin, '|' separated)
table_draw() {
  local hdr=$1 numbered=${2:-0} stcol=${3:-0}
  local -a rows=() hd=() cell=() w=() fields=()
  local line r c f l ncol nrow sumw total pad=2
  while IFS= read -r line; do [[ -n $line ]] && rows+=("$line"); done
  IFS='|' read -r -a hd <<<"$hdr"
  nrow=${#rows[@]}
  if (( nrow == 0 )); then printf '  %s(nothing to show)%s\n' "$C_DIM" "$C_RST"; return 0; fi
  if (( numbered )); then hd=("#" "${hd[@]}"); (( stcol > 0 )) && stcol=$((stcol + 1)); fi
  ncol=${#hd[@]}

  for ((r = 0; r < nrow; r++)); do
    fields=()
    IFS='|' read -r -a fields <<<"${rows[r]}"
    (( numbered )) && fields=("$((r + 1))" "${fields[@]}")
    for ((c = 0; c < ncol; c++)); do
      f=${fields[c]:-}
      (( c + 1 == stcol )) && f="$G_DOT $f"
      cell[r * ncol + c]=$f
    done
  done

  for ((c = 0; c < ncol; c++)); do w[c]=${#hd[c]}; done
  for ((r = 0; r < nrow; r++)); do
    for ((c = 0; c < ncol; c++)); do
      l=${#cell[r * ncol + c]}; (( l > w[c] )) && w[c]=$l
    done
  done
  sumw=0; for ((c = 0; c < ncol; c++)); do sumw=$((sumw + w[c])); done
  total=$((2 + sumw + ncol * 2 * pad + ncol + 1))
  if (( total > TERM_COLS )); then pad=1; total=$((2 + sumw + ncol * 2 * pad + ncol + 1)); fi
  local mi mw
  while (( total > TERM_COLS )); do
    mi=-1; mw=8
    for ((c = 0; c < ncol; c++)); do (( w[c] > mw )) && { mw=${w[c]}; mi=$c; }; done
    (( mi < 0 )) && break
    w[mi]=$((w[mi] - 1)); total=$((total - 1))
  done

  _tb_border "$G_TL" "$G_TJ" "$G_TR"
  printf '  %s%s%s' "$C_DIM" "$G_V" "$C_RST"
  for ((c = 0; c < ncol; c++)); do
    f=${hd[c]}; (( ${#f} > w[c] )) && f="${f:0:w[c]-1}$G_ELL"
    sp "$pad"; printf '%s%s%s' "$C_BOLD" "$f" "$C_RST"; sp $((w[c] - ${#f} + pad))
    printf '%s%s%s' "$C_DIM" "$G_V" "$C_RST"
  done
  printf '\n'
  _tb_border "$G_LJ" "$G_X" "$G_RJ"
  for ((r = 0; r < nrow; r++)); do
    printf '  %s%s%s' "$C_DIM" "$G_V" "$C_RST"
    for ((c = 0; c < ncol; c++)); do
      f=${cell[r * ncol + c]}
      (( ${#f} > w[c] )) && f="${f:0:w[c]-1}$G_ELL"
      sp "$pad"
      if (( c + 1 == stcol )) && [[ $f == "$G_DOT "* ]]; then
        status_color "${f:2}"
        printf '%s%s%s %s' "$SC" "$G_DOT" "$C_RST" "${f:2}"
      elif (( numbered && c == 0 )); then
        printf '%s%s%s' "$C_CYAN" "$f" "$C_RST"
      else
        printf '%s' "$f"
      fi
      sp $((w[c] - ${#f} + pad))
      printf '%s%s%s' "$C_DIM" "$G_V" "$C_RST"
    done
    printf '\n'
  done
  _tb_border "$G_BL" "$G_BJ" "$G_BR"
}

# ================================================================== MENUS ===
# menu_grid "@TITLE" "key|label" ... "@TITLE2" ...   (each @TITLE starts a column)
menu_grid() {
  local -A ck=() cl=()
  local -a titles=() cnt=() cw=()
  local a ci=-1 r c n key label maxr=0 total
  for a in "$@"; do
    if [[ $a == @* ]]; then
      ci=$((ci + 1)); titles[ci]=${a#@}; cnt[ci]=0; cw[ci]=${#titles[ci]}
    else
      key=${a%%|*}; label=${a#*|}; r=${cnt[ci]}
      ck[$ci,$r]=$key; cl[$ci,$r]=$label; cnt[ci]=$((r + 1))
      (( 3 + ${#label} > cw[ci] )) && cw[ci]=$((3 + ${#label}))
    fi
  done
  n=$((ci + 1)); total=2
  for ((c = 0; c < n; c++)); do
    total=$((total + cw[c])); (( c < n - 1 )) && total=$((total + 3))
    (( cnt[c] > maxr )) && maxr=${cnt[c]}
  done

  if (( total <= TERM_COLS )); then
    for ((r = -2; r < maxr; r++)); do
      printf '  '
      for ((c = 0; c < n; c++)); do
        if (( r == -2 )); then
          printf '%s%s%s' "$C_BOLD" "${titles[c]}" "$C_RST"; sp $((cw[c] - ${#titles[c]}))
        elif (( r == -1 )); then
          printf '%s' "$C_DIM"; rep "$G_H" "${cw[c]}"; printf '%s' "$C_RST"
        elif (( r < cnt[c] )); then
          printf '%s%-3s%s%s' "$C_CYAN" "${ck[$c,$r]}" "$C_RST" "${cl[$c,$r]}"
          sp $((cw[c] - 3 - ${#cl[$c,$r]}))
        else
          sp "${cw[c]}"
        fi
        (( c < n - 1 )) && sp 3
      done
      printf '\n'
    done
  else   # narrow terminal: stack the groups
    for ((c = 0; c < n; c++)); do
      printf '  %s%s%s\n' "$C_BOLD" "${titles[c]}" "$C_RST"
      for ((r = 0; r < cnt[c]; r++)); do
        printf '  %s%-3s%s%s\n' "$C_CYAN" "${ck[$c,$r]}" "$C_RST" "${cl[$c,$r]}"
      done
      (( c < n - 1 )) && echo
    done
  fi
}

# ---------------------------------------------------------------- dashboard -
docker_count() { "${SUDO[@]}" docker "$@" 2>/dev/null | sort -u | grep -c . ; }

status_line() {
  (( DRY_RUN )) && return 0
  local run all
  run=$(docker_count ps -q); all=$(docker_count ps -aq)
  printf '\n  %s%s%s %s running     %s%s%s %s stopped\n' "$C_GRN" "$G_DOT" "$C_RST" "$run" "$C_DIM" "$G_ODOT" "$C_RST" "$((all - run))"
}

dash_panel() {
  local run="-" all="-" img="-" vol="-" net="-" stopped="-"
  if (( ! DRY_RUN )); then
    run=$(docker_count ps -q); all=$(docker_count ps -aq); stopped=$((all - run))
    img=$(docker_count images -q); vol=$(docker_count volume ls -q); net=$(docker_count network ls -q)
  fi
  local plain="$G_DOT $run running     $G_ODOT $stopped stopped     Images $img     Volumes $vol     Networks $net"
  local inner=$((TERM_COLS - 6)) colored
  colored="${C_GRN}${G_DOT}${C_RST} ${C_BOLD}${run}${C_RST} running     ${C_DIM}${G_ODOT}${C_RST} ${C_BOLD}${stopped}${C_RST} stopped     Images ${C_BOLD}${img}${C_RST}     Volumes ${C_BOLD}${vol}${C_RST}     Networks ${C_BOLD}${net}${C_RST}"
  echo
  if (( ${#plain} + 4 <= inner )); then
    printf '  %s%s' "$C_DIM" "$G_TL"; rep "$G_H" $((inner)); printf '%s%s\n' "$G_TR" "$C_RST"
    printf '  %s%s%s  %s' "$C_DIM" "$G_V" "$C_RST" "$colored"; sp $((inner - 2 - ${#plain}))
    printf '%s%s%s\n' "$C_DIM" "$G_V" "$C_RST"
    printf '  %s%s' "$C_DIM" "$G_BL"; rep "$G_H" $((inner)); printf '%s%s\n' "$G_BR" "$C_RST"
  else
    printf '  %s\n' "$colored"
  fi
}

dash_running() {
  (( DRY_RUN )) && return 0
  local max=$((TERM_ROWS - 27)); (( max > 8 )) && max=8
  (( max < 1 )) && return 0
  local out total; out=$("${SUDO[@]}" docker ps --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}' 2>/dev/null)
  total=$(printf '%s\n' "$out" | grep -c .)
  (( total == 0 )) && { printf '\n  %sNo containers are running.%s\n' "$C_DIM" "$C_RST"; return 0; }
  section "Running containers"
  printf '%s\n' "$out" | head -n "$max" | table_draw "NAME|IMAGE|STATUS|PORTS" 0 3
  (( total > max )) && printf '  %s+ %d more (Containers > List running)%s\n' "$C_DIM" "$((total - max))" "$C_RST"
  return 0
}

# ---------------------------------------------------------------- picker ----
# pick_from_docker "thing" "H1|H2" status_col docker-args...   (format emits value|col1|col2...)
pick_from_docker() {
  local title=$1 hdr=$2 st=$3; shift 3
  local -a vals=() rest=()
  local line choice
  if (( ! DRY_RUN )); then
    while IFS= read -r line; do
      [[ -z $line ]] && continue
      vals+=("${line%%|*}"); rest+=("${line#*|}")
    done < <("${SUDO[@]}" docker "$@" 2>/dev/null)
  fi
  echo
  if (( ${#vals[@]} == 0 )); then
    warn "No $title found automatically."
    ask choice "Type a name/ID manually (blank = cancel)"
    [[ -z $choice ]] && return 1
    PICKED=$choice; return 0
  fi
  section "Select a $title"
  printf '%s\n' "${rest[@]}" | table_draw "$hdr" 1 "$st"
  printf '  %s0 = cancel%s\n\n' "$C_DIM" "$C_RST"
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
  local -a a=(ps --format '{{.Names}}|{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}')
  [[ ${1:-all} == all ]] && a=(ps -a --format '{{.Names}}|{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}')
  pick_from_docker "container" "NAME|IMAGE|STATUS|PORTS" 3 "${a[@]}"
}
pick_image() {
  pick_from_docker "image" "IMAGE|SIZE|CREATED" 0 images --format '{{if eq .Tag "<none>"}}{{.ID}}{{else}}{{.Repository}}:{{.Tag}}{{end}}|{{.Repository}}:{{.Tag}}|{{.Size}}|{{.CreatedSince}}'
}
pick_volume()  { pick_from_docker "volume"  "NAME|DRIVER" 0 volume ls --format '{{.Name}}|{{.Name}}|{{.Driver}}'; }
pick_network() { pick_from_docker "network" "NAME|DRIVER|SCOPE" 0 network ls --format '{{.Name}}|{{.Name}}|{{.Driver}}|{{.Scope}}'; }

# --------------------------------------------------------------- executor ---
is_bool_flag() { case $1 in -d|-i|-t|-it|-ti|--rm|--no-cache|--pull|--internal|--no-stream|-q|--quiet|-a|--all|--volumes|--force) return 0;; esac; return 1; }

# fmt_cmd args... -> prints the command, one option per line when it is long
fmt_cmd() {
  local -a q=(); local t i=0 n cur one
  for t in "$@"; do printf -v t '%q' "$t"; q+=("$t"); done
  n=${#q[@]}; one="${q[*]}"
  if (( ${#one} <= TERM_COLS - 20 )); then printf '%s\n' "$one"; return; fi
  local -a lines=(); cur=""
  while (( i < n )) && [[ ${q[i]} != -* ]]; do cur+="${cur:+ }${q[i]}"; i=$((i + 1)); done
  [[ -n $cur ]] && lines+=("$cur")
  while (( i < n )); do
    t=${q[i]}
    if [[ $t == -* ]]; then
      cur=$t; i=$((i + 1))
      if ! is_bool_flag "$t" && (( i < n )) && [[ ${q[i]} != -* ]]; then cur+=" ${q[i]}"; i=$((i + 1)); fi
      lines+=("  $cur")
    else
      lines+=("  ${q[*]:i}"); break
    fi
  done
  for ((i = 0; i < ${#lines[@]}; i++)); do
    if (( i < ${#lines[@]} - 1 )); then printf '%s \\\n' "${lines[i]}"; else printf '%s\n' "${lines[i]}"; fi
  done
}

show_kv() { # "Label" "text"  (wrapped, aligned)
  local label=$1 text=$2 first=1 ln
  while IFS= read -r ln; do
    if (( first )); then printf '  %s%-12s%s  %s\n' "$C_DIM" "$label" "$C_RST" "$ln"; first=0
    else printf '  %12s  %s\n' '' "$ln"; fi
  done < <(printf '%s\n' "$text" | fold -s -w $((TERM_COLS - 18)))
}

show_cmd() { # full command words (sudo included)
  local first=1 ln
  while IFS= read -r ln; do
    if (( first )); then printf '  %s%-12s%s  %s%s%s\n' "$C_DIM" "Command" "$C_RST" "$C_CYAN" "$ln" "$C_RST"; first=0
    else printf '  %12s  %s%s%s\n' '' "$C_CYAN" "$ln" "$C_RST"; fi
  done < <(fmt_cmd "$@")
}

show_note() { [[ -n $NOTE ]] && show_kv "What it does" "$NOTE"; NOTE=""; return 0; }

# run_cmd [--danger] docker ...  -> preview, confirm, run, log, offer to save, pause
run_cmd() {
  local danger=0
  if [[ $1 == --danger ]]; then danger=1; shift; fi
  local -a cmd=("$@")
  local pv rc
  printf -v pv '%q ' "${cmd[@]}"; pv=${pv% }

  echo; show_note; show_cmd "${SUDO[@]}" "${cmd[@]}"; echo
  if (( DRY_RUN )); then warn "[dry-run] not executed."; log DRYRUN "$pv"; pause; return 0; fi
  if (( danger )); then
    confirm "${C_RED}This is destructive.${C_RST} Proceed?" n || { log CANCEL "$pv"; return 1; }
  else
    confirm "Run it?" y || { log CANCEL "$pv"; return 1; }
  fi

  echo; log RUN "${SUDO[*]:+${SUDO[*]} }$pv"
  trap ':' INT                       # Ctrl+C stops the command, not the helper
  "${SUDO[@]}" "${cmd[@]}"; rc=$?
  trap 'echo; info "Bye."; exit 0' INT
  echo
  if   (( rc == 0 ));   then ok "Done.";                  log OK   "$pv"
  elif (( rc == 130 )); then warn "Interrupted.";         log INT  "$pv"
  else                       err "Exited with code $rc";  log FAIL "($rc) $pv"; fi
  (( rc == 0 && danger == 0 && NO_SAVE_PROMPT == 0 )) && maybe_save "$pv"
  pause
  return $rc
}

# run_view docker ...  -> read-only raw output, no confirmation
run_view() {
  local -a cmd=("$@"); local pv
  printf -v pv '%q ' "${cmd[@]}"; pv=${pv% }
  echo; show_note; show_cmd "${SUDO[@]}" "${cmd[@]}"; echo
  if (( DRY_RUN )); then warn "[dry-run] not executed."; pause; return 0; fi
  log VIEW "$pv"
  trap ':' INT
  "${SUDO[@]}" "${cmd[@]}"
  trap 'echo; info "Bye."; exit 0' INT
  pause
  return 0
}

# view_table "H1|H2" status_col "shown command" docker-args...  (format must emit | separated)
view_table() {
  local hdr=$1 st=$2 show=$3; shift 3
  echo; show_note
  printf '  %s$ %s%s\n\n' "$C_DIM" "$show" "$C_RST"
  if (( DRY_RUN )); then warn "[dry-run] not executed."; pause; return 0; fi
  log VIEW "$show"
  local out rc
  out=$("${SUDO[@]}" docker "$@" 2>&1); rc=$?
  if (( rc != 0 )); then err "$out"; else printf '%s\n' "$out" | table_draw "$hdr" 0 "$st"; fi
  pause
  return $rc
}

# exec_step "label" cmd...  -> one step of a multi-step flow (no prompts)
exec_step() {
  local label=$1; shift
  local pv out rc; printf -v pv '%q ' "$@"; pv=${pv% }
  printf '\n  %s%s%s\n' "$C_BOLD" "$label" "$C_RST"
  printf '    %s$ %s%s%s\n' "$C_DIM" "${SUDO[*]:+${SUDO[*]} }" "$pv" "$C_RST"
  if (( DRY_RUN )); then log DRYRUN "$pv"; return 0; fi
  log RUN "$pv"
  out=$("${SUDO[@]}" "$@" 2>&1); rc=$?
  [[ -n $out ]] && printf '%s\n' "$out" | sed 's/^/      /'
  if (( rc == 0 )); then log OK "$pv"; else log FAIL "($rc) $pv"; fi
  return $rc
}

maybe_save() {
  confirm "Save this to your favorites?" n || return 0
  local label; ask label "Short label"
  [[ -z $label ]] && label=$1
  label=${label//$'\t'/ }
  printf '%s\t%s\n' "$label" "$1" >> "$SAVED_FILE"
  ok "Saved."
}

# -------------------------------------------------------------- setup -------
setup_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    if (( DRY_RUN )); then return 0; fi
    err "Docker CLI not found. Install it first: https://docs.docker.com/engine/install/"
    exit 1
  fi
  (( DRY_RUN )) && return 0
  if docker info >/dev/null 2>&1; then
    SUDO=()
  elif [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    SUDO=(sudo); warn "Using sudo for docker (add yourself to the 'docker' group to avoid this)."; sleep 1
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
  screen "Containers $G_ARR Run new container"
  local image name detached="" restart="no" mem cpus cmdline p
  local -a cmd=(docker run)

  section "1 · Basics"
  ask_valid image "Image (e.g. nginx:latest)" "$RE_IMAGE" "Invalid image reference."
  ask_valid name  "Container name (optional)" "$RE_NAME" "Use letters, digits, _ . -" 0
  if confirm "Run in the background (detached)?" y; then detached=1; cmd+=(-d); else cmd+=(-it); fi
  if (( detached )); then
    echo "    1) no   2) always   3) unless-stopped   4) on-failure"
    local r; ask r "Restart policy" 1
    case $r in 2) restart=always;; 3) restart=unless-stopped;; 4) restart=on-failure;; *) restart=no;; esac
    [[ $restart != no ]] && cmd+=(--restart "$restart")
  else
    confirm "Remove the container when it exits (--rm)?" y && cmd+=(--rm)
  fi
  [[ -n $name ]] && cmd+=(--name "$name")

  section "2 · Ports, variables, storage"
  collect_list "Port HOST:CONTAINER, e.g. 8080:80" valid_port "Format: [ip:]host:container[/tcp|udp], ports 1-65535"
  for p in "${LIST[@]}"; do cmd+=(-p "$p"); done
  collect_list "Variable KEY=VALUE" valid_env "Format must be KEY=VALUE"
  for p in "${LIST[@]}"; do cmd+=(-e "$p"); done
  collect_list "Volume SRC:/path[:ro], e.g. ./data:/data" valid_vol "Format: /host/dir:/path or volname:/path[:ro]"
  for p in "${LIST[@]}"; do cmd+=(-v "$(abs_vol "$p")"); done

  section "3 · Network and limits"
  if confirm "Attach to a specific network?" n; then pick_network && cmd+=(--network "$PICKED"); fi
  ask_valid mem  "Memory limit, e.g. 512m or 2g (blank = none)" "$RE_MEM" "Use a number with optional b/k/m/g." 0
  [[ -n $mem ]] && cmd+=(--memory "$mem")
  ask_valid cpus "CPU limit, e.g. 1.5 (blank = none)" "$RE_CPUS" "Use a number like 2 or 1.5." 0
  [[ -n $cpus ]] && cmd+=(--cpus "$cpus")

  cmd+=("$image")
  ask cmdline "Override command/args (blank = image default)"
  if [[ -n $cmdline ]]; then local -a extra; read -r -a extra <<<"$cmdline"; cmd+=("${extra[@]}"); fi

  NOTE="Creates and starts a new container from '$image' with the options you chose."
  run_cmd "${cmd[@]}"
}

container_logs() {
  pick_container all || return
  local c=$PICKED tail
  echo
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
  local c=$PICKED m
  echo; echo "    1) Auto shell (bash, falls back to sh)   2) sh   3) Custom command"
  ask m "Choose" 1
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
  local c=$PICKED m
  echo; echo "    1) Full JSON   2) IP address   3) Environment   4) Mounts   5) State / health   6) Ports"
  ask m "Choose" 2
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
  local d src dst c
  echo; echo "    1) Host -> container   2) Container -> host"
  ask d "Direction" 1
  pick_container all || return
  c=$PICKED; echo
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

# ------------------------------------------------ edit an existing container
declare -a EC_PORTS=() EC_ENVS=() EC_VOLS=() EC_ENTRY=() EC_CMD=() EC_WARN=() EC_RUN=()
declare -a EC_PORTS0=() EC_ENVS0=() EC_VOLS0=()
EC_NAME=""; EC_IMAGE=""; EC_IMGID=""; EC_STATE=""; EC_RESTART="no"; EC_MEM=0; EC_NANO=0
EC_NET=""; EC_TTY=""; EC_STDIN=""; EC_USER=""; EC_WD=""; EC_USER_SET=0; EC_WD_SET=0
EC_EP_CUSTOM=0; EC_CMD_CUSTOM=0; EC_DIRTY=0

ec_inspect() { "${SUDO[@]}" docker inspect -f "$1" "$EC_NAME" 2>/dev/null; }
ec_img_inspect() { "${SUDO[@]}" docker image inspect -f "$1" "$EC_IMGID" 2>/dev/null; }

ec_load_basic() {
  EC_STATE=$(ec_inspect '{{.State.Status}}')
  local rp mr
  rp=$(ec_inspect '{{.HostConfig.RestartPolicy.Name}}'); mr=$(ec_inspect '{{.HostConfig.RestartPolicy.MaximumRetryCount}}')
  [[ -z $rp ]] && rp=no
  [[ $rp == on-failure && ${mr:-0} -gt 0 ]] && rp="on-failure:$mr"
  EC_RESTART=$rp
  EC_MEM=$(ec_inspect '{{.HostConfig.Memory}}'); EC_MEM=${EC_MEM:-0}
  EC_NANO=$(ec_inspect '{{.HostConfig.NanoCpus}}'); EC_NANO=${EC_NANO:-0}
}

ec_load() {
  EC_NAME=$1; EC_DIRTY=0
  EC_IMAGE=$(ec_inspect '{{.Config.Image}}')
  [[ -z $EC_IMAGE ]] && return 1
  EC_IMGID=$(ec_inspect '{{.Image}}')
  ec_load_basic
  EC_NET=$(ec_inspect '{{.HostConfig.NetworkMode}}')
  EC_TTY=$(ec_inspect '{{.Config.Tty}}'); EC_STDIN=$(ec_inspect '{{.Config.OpenStdin}}')
  EC_USER=$(ec_inspect '{{.Config.User}}'); EC_WD=$(ec_inspect '{{.Config.WorkingDir}}')
  [[ $EC_USER != "$(ec_img_inspect '{{.Config.User}}')" ]] && EC_USER_SET=1 || EC_USER_SET=0
  [[ $EC_WD   != "$(ec_img_inspect '{{.Config.WorkingDir}}')" ]] && EC_WD_SET=1 || EC_WD_SET=0

  EC_PORTS=(); local ip hp cp proto cport spec
  while IFS='|' read -r ip hp cp; do
    [[ -z $cp ]] && continue
    proto=${cp#*/}; cport=${cp%%/*}
    if [[ -n $hp ]]; then spec="$hp:$cport"; else spec="$cport"; fi
    [[ -n $ip && $ip != 0.0.0.0 && -n $hp ]] && spec="$ip:$spec"
    [[ $proto != tcp ]] && spec+="/$proto"
    EC_PORTS+=("$spec")
  done < <(ec_inspect '{{range $p,$c := .HostConfig.PortBindings}}{{range $c}}{{.HostIp}}|{{.HostPort}}|{{$p}}{{println}}{{end}}{{end}}')

  local -a allenv=() baseenv=(); local e
  mapfile -t allenv  < <(ec_inspect '{{range .Config.Env}}{{println .}}{{end}}')
  mapfile -t baseenv < <(ec_img_inspect '{{range .Config.Env}}{{println .}}{{end}}')
  EC_ENVS=()
  for e in "${allenv[@]}"; do
    [[ -z $e ]] && continue
    printf '%s\n' "${baseenv[@]}" | grep -qxF -- "$e" || EC_ENVS+=("$e")
  done

  EC_VOLS=(); local t nm src dst rw
  while IFS='|' read -r t nm src dst rw; do
    [[ -z $dst ]] && continue
    case $t in bind) spec="$src:$dst";; volume) spec="$nm:$dst";; *) continue;; esac
    [[ $rw == false ]] && spec+=":ro"
    EC_VOLS+=("$spec")
  done < <(ec_inspect '{{range .Mounts}}{{.Type}}|{{.Name}}|{{.Source}}|{{.Destination}}|{{.RW}}{{println}}{{end}}')

  mapfile -t EC_ENTRY < <(ec_inspect '{{range .Config.Entrypoint}}{{println .}}{{end}}')
  mapfile -t EC_CMD   < <(ec_inspect '{{range .Config.Cmd}}{{println .}}{{end}}')
  local ie ic
  ie=$(ec_img_inspect '{{range .Config.Entrypoint}}{{println .}}{{end}}')
  ic=$(ec_img_inspect '{{range .Config.Cmd}}{{println .}}{{end}}')
  [[ "$(printf '%s\n' "${EC_ENTRY[@]}")" != "$ie" ]] && EC_EP_CUSTOM=1  || EC_EP_CUSTOM=0
  [[ "$(printf '%s\n' "${EC_CMD[@]}")"   != "$ic" ]] && EC_CMD_CUSTOM=1 || EC_CMD_CUSTOM=0

  EC_WARN=()
  [[ $(ec_inspect '{{.HostConfig.Privileged}}') == true ]] && EC_WARN+=("privileged mode")
  [[ -n $(ec_inspect '{{range .HostConfig.CapAdd}}x{{end}}') ]]   && EC_WARN+=("added capabilities")
  [[ -n $(ec_inspect '{{range .HostConfig.Devices}}x{{end}}') ]]  && EC_WARN+=("device mappings")
  [[ -n $(ec_inspect '{{range .HostConfig.Dns}}x{{end}}') ]]      && EC_WARN+=("custom DNS")
  [[ -n $(ec_inspect '{{range .HostConfig.ExtraHosts}}x{{end}}') ]] && EC_WARN+=("extra hosts")
  [[ -n $(ec_inspect '{{range .HostConfig.SecurityOpt}}x{{end}}') ]] && EC_WARN+=("security options")
  [[ -n $(ec_inspect '{{range .HostConfig.Ulimits}}x{{end}}') ]]  && EC_WARN+=("ulimits")
  [[ -n $(ec_inspect '{{index .Config.Labels "com.docker.compose.project"}}') ]] && EC_WARN+=("managed by Docker Compose (better to edit the compose file)")
  local nn; nn=$(ec_inspect '{{len .NetworkSettings.Networks}}')
  [[ ${nn:-1} -gt 1 ]] && EC_WARN+=("several networks")
  EC_PORTS0=("${EC_PORTS[@]}"); EC_ENVS0=("${EC_ENVS[@]}"); EC_VOLS0=("${EC_VOLS[@]}")
  return 0
}

ec_changed() { # name-of-array name-of-original -> 0 if differs
  local -n _a=$1; local -n _b=$2
  [[ "${_a[*]}" != "${_b[*]}" ]]
}

ec_show() {
  local mem="unlimited" cpus="unlimited" pend_p="" pend_e="" pend_v=""
  (( EC_MEM > 0 ))  && mem="$((EC_MEM / 1048576)) MiB"
  (( EC_NANO > 0 )) && cpus=$(awk -v n="$EC_NANO" 'BEGIN{printf "%g", n/1000000000}')
  ec_changed EC_PORTS EC_PORTS0 && pend_p=" $G_PEN edited"
  ec_changed EC_ENVS  EC_ENVS0  && pend_e=" $G_PEN edited"
  ec_changed EC_VOLS  EC_VOLS0  && pend_v=" $G_PEN edited"
  local ports envs vols
  (( ${#EC_PORTS[@]} )) && ports=$(join_by ', ' "${EC_PORTS[@]}") || ports="(none)"
  (( ${#EC_ENVS[@]} ))  && envs="${#EC_ENVS[@]} variable(s)"      || envs="(none)"
  (( ${#EC_VOLS[@]} ))  && vols=$(join_by ', ' "${EC_VOLS[@]}")    || vols="(none)"
  echo
  {
    printf '%s|%s|%s\n' "Name"           "$EC_NAME"        "change now"
    printf '%s|%s|%s\n' "Image"          "$EC_IMAGE"       "read-only"
    printf '%s|%s|%s\n' "State"          "$EC_STATE"       "-"
    printf '%s|%s|%s\n' "Restart policy" "$EC_RESTART"      "change now"
    printf '%s|%s|%s\n' "Memory limit"   "$mem"            "change now"
    printf '%s|%s|%s\n' "CPU limit"      "$cpus"           "change now"
    printf '%s|%s|%s\n' "Ports"          "$ports"          "needs rebuild$pend_p"
    printf '%s|%s|%s\n' "Environment"    "$envs"           "needs rebuild$pend_e"
    printf '%s|%s|%s\n' "Volumes"        "$vols"           "needs rebuild$pend_v"
  } | table_draw "SETTING|VALUE|HOW IT CHANGES" 0 0
  if (( ${#EC_WARN[@]} )); then
    printf '\n'; warn "Heads-up, this container also uses: $(join_by ', ' "${EC_WARN[@]}")."
  fi
}

# row renderers for the list editor
ec_rows_ports() {
  local s rest proto hp cp ip; local -a p
  for s in "$@"; do
    rest=$s; proto=tcp
    if [[ $rest == */* ]]; then proto=${rest##*/}; rest=${rest%/*}; fi
    IFS=: read -ra p <<<"$rest"
    case ${#p[@]} in 3) ip=${p[0]}; hp=${p[1]}; cp=${p[2]};; 2) ip=any; hp=${p[0]}; cp=${p[1]};; *) ip=any; hp=random; cp=${p[0]};; esac
    printf '%s|%s|%s|%s\n' "$hp" "$cp" "$proto" "$ip"
  done
}
ec_rows_envs() { local s v; for s in "$@"; do v=${s#*=}; printf '%s|%s\n' "${s%%=*}" "${v//|/¦}"; done; }
ec_rows_vols() { local s mode; local -a p; for s in "$@"; do IFS=: read -ra p <<<"$s"; mode=${p[2]:-rw}; printf '%s|%s|%s\n' "${p[0]}" "${p[1]}" "$mode"; done; }

# ec_edit_list "Title" ARRAY validator rows_fn "table header" "example" "error"
ec_edit_list() {
  local title=$1 validator=$3 rowsfn=$4 hdr=$5 example=$6 emsg=$7
  local -n arr=$2
  local line verb num new
  while true; do
    screen "Containers $G_ARR Edit '$EC_NAME' $G_ARR $title"
    echo
    if (( ${#arr[@]} )); then "$rowsfn" "${arr[@]}" | table_draw "$hdr" 1 0
    else printf '  %s(none yet)%s\n' "$C_DIM" "$C_RST"; fi
    printf '\n  %sa%s add     %se N%s edit row N     %sd N%s delete row N     %s0%s done\n' "$C_CYAN" "$C_RST" "$C_CYAN" "$C_RST" "$C_CYAN" "$C_RST" "$C_CYAN" "$C_RST"
    printf '  %sExample: %s%s\n' "$C_DIM" "$example" "$C_RST"
    read -r -p "  $G_PROMPT " line || { echo; exit 0; }
    if [[ $line =~ ^([aed])[[:space:]]*([0-9]*)$ ]]; then verb=${BASH_REMATCH[1]}; num=${BASH_REMATCH[2]}
    elif [[ -z $line || $line == 0 ]]; then return 0
    else flash "Type a, e N, d N or 0."; continue; fi
    case $verb in
      a) ask new "New entry"
         [[ -z $new ]] && continue
         if "$validator" "$new"; then
           [[ $validator == valid_vol ]] && new=$(abs_vol "$new")
           arr+=("$new"); EC_DIRTY=1
         else flash "$emsg"; fi;;
      e) if [[ -z $num ]] || (( num < 1 || num > ${#arr[@]} )); then flash "Give a valid row number, e.g. e 2"; continue; fi
         ask new "Edit entry $num" "${arr[num-1]}"
         if "$validator" "$new"; then
           [[ $validator == valid_vol ]] && new=$(abs_vol "$new")
           arr[num-1]=$new; EC_DIRTY=1
         else flash "$emsg"; fi;;
      d) if [[ -z $num ]] || (( num < 1 || num > ${#arr[@]} )); then flash "Give a valid row number, e.g. d 2"; continue; fi
         unset 'arr[num-1]'; arr=("${arr[@]}"); EC_DIRTY=1;;
    esac
  done
}

ec_live_restart() {
  local r pol mx
  echo; echo "    1) no   2) always   3) unless-stopped   4) on-failure"
  ask r "New restart policy" 3
  case $r in 1) pol=no;; 2) pol=always;; 4) pol=on-failure;; *) pol=unless-stopped;; esac
  if [[ $pol == on-failure ]]; then
    ask_valid mx "Max retries (0 = unlimited)" "$RE_INT" "Enter a number." 1 0
    (( mx > 0 )) && pol="on-failure:$mx"
  fi
  NOTE="Changes what Docker does when the container exits or the daemon restarts. Applies instantly."
  run_cmd docker update --restart "$pol" "$EC_NAME" && ec_load_basic
}
ec_live_memory() {
  local m
  echo; ask_valid m "New memory limit, e.g. 512m or 2g (0 = unlimited)" "$RE_MEM" "Use a number with optional b/k/m/g." 1
  if [[ $m =~ ^0+[bkmgBKMG]?$ ]]; then
    NOTE="Removes the memory limit. Applies instantly, no restart."
    run_cmd docker update --memory 0 --memory-swap -1 "$EC_NAME" && ec_load_basic
  else
    NOTE="Sets a hard memory cap (swap is set equal, so the cap is strict). Applies instantly, no restart."
    run_cmd docker update --memory "$m" --memory-swap "$m" "$EC_NAME" && ec_load_basic
  fi
}
ec_live_cpus() {
  local c
  echo; ask_valid c "New CPU limit, e.g. 1.5 (0 = unlimited)" "$RE_CPUS" "Use a number like 2 or 1.5." 1
  NOTE="Limits how many CPU cores the container may use. Applies instantly, no restart."
  run_cmd docker update --cpus "$c" "$EC_NAME" && ec_load_basic
}
ec_live_rename() {
  local n
  echo; ask_valid n "New name" "$RE_NAME" "Use letters, digits, _ . -"
  NOTE="Renames the container. Anything that refers to the old name must be updated."
  run_cmd docker rename "$EC_NAME" "$n" && EC_NAME=$n
}

ec_build_cmd() {
  EC_RUN=(docker)
  if [[ $EC_STATE == running || $EC_STATE == restarting ]]; then EC_RUN+=(run -d); else EC_RUN+=(create); fi
  [[ $EC_STDIN == true ]] && EC_RUN+=(-i)
  [[ $EC_TTY == true ]]   && EC_RUN+=(-t)
  EC_RUN+=(--name "$EC_NAME")
  [[ $EC_RESTART != no ]] && EC_RUN+=(--restart "$EC_RESTART")
  case $EC_NET in default|bridge|"") ;; *) EC_RUN+=(--network "$EC_NET");; esac
  local p
  if [[ $EC_NET != host ]]; then for p in "${EC_PORTS[@]}"; do EC_RUN+=(-p "$p"); done; fi
  for p in "${EC_ENVS[@]}"; do EC_RUN+=(-e "$p"); done
  for p in "${EC_VOLS[@]}"; do EC_RUN+=(-v "$p"); done
  (( EC_MEM > 0 ))  && EC_RUN+=(--memory "${EC_MEM}b")
  (( EC_NANO > 0 )) && EC_RUN+=(--cpus "$(awk -v n="$EC_NANO" 'BEGIN{printf "%g", n/1000000000}')")
  (( EC_USER_SET )) && [[ -n $EC_USER ]] && EC_RUN+=(--user "$EC_USER")
  (( EC_WD_SET ))   && [[ -n $EC_WD ]]   && EC_RUN+=(--workdir "$EC_WD")
  local -a tail=()
  if (( EC_EP_CUSTOM )); then
    if (( ${#EC_ENTRY[@]} == 0 )); then EC_RUN+=(--entrypoint ""); else
      EC_RUN+=(--entrypoint "${EC_ENTRY[0]}"); tail+=("${EC_ENTRY[@]:1}")
    fi
    tail+=("${EC_CMD[@]}")
  elif (( EC_CMD_CUSTOM )); then
    tail+=("${EC_CMD[@]}")
  fi
  EC_RUN+=("$EC_IMAGE" "${tail[@]}")
}

ec_apply() {
  if (( ! EC_DIRTY )); then flash "No pending rebuild changes (ports / env / volumes)."; return; fi
  ec_build_cmd
  local backup="${EC_NAME}-backup-$(date +%H%M%S)" was_running=0
  [[ $EC_STATE == running ]] && was_running=1
  screen "Containers $G_ARR Edit '$EC_NAME' $G_ARR Apply changes"
  echo
  if (( ${#EC_WARN[@]} )); then
    warn "This container uses: $(join_by ', ' "${EC_WARN[@]}")."
    warn "A rebuild does NOT carry those over. Your old container stays as a backup."
    confirm "Continue anyway?" n || return
  fi
  section "What will happen"
  local n=1
  (( was_running )) && { printf '    %d. Stop %s\n' "$n" "$EC_NAME"; n=$((n + 1)); }
  printf '    %d. Rename the old container to %s (kept as a backup)\n' "$n" "$backup"; n=$((n + 1))
  printf '    %d. Create the new container with your changes\n' "$n"; n=$((n + 1))
  printf '    %d. If anything fails, the old container is restored automatically\n\n' "$n"
  show_cmd "${SUDO[@]}" "${EC_RUN[@]}"; echo
  confirm "Apply these changes?" y || return

  rollback() {
    exec_step "Restoring the old container" docker rm -f "$EC_NAME" >/dev/null 2>&1
    exec_step "  rename back" docker rename "$backup" "$EC_NAME"
    (( was_running )) && exec_step "  start again" docker start "$EC_NAME"
    err "Rolled back. Nothing was changed."
  }
  local good=1
  if (( was_running )); then exec_step "Step 1 · Stopping '$EC_NAME'" docker stop "$EC_NAME" || good=0; fi
  if (( good )); then exec_step "Step 2 · Keeping the old container as '$backup'" docker rename "$EC_NAME" "$backup" || { good=0; (( was_running )) && docker start "$EC_NAME" >/dev/null 2>&1; }
    if (( good )); then
      if exec_step "Step 3 · Creating the new container" "${EC_RUN[@]}"; then
        if (( was_running && ! DRY_RUN )); then
          sleep 2
          if [[ $("${SUDO[@]}" docker inspect -f '{{.State.Running}}' "$EC_NAME" 2>/dev/null) != true ]]; then
            err "The new container exited right after starting. Last log lines:"
            "${SUDO[@]}" docker logs --tail 10 "$EC_NAME" 2>&1 | sed 's/^/      /'
            rollback; good=0
          fi
        fi
      else
        rollback; good=0
      fi
    fi
  else
    err "Could not stop the container. Nothing was changed."
  fi
  if (( good )); then
    echo; ok "Done. '$EC_NAME' now has your changes."
    if confirm "Delete the old backup container '$backup' now?" n; then exec_step "Removing backup" docker rm "$backup"
    else info "Kept as '$backup'. Remove it later from Containers > Remove."; fi
    (( DRY_RUN )) || ec_load "$EC_NAME"
  fi
  pause
}

edit_container() {
  pick_container all || return
  if ! ec_load "$PICKED"; then flash "Could not read '$PICKED' (is the name right?)."; return; fi
  local c
  while true; do
    screen "Containers $G_ARR Edit '$EC_NAME'"
    ec_show
    echo
    menu_grid \
      "@CHANGE NOW (instant)" "1|Restart policy" "2|Memory limit" "3|CPU limit" "4|Rename" \
      "@NEEDS REBUILD" "5|Ports" "6|Environment vars" "7|Volumes" \
      "@APPLY" "a|Apply changes" "x|Discard edits" "0|Back"
    prompt_choice; c=$CHOICE
    case $c in
      1) ec_live_restart;;
      2) ec_live_memory;;
      3) ec_live_cpus;;
      4) ec_live_rename;;
      5) ec_edit_list "Ports" EC_PORTS valid_port ec_rows_ports "HOST PORT|CONTAINER PORT|PROTOCOL|BIND IP" "8080:80   or   127.0.0.1:5432:5432   or   53:53/udp" "Format: [ip:]host:container[/tcp|udp], ports 1-65535";;
      6) ec_edit_list "Environment" EC_ENVS valid_env ec_rows_envs "KEY|VALUE" "TZ=Europe/Paris" "Format must be KEY=VALUE";;
      7) ec_edit_list "Volumes" EC_VOLS valid_vol ec_rows_vols "SOURCE|DESTINATION|MODE" "./data:/data   or   mydata:/var/lib/data:ro" "Format: /host/dir:/path or volname:/path[:ro]";;
      a|A) ec_apply;;
      x|X) EC_PORTS=("${EC_PORTS0[@]}"); EC_ENVS=("${EC_ENVS0[@]}"); EC_VOLS=("${EC_VOLS0[@]}"); EC_DIRTY=0; flash "Edits discarded.";;
      0|"") if (( EC_DIRTY )); then confirm "You have unapplied edits. Leave anyway?" n || continue; fi; return;;
      *) flash "Invalid choice.";;
    esac
  done
}

containers_menu() {
  local c
  while true; do
    screen "Containers"
    status_line; echo
    menu_grid \
      "@VIEW" "1|List running" "2|List all" "3|Logs" "4|Inspect details" "5|Live stats" \
      "@CONTROL" "6|Start" "7|Stop" "8|Restart" "9|Pause / Unpause" "10|Open a shell" \
      "@CHANGE" "11|Run new (wizard)" "12|Edit settings" "13|Copy files" "14|Remove" "15|Prune stopped" "0|Back"
    prompt_choice; c=$CHOICE
    case $c in
      1) NOTE="Shows containers that are running right now."
         view_table "NAME|IMAGE|STATUS|PORTS" 3 "docker ps" ps --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}';;
      2) NOTE="Shows every container, running or not."
         view_table "NAME|IMAGE|STATUS|PORTS" 3 "docker ps -a" ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}';;
      3) container_logs;;
      4) container_inspect;;
      5) NOTE="One-time snapshot of CPU, memory and network use of running containers."
         view_table "NAME|CPU|MEMORY|MEM %|NET I/O" 0 "docker stats --no-stream" stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}';;
      6) pick_container all && { NOTE="Starts a stopped container."; run_cmd docker start "$PICKED"; };;
      7) pick_container running && {
           local t cn=$PICKED; echo; ask_valid t "Grace period in seconds" "$RE_INT" "Enter a number." 1 10
           NOTE="Sends SIGTERM, then SIGKILL after the grace period."; run_cmd docker stop -t "$t" "$cn"; };;
      8) pick_container all && { NOTE="Stops and starts the container again."; run_cmd docker restart "$PICKED"; };;
      9) local pm; echo; echo "    1) Pause   2) Unpause"; ask pm "Choose" 1
         if [[ $pm == 2 ]]; then pick_container all && { NOTE="Resumes a paused container."; run_cmd docker unpause "$PICKED"; }
         else pick_container running && { NOTE="Freezes all processes in the container."; run_cmd docker pause "$PICKED"; }; fi;;
      10) container_shell;;
      11) container_run_wizard;;
      12) edit_container;;
      13) container_copy;;
      14) pick_container all && {
            local -a cmd=(docker rm); local rname=$PICKED; echo
            confirm "Force remove even if running (-f)?" n && cmd+=(-f)
            confirm "Also delete its anonymous volumes (-v)?" n && cmd+=(-v)
            NOTE="Deletes the container (not the image)."; run_cmd --danger "${cmd[@]}" "$rname"; };;
      15) NOTE="Removes ALL stopped containers."; run_cmd --danger docker container prune;;
      0|"") return;;
      *) flash "Invalid choice.";;
    esac
  done
}

# ================================================================== IMAGES ==
image_build() {
  screen "Images $G_ARR Build an image"
  local ctx tag file a
  echo
  ask_valid ctx "Build context directory" "$RE_PATH" "Path required." 1 "."
  ask_valid tag "Image name:tag (e.g. myapp:1.0)" "$RE_IMAGE" "Invalid image reference."
  ask file "Dockerfile path (blank = <context>/Dockerfile)"
  local -a cmd=(docker build -t "$tag")
  [[ -n $file ]] && cmd+=(-f "$file")
  confirm "Disable cache (--no-cache)?" n && cmd+=(--no-cache)
  confirm "Always pull newer base images (--pull)?" n && cmd+=(--pull)
  collect_list "Build arg KEY=VALUE" valid_env "Format must be KEY=VALUE"
  for a in "${LIST[@]}"; do cmd+=(--build-arg "$a"); done
  cmd+=("$ctx")
  NOTE="Builds an image from the Dockerfile found in the build context."
  run_cmd "${cmd[@]}"
}

images_menu() {
  local c
  while true; do
    screen "Images"
    status_line; echo
    menu_grid \
      "@VIEW" "1|List images" "2|Search Docker Hub" "3|Layer history" \
      "@GET & BUILD" "4|Pull" "5|Build (wizard)" "6|Tag" "7|Push" \
      "@MOVE & CLEAN" "8|Save to .tar" "9|Load from .tar" "10|Remove" "11|Prune dangling" "12|Prune all unused" "0|Back"
    prompt_choice; c=$CHOICE
    case $c in
      1) NOTE="Lists images stored on this machine."
         view_table "IMAGE|ID|SIZE|CREATED" 0 "docker images" images --format '{{.Repository}}:{{.Tag}}|{{.ID}}|{{.Size}}|{{.CreatedSince}}';;
      2) local term; echo; ask term "Search term"
         [[ -n $term ]] && { NOTE="Searches Docker Hub."
           view_table "NAME|DESCRIPTION|STARS|OFFICIAL" 0 "docker search --limit 15 $term" search --limit 15 --format '{{.Name}}|{{.Description}}|{{.StarCount}}|{{.IsOfficial}}' "$term"; };;
      3) pick_image && { NOTE="Shows how the image was built, layer by layer."
           view_table "CREATED|SIZE|CREATED BY" 0 "docker history $PICKED" history --format '{{.CreatedSince}}|{{.Size}}|{{.CreatedBy}}' "$PICKED"; };;
      4) local img; echo; ask_valid img "Image to pull (e.g. ubuntu:24.04)" "$RE_IMAGE" "Invalid image reference."
         NOTE="Downloads the image from a registry."; run_cmd docker pull "$img";;
      5) image_build;;
      6) pick_image && { local src=$PICKED dst; echo
           ask_valid dst "New name:tag" "$RE_IMAGE" "Invalid image reference."
           NOTE="Adds an additional name/tag to the same image."; run_cmd docker tag "$src" "$dst"; };;
      7) pick_image && { NOTE="Uploads the image to its registry (you must be logged in)."; run_cmd docker push "$PICKED"; };;
      8) pick_image && { local f isrc=$PICKED; echo; ask_valid f "Output file" "$RE_PATH" "Path required." 1 "image.tar"
           NOTE="Exports the image to a tar archive."; run_cmd docker save -o "$f" "$isrc"; };;
      9) local lf; echo; ask_valid lf "Tar file to load" "$RE_PATH" "Path required."
         NOTE="Imports an image from a tar archive."; run_cmd docker load -i "$lf";;
      10) pick_image && { local -a cmd=(docker rmi); local rimg=$PICKED; echo
            confirm "Force remove (-f)?" n && cmd+=(-f)
            NOTE="Deletes the image from this machine."; run_cmd --danger "${cmd[@]}" "$rimg"; };;
      11) NOTE="Removes untagged (<none>) images."; run_cmd --danger docker image prune;;
      12) NOTE="Removes every image not used by a container."; run_cmd --danger docker image prune -a;;
      0|"") return;;
      *) flash "Invalid choice.";;
    esac
  done
}

# ================================================================= VOLUMES ==
volumes_menu() {
  local c
  while true; do
    screen "Volumes"
    status_line; echo
    menu_grid \
      "@VIEW" "1|List volumes" "2|Inspect a volume" \
      "@CHANGE" "3|Create a volume" "4|Remove a volume" \
      "@CLEAN UP" "5|Prune unused" "0|Back"
    prompt_choice; c=$CHOICE
    case $c in
      1) NOTE="Lists named volumes."
         view_table "NAME|DRIVER|SCOPE" 0 "docker volume ls" volume ls --format '{{.Name}}|{{.Driver}}|{{.Scope}}';;
      2) pick_volume && { NOTE="Shows mountpoint, driver and labels."; run_view docker volume inspect "$PICKED"; };;
      3) local n lbl; echo; ask_valid n "Volume name" "$RE_NAME" "Use letters, digits, _ . -"
         local -a cmd=(docker volume create)
         ask lbl "Label KEY=VALUE (optional)"
         [[ -n $lbl ]] && { if valid_env "$lbl"; then cmd+=(--label "$lbl"); else warn "Ignoring invalid label."; fi; }
         NOTE="Creates persistent storage managed by Docker."; run_cmd "${cmd[@]}" "$n";;
      4) pick_volume && { NOTE="Deletes the volume and ALL data in it."; run_cmd --danger docker volume rm "$PICKED"; };;
      5) NOTE="Removes every volume not used by any container."; run_cmd --danger docker volume prune;;
      0|"") return;;
      *) flash "Invalid choice.";;
    esac
  done
}

# ================================================================ NETWORKS ==
network_create() {
  screen "Networks $G_ARR Create a network"
  local n drv subnet gw d; echo
  ask_valid n "Network name" "$RE_NAME" "Use letters, digits, _ . -"
  echo "    1) bridge   2) overlay   3) macvlan   4) ipvlan"
  ask d "Driver" 1
  case $d in 2) drv=overlay;; 3) drv=macvlan;; 4) drv=ipvlan;; *) drv=bridge;; esac
  local -a cmd=(docker network create -d "$drv")
  ask_valid subnet "Subnet CIDR, e.g. 172.28.0.0/16 (blank = auto)" "$RE_CIDR" "Format: a.b.c.d/nn" 0
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
    screen "Networks"
    status_line; echo
    menu_grid \
      "@VIEW" "1|List networks" "2|Inspect a network" \
      "@CHANGE" "3|Create a network" "4|Connect container" "5|Disconnect container" \
      "@CLEAN UP" "6|Remove a network" "7|Prune unused" "0|Back"
    prompt_choice; c=$CHOICE
    case $c in
      1) NOTE="Lists Docker networks."
         view_table "NAME|DRIVER|SCOPE|ID" 0 "docker network ls" network ls --format '{{.Name}}|{{.Driver}}|{{.Scope}}|{{.ID}}';;
      2) pick_network && { NOTE="Shows subnet, gateway and attached containers."; run_view docker network inspect "$PICKED"; };;
      3) network_create;;
      4) pick_network && { local nw=$PICKED; pick_container all && {
           local -a cmd=(docker network connect); local ct=$PICKED ip; echo
           ask_valid ip "Static IP (blank = automatic)" "$RE_IP" "Enter a valid IPv4 address." 0
           [[ -n $ip ]] && cmd+=(--ip "$ip")
           NOTE="Attaches a container to the network."; run_cmd "${cmd[@]}" "$nw" "$ct"; }; };;
      5) pick_network && { local nw2=$PICKED; pick_container all && {
           NOTE="Detaches a container from the network."; run_cmd docker network disconnect "$nw2" "$PICKED"; }; };;
      6) pick_network && { NOTE="Deletes the network (must have no containers attached)."; run_cmd --danger docker network rm "$PICKED"; };;
      7) NOTE="Removes all networks not used by containers."; run_cmd --danger docker network prune;;
      0|"") return;;
      *) flash "Invalid choice.";;
    esac
  done
}

# ================================================================= COMPOSE ==
compose_select_file() {
  COMPOSE_FILE_ARG=()
  local f
  for f in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
    [[ -f $f ]] && return 0
  done
  echo; warn "No compose file found in $(pwd)."
  local p; ask p "Path to compose file (blank = cancel)"
  [[ -z $p ]] && return 1
  if [[ ! -f $p ]] && (( ! DRY_RUN )); then err "File not found: $p"; pause; return 1; fi
  COMPOSE_FILE_ARG=(-f "$p")
}

compose_menu() {
  detect_compose
  if (( ${#COMPOSE[@]} == 0 )); then flash "Docker Compose is not installed."; return; fi
  compose_select_file || return
  local c svc
  while true; do
    screen "Compose"
    printf '\n  %s%s %s in %s%s\n\n' "$C_DIM" "${COMPOSE[*]}" "${COMPOSE_FILE_ARG[*]:-(auto-detected file)}" "$(pwd)" "$C_RST"
    menu_grid \
      "@RUN" "1|Up (detached)" "2|Up + rebuild" "3|Down" "4|Down + volumes" "5|Restart" "6|Stop" "7|Start" \
      "@INSPECT" "8|Status" "9|Logs" "10|Merged config" "11|Shell in service" \
      "@IMAGES" "12|Build" "13|Pull" "0|Back"
    prompt_choice; c=$CHOICE
    local -a base=("${COMPOSE[@]}" "${COMPOSE_FILE_ARG[@]}")
    case $c in
      1) NOTE="Creates and starts all services in the background."; run_cmd "${base[@]}" up -d;;
      2) NOTE="Rebuilds images, then (re)creates the services."; run_cmd "${base[@]}" up -d --build;;
      3) NOTE="Stops and removes containers and networks (volumes are kept)."; run_cmd --danger "${base[@]}" down;;
      4) NOTE="Same as 'down', but ALSO deletes named volumes. Data is lost."; run_cmd --danger "${base[@]}" down -v;;
      5) echo; ask svc "Service (blank = all)"; NOTE="Restarts containers."; run_cmd "${base[@]}" restart ${svc:+"$svc"};;
      6) echo; ask svc "Service (blank = all)"; NOTE="Stops containers without removing them."; run_cmd "${base[@]}" stop ${svc:+"$svc"};;
      7) echo; ask svc "Service (blank = all)"; NOTE="Starts existing containers."; run_cmd "${base[@]}" start ${svc:+"$svc"};;
      8) NOTE="Shows the state of each service."
         if [[ ${COMPOSE[0]} == docker && ${COMPOSE[1]:-} == compose ]]; then
           view_table "SERVICE|CONTAINER|STATUS" 3 "${base[*]} ps" "${base[@]:1}" ps -a --format '{{.Service}}|{{.Name}}|{{.Status}}'
         else run_view "${base[@]}" ps; fi;;
      9) echo; ask svc "Service (blank = all)"
         local -a cmd=("${base[@]}" logs --tail 100)
         confirm "Follow live output (Ctrl+C to stop)?" n && cmd+=(-f)
         [[ -n $svc ]] && cmd+=("$svc")
         NOTE="Prints service logs."; run_view "${cmd[@]}";;
      10) NOTE="Validates the file and prints the resolved configuration."; run_view "${base[@]}" config;;
      11) echo; ask_valid svc "Service name" "$RE_NAME" "Invalid service name."
          NOTE="Opens a shell inside a running service container."
          run_cmd "${base[@]}" exec "$svc" sh -c 'command -v bash >/dev/null 2>&1 && exec bash || exec sh';;
      12) NOTE="Builds images for services that have a build section."; run_cmd "${base[@]}" build;;
      13) NOTE="Downloads the latest images for all services."; run_cmd "${base[@]}" pull;;
      0|"") return;;
      *) flash "Invalid choice.";;
    esac
  done
}

# ================================================================== SYSTEM ==
system_menu() {
  local c
  while true; do
    screen "System & cleanup"
    status_line; echo
    menu_grid \
      "@VIEW" "1|Disk usage" "2|Docker info" "3|Docker version" "4|Live events" \
      "@CLEAN UP" "5|Prune (safe)" "6|Prune everything" \
      "@ACCOUNT" "7|Registry login" "8|Registry logout" "0|Back"
    prompt_choice; c=$CHOICE
    case $c in
      1) NOTE="Shows how much space images, containers and volumes use."
         view_table "TYPE|TOTAL|ACTIVE|SIZE|RECLAIMABLE" 0 "docker system df" system df --format '{{.Type}}|{{.TotalCount}}|{{.Active}}|{{.Size}}|{{.Reclaimable}}';;
      2) run_view docker info;;
      3) run_view docker version;;
      4) NOTE="Streams Docker daemon events until you press Ctrl+C."; run_view docker events;;
      5) NOTE="Removes stopped containers, unused networks, dangling images and build cache."; run_cmd --danger docker system prune;;
      6) NOTE="Aggressive: also removes ALL unused images AND volumes."; run_cmd --danger docker system prune -a --volumes;;
      7|8) local srv; echo; ask srv "Registry (blank = Docker Hub)"
          if [[ $c == 8 ]]; then run_cmd docker logout ${srv:+"$srv"}; else run_cmd docker login ${srv:+"$srv"}; fi;;
      0|"") return;;
      *) flash "Invalid choice.";;
    esac
  done
}

# ================================================================ FAVORITES ==
favorites_menu() {
  local c
  while true; do
    screen "Saved favorites"
    echo
    if [[ ! -s $SAVED_FILE ]]; then
      printf '  %sNothing saved yet. After running a command, answer "y" to "Save this to your favorites?".%s\n' "$C_DIM" "$C_RST"
      pause; return
    fi
    local -a labels=() cmds=(); local l cm
    while IFS=$'\t' read -r l cm; do
      [[ -z $l ]] && continue
      labels+=("$l"); cmds+=("$cm")
    done < "$SAVED_FILE"
    local i; for i in "${!labels[@]}"; do printf '%s|%s\n' "${labels[i]//|/¦}" "${cmds[i]//|/¦}"; done | table_draw "LABEL|COMMAND" 1 0
    printf '\n  %sr N%s run     %sd N%s delete     %s0%s back          %s(example: r 2)%s\n' "$C_CYAN" "$C_RST" "$C_CYAN" "$C_RST" "$C_CYAN" "$C_RST" "$C_DIM" "$C_RST"
    prompt_choice; c=$CHOICE
    if [[ $c =~ ^([rd])[[:space:]]*([0-9]+)$ ]]; then
      local verb=${BASH_REMATCH[1]} n=${BASH_REMATCH[2]}
      if (( n < 1 || n > ${#cmds[@]} )); then flash "Number out of range."; continue; fi
      if [[ $verb == r ]]; then
        local -a arr; eval "arr=(${cmds[n-1]})"
        NO_SAVE_PROMPT=1; run_cmd "${arr[@]}"; NO_SAVE_PROMPT=0
      else
        echo; if confirm "Delete '${labels[n-1]}'?" n; then
          awk -v k="$n" 'NR!=k' "$SAVED_FILE" > "$SAVED_FILE.tmp" && mv "$SAVED_FILE.tmp" "$SAVED_FILE"
          flash "Deleted."
        fi
      fi
    elif [[ $c == 0 || -z $c ]]; then return
    else flash "Use r N, d N or 0."; fi
  done
}

view_log() {
  screen "Activity log"
  printf '\n  %s%s%s\n\n' "$C_DIM" "$LOG_FILE" "$C_RST"
  if [[ -s $LOG_FILE ]]; then
    local line
    tail -n $((TERM_ROWS > 30 ? 20 : 12)) "$LOG_FILE" | while IFS= read -r line; do
      if [[ $line =~ ^([0-9-]+\ [0-9:]+)\ \[([A-Z]+)\]\ (.*)$ ]]; then
        printf '%s|%s|%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]//|/¦}"
      fi
    done | table_draw "TIME|TYPE|COMMAND" 0 0
  else info "The log is empty."; fi
  pause
}

cheat_sheet() {
  screen "Cheat sheet"
  echo
  cat <<'EOF' | table_draw "COMMAND|WHAT IT DOES" 0 0
docker ps [-a]|List containers (running / all)
docker run -d -p 8080:80 nginx|Start a container in the background
docker exec -it NAME bash|Open a shell inside a container
docker logs -f NAME|Follow container logs
docker stop / start / restart NAME|Control a container
docker update --restart always NAME|Change restart policy live
docker rm [-f] NAME|Delete a container
docker images / pull / rmi|Manage images
docker build -t name:tag .|Build an image from a Dockerfile
docker volume ls / create / rm|Manage persistent data
docker network ls / create|Manage networks
docker compose up -d / down|Run multi-container apps
docker system df / prune|See usage / clean up
EOF
  pause
}

# ================================================================ MAIN MENU ==
usage() {
  cat <<EOF
Docker Command Helper v$VERSION
Usage: $(basename "$0") [options]
  -n, --dry-run    Show the commands but never execute them
      --no-clear   Do not clear the terminal between screens
  -v, --version    Print version
  -h, --help       Show this help
Env: DH_KEEP_SCROLLBACK=1 keeps terminal scrollback when clearing.
Files: log -> $LOG_FILE   favorites -> $SAVED_FILE
EOF
}

main_menu() {
  local c
  while true; do
    screen ""
    dash_panel
    dash_running
    echo
    menu_grid \
      "@MANAGE" "1|Containers" "2|Images" "3|Volumes" "4|Networks" \
      "@TOOLS" "5|Compose" "6|System & cleanup" "7|Cheat sheet" \
      "@HELPER" "8|Saved favorites" "9|Activity log" "0|Exit"
    prompt_choice; c=$CHOICE
    case $c in
      1) containers_menu;; 2) images_menu;; 3) volumes_menu;; 4) networks_menu;;
      5) compose_menu;; 6) system_menu;; 7) cheat_sheet;; 8) favorites_menu;; 9) view_log;;
      0|q|Q) info "Bye!"; exit 0;;
      *) flash "Invalid choice.";;
    esac
  done
}

# ================================================================== START ====
for arg in "$@"; do
  case $arg in
    -n|--dry-run)  DRY_RUN=1;;
    --no-clear)    NO_CLEAR=1;;
    -v|--version)  echo "docker-helper $VERSION"; exit 0;;
    -h|--help)     usage; exit 0;;
    *) echo "Unknown option: $arg" >&2; usage; exit 2;;
  esac
done

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
  echo "Bash 4.3+ is required (you have $BASH_VERSION). On macOS: brew install bash" >&2; exit 1
fi

trap 'echo; info "Bye."; exit 0' INT
setup_docker
log START "docker-helper $VERSION (dry-run=$DRY_RUN)"
main_menu
