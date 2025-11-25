#!/bin/bash
#
# Example: Start a service and maintain heartbeat
#
# This script demonstrates how to:
# 1. Register a service when it starts
# 2. Maintain a heartbeat while running
# 3. Clean up on exit
#

set -e

# Configuration
SERVICE_TYPE="inference"
HOST=$(hostname -i 2>/dev/null || echo "127.0.0.1")
PORT=${PORT:-8000}
SERVICE_ID="${SERVICE_TYPE}-$(hostname)-$$"
HEARTBEAT_INTERVAL=10  # seconds
REDIS_HOST=${REDIS_HOST:-localhost}
REDIS_PORT=${REDIS_PORT:-6379}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*" >&2
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $*"
}

# Cleanup function
cleanup() {
    log "Shutting down..."
    
    # Update status to stopping
    python3 cli.py --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" \
        update-health "$SERVICE_ID" --status stopping 2>/dev/null || true
    
    # Kill the background service if it's still running
    if [ -n "$SERVICE_PID" ] && kill -0 "$SERVICE_PID" 2>/dev/null; then
        log "Stopping service process (PID: $SERVICE_PID)..."
        kill "$SERVICE_PID" 2>/dev/null || true
        wait "$SERVICE_PID" 2>/dev/null || true
    fi
    
    # Kill heartbeat loop if running
    if [ -n "$HEARTBEAT_PID" ] && kill -0 "$HEARTBEAT_PID" 2>/dev/null; then
        kill "$HEARTBEAT_PID" 2>/dev/null || true
    fi
    
    # Deregister service
    log "Deregistering service: $SERVICE_ID"
    python3 cli.py --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" \
        deregister "$SERVICE_ID" || warn "Failed to deregister service"
    
    log "Cleanup complete"
}

# Set up signal handlers
trap cleanup EXIT INT TERM

# Change to script directory
cd "$(dirname "$0")"

# Check if Redis is accessible
log "Checking Redis connection..."
if ! python3 -c "import redis; r=redis.Redis(host='$REDIS_HOST', port=$REDIS_PORT); r.ping()" 2>/dev/null; then
    error "Cannot connect to Redis at $REDIS_HOST:$REDIS_PORT"
    exit 1
fi
log "Redis connection OK"

# Register service
log "Registering service: $SERVICE_ID"
log "  Type: $SERVICE_TYPE"
log "  Host: $HOST"
log "  Port: $PORT"

METADATA='{"node":"'$(hostname)'","pid":'$$',"model":"llama-3"}'

if ! python3 cli.py --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" \
    register "$SERVICE_ID" \
    --host "$HOST" \
    --port "$PORT" \
    --service-type "$SERVICE_TYPE" \
    --status starting \
    --metadata "$METADATA"; then
    error "Failed to register service"
    exit 1
fi

log "Service registered successfully"

# Start the actual service (simulated with sleep in this example)
log "Starting service process..."
# Replace this with your actual service command:
# ./start_vllm.sh &
sleep infinity &
SERVICE_PID=$!

log "Service process started (PID: $SERVICE_PID)"

# Wait a bit for service to initialize
sleep 2

# Update status to healthy
log "Updating service status to healthy..."
python3 cli.py --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" \
    update-health "$SERVICE_ID" --status healthy

# Start heartbeat loop in background
log "Starting heartbeat monitor (interval: ${HEARTBEAT_INTERVAL}s)..."
(
    while true; do
        if kill -0 "$SERVICE_PID" 2>/dev/null; then
            python3 cli.py --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" \
                heartbeat "$SERVICE_ID" --quiet || warn "Heartbeat failed"
        else
            warn "Service process no longer running"
            break
        fi
        sleep "$HEARTBEAT_INTERVAL"
    done
) &
HEARTBEAT_PID=$!

log "Service is running. Press Ctrl+C to stop."
log "Service ID: $SERVICE_ID"
log "Monitor with: python3 cli.py --redis-host $REDIS_HOST get $SERVICE_ID"

# Wait for the service process
wait "$SERVICE_PID"
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
    error "Service process exited with code $EXIT_CODE"
    # Update status to unhealthy before cleanup
    python3 cli.py --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" \
        update-health "$SERVICE_ID" --status unhealthy 2>/dev/null || true
fi

exit $EXIT_CODE

