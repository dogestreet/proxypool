{-# LANGUAGE OverloadedStrings #-}
-- | Entry point for proxy pool
module Main where

import ProxyPool.Network (configureKeepAlive, connectTimeout)
import ProxyPool.Handlers

import Control.Monad (forever)
import Control.Exception (bracket, catch, IOException)
import Control.Concurrent (forkIO, ThreadId)
import Control.Applicative ((<$>))

import System.Posix.Signals (installHandler, sigPIPE, Handler(..))
import System.IO (stdout, IOMode(..))

import System.Log.Logger
import System.Log.Handler (setFormatter)
import System.Log.Handler.Simple
import System.Log.Formatter

import Data.Word

import Network
import Network.Socket hiding (accept)

-- | Manage incoming connections
listenDownstream :: GlobalState -> Word16 -> IO ()
listenDownstream state port = do
    sock <- listenOn $ PortNumber $ fromIntegral port

    setSocketOption sock ReuseAddr 1
    setSocketOption sock NoDelay 1
    _ <- configureKeepAlive sock

    infoM "client" $ "Listening on localhost:" ++ show port
    -- listen for connections on separate thread
    _ <- forkIO . forever $ do
        (handle, host, remotePort) <- accept sock
        -- handle each incoming connection on a separate thread
        forkIO $ do
            infoM "client" $ "Accepted connection from " ++ host ++ ":" ++ show remotePort
            bracket
                (initaliseClient handle state)
                finaliseClient
                (handleClient state)
            `catch` \e -> warningM "client" $ "IOException in client: " ++ show (e :: IOException)

    return ()

-- | Handles connection to upstream pool server
runUpstream :: GlobalState -> String -> Int -> IO ThreadId
runUpstream state url port = forkIO $ forever $ do
    upstream <- getAddrInfo
                    (Just $ defaultHints { addrFamily = AF_INET, addrSocketType = Stream })
                    (Just url)
                    (Just $ show port)

    case upstream of
        []  -> criticalM "server" "Could not resolve upstream server"
        x:_ -> bracket
                   (do
                        sock <- socket AF_INET Stream defaultProtocol
                        -- set up socket
                        setSocketOption sock NoDelay 1
                        _ <- configureKeepAlive sock

                        infoM "server" $ "Connecting to upstream: " ++ url ++ ":" ++ show port
                        connectTimeout sock (addrAddress x) 20

                        handle <- socketToHandle sock ReadWriteMode
                        initaliseServer handle
                   )
                   finaliseServer
                   (handleServer state)
               `catch` \e -> warningM "server" $ "IOException in server: " ++ show (e :: IOException)

main :: IO ()
main = withSocketsDo $ do
    -- don't let the process die from a broken pipe
    _ <- installHandler sigPIPE Ignore Nothing

    -- start the logger
    logger <- flip setFormatter (tfLogFormatter "%F %T" "[$time][$loggername][$prio] $msg") <$> streamHandler stdout DEBUG
    updateGlobalLogger rootLoggerName $ setLevel DEBUG . setHandlers [logger]

    -- create the global state
    state <- initaliseGlobal $ ServerSettings "DATkurgeSP7nHDnSade7GbrGaLK3E4Aezc+0.000500" "anything" 2 2 180 10 0.25 0.000448

    listenDownstream state 9555
    _ <- runUpstream state "pool.doge.st" 9555

    -- hack to get control-c working
    _ <- getLine
    return ()
