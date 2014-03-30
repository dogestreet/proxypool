# proxypool
[![Build Status](https://travis-ci.org/dogestreet/proxypool.png?branch=master)](https://travis-ci.org/dogestreet/proxypool)

A Stratum to Stratum proxy pool. Released under AGPL-V3.

`proxypool` is a pool server that splits work from an upstream pool server and redistributes them to its miners, handling both share submission and sharelogging for it's patrons.

Hosted on [Doge Street mining pool](http://doge.st)

Donations :) DGJucYFxGt84y2YQEyskGVpg5aJ8vKTVtb

## Compatibility ##
There is a bug in cgminer v3.7.2 that incorrectly assumes the `extraNonce2` field is always 4 bytes long, this results in some parts of the `coinbase2` being overwritten by the nonce rendering all submitted work invalid. This only affects upstream servers that have `coinbase2` as non zero values. P2Pool is not affected.

If you are running a pool server that is using non zero values in `coinbase2` (such as `stratum-mining`), please ask your miners to upgrade to the latest `cgminer` or `sgminer`.

## Features ##

 * Vardiff
 * Address validation
 * Redis pubsub for share logging

Currently only Scrypt is supported for upstream servers. This repository does not include the payout system only share logging.

## How it works (how to proxy Stratrum) ##
The main problem to solve is how to generate unique work for every proxypool client.

The idea is to reduce the size of `extraNonce2` so that the server controls the first few bytes. This means that server will be able to generate a unique coinbase for each client, mutating the coinbase hash.

This reduces the block search space for clients. However, the impact is negligible. With a 4 byte upstream `extraNonce2`, and with the proxypool server keeping 2 bytes for itself (clients get the other 2). This allows the server to have 65536 concurrent connections and clients to have a maximum hashrate of 2^32 x 2^16, or 256 tera hashes per second, which is more than enough for Scrypt based coins at the time of writing.

Upon client share submission, the server checks that the share matches the required upstream difficulty and resubmits it under it's own name.

## Installation guide for (Ubuntu 13.10 +)##

### Getting Haskell platform and cabal v1.18+ ###
Haskell platform provides the compiler and base packages to build the proxypool. Cabal is the Haskell package manager and build tool. We want `cabal` v1.18 or above because it comes with the package sandbox feature - allowing us to install our package dependencies locally instead of system wide.

    $ sudo apt-get install haskell-platform
    $ cabal update
    $ cabal install cabal-install    # installs the latest version of cabal

Add `PATH="$HOME/.cabal/bin:$PATH"` to your ~/.profile

Check that you now have `cabal` 1.18 or higher

    $ cabal --version

### Building ###

    $ cabal sandbox init    # create a package sandbox so you don't mess up your system's packages
    $ cabal configure
    $ cabal build

### Getting Redis ###
The proxypool [publishes](http://redis.io/topics/pubsub) shares in [Redis](http://redis.io). Ensure it's installed and configured.

    $ sudo apt-get install redis-server

## Redis data format ##
Shares are published to Redis in JSON form.
The format is:

    {
        "sub": "DPPowFrL1RJ9FKa2NTzcy3kfKwohJYPTNj"  // submitter
      , "srv": "Test server"                         // name of the proxypool server
      , "diff": 1.0e-5                               // difficulty in raw form (multiply by 65536 to get cgminer difficulty)
      , "host": "127.0.0.1"                          // IP of submitter
      , "valid": true                                // share validity
    }

## Configuration ##
All configuration is done in `proxypool.json`. Most options should be self explanatory.

### Redis ###
`redisHost` is the hostname of the Redis server. `redisAuth` is the auth key used to access it, it can be set as `null` if there is no auth key. `redisChanName` is the name of the channel used to publish shares.

### Address validation ###
The proxypool implements the proper address validation algorithm for public keys. Since different coins prepend a different byte to the checksum, this option is configurable in `publicKeyByte`. It is expected that miners use their payout address as their username in their mining client. The server does not check passwords.

### Nonce ###
`extraNonce2Size` and `extraNonce3Size` control the how the upstream's `extraNonce2` is split. Thus `extraNonce2Size` and `extraNonce3Size` should add up the to the upstream's `extraNonce2`'s size.

### Vardiff control ###
Variable difficulty allows the server to dynamically adjust share difficulty for clients, improving miner efficency and reducing server load. Difficulty adjustments happen every `vardiffRetargetTime` or if the client has submitted `vardiffShares` in `vardiffRetargetTime`. The difficulty values used in the configuration are the raw Bitcoin difficulty values - difficulty 0.0002 is equivalent to difficulty 13.1072 in most mining software (multiply by 65536).

| Vardiff                | Configuration
| -----------------------|------------------------
| `vardiffRetargetTime`  | How long in seconds before the server changes the clients's share difficulty
| `vardiffTarget`        | How many shares should be submitted in `vardiffRetargetTime`
| `vardiffAllowance`     | How much under/over target is tolerated, 0.25 = 25%
| `vardiffMin`           | The minimum share difficulty
| `vardiffInitial`       | The initial share difficulty
| `vardiffShares`        | The number of shares submitted in `vardiffRetargetTime` before a difficulty adjustment is forced

### Invalid share kicks ###
Since the proxy pool validates shares before submitting to the upstream, profiling results show that checking shares consume around 50% of the server's CPU time. A malicious client sending invalid shares can cause a denial of service for the pool server. The server will disconnect clients that have over 90% invalid shares.

## References ##
 * [Stratum protocol specifications](https://mining.bitcoin.cz/stratum-mining)
 * [Stratum protocol description from BTCGuild](https://www.btcguild.com/new_protocol.php)
