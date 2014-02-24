{-# LANGUAGE ScopedTypeVariables #-}
-- | Client for stress testing and benchmarking
module Main where

import ProxyPool.Network (configureKeepAlive, connectTimeout)
import ProxyPool.Stratum

import System.IO
import System.Random

import Data.IORef
import Data.Aeson

import Text.Printf

import qualified Data.Text as T
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as BL

import Control.Applicative ((<$>))
import Control.Monad
import Control.Concurrent

import Network.Socket hiding (accept)

main :: IO ()
main = do
    -- run 1000 connections
    replicateM_ 1000 runClient
    -- for 5 minutes
    threadDelay $ 60 * 5 * 10^(6 :: Integer)

runClient :: IO ThreadId
runClient = forkIO $ do
    name <- printf "%08x" <$> randomRIO (0 :: Integer, 2^(32 :: Integer))

    upstream <- getAddrInfo
                    (Just $ defaultHints { addrFamily = AF_INET, addrSocketType = Stream })
                    (Just "localhost")
                    (Just "9666")

    case upstream of
        []  -> hPutStrLn stderr $ name ++ ": getaddrinfo failed"
        x:_ -> do
                   sock <- socket AF_INET Stream defaultProtocol
                   -- set up socket
                   setSocketOption sock NoDelay 1
                   _ <- configureKeepAlive sock

                   connectTimeout sock (addrAddress x) 20
                   handle <- socketToHandle sock ReadWriteMode

                   -- send subscription and auth
                   hPutStrLn handle "{\"id\": 2, \"method\": \"mining.subscribe\", \"params\": []}"
                   hPutStrLn handle "{\"id\": 3, \"method\": \"mining.authorize\", \"params\": [\"DReCBSKnatV3DuWez4YJWkQfpUxGknzmkN\", \"asdf\"]}"

                   en2Size <- newIORef 0

                   -- read stuff from server
                   _ <- forkIO $ forever $ do
                       xs <- B.hGetLine handle
                       case decodeStrict xs of
                           Just (Response _ (Initalise _ en2)) -> do
                               writeIORef en2Size en2
                           Just (Response _ wn@(WorkNotify{})) -> do
                               -- since p2pools send worknotify a lot, just spray some packets back whenever we get a new job

                               let packInt :: Int -> Integer -> T.Text
                                   packInt size value = T.pack $ printf "%0*x" (size * 2) value
                                   randomSubmit = do
                                       ntime  <- packInt 4 <$> randomRIO (0, 2^(32 :: Integer))
                                       nonce  <- packInt 4 <$> randomRIO (0, 2^(32 :: Integer))

                                       en2 <- readIORef en2Size
                                       en2Val <- packInt en2 <$> randomRIO (0, 2^(en2 * 8))
                                       return $ Request (Number 1) $ Submit (T.pack name) (wn_job wn) en2Val ntime nonce
                               replicateM_ 5 $ randomSubmit >>= B8.hPutStrLn handle . BL.toStrict . encode
                           _ -> return ()

                   return ()
