module ProxyPool.Handlers (handleClient, handleServer) where

import ProxyPool.Stratum

import System.IO (Handle)

import Control.Monad (forever, mzero)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Maybe

import Data.Aeson

import qualified Data.ByteString as BS

handleClient :: Handle -> IO ()
handleClient handle = do
    -- wait for mining.subscription call
    _ <- runMaybeT $ forever $ do
        line <- liftIO $ BS.hGetLine handle
        case decodeStrict line of
            Just (Request rid Subscribe) -> do
                mzero
            _ -> return ()

    forever $ do
        line <- liftIO $ BS.hGetLine handle
        case decodeStrict line of
            Just (Request rid (Authorize user pass)) -> return ()
            _ -> return ()
        print line

handleServer :: Handle -> IO ()
handleServer handle = return ()
