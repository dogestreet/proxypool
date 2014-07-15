from config import config

import logging
import psycopg2
import redis

def get_logger(name):
    logger = logging.getLogger(name)
    logger.setLevel(logging.DEBUG)

    ch = logging.StreamHandler()
    ch.setLevel(logging.DEBUG)
    ch.formatter = logging.Formatter('[%(asctime)s][%(name)s][%(levelname)s] %(message)s')
    logger.addHandler(ch)
    return logger

def get_postgres_conn():
    return psycopg2.connect(database=config['postgresDB'], host=config['postgresHost'], user=config['postgresUser'], password=config['postgresPass'])

def get_redis_conn():
    return redis.StrictRedis(host=config['redisHost'], password=config['redisAuth'])
