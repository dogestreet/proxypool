-- | Entry point for proxy pool
module Main where

import ProxyPool.Network (configureKeepAlive, connectTimeout)
import ProxyPool.Handlers (HandlerState, handlerInitalise, initaliseClient, handleClient, finaliseClient, handleServer, ServerSettings(..))

import Control.Monad (forever)
import Control.Exception (bracket, catch, IOException)
import Control.Concurrent (forkIO)

import System.Posix.Signals (installHandler, sigPIPE, Handler(..))
import System.IO (hPutStrLn, stderr, IOMode(..))

import Data.Word

import Network
import Network.Socket hiding (accept)

-- | Manage incoming connections
listenDownstream :: HandlerState -> Word16 -> IO ()
listenDownstream state port = do
    sock <- listenOn (PortNumber $ PortNum port)
    setSocketOption sock ReuseAddr 1
    setSocketOption sock NoDelay 1
    _ <- configureKeepAlive sock

    -- listen for connections on separate thread
    _ <- forkIO . forever $ do
            (handle, _, _) <- accept sock
            -- handle each incoming connection on a separate thread
            forkIO $
                bracket
                    (initaliseClient handle state)
                    finaliseClient
                    (handleClient state)
                `catch` \e -> hPutStrLn stderr $ "IOException in client: " ++ show (e :: IOException)

    putStrLn "Server started"

-- | Handles connection to upstream pool server
runUpstream :: HandlerState -> String -> Int -> IO ()
runUpstream state url port = forever $ do
    upstream <- getAddrInfo
                    (Just $ defaultHints { addrFamily = AF_INET, addrSocketType = Stream })
                    (Just url)
                    (Just $ show port)

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
                       handleServer sock_handle state
                   )
               `catch` \e -> hPutStrLn stderr $ "IOException: " ++ show (e :: IOException)

main :: IO ()
main = withSocketsDo $ do
    -- don't let the process die from a broken pipe
    _ <- installHandler sigPIPE Ignore Nothing

    -- create the global state
    state <- handlerInitalise $ ServerSettings "DATkurgeSP7nHDnSade7GbrGaLK3E4Aezc" "anything" 2 2

    listenDownstream state 9555
    runUpstream state "pool.doge.st" 9555
