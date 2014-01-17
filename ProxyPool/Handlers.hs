{-# LANGUAGE OverloadedStrings, LambdaCase #-}
module ProxyPool.Handlers (
    initaliseGlobal,

    initaliseClient,
    handleClient,
    finaliseClient,

    initaliseServer,
    handleServer,
    finaliseServer,

    GlobalState,
    ServerSettings(..)) where

-- TODO: clean up error outputs

import ProxyPool.Stratum

import System.IO (Handle, hClose)

import Control.Applicative ((<$>), (<*>))
import Control.Arrow ((&&&))

import Control.Monad (forever, join)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Trans.Either

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

data HandlerState
    = HandlerState { _handle   :: Handle
                   , _children :: IORef [ThreadId]
                   }

data ServerState
    = ServerState { s_handler   :: HandlerState
                  }

data ClientState
    = ClientState { c_handler      :: HandlerState
                  , c_currentNonce :: IORef Integer
                  }

data ServerSettings
    = ServerSettings { _username        :: T.Text
                     , _password        :: T.Text
                     , _extraNonce2Size :: Int
                     , _extraNonce3Size :: Int
                     } deriving (Show)

data GlobalState
    = GlobalState { _nonceCounter   :: IORef Integer
                  , _matchCounter   :: IORef Integer
                  -- | Matches server responses with a handler
                  , _matches        :: HashTable Integer (StratumResponse -> IO ())
                  -- | HashTable is not thread safe, thread must aquire lock first
                  , _matchesLock    :: MVar ()
                  -- | Channel for notifications
                  , _notifyChan     :: Chan StratumResponse
                  -- | Channel for upstream requests
                  , _upstreamChan   :: Chan Request
                  , _settings       :: ServerSettings
                  }

-- | Send request to upstream, taking the request and a callback
upstreamRequest :: GlobalState -> StratumRequest -> (StratumResponse -> IO ()) -> IO ()
upstreamRequest global request callback = do
    -- generate a new request ID
    rid <- atomicModifyIORef' (_matchCounter global) $ join (&&&) (1+)
    -- save the callback
    withMVar (_matchesLock global) $ const $ H.insert (_matches global) rid callback
    -- send request to the upstream listener
    writeChan (_upstreamChan global) $ Request (Number . fromInteger $ rid) request

-- | Run the callback when an upstream response has arrived
upstreamResponse :: GlobalState -> Integer -> StratumResponse -> IO ()
upstreamResponse global rid resp = do
    callback <- withMVar (_matchesLock global) $ const $ do
        result <- H.lookup (_matches global) rid
        case result of
            Just cb -> do
                H.delete (_matches global) rid
                return cb
            Nothing -> return $ const $ putStrLn $ "Invalid rid: " ++ show rid ++ show resp

    callback resp

initaliseGlobal :: ServerSettings -> IO GlobalState
initaliseGlobal settings = GlobalState     <$>
                           newIORef 0      <*>
                           newIORef 0      <*>
                           H.new           <*>
                           newMVar ()      <*>
                           newChan         <*>
                           newChan         <*>
                           return settings

initaliseHandler :: Handle -> IO HandlerState
initaliseHandler handle = HandlerState <$> return handle <*> newIORef []

finaliseHandler :: HandlerState -> IO ()
finaliseHandler state = do
    hClose $ _handle state
    readIORef (_children state) >>= mapM_ killThread

-- | Initalises client state
--   TODO: add more data as neccessary
initaliseClient :: Handle -> GlobalState -> IO ClientState
initaliseClient handle _ = ClientState             <$>
                           initaliseHandler handle <*>
                           newIORef 0

recordChild :: HandlerState -> ThreadId -> IO ()
recordChild handler tid = modifyIORef' (_children $ handler) (tid:)

process :: (Monad m, MonadIO m, FromJSON a) => Handle -> (Maybe a -> EitherT b m ()) -> m b
process handle f = do
    result <- runEitherT $ forever $ do
        line <- liftIO $ BS.hGetLine $ handle
        f $ decodeStrict line

    return $ either id (error "impossible") result

finish :: Monad m => e -> EitherT e m a
finish = left

continue :: Monad m => EitherT e m ()
continue = return ()

handleClient :: GlobalState -> ClientState -> IO ()
handleClient global local = do
    let
        -- | Write server response
        writeResponse :: Value -> StratumResponse -> IO ()
        writeResponse rid resp = B8.hPutStrLn handle . BL.toStrict . encode $ Response rid resp

        en2Size :: Int
        en2Size = _extraNonce2Size . _settings $ global

        nextNonce :: IO Integer
        nextNonce = atomicModifyIORef' (_nonceCounter global) $ join (&&&) $ \x -> (x + 1) `mod` (2 ^ (8 * en2Size))

        packEn2 :: Integer -> T.Text
        packEn2 nonce = T.pack $ printf "%0*x" en2Size nonce

        handle :: Handle
        handle = _handle . c_handler $ local

    -- TODO: Time out client if non initialisation
    -- wait for mining.subscription call
    process handle $ \case
        Just (Request rid Subscribe) -> do
            -- reply with initalisation, set extraNonce1 as empty
            -- it'll be reinserted by the work notification
            liftIO $ writeResponse rid $ Initalise "" $ _extraNonce3Size . _settings $ global
            finish ()
        _ -> continue

    -- proxy server notifications
    (recordChild (c_handler local) =<<) . forkIO . forever $ do
        readChan (_notifyChan global) >>= \case
            -- coinbase1 is usually massive, so appending at the back will cost us a lot, we'll have to hand serialise this
            WorkNotify job prev cb1 cb2 merkle bv nbit ntime clean extraNonce1 _ -> liftIO $ do
                -- get generate unique client nonce
                nonce <- nextNonce

                TL.hPutStr handle $ TL.toLazyText $ foldr1 (<>) $ map TL.fromText
                    [ "{id:null,error:null,method:\"mining.notify\",params:["
                    , "\"", job, "\","
                    , "\"", prev, "\",\""
                    ]
                T.hPutStr handle cb1
                -- append things to cb1
                TL.hPutStr handle $ TL.toLazyText $ foldr1 (<>) $ map TL.fromText
                    [ extraNonce1
                    , packEn2 nonce
                    , "\",\"", cb2, "\","
                    , "\"", T.decodeUtf8 (BL.toStrict $ encode merkle), "\","
                    , "\"", bv, "\","
                    , "\"", nbit, "\","
                    , "\"", ntime, "\","
                    , if clean then "true" else "false"
                    , "]}\n"
                    ]

                atomicWriteIORef (c_currentNonce local) nonce

            sd@(SetDifficulty{}) -> liftIO $ writeResponse Null sd
            _ -> error "Invalid notify command"

    -- wait for mining.authorization call
    user <- process handle $ \case
        Just (Request rid (Authorize user _)) -> do
            liftIO $ writeResponse rid $ General $ Right $ Bool True
            finish user
        _ -> continue

    -- process workers submissions (forever)
    process handle $ \case
        Just (Request rid req) -> liftIO $ do
            -- prepend the nonce
            nonce <- readIORef $ c_currentNonce local
            -- generate a new server request
            upstreamRequest global (req { s_extraNonce2 = packEn2 nonce <> s_extraNonce2 req }) $ \resp -> do
                -- record if share was accepted
                case resp of
                    General (Right _) -> T.putStrLn $ "Share accepted" <> user
                    General (Left _)  -> T.putStrLn $ "Share rejected" <> user
                    _ -> return ()

                writeResponse rid resp
        _ -> continue

finaliseClient :: ClientState -> IO ()
finaliseClient = finaliseHandler . c_handler

initaliseServer :: Handle -> IO ServerState
initaliseServer handle = ServerState <$> initaliseHandler handle

handleServer :: GlobalState -> ServerState -> IO ()
handleServer global local = do
    let
        handle :: Handle
        handle = _handle . s_handler $ local

        writeRequest :: Request -> IO ()
        writeRequest = B8.hPutStrLn handle . BL.toStrict . encode

    -- subscribe to mining
    writeRequest $ Request (Number 1) Subscribe

    -- wait for subscription response
    (extraNonce1, originalEn2Size) <- process handle $ \case
        Just (Response (Number 1) (Initalise en1 oen2s)) -> finish (en1, oen2s)
        _ -> continue

    -- authorize
    writeRequest $ Request (Number 2) $ Authorize (_username . _settings $ global) (_password . _settings $ global)

    -- wait for authorization response
    process handle $ \case
        Just (Response (Number 2) (General (Right _))) -> finish ()
        Just (Response (Number 2) (General (Left _)))  -> error "Upstream authorisation failed"
        _ -> continue

    -- thread to listen for server notifications
    (recordChild (s_handler local) =<<) . forkIO $ do
        process handle $ liftIO . \case
            Just (Response _ wn@(WorkNotify{})) -> writeChan (_notifyChan global) $ wn { wn_extraNonce1 = extraNonce1, wn_originalEn2Size = originalEn2Size }
            Just (Response _ sd@(SetDifficulty{})) -> writeChan (_notifyChan global) sd
            Just (Response (Number rid) gn@(General{})) -> upstreamResponse global (floor rid) gn
            _ -> return ()

    -- thread to listen to client requests (forever)
    forever $ readChan (_upstreamChan global) >>= writeRequest

finaliseServer :: ServerState -> IO ()
finaliseServer = finaliseHandler . s_handler
