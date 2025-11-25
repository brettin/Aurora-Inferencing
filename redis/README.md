# Redis Service Infrastructure Library

A Python library for managing distributed services using Redis, providing service registry, health tracking, job queuing, and result collection.

## Features

### 1. Service Registry & Health Tracking ✅

Uses Redis hashes and sets to provide:
- Service registration with metadata
- Health status tracking
- Service discovery
- Heartbeat mechanism
- Automatic cleanup of stale services

## Installation

```bash
pip install -r requirements.txt
```

## Quick Start

### Python API

```python
from redis import ServiceRegistry, ServiceInfo, ServiceStatus

# Initialize registry
registry = ServiceRegistry(redis_host='localhost', redis_port=6379)

# Register a service
service = ServiceInfo(
    service_id="vllm-node-001",
    host="10.0.0.1",
    port=8000,
    service_type="inference",
    metadata={"model": "llama-3", "gpu": "A100"}
)
registry.register_service(service)

# Send heartbeat
registry.heartbeat("vllm-node-001")

# Update health status
registry.update_health("vllm-node-001", ServiceStatus.HEALTHY)

# Get service info
service = registry.get_service("vllm-node-001")
print(f"Service at {service.host}:{service.port} is {service.status}")

# List all services
services = registry.list_services()
for s in services:
    print(f"{s.service_id}: {s.host}:{s.port} ({s.service_type})")

# Get healthy services only
healthy = registry.get_healthy_services(timeout_seconds=30)

# Cleanup stale services
removed = registry.cleanup_stale_services(timeout_seconds=300)
```

### CLI Usage

The library includes a comprehensive CLI for shell scripting:

#### Register a service

```bash
python cli.py register vllm-node-001 \
    --host 10.0.0.1 \
    --port 8000 \
    --service-type inference \
    --metadata '{"model": "llama-3", "gpu": "A100"}'
```

#### Send heartbeat

```bash
python cli.py heartbeat vllm-node-001
```

#### Update health status

```bash
python cli.py update-health vllm-node-001 --status healthy
```

#### Get service information

```bash
# Text format
python cli.py get vllm-node-001

# JSON format
python cli.py get vllm-node-001 --format json
```

#### List services

```bash
# List all services
python cli.py list

# Filter by type
python cli.py list --service-type inference

# Filter by status
python cli.py list --status healthy

# JSON output
python cli.py list --format json
```

#### List healthy services

```bash
python cli.py list-healthy --timeout 30
```

#### Get service count

```bash
python cli.py count
python cli.py count --service-type inference
```

#### List service types

```bash
python cli.py types
```

#### Cleanup stale services

```bash
python cli.py cleanup --timeout 300
```

#### Deregister a service

```bash
python cli.py deregister vllm-node-001
```

#### Clear all data

```bash
python cli.py clear --confirm
```

### Shell Integration Example

Here's a complete shell script example for registering a service and maintaining heartbeat:

```bash
#!/bin/bash

SERVICE_ID="vllm-$(hostname)-$$"
HOST=$(hostname -i)
PORT=8000

# Register service
python cli.py register "$SERVICE_ID" \
    --host "$HOST" \
    --port "$PORT" \
    --service-type inference \
    --metadata '{"model": "llama-3"}'

# Start your service
./start_vllm.sh &
SERVICE_PID=$!

# Heartbeat loop
while kill -0 $SERVICE_PID 2>/dev/null; do
    python cli.py heartbeat "$SERVICE_ID" --quiet
    sleep 10
done

# Cleanup on exit
python cli.py deregister "$SERVICE_ID"
```

## Redis Data Structure

### Service Information (Hash)

```
Key: service:{service_id}
Fields:
  - service_id: unique identifier
  - host: service hostname/IP
  - port: service port number
  - service_type: type of service (e.g., "inference", "worker")
  - status: health status (healthy, unhealthy, starting, stopping, unknown)
  - last_seen: Unix timestamp of last heartbeat
  - metadata: JSON string with additional metadata
```

### Active Services (Set)

```
Key: services:active
Members: Set of active service_ids
```

### Service Type Index (Sets)

```
Key: services:type:{type}
Members: Set of service_ids of that type
```

## API Reference

### ServiceRegistry Class

#### `__init__(redis_host='localhost', redis_port=6379, redis_db=0, redis_password=None, key_prefix='')`

Initialize the service registry.

#### `register_service(service_info: ServiceInfo) -> bool`

Register a new service or update existing one.

#### `deregister_service(service_id: str) -> bool`

Deregister a service.

#### `update_health(service_id: str, status: ServiceStatus, metadata: Optional[Dict] = None) -> bool`

Update service health status.

#### `heartbeat(service_id: str) -> bool`

Record a heartbeat for a service (updates last_seen timestamp).

#### `get_service(service_id: str) -> Optional[ServiceInfo]`

Get service information.

#### `list_services(service_type: Optional[str] = None, status_filter: Optional[ServiceStatus] = None) -> List[ServiceInfo]`

List all registered services with optional filters.

#### `get_healthy_services(service_type: Optional[str] = None, timeout_seconds: int = 30) -> List[ServiceInfo]`

Get all healthy services (with recent heartbeat).

#### `cleanup_stale_services(timeout_seconds: int = 300) -> int`

Remove services that haven't sent a heartbeat in a while. Returns number of services removed.

#### `get_service_count(service_type: Optional[str] = None) -> int`

Get count of registered services.

#### `get_service_types() -> List[str]`

Get list of all service types.

#### `clear_all() -> bool`

Clear all service registry data (USE WITH CAUTION).

### ServiceInfo Class

Dataclass representing service information:

```python
@dataclass
class ServiceInfo:
    service_id: str
    host: str
    port: int
    service_type: str
    status: str = ServiceStatus.HEALTHY.value
    last_seen: float = None
    metadata: Dict[str, Any] = None
```

### ServiceStatus Enum

Available status values:
- `HEALTHY`: Service is healthy and operational
- `UNHEALTHY`: Service is experiencing issues
- `STARTING`: Service is starting up
- `STOPPING`: Service is shutting down
- `UNKNOWN`: Status is unknown

## Use Cases

### 1. Distributed Inference Service

Register multiple inference nodes and use service discovery to route requests:

```python
# Each node registers itself
registry.register_service(ServiceInfo(
    service_id=f"inference-{node_id}",
    host=node_host,
    port=8000,
    service_type="inference"
))

# Load balancer discovers healthy nodes
nodes = registry.get_healthy_services(service_type="inference")
selected_node = random.choice(nodes)
```

### 2. Health Monitoring

Monitor service health across your cluster:

```python
# Periodic health check
def health_check():
    services = registry.list_services()
    for service in services:
        if time.time() - service.last_seen > 30:
            print(f"WARNING: {service.service_id} hasn't reported in 30s")
```

### 3. Auto-scaling

Use service counts to make scaling decisions:

```python
# Check if we need more workers
worker_count = registry.get_service_count(service_type="worker")
if worker_count < 5:
    spawn_new_worker()
```

## Configuration

### Redis Connection

You can configure Redis connection via:

1. Constructor parameters:
```python
registry = ServiceRegistry(
    redis_host='redis.example.com',
    redis_port=6380,
    redis_db=1,
    redis_password='secret'
)
```

2. CLI arguments:
```bash
python cli.py --redis-host redis.example.com --redis-port 6380 list
```

### Key Prefix

Use key prefix to isolate different environments:

```python
# Production
prod_registry = ServiceRegistry(key_prefix='prod:')

# Staging
staging_registry = ServiceRegistry(key_prefix='staging:')
```

## Coming Soon

- **Centralized Job Queue**: Using Redis lists/streams for distributed task management
- **Result Collection & Async API**: Status tracking and result storage for async operations

## License

See the main repository license.

