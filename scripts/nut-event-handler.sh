#!/bin/bash
# Generic NUT event dispatcher. Final host shutdown belongs to PVE-UPS.
set -u

EVENT="${NOTIFYTYPE:-unknown}"
LOGGER_TAG="nut-event"

logger -t "$LOGGER_TAG" -- "Received NUT event: ${EVENT}"

case "$EVENT" in
    ONBATT)
        logger -t "$LOGGER_TAG" -- "Stage 1 timer requested: 600 seconds."
        ;;
    ONLINE)
        logger -t "$LOGGER_TAG" -- "Stage 1 timer cancellation requested."
        ;;
esac

/usr/sbin/upssched
exit 0
