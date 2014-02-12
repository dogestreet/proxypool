# proxypool

A Stratum to Stratum proxy pool. Released under AGPL-V3.

Proxypool is a pool server that splits the work from an upstream pool server and redistributes them to its miners, handling both shares submission and share logging for it's patrons.

Currently running on [Doge Street](http://proxypool.doge.st)

## Features ##

* Vardiff
* Address validation
* IP based bans for too many invalid shares
* Redis pubsub for share logging

Currently only Scrypt is supported for upstream servers.
The source does not yet include the CPPSRB payout scripts, it will be released once I clean them up.

## How it works (how to proxy Stratrum) ##
The main problem to solve is how to generate unique work for every proxypool client.

The idea is to reduce the size of `extraNonce2` so that server controls the first few byte to generate unique work for every client and the client can then use the rest to generate work locally.

This does reduce the block search space for clients, however, the impact is negligible. With a 4 byte upstream `extraNonce2`, and with the proxypool server keeping 2 bytes for itself (clients get the other 2). This allows the server to have 65536 concurrent connections and clients to have a maximum hashrate of 2^32 x 2^16, or 256 tera hashes per second, which is more than enough for Scrypt based coins at the time of writing.

## Installation ##
Hackage package coming soon.

It is recommended `cabal` be updated to verion 1.18 for `cabal` package sandbox support, simply go to the project directory and

    $ cabal sandbox init
    $ cabal configure
    $ cabal install

## Configuration ##
All configuration is done in `proxypool.json`. Most options should be self explanatory.

### Address validation ###
The proxypool implements the proper address validation algorithm for public keys. Since different coins prepend a different byte to the checksum, this option is configuratible in `publicKeyByte`. It is expected that miners use their payout address as their username in their mining client. The server does not check passwords.

### Nonce ###
`extraNonce2Size` and `extraNonce3Size` control the how the upstream's `extraNonce2` is split. Thus `extraNonce2Size` and `extraNonce3Size` should add up the to the upstream's `extraNonce2`'s size.

### Vardiff control ###
Variable difficulty allows the server to dynamically adjust share difficulty for clients, improving miner efficency and reducing server load. Difficulty adjustments happen every `vardiffRetargetTime` or if the client has submitted `vardiffShares` in `vardiffRetargetTime`.

| Vardiff                | Configuration
| -----------------------|------------------------
| `vardiffRetargetTime`  | How long in seconds before the server changes the clients's share difficulty
| `vardiffTarget`        | How many shares should be submitted in `vardiffRetargetTime`
| `vardiffAllowance`     | How much under/over target is tolerated, 0.25 = 25%
| `vardiffMin`           | The minimum share difficulty
| `vardiffInitial`       | The initial share difficulty
| `vardiffShares`        | The number of shares submitted in `vardiffRetargetTime` before a difficulty adjustment is forced

### Invalid share bans ###
Since the proxy pool validates shares before submitting to upstream, profiling results show that checking shares consume around 50% of the server's CPU time. A malicious client sending invalid shares can cause a denial of service for the pool server. The server bans a client when over 90% of submitted shares are dead. The ban expires in `banExpiry` minutes.
