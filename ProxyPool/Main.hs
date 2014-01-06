-- | Entry point for proxy pool
module Main where

import ProxyPool.Util

import System.IO (hPutStrLn, stderr, IOMode(..))

import Network
import Network.Socket

import Control.Monad (unless, forever)
import Control.Exception (bracket)

import qualified Data.ByteString as B

main :: IO ()
main = withSocketsDo $ do
    -- connect to pool server
    upstream <- getAddrInfo
                    (Just $ defaultHints { addrFamily = AF_INET, addrSocketType = Stream })
                    (Just "pool.doge.st")
                    (Just "9555")

    case upstream of
        []  -> hPutStrLn stderr "Could not resolve upstream server"
        x:_ -> bracket
                   (socket AF_INET Stream defaultProtocol)
                   (`shutdown` ShutdownBoth)
                   (\sock -> do
                       setSocketOption sock NoDelay 1

                       support <- configureKeepAlive sock
                       unless support $ putStrLn "No native support for TCP_KEEPIDLE | TCP_KEEPINTVL | TCP_KEEPCNT"
                       print "Connecting"
                       connectTimeout sock (addrAddress x) 20

                       sock_handle <- socketToHandle sock ReadWriteMode

                       -- TODO: subscribe to mining
                       -- read from server
                       forever $ do
                           line <- B.hGetLine sock_handle
                           print line
                   )


    return ()
