#!/usr/bin/env bash

set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

find_bin() {
  local name="$1"
  local path

  if path="$(command -v "$name" 2>/dev/null)"; then
    printf '%s\n' "$path"
    return 0
  fi

  for path in \
    "/usr/bin/$name" \
    "/bin/$name" \
    "/usr/local/bin/$name" \
    "/opt/cloudflare-warp/bin/$name"
  do
    if [ -x "$path" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  done

  return 1
}

cleanup() {
  local exit_code=$?

  if [ -n "${WARP_SVC_PID:-}" ] && kill -0 "$WARP_SVC_PID" 2>/dev/null; then
    kill "$WARP_SVC_PID" 2>/dev/null || true
    wait "$WARP_SVC_PID" 2>/dev/null || true
  fi

  if [ -n "${DBUS_PID:-}" ] && kill -0 "$DBUS_PID" 2>/dev/null; then
    kill "$DBUS_PID" 2>/dev/null || true
    wait "$DBUS_PID" 2>/dev/null || true
  fi

  exit "$exit_code"
}

trap cleanup EXIT INT TERM

mkdir -p /var/run/dbus /var/lib/cloudflare-warp
rm -f /run/dbus/pid /var/run/dbus/pid

dbus-daemon --system --fork --nopidfile
DBUS_PID="$(pgrep -xo dbus-daemon || true)"
[ -n "$DBUS_PID" ] || die "Failed to start dbus-daemon"
log "Started dbus-daemon (pid=$DBUS_PID)"

WARP_CLI_BIN="$(find_bin warp-cli)" || die "warp-cli not found"
WARP_SVC_BIN="$(find_bin warp-svc)" || die "warp-svc not found"

if [ ! -c /dev/net/tun ]; then
  die "/dev/net/tun is missing. Run the container with --device /dev/net/tun:/dev/net/tun"
fi

if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || printf '0')" != "1" ]; then
  log "net.ipv4.ip_forward is not enabled inside the container namespace"
  log "Run with --sysctl net.ipv4.ip_forward=1 or the equivalent Compose setting"
fi

"$WARP_SVC_BIN" &
WARP_SVC_PID=$!
log "Started warp-svc (pid=$WARP_SVC_PID)"

warp_cli() {
  if "$WARP_CLI_BIN" --help 2>&1 | grep -q -- '--accept-tos'; then
    "$WARP_CLI_BIN" --accept-tos "$@"
  else
    "$WARP_CLI_BIN" "$@"
  fi
}

wait_for_warp_cli() {
  local attempt

  for attempt in $(seq 1 30); do
    if warp_cli status >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  return 1
}

wait_for_connected() {
  local attempt
  local status_output

  for attempt in $(seq 1 60); do
    status_output="$(warp_cli status 2>&1 || true)"
    if printf '%s' "$status_output" | grep -qi 'Connected'; then
      log "WARP reports connected"
      return 0
    fi
    sleep 2
  done

  log "Timed out waiting for WARP to connect"
  warp_cli status || true
  return 1
}

wait_for_warp_cli || die "warp-cli could not talk to warp-svc"

if [ -n "${WARP_CONNECTOR_TOKEN:-}" ]; then
  if warp_cli registration show >/dev/null 2>&1; then
    log "Existing WARP registration found; skipping connector enrollment"
  else
    log "Enrolling connector"
    warp_cli connector new "$WARP_CONNECTOR_TOKEN"
  fi

  if [ "${WARP_AUTO_CONNECT:-true}" = "true" ]; then
    log "Connecting WARP"
    warp_cli connect
  fi
fi

if [ "${WARP_WAIT_FOR_CONNECT:-true}" = "true" ] && [ "${WARP_AUTO_CONNECT:-true}" = "true" ] && [ -n "${WARP_CONNECTOR_TOKEN:-}" ]; then
  wait_for_connected
fi

if [ "$#" -gt 0 ]; then
  exec "$@"
fi

wait "$WARP_SVC_PID"
