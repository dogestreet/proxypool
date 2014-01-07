-- | Entry point for proxy pool
module Main where

import ProxyPool.Util
import ProxyPool.Stratum

import System.Posix.Signals (installHandler, sigPIPE, Handler(..))
import System.IO (Handle, hPutStrLn, hClose, stderr, IOMode(..))

import Network
import Network.Socket hiding (accept)

import Control.Applicative ((<$>))

import Control.Monad (unless, forever)
import Control.Exception (bracket, bracket_, catch, IOException)
import Control.Concurrent (forkIO, ThreadId)

import Control.Concurrent.STM

import qualified Data.ByteString as B

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
            forkIO $ handleClient handle

    putStrLn "Server started"

-- | Handles a connected miner
handleClient :: Handle -> IO ()
handleClient handle =
    bracket_
        (return handle)
        (hClose handle)
        (forever $ do
            line <- B.hGetLine handle
            print line
        )
    `catch` \e -> hPutStrLn stderr $ "IOException in client: " ++ show (e :: IOException)

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
                       setSocketOption sock NoDelay 1
                       _ <- configureKeepAlive sock

                       print "Connecting"
                       connectTimeout sock (addrAddress x) 20

                       sock_handle <- socketToHandle sock ReadWriteMode

                       -- TODO: subscribe to mining
                       -- read from server
                       forever $ do
                           line <- B.hGetLine sock_handle
                           print line
                   )
               `catch` \e -> hPutStrLn stderr $ "IOException: " ++ show (e :: IOException)

main :: IO ()
main = withSocketsDo $ do
    -- don't let the process die from a broken socket
    installHandler sigPIPE Ignore Nothing

    listenDownstream
    runUpstream
