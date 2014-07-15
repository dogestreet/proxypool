#!./env/bin/python3

from config import config
from common import get_redis_conn, get_postgres_conn, get_logger
import cherrypy
import redis
import json
import time

from multiprocessing import Process

class Stats(object):
    """ Serve stats directly from Redis """
    def __init__(self):
        self._red = get_redis_conn()
        self._pg = get_postgres_conn()
        self._logger = get_logger('web')

    @cherrypy.expose
    @cherrypy.tools.json_out()
    def server(self):
        try:
            return dict({ k.decode('utf-8'): v.decode('utf-8') for k, v in self._red.hgetall('stats:server').items() })
        except redis.RedisError:
            return dict({'error': 'Redis connection lost'})

    @cherrypy.expose
    @cherrypy.tools.json_out()
    def stats(self, address):
        try:
            return dict({ k.decode('utf-8'): v.decode('utf-8') for k, v in self._red.hgetall('stats:' + address).items() })
        except redis.RedisError:
            return dict({'error': 'Redis error'})

    @cherrypy.expose
    @cherrypy.tools.json_out()
    def hashrate(self, address):
        try:
            return { address: [ v.decode('utf-8') for v in self._red.lrange('hashrate:' + address, 0, 300) ] }
        except redis.RedisError:
            return dict({'error': 'Redis error'})

    @cherrypy.expose
    @cherrypy.tools.json_out()
    def balance(self, address):
        try:
            with self._pg.cursor() as cur:
                cur.execute('SELECT COALESCE((SELECT balance FROM balances WHERE address = %s), 0);', (address,))
                row = cur.fetchone()
                self._pg.commit()
                return dict({ address: row[0] })
        except Exception as e:
            self._logger.warning(str(e))
            return dict({'error': 'Error reading table'})

    @cherrypy.expose
    @cherrypy.tools.json_out()
    def paid(self, address):
        try:
            with self._pg.cursor() as cur:
                cur.execute('SELECT txid, amount, EXTRACT(epoch from paidat) FROM paylog INNER JOIN transactions ON transactions.id = paylog.tid WHERE address = %s ORDER BY transactions.paidat DESC LIMIT 10;', (address,))
                rows = cur.fetchall()
                self._pg.commit()
                return dict({ address: rows })
        except Exception as e:
            self._logger.warning(str(e))
            return dict({'error': 'Error reading table'})

    @cherrypy.expose
    @cherrypy.tools.json_out()
    def backlog(self):
        try:
            with self._pg.cursor() as cur:
                cur.execute('SELECT COALESCE(COUNT(*), 0) from shares;')
                rows = cur.fetchone()
                self._pg.commit()
                return dict({ 'backlog': rows[0] })
        except Exception as e:
            self._logger.warning(str(e))
            return dict({'error': 'Error reading table'})

    @cherrypy.expose
    @cherrypy.tools.json_out()
    def lastpaid(self):
        try:
            with self._pg.cursor() as cur:
                cur.execute('SELECT txid, total, EXTRACT(epoch from paidat) from transactions ORDER BY id DESC LIMIT 5;')
                rows = cur.fetchall()
                self._pg.commit()
                return dict({ 'lastpaid': rows })
        except Exception as e:
            self._logger.warning(str(e))
            return dict({'error': 'Error reading table'})

def redis_proc():
    logger = get_logger('db')
    while True:
        try:
            red = get_redis_conn()
            red.ping()
            logger.info('Connected to redis')

            pubsub = red.pubsub()
            pubsub.subscribe('shares')

            last_active_update = 0
            active = {}

            for item in pubsub.listen():
                if type(item['data']) is bytes:
                    # sub, srv, diff, valid
                    data = json.loads(item['data'].decode('utf-8'))

                    # update server stats
                    now = time.time()

                    active[data['sub']] = now
                    if now - last_active_update > 5 * 60:
                        last_active_update = now
                        for k, v in list(active.items()):
                            if now - v > 5 * 60:
                                del active[k]
                        red.hset('stats:server', 'active', len(active))

                    red.hincrbyfloat('stats:server', 'shares', data['diff'] * 65536)
                    stats_key = 'stats:' + data['sub']
                    hashrate_key = 'hashrate:' + data['sub']

                    def initalise_key():
                        pipe = red.pipeline()
                        pipe.hset(stats_key, 'shares', 0)
                        pipe.hset(stats_key, 'invalid_shares', 0)
                        pipe.hset(stats_key, 'start_time', now)
                        pipe.execute()

                    start_time = now
                    if not red.exists(stats_key):
                        # initalise the data
                        initalise_key()
                        red.hset(stats_key, 'session_start_time', now)
                    else:
                        start_time = float(red.hget(stats_key, 'start_time'))

                    time_diff = now - start_time

                    # collected more than 5 minutes
                    if time_diff > 5 * 60:
                        pipe = red.pipeline()
                        pipe.hget(stats_key, 'shares')
                        pipe.hget(stats_key, 'invalid_shares')

                        shares, invalid_shares = pipe.execute()
                        shares, invalid_shares = float(shares), float(invalid_shares)

                        pipe = red.pipeline()
                        pipe.hset(stats_key, 'average_valid', shares / time_diff)
                        pipe.hset(stats_key, 'average_invalid', invalid_shares / time_diff)

                        pipe.hincrbyfloat(stats_key, 'total_shares', shares)
                        pipe.hincrbyfloat(stats_key, 'total_invalid_shares', invalid_shares)

                        pipe.lpush(hashrate_key, ','.join(map(str, [shares / time_diff, invalid_shares / time_diff, now])))
                        pipe.ltrim(hashrate_key, 0, 300)
                        pipe.expire(hashrate_key, 3600 * 24)
                        pipe.execute()

                        initalise_key()
                    else:
                        if data['valid']:
                            red.hincrbyfloat(stats_key, 'shares', data['diff'] * 65536)
                        else:
                            red.hincrbyfloat(stats_key, 'invalid_shares', data['diff'] * 65536)

                    # 5 minute expiry
                    red.expire(stats_key, 5 * 60)

        except Exception as e:
            logger.warning(e)
            logger.info('Exception: retrying in 5 seconds')
            time.sleep(5)

if __name__ == '__main__':
    Process(target=redis_proc).start()

    cherrypy.config.update({ 'server.socket_host': '0.0.0.0', 'server.socket_port': 9000, 'environment': config['env'] })

    cherrypy.quickstart(Stats())
