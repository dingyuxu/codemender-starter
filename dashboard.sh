#!/usr/bin/env bash
# Starts, stops or refreshes the local dashboard of one repository.
# Run it inside the repository:
#
#   bash /path/to/codemender-starter/dashboard.sh serve [--port N] [--no-open]
#   bash /path/to/codemender-starter/dashboard.sh stop
#   bash /path/to/codemender-starter/dashboard.sh refresh
#   bash /path/to/codemender-starter/dashboard.sh status
#
# The dashboard is a read-only page served on this machine only (127.0.0.1).
# Its data lives in <git dir>/codemender/dashboard/ and never enters a commit.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

cmd="${1:-status}"
[ $# -gt 0 ] && shift
want_port=""
open_page=1
while [ $# -gt 0 ]; do
  case "$1" in
    --port)     [ $# -ge 2 ] || die "--port needs a number."; want_port="$2"; shift 2 ;;
    --port=*)   want_port="${1#*=}"; shift ;;
    --no-open)  open_page=0; shift ;;
    -h | --help) usage; exit 0 ;;
    *)          usage >&2; die "Unknown option: $1" ;;
  esac
done

repo_root="$(git rev-parse --show-toplevel 2> /dev/null)" || die "Run this inside the git repository."
cd "$repo_root" || die "Cannot enter $repo_root"
dash_dir="$(git rev-parse --absolute-git-dir)/codemender/dashboard"
pid_file="$dash_dir/server.pid"
port_file="$dash_dir/server.port"
log_file="$dash_dir/server.log"
bind="${CODEMENDER_DASHBOARD_BIND:-127.0.0.1}"
exporter="$KIT_DIR/dashboard/export.py"

command -v python3 > /dev/null 2>&1 || die "The dashboard needs python3."

running() {
  [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2> /dev/null
}

port_in_use() {
  (exec 3<> "/dev/tcp/127.0.0.1/$1") 2> /dev/null
}

show_url() {
  local port="$1"
  say "Dashboard: http://localhost:$port"
  if [ -n "${SSH_CONNECTION:-}" ]; then
    say "  This looks like a remote machine. To open the page on your own computer, run this there first:"
    say "    ssh -N -L $port:127.0.0.1:$port $(hostname -f 2> /dev/null || hostname)"
  fi
}

case "$cmd" in
  serve)
    if running; then
      say "The dashboard is already running."
      show_url "$(cat "$port_file" 2> /dev/null || echo 8787)"
      exit 0
    fi
    port="$want_port"
    [ -n "$port" ] || port="$(git config --get codemender.dashboardPort 2> /dev/null || true)"
    [ -n "$port" ] || port=8787
    tries=0
    while port_in_use "$port"; do
      port=$(( port + 1 ))
      tries=$(( tries + 1 ))
      [ "$tries" -le 20 ] || die "No free port found near $port."
    done
    mkdir -p "$dash_dir/data"
    python3 "$exporter" health > /dev/null || true
    python3 "$exporter" refresh --quiet || true
    nohup python3 "$KIT_DIR/dashboard/serve.py" --repo "$repo_root" --dash-dir "$dash_dir" \
      --port "$port" --bind "$bind" > "$log_file" 2>&1 &
    echo $! > "$pid_file"
    echo "$port" > "$port_file"
    sleep 1
    running || die "The dashboard did not start. See $log_file"
    git config --local codemender.dashboardPort "$port"
    show_url "$port"
    if [ "$open_page" -eq 1 ] && [ -z "${SSH_CONNECTION:-}" ]; then
      if [ "$(uname -s)" = "Darwin" ]; then
        open "http://localhost:$port" > /dev/null 2>&1 || true
      elif [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v xdg-open > /dev/null 2>&1; then
        xdg-open "http://localhost:$port" > /dev/null 2>&1 || true
      fi
    fi
    ;;
  stop)
    if running; then
      kill "$(cat "$pid_file")" 2> /dev/null || true
      say "Dashboard stopped."
    else
      say "The dashboard is not running."
    fi
    rm -f "$pid_file" "$port_file"
    ;;
  refresh)
    mkdir -p "$dash_dir/data"
    say "Health check: $(python3 "$exporter" health)"
    python3 "$exporter" refresh
    ;;
  status)
    if running; then
      say "The dashboard is running."
      show_url "$(cat "$port_file" 2> /dev/null || echo 8787)"
    else
      say "The dashboard is not running. Start it with: bash $KIT_DIR/dashboard.sh serve"
    fi
    ;;
  -h | --help | help)
    usage
    ;;
  *)
    usage >&2
    die "Unknown command: $cmd"
    ;;
esac
