# redis env for redis, vllm and ollama servers

# Where the custom redis code resides.
export REDIS_DIR="$HOME/candle_aesp_CNDA/brettin/Aurora-Inferencing/redis"

module load frameworks
export PKGDIR="/tmp/redis_env"
export PYTHONPATH="$PKGDIR:$PYTHONPATH"
python -c 'import redis'

# Fix this by installing redis-stable to /tmp/redis_env
export REDIS_STABLE="$HOME/candle_aesp_CNDA/brettin/Aurora-Inferencing/redis/redis-stable"
export PATH="$PATH:$REDIS_STABLE/src"

# Make commands available in path
export PATH="$PATH:$REDIS_STABLE/src"
