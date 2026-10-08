#!/bin/bash
# Gracefully shut down all running Proxmox guests with the exact tag "ups-aware".
# Default is dry-run. Real shutdown requires --execute. No hard-stop is used.
set -u

TAG="ups-aware"
LOGGER_TAG="ups-stage1"
SHUTDOWN_TIMEOUT=300
MODE="dry-run"

case "${1:-}" in
    ""|--dry-run) MODE="dry-run" ;;
    --execute) MODE="execute" ;;
    *) echo "Usage: $0 [--dry-run|--execute]" >&2; exit 2 ;;
esac

log() {
    local message="$*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $message"
    logger -t "$LOGGER_TAG" -- "$message"
}

has_tag() {
    local config="$1" tags
    tags="$(sed -n 's/^tags:[[:space:]]*//p' "$config" | head -n 1)"
    [[ ";${tags};" == *";${TAG};"* ]]
}

shutdown_qemu() {
    local vmid="$1" name="$2"
    log "QEMU ${vmid} (${name}): requesting graceful shutdown."
    if qm shutdown "$vmid" --timeout "$SHUTDOWN_TIMEOUT" --forceStop 0; then
        log "QEMU ${vmid} (${name}): stopped gracefully."
    else
        log "ERROR: QEMU ${vmid} (${name}): still running or shutdown failed after ${SHUTDOWN_TIMEOUT}s. NO hard-stop performed."
    fi
}

shutdown_lxc() {
    local vmid="$1" hostname="$2"
    log "LXC ${vmid} (${hostname}): requesting graceful shutdown."
    if pct shutdown "$vmid" --timeout "$SHUTDOWN_TIMEOUT" --forceStop 0; then
        log "LXC ${vmid} (${hostname}): stopped gracefully."
    else
        log "ERROR: LXC ${vmid} (${hostname}): still running or shutdown failed after ${SHUTDOWN_TIMEOUT}s. NO hard-stop performed."
    fi
}

tagged=0
candidates=0
pids=()
log "Stage 1 started. Mode=${MODE}; tag=${TAG}; timeout=${SHUTDOWN_TIMEOUT}s."

for config in /etc/pve/qemu-server/*.conf; do
    [[ -e "$config" ]] || continue
    has_tag "$config" || continue
    tagged=$((tagged + 1))
    vmid="$(basename "$config" .conf)"
    name="$(sed -n 's/^name:[[:space:]]*//p' "$config" | head -n 1)"
    [[ -n "$name" ]] || name="unknown"
    status="$(qm status "$vmid" 2>/dev/null | awk '{print $2}')"
    if [[ "$status" != "running" ]]; then
        log "QEMU ${vmid} (${name}): ${status:-unknown}, skipped."
        continue
    fi
    candidates=$((candidates + 1))
    if [[ "$MODE" == "dry-run" ]]; then
        log "QEMU ${vmid} (${name}): running, WOULD request graceful shutdown."
    else
        shutdown_qemu "$vmid" "$name" &
        pids+=("$!")
    fi
done

for config in /etc/pve/lxc/*.conf; do
    [[ -e "$config" ]] || continue
    has_tag "$config" || continue
    tagged=$((tagged + 1))
    vmid="$(basename "$config" .conf)"
    hostname="$(sed -n 's/^hostname:[[:space:]]*//p' "$config" | head -n 1)"
    [[ -n "$hostname" ]] || hostname="unknown"
    status="$(pct status "$vmid" 2>/dev/null | awk '{print $2}')"
    if [[ "$status" != "running" ]]; then
        log "LXC ${vmid} (${hostname}): ${status:-unknown}, skipped."
        continue
    fi
    candidates=$((candidates + 1))
    if [[ "$MODE" == "dry-run" ]]; then
        log "LXC ${vmid} (${hostname}): running, WOULD request graceful shutdown."
    else
        shutdown_lxc "$vmid" "$hostname" &
        pids+=("$!")
    fi
done

log "Stage 1 dispatch complete. Tagged=${tagged}; running candidates=${candidates}."

if [[ "$MODE" == "execute" && "${#pids[@]}" -gt 0 ]]; then
    log "Waiting for ${#pids[@]} parallel graceful shutdown operation(s)."
    wait
    log "Stage 1 shutdown operations completed. No hard-stop was performed."
fi

exit 0
