# Service Registry Quick Start Guide

## Overview

This library provides Redis-based service registry and health tracking for distributed systems. It's designed to work both as a Python library and through shell commands.

## Prerequisites

1. **Redis Server**: You need a running Redis instance
   ```bash
   # Check if Redis is running
   redis-cli ping
   # Should return: PONG
   ```

2. **Python Dependencies**:
   ```bash
   pip install -r requirements.txt
   ```

   **Aurora-Inferencing**:
   ```
   PKGDIR=/tmp/redis_env
   python3 -m pip install --target "$PKGDIR" -r requirements.txt
   export PYTHONPATH="$PKGDIR:$PYTHONPATH"
   ```

## 5-Minute Tutorial

### 1. Basic Usage from Shell

```bash
# Navigate to the redis directory
cd /Users/brettin/github/Aurora-Inferencing/redis

# Register a service
./service-registry register my-service-001 \
    --host 10.0.0.1 \
    --port 8000 \
    --service-type inference \
    --metadata '{"model": "llama-3", "gpu": "A100"}'

# List all services
./service-registry list

# Get specific service info
./service-registry get my-service-001

# Send heartbeat
./service-registry heartbeat my-service-001

# Update health status
./service-registry update-health my-service-001 --status healthy

# List only healthy services
./service-registry list-healthy

# Deregister when done
./service-registry deregister my-service-001
```

### 2. Basic Usage from Python

```python
from service_registry import ServiceRegistry, ServiceInfo, ServiceStatus

# Initialize registry
registry = ServiceRegistry(redis_host='localhost', redis_port=6379)

# Register a service
service = ServiceInfo(
    service_id="my-service-001",
    host="10.0.0.1",
    port=8000,
    service_type="inference",
    metadata={"model": "llama-3", "gpu": "A100"}
)
registry.register_service(service)

# List all services
services = registry.list_services()
for s in services:
    print(f"{s.service_id}: {s.host}:{s.port} - {s.status}")

# Send heartbeat
registry.heartbeat("my-service-001")

# Get healthy services
healthy = registry.get_healthy_services(timeout_seconds=30)

# Cleanup
registry.deregister_service("my-service-001")
```

### 3. Run Examples

```bash
# Run Python examples
./example_usage.py

# Test the library
./test_registry.py
```

### 4. Real-World Service Integration

The `example_service.sh` shows how to integrate service registration into your actual service startup:

```bash
# Start a service with automatic registration and heartbeat
./example_service.sh

# The script will:
# 1. Register the service on startup
# 2. Send periodic heartbeats
# 3. Deregister on exit (even with Ctrl+C)
```

## Common Use Cases

### Use Case 1: Service Discovery for Load Balancing

```python
# Get all healthy inference nodes
registry = ServiceRegistry()
nodes = registry.get_healthy_services(service_type="inference")

# Pick one for load balancing
import random
selected = random.choice(nodes)
endpoint = f"http://{selected.host}:{selected.port}"
```

### Use Case 2: Health Monitoring Dashboard

```bash
# Monitor services in real-time
watch -n 2 './service-registry list --format json | jq .'

# Count services by type
./service-registry types | while read type; do
    count=$(./service-registry count --service-type $type)
    echo "$type: $count"
done
```

### Use Case 3: Auto-scaling Decision

```python
# Check if we need more workers
worker_count = registry.get_service_count(service_type="worker")
if worker_count < MIN_WORKERS:
    spawn_new_worker()
```

### Use Case 4: Periodic Cleanup (Cron Job)

```bash
# Add to crontab to cleanup stale services every 5 minutes
*/5 * * * * cd /path/to/redis && ./service-registry cleanup --timeout 300
```

## Shell Integration Examples

### Example 1: Register on Startup, Deregister on Exit

```bash
#!/bin/bash
SERVICE_ID="my-service-$$"

# Register
./service-registry register "$SERVICE_ID" \
    --host $(hostname -i) \
    --port 8000 \
    --service-type worker

# Ensure cleanup on exit
trap './service-registry deregister "$SERVICE_ID"' EXIT

# Your service logic here
while true; do
    # Do work...
    sleep 1
    
    # Send heartbeat every 10 iterations
    if [ $((RANDOM % 10)) -eq 0 ]; then
        ./service-registry heartbeat "$SERVICE_ID" --quiet
    fi
done
```

### Example 2: Find and Connect to a Service

```bash
#!/bin/bash
# Find a healthy inference service and make a request

# Get healthy services as JSON
SERVICES=$(./service-registry list-healthy \
    --service-type inference \
    --format json)

# Extract first service endpoint
HOST=$(echo "$SERVICES" | jq -r '.[0].host')
PORT=$(echo "$SERVICES" | jq -r '.[0].port')

# Make request
curl -X POST "http://$HOST:$PORT/v1/completions" \
    -H "Content-Type: application/json" \
    -d '{"prompt": "Hello", "max_tokens": 100}'
```

### Example 3: Batch Register Multiple Services

```bash
#!/bin/bash
# Register multiple services from a config file

# Format: service_id,host,port,type
cat services.txt | while IFS=, read -r id host port type; do
    ./service-registry register "$id" \
        --host "$host" \
        --port "$port" \
        --service-type "$type"
done
```

## Configuration Options

### Redis Connection

```bash
# Use environment variables
export REDIS_HOST=redis.example.com
export REDIS_PORT=6380

# Or pass as arguments
./service-registry --redis-host redis.example.com --redis-port 6380 list
```

### Key Prefix (for multi-tenancy)

```bash
# Production environment
./service-registry --key-prefix "prod:" list

# Staging environment
./service-registry --key-prefix "staging:" list
```

## Troubleshooting

### Redis Connection Failed

```bash
# Check if Redis is running
redis-cli ping

# Check Redis is accessible
telnet localhost 6379
```

### Service Not Found

```bash
# List all services to verify
./service-registry list

# Check service types
./service-registry types
```

### Stale Services

```bash
# Clean up services that haven't sent heartbeat in 5 minutes
./service-registry cleanup --timeout 300
```

## Next Steps

1. **Job Queue** (coming soon): Centralized job queue with Redis lists/streams
2. **Result Collection** (coming soon): Async API for result storage and retrieval

## Reference

- Full documentation: `README.md`
- API reference: See docstrings in `service_registry.py`
- Examples: `example_usage.py`
- Tests: `test_registry.py`

