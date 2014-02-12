# proxypool

A Stratum to Stratum proxy pool. Released under AGPL-V3.

Proxypool is a pool server that splits the work from an upstream pool server and redistributes them to its miners, handling both shares submission and share logging for it's patrons.

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

This does reduce the block search space for clients, however, the impact is negligible. With a 4 byte upstream `extraNonce2`, and with the proxypool server keeping 2 bytes for itself (clients get the other 2). This allows the server to have 65536 concurrent connections and clients to have a maximum hashrate of 2^32 x 2^16, or 256 tera Hashes per second, which is more than enough for Scrypt based coins at the time of writing.

# Installation #
Hackage package coming soon.

# Implementation #
Currently hosted on http://proxypool.doge.st
