#!./env/bin/python3

from config import config
from common import get_logger, get_postgres_conn

import bitcoinrpc
import math
import time

def subsidy_func(height):
    """ Subsidy function for Python """
    if height > 600000:
        return 10000
    else:
        return 500000 * pow(2, - math.floor((height - 1)/100000))

def balance():
    return float(rpc.getbalance(account='', minconf=120)) - config['serverMin']

logger = get_logger('payout')

while True:
    try:
        logger.info('Connecting to dogecoind')
        rpc = bitcoinrpc.connect_to_remote(config['dogecoindUser'], config['dogecoindPass'], config['dogecoindHost'], config['dogecoindPort'])

        # reserve an amount for transaction fees
        block_count = rpc.getblockcount()
        block_value = subsidy_func(block_count)

        conn = get_postgres_conn()
        cur = conn.cursor()

        logger.info('Block value: ' + str(block_value))
        logger.info('Server balance: ' + str(balance()))

        def pay_pending():
            # try and pay outstanding tids
            conn.set_session('serializable')
            cur.execute('SELECT id, total FROM transactions WHERE txid is NULL;')
            # we can do a join but there's no point, since we'll need to split it anyway
            pending_tids = cur.fetchall();
            logger.info('Pending tids: ' + str(pending_tids))

            for tid, total in pending_tids:
                if balance() < total:
                    logger.warning('Failed to pay tx: ' + str(tid) + ' not enough balance')
                    break

                cur.execute('SELECT address, amount FROM paylog WHERE tid = %s', (tid,))
                payouts = dict(cur.fetchall())
                logger.info('Paying ' + str(tid) + ' ' + str(payouts))
                tx = rpc.sendmany('', payouts)
                logger.info('Tx: ' + tx)
                cur.execute('UPDATE transactions SET txid = %s, paidat = NOW() WHERE id = %s', (tx, tid))

            conn.commit()

        pay_pending()

        # move shares to balances
        conn.set_session('read committed')
        cur.execute('SELECT * FROM pay_to_balances(%s, %s);', (block_value, balance()))
        logger.info('Paid shares: ' + str(cur.fetchone()))
        conn.commit()

        # try and clear to books
        cur.execute('SELECT new_tid(%s, %s);', (balance(), config['minPay']))
        logger.info('New tid: ' + str(cur.fetchone()))
        conn.commit()

        pay_pending()
        time.sleep(5 * 60)
    except Exception as e:
        print(e)
        logger.warning('Sleeping for 5 seconds')
        time.sleep(5)
