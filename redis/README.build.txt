REDIS_DIR="/lus/flare/projects/candle_aesp_CNDA/brettin/Aurora-Inferencing/redis"

cd $REDIS_DIR
wget https://download.redis.io/redis-stable.tar.gz
tar xzf redis-stable.tar.gz
cd redis-stable
make
make test

# Start command
$REDIS_DIR/redis-stable//src/redis-server $REDIS_DIR/redis-stable/redis.conf
