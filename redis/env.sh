# redis env for redis, vllm and ollama servers

# Where the custom redis code resides.
export REDIS_DIR="$HOME/candle_aesp_CNDA/brettin/Aurora-Inferencing/redis"

# Redis Service Registry Timeout Configuration
# Time thresholds for service health monitoring
export REDIS_HEARTBEAT_INTERVAL=${REDIS_HEARTBEAT_INTERVAL:-10}     # How often services send heartbeats (seconds)
export REDIS_UNHEALTHY_TIMEOUT=${REDIS_UNHEALTHY_TIMEOUT:-30}       # Mark unhealthy if no heartbeat (seconds) - 3x heartbeat
# Note: cleanup removes all unhealthy services immediately (no timeout needed)

module load frameworks
export PKGDIR="/tmp/redis_env"
export PYTHONPATH="$PKGDIR:$PYTHONPATH"
python -c 'import redis' 2>/dev/null || {
  echo "python-redis not found, attempting to install into $PKGDIR"
  pip install --target="$PKGDIR" redis || {
    echo "Failed to install redis python package"
    return 1
  }
}

# Fix this by installing redis-stable to /tmp/redis_env
export REDIS_STABLE="$HOME/candle_aesp_CNDA/brettin/Aurora-Inferencing/redis/redis-stable"
export PATH="$PATH:$REDIS_STABLE/src"

# Make commands available in path
export PATH="$PATH:$REDIS_STABLE/src"
