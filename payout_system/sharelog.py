#!./env/bin/python3

import threading
import json

import redis
import time

from config import config
from common import get_logger, get_postgres_conn, get_redis_conn

import bitcoinrpc

logger = get_logger('sharelogger')

def getdiff():
    lookback = 100

    current_diff = rpc.getinfo().difficulty
    blocks = rpc.getblockcount()

    lowest = max(1, blocks-lookback)
    total = sum(rpc.getblock(rpc.getblockhash(i))['difficulty'] for i in range(lowest, blocks))
    total /= (blocks - lowest) + 1

    return round(total, 2)

while True:
    try:
        # postgresql setup
        conn = get_postgres_conn()
        cur = conn.cursor()

        logger.info('Connected to postgresql')

        # set up redis
        red = get_redis_conn()
        red.ping()
        logger.info('Connected to redis')

        # rpc
        rpc = bitcoinrpc.connect_to_remote(config['dogecoindUser'], config['dogecoindPass'], config['dogecoindHost'], config['dogecoindPort'])

        # insert shares from redis to postgresql
        pubsub = red.pubsub()
        pubsub.subscribe('shares')

        for item in pubsub.listen():
            if type(item['data']) is bytes:
                data = json.loads(item['data'].decode('utf-8'))
                nethash = getdiff()

                if data['valid']:
                    cur.execute('INSERT INTO shares (address, difficulty, nethash, coin) VALUES (%s, %s, %s, %s)', (data['sub'], data['diff'], nethash, 0))
                    conn.commit()

    except Exception as e:
        raise e
        print(e)
        logger.warning('Sleeping for 5 seconds')
        time.sleep(5)
