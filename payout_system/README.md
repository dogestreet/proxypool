## Getting it running ##

0. Rename config.py.example to config.py and configure to suit your setup
1. Insert proxypool.sql into your DB (postgresql)
2. Configure pyvenv, install requirements (`pip -r requirements.txt`), I tend to name the environment folder `env`
3. Apply the patch `bitcoinrpc-util.py.patch`, this fixes bitcoin-rpc for Python 3
4. Verify that all the scripts work (payout, sharelog, stats)
5. To ensure the scripts stay running. I used an upstart script:

```
$ cat /etc/init/payout.conf

start on runlevel [2345]
stop on runlevel [016]

setuid doge
setgid doge

respawn

env PYTHON_HOME=/home/doge/sharelogger/env
exec $PYTHON_HOME/bin/python3 /home/doge/sharelogger/payout.py
```

## Running operations ##

A few tips for the new pool op:

### Allow more than 1024 open file handles ###
Your pool may get popular! So make sure you remember to up the default file handle (sockets are file handles) limits, or you'll start to find new connections dying. Ubuntu has 1024 as default so pop into /etc/security/limits.conf and

```
* soft nofile 999999
* hard nofile 999999
```

### Use fail2ban and ipset to remove botnets, idiots and general undesirables ###
Suddenly finding 2000 new CPU miners from South East Asia is usually not normal. If a particular account had 10 different IPs mining for it, it'd trigger my botnet detector and all 10 will be blackholed. Since Doge Street only catered to the U.S/Canada audience (too much latency for P2Pool), I blackholed most of Asia.

Proxypool is written with a fair amount of paranoia in mind, thus invulnerable to layer 7 attacks like stratum-flooder and friends. People who tried got the blackhole from fail2ban.
