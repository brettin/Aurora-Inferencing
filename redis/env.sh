module load frameworks
export PKGDIR="/tmp/redis_env"
export PYTHONPATH="$PKGDIR:$PYTHONPATH"
python -c 'import redis'

# Fix this by installing redis-stable to /tmp/redis_env
REDIS_DIR="$HOME/candle_aesp_CNDA/brettin/Aurora-Inferencing/redis/redis-stable"
export PATH="$PATH:$REDIS_DIR/src"

# Make commands available in path
export PATH="$PATH:$REDIS_DIR/src"

# Start command
# $REDIS_DIR/src/redis-server $REDIS_DIR/redis.conf