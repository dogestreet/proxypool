-- | Entry point for proxy pool
module Main where

import ProxyPool.Network (configureKeepAlive, connectTimeout)
import ProxyPool.Handlers (handleClient, handleServer)

import Control.Monad (forever)
import Control.Exception (bracket, bracket_, catch, IOException)
import Control.Concurrent (forkIO)

import System.Posix.Signals (installHandler, sigPIPE, Handler(..))
import System.IO (hPutStrLn, hClose, stderr, IOMode(..))

import Network
import Network.Socket hiding (accept)

-- | Manage incoming connections
listenDownstream :: IO ()
listenDownstream = do
    sock <- listenOn (PortNumber 9555)
    setSocketOption sock ReuseAddr 1
    setSocketOption sock NoDelay 1
    _ <- configureKeepAlive sock

    -- listen for connections on separate thread
    _ <- forkIO . forever $ do
            (handle, _, _) <- accept sock
            -- handle each incoming connection on a separate thread
            forkIO $
                bracket_
                    (return handle)
                    (hClose handle)
                    (handleClient handle)
                `catch` \e -> hPutStrLn stderr $ "IOException in client: " ++ show (e :: IOException)

    putStrLn "Server started"

-- | Handles connection to upstream pool server
runUpstream :: IO ()
runUpstream = forever $ do
    upstream <- getAddrInfo
                    (Just $ defaultHints { addrFamily = AF_INET, addrSocketType = Stream })
                    (Just "pool.doge.st")
                    (Just "9555")

    case upstream of
        []  -> hPutStrLn stderr "Could not resolve upstream server"
        x:_ -> bracket
                   (socket AF_INET Stream defaultProtocol)
                   (\sock -> do
                        shutdown sock ShutdownBoth
                        hPutStrLn stderr "Exception thrown, reconnecting"
                   )
                   (\sock -> do
                       -- set up socket
                       setSocketOption sock NoDelay 1
                       _ <- configureKeepAlive sock

                       print "Connecting"
                       connectTimeout sock (addrAddress x) 20

                       sock_handle <- socketToHandle sock ReadWriteMode
                       handleServer sock_handle
                   )
               `catch` \e -> hPutStrLn stderr $ "IOException: " ++ show (e :: IOException)

main :: IO ()
main = withSocketsDo $ do
    -- don't let the process die from a broken pipe
    _ <- installHandler sigPIPE Ignore Nothing

    listenDownstream
    runUpstream
