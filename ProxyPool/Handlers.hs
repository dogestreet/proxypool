{-# LANGUAGE OverloadedStrings #-}
module ProxyPool.Handlers (
    handlerInitalise,
    initaliseClient,
    handleClient,
    finaliseClient,
    handleServer,
    HandlerState,
    ServerSettings(..)) where

import ProxyPool.Stratum

import System.IO (Handle, hClose)

import Control.Applicative ((<$>), (<*>))
import Control.Arrow ((&&&))

import Control.Monad (forever, mzero, join)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Trans.Maybe

import Control.Concurrent (forkIO, ThreadId, killThread)
import Control.Concurrent.MVar
import Control.Concurrent.Chan

import Data.IORef
import Data.Aeson

import Data.Monoid ((<>))
import Text.Printf

import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Lazy.Builder as TL
import qualified Data.Text.Lazy.IO as TL

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as BL

import qualified Data.HashTable.IO as H

type HashTable k v = H.BasicHashTable k v

data ServerSettings = ServerSettings { _username        :: String
                                     , _password        :: String
                                     , _extraNonce2Size :: Int
                                     , _extraNonce3Size :: Int
                                     } deriving (Show)

data ClientState = ClientState { _handle          :: Handle
                               , _children        :: IORef [ThreadId]
                               }

data HandlerState = HandlerState { _nonceCounter   :: IORef Integer
                                 , _matchCounter   :: IORef Integer
                                 -- | Matches server responses with a handler
                                 , _matches        :: HashTable Integer (Bool -> IO ())
                                 -- | HashTable is not thread safe, thread must aquire lock first
                                 , _matchesLock    :: MVar ()
                                 -- | Channel for notifications
                                 , _notifyChan     :: Chan StratumResponse
                                 -- | Channel for share submissions
                                 , _submitChan     :: Chan StratumRequest
                                 , _settings       :: ServerSettings
                                 }

-- | Thread safe access to hashtable
withMatches :: HandlerState -> (HashTable Integer (Bool -> IO ()) -> IO ()) -> IO ()
withMatches global f = withMVar (_matchesLock global) $ const $ f $ _matches global

handlerInitalise :: ServerSettings -> IO HandlerState
handlerInitalise settings = HandlerState    <$>
                            newIORef 0      <*>
                            newIORef 0      <*>
                            H.new           <*>
                            newMVar ()      <*>
                            newChan         <*>
                            newChan         <*>
                            return settings

-- | Initalises client state
--   TODO: add more data as neccessary
initaliseClient :: Handle -> HandlerState -> IO ClientState
initaliseClient handle _ = ClientState   <$>
                           return handle <*>
                           newIORef []

handleClient :: HandlerState -> ClientState -> IO ()
handleClient global local = do
    let processRequest :: (Monad m, MonadIO m) => (Maybe Request -> MaybeT m a) -> m (Maybe a)
        processRequest f = runMaybeT $ forever $ do
            line <- liftIO $ BS.hGetLine $ _handle local
            f $ decodeStrict line

        -- | Write server response
        writeResponse :: Value -> StratumResponse -> IO ()
        writeResponse rid resp = B8.hPutStrLn (_handle local) . BL.toStrict . encode $ Response rid resp

        en2Size :: Int
        en2Size = _extraNonce2Size . _settings $ global

        nextNonce :: IO Integer
        nextNonce = atomicModifyIORef' (_nonceCounter global) $ join (&&&) $ \x -> (x + 1) `mod` (2 ^ (8 * en2Size))

        recordChild :: ThreadId -> IO ()
        recordChild tid = modifyIORef' (_children local) (tid:)

    -- TODO: Time out client if non initialisation
    -- wait for mining.subscription call
    _ <- processRequest $ \req -> case req of
        Just (Request rid Subscribe) -> do
            -- reply with initalisation, set extraNonce1 as empty
            -- it'll be reinserted by the work notification
            liftIO $ writeResponse rid $ Initalise "" $ _extraNonce3Size . _settings $ global
            mzero
        _ -> return ()

    -- proxy server notifications
    (recordChild =<<) . forkIO . forever $ do
        note <- readChan (_notifyChan global)
        case note of
            -- coinbase1 is usually massive, so appending at the back will cost us a lot, we'll have to hand serialise this
            WorkNotify job prev cb1 cb2 merkle bv nbit ntime clean extraNonce1 _ -> liftIO $ do
                -- get generate unique client nonce
                nonce <- nextNonce

                TL.hPutStr (_handle local) $ TL.toLazyText $ foldr1 (<>) $ map TL.fromText
                    [ "{id:null,error:null,method:\"mining.notify\",params:["
                    , "\"", job, "\","
                    , "\"", prev, "\",\""
                    ]
                T.hPutStr (_handle local) cb1
                -- append things to cb1
                TL.hPutStr (_handle local) $ TL.toLazyText $ foldr1 (<>) $ map TL.fromText
                    [ extraNonce1
                    , T.pack $ printf "%0*x" en2Size nonce
                    , "\",\"", cb2, "\","
                    , "\"", T.decodeUtf8 (BL.toStrict $ encode merkle), "\","
                    , "\"", bv, "\","
                    , "\"", nbit, "\","
                    , "\"", ntime, "\","
                    , if clean then "true" else "false"
                    , "]}\n"
                    ]

            sd@(SetDifficulty{}) -> liftIO $ writeResponse Null sd
            _ -> error "Invalid notify command"

    -- wait for mining.authorization call
    user <- processRequest $ \req -> case req of
        Just (Request _ (Authorize user _)) -> return user
        _ -> return "Anonmyous"

    -- process workers submissions
    _ <- processRequest $ \req -> case req of
        Just (Request rid (Submit worker job en2 ntime nonce)) -> return ()
        _ -> return ()

    return ()

finaliseClient :: ClientState -> IO ()
finaliseClient local = do
    hClose $ _handle local
    readIORef (_children local) >>= mapM_ killThread

handleServer :: Handle -> HandlerState -> IO ()
handleServer handle global = do
    -- subscribe to mining
    -- warn about bad en sizes
    return ()
