module Main where

import ProxyPool.Util

import Network
import Network.Socket

import System.IO

import Control.Monad

main :: IO ()
main = withSocketsDo $ do
    -- connect to pool server
    upstream <- getAddrInfo
                    (Just $ defaultHints { addrFamily = AF_INET, addrSocketType = Stream })
                    (Just "pool.doge.st")
                    (Just "9555")

    case upstream of
        []  -> hPutStrLn stderr "Could not resolve upstream server"
        x:_ -> do
            sock <- socket AF_INET Stream defaultProtocol
            setSocketOption sock NoDelay 1
            support <- configureKeepAlive sock
            unless support $ putStrLn "No native support for TCP keep alives"
            connect sock $ addrAddress x

    return ()
