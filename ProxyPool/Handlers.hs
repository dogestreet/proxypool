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

import ProxyPool.Stratum
import ProxyPool.Mining

import System.IO (Handle, hClose)
import System.Log.Logger

import Control.Applicative ((<$>), (<*>))
import Control.Arrow ((&&&))

import Control.Monad (forever, join, when, unless)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Trans.Either

import Control.Concurrent (forkIO, ThreadId, killThread, threadDelay)
import Control.Concurrent.Chan

import Data.IORef
import Data.Aeson

import Data.Monoid ((<>))

import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Lazy.Builder as TL
import qualified Data.Text.Lazy.Encoding as TL

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy.Builder as B
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as BL

data HandlerState
    = HandlerState { _handle   :: Handle
                   , _children :: IORef [ThreadId]
                   }

data ServerState
    = ServerState { s_handler    :: HandlerState
                  , s_writerChan :: Chan B.ByteString
                  }

data ClientState
    = ClientState { c_handler      :: HandlerState
                  , c_writerChan   :: Chan B.ByteString
                  , c_job          :: IORef Job
                  , c_difficulty   :: IORef Double
                  -- | Number of shares submitted by the client since last vardiff retarget
                  , c_lastShares   :: IORef Int
                  }

data ServerSettings
    = ServerSettings { _username            :: T.Text
                     , _password            :: T.Text
                     -- | Size of the new en2
                     , _extraNonce2Size     :: Int
                     -- | Size of the new en3
                     , _extraNonce3Size     :: Int
                     -- | Time (s) between vardiff updates
                     , _vardiffRetargetTime :: Int
                     -- | Target shares retarget time
                     , _vardiffTarget       :: Int
                     -- | Allow variances to be within this range
                     , _vardiffAllowance    :: Double
                     -- | Minimum allowable difficulty
                     , _vardiffMin          :: Double
                     } deriving (Show)

data GlobalState
    = GlobalState { _nonceCounter   :: IORef Integer
                  , _matchCounter   :: IORef Integer
                  -- | Channel for notifications
                  , _notifyChan     :: Chan StratumResponse
                  -- | Channel for upstream requests
                  , _upstreamChan   :: Chan Request
                  , _upstreamDiff   :: IORef Double
                  , _currentWork    :: IORef Work
                  , _settings       :: ServerSettings
                  }

data Job
    = Job { _jobID  :: T.Text
          , _nonce1 :: (Integer, Int)
          , _nonce2 :: (Integer, Int)
          }
    deriving (Show)

-- | Send request to upstream, taking the request and a callback
upstreamRequest :: GlobalState -> StratumRequest -> IO ()
upstreamRequest global request = do
    -- generate a new request ID
    rid <- atomicModifyIORef' (_matchCounter global) $ join (&&&) (1+)
    -- send request to the upstream listener
    writeChan (_upstreamChan global) $ Request (Number . fromInteger $ rid) request

initaliseGlobal :: ServerSettings -> IO GlobalState
initaliseGlobal settings = GlobalState        <$>
                           newIORef 0         <*>
                           newIORef 0         <*>
                           newChan            <*>
                           newChan            <*>
                           newIORef 0.0       <*>
                           newIORef emptyWork <*>
                           return settings

initaliseHandler :: Handle -> IO HandlerState
initaliseHandler handle = HandlerState <$> return handle <*> newIORef []

finaliseHandler :: HandlerState -> IO ()
finaliseHandler state = do
    hClose $ _handle state
    readIORef (_children state) >>= mapM_ killThread

-- | Initalises client state
initaliseClient :: Handle -> GlobalState -> IO ClientState
initaliseClient handle _ = ClientState                   <$>
                           initaliseHandler handle       <*>
                           newChan                       <*>
                           newIORef (Job "" (0,0) (0,0)) <*>
                           newIORef 0.000488             <*>
                           newIORef 0

recordChild :: HandlerState -> ThreadId -> IO ()
recordChild handler tid = modifyIORef' (_children $ handler) (tid:)

process :: (Monad m, MonadIO m, FromJSON a) => Handle -> (Maybe a -> EitherT b m ()) -> m b
process handle f = do
    result <- runEitherT $ forever $ do
        line <- liftIO $ B.hGetLine $ handle
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
        writeResponse rid resp = writeResponseRaw $ BL.toStrict . encode $ Response rid resp

        writeResponseRaw :: B.ByteString -> IO ()
        writeResponseRaw = writeChan (c_writerChan local)

        en2Size :: Int
        en2Size = _extraNonce2Size . _settings $ global

        nextNonce :: IO Integer
        nextNonce = atomicModifyIORef' (_nonceCounter global) $ join (&&&) $ \x -> (x + 1) `mod` (2 ^ (8 * en2Size))

        packEn2 :: Integer -> T.Text
        packEn2 nonce = toHex $ BL.toStrict $ B.toLazyByteString $ packIntLE nonce en2Size

        handle :: Handle
        handle = _handle . c_handler $ local

    -- thread to sequence writes
    (recordChild (c_handler local) =<<) . forkIO . forever $ do
        line <- readChan (c_writerChan local)
        B8.hPutStrLn handle line

    -- TODO: Time out client if non initialisation
    -- wait for mining.subscription call
    process handle $ \case
        Just (Request rid Subscribe) -> do
            -- reply with initalisation, set extraNonce1 as empty
            -- it'll be reinserted by the work notification
            liftIO $ writeResponse rid $ Initalise "" $ _extraNonce3Size . _settings $ global
            finish ()
        _ -> continue

    -- duplicate server notification channel
    localNotifyChan <- dupChan (_notifyChan global)

    -- proxy server notifications
    (recordChild (c_handler local) =<<) . forkIO . forever $ do
        readChan localNotifyChan >>= \case
            -- coinbase1 is usually massive, so appending at the back will cost us a lot, we'll have to hand serialise this
            WorkNotify job prev cb1 cb2 merkle bv nbit ntime clean extraNonce1 _ -> liftIO $ do
                -- get generate unique client nonce
                nonce <- nextNonce

                -- change the current job
                atomicWriteIORef (c_job local) $ Job job (unpackIntLE . fromHex $ extraNonce1, T.length extraNonce1 `quot` 2) (nonce, en2Size)

                -- set difficulty
                diff <- readIORef $ c_difficulty local
                writeResponse Null $ SetDifficulty $ diff * 65536

                -- set the work
                writeResponseRaw $ BL.toStrict $ TL.encodeUtf8 $ TL.toLazyText $ foldr1 (<>) $ map TL.fromText
                    [ "{\"id\":null,\"error\":null,\"method\":\"mining.notify\",\"params\":["
                    , "\"", job, "\","
                    , "\"", prev, "\",\""
                    , cb1
                    , extraNonce1
                    , packEn2 nonce
                    , "\",\"", cb2, "\","
                    , T.decodeUtf8 (BL.toStrict $ encode merkle), ","
                    , "\"", bv, "\","
                    , "\"", nbit, "\","
                    , "\"", ntime, "\","
                    , if clean then "true" else "false"
                    , "]}"
                    ]

            -- cap vardiff at upstream difficulty
            SetDifficulty diff -> liftIO $ atomicModifyIORef (c_difficulty local) $ max (diff / 65536) &&& const ()
            _ -> return ()

    -- wait for mining.authorization call
    user <- process handle $ \case
        Just (Request rid (Authorize user _)) -> do
            liftIO $ writeResponse rid $ General $ Right $ Bool True
            finish user
        _ -> continue

    infoM "client" $ T.unpack $ "Client " <> user <> " connected"

    -- vardiff thread
    (recordChild (c_handler local) =<<) . forkIO . forever $ do
        let retargetTime     = _vardiffRetargetTime . _settings $ global
            target           = _vardiffTarget       . _settings $ global
            targetAllowance  = _vardiffAllowance    . _settings $ global
            minDifficulty    = _vardiffMin          . _settings $ global

        -- wait till retarget
        threadDelay $ retargetTime * 10^(6 :: Integer)

        accepted    <- fromIntegral <$> (readIORef $ c_lastShares local)
        currentDiff <- readIORef $ c_difficulty local

        -- convert accepted shares, difficulty to hashrate
        let estimatedHash = ad2h (accepted            * (60 / fromIntegral retargetTime)) currentDiff
            currentHash   = ad2h (fromIntegral target * (60 / fromIntegral retargetTime)) currentDiff

        -- check if hashrate is in vardiff allowance
        unless (currentHash * (1 - targetAllowance) < estimatedHash && estimatedHash < currentHash * (1 + targetAllowance)) $ do
            upstreamDiff <- readIORef $ _upstreamDiff global
            -- cap difficulty to min and upstream
            let newDiff = min (max minDifficulty $ ah2d (fromIntegral target * (60 / fromIntegral retargetTime)) estimatedHash) upstreamDiff

            writeIORef (c_difficulty local) newDiff
            writeResponse Null $ SetDifficulty $ newDiff * 65536

        -- clear the share counter
        writeIORef (c_lastShares local) 0

    -- process workers submissions (forever)
    process handle $ \case
        Just (Request rid sub@(Submit{})) -> liftIO $ do
            job  <- readIORef $ c_job local
            diff <- readIORef $ c_difficulty local
            work <- readIORef $ _currentWork global

            let submitDiff = targetToDifficulty $ getPOW sub work (_nonce1 job) (_nonce2 job) (_extraNonce3Size . _settings $ global) scrypt

            -- verify job and share difficulty
            if s_job sub == _jobID job && submitDiff >= diff
                then do
                    -- check if it meets upstream difficulty
                    upstreamDiff <- readIORef $ _upstreamDiff global

                    -- submit share to upstream
                    when (submitDiff >= upstreamDiff) $ upstreamRequest global (sub { s_extraNonce2 = packEn2 (fst . _nonce2 $ job) <> s_extraNonce2 sub })

                    -- write response
                    writeResponse rid $ General $ Right $ Bool True
                else do
                -- stale or invalid
                    writeResponse rid $ General $ Left $ Bool False

            -- TODO share logging

            -- record share for vardiff
            atomicModifyIORef' (c_lastShares local) $ (1+) &&& const ()

        _ -> continue

finaliseClient :: ClientState -> IO ()
finaliseClient = finaliseHandler . c_handler

initaliseServer :: Handle -> IO ServerState
initaliseServer handle = ServerState <$> initaliseHandler handle <*> newChan

handleServer :: GlobalState -> ServerState -> IO ()
handleServer global local = do
    let
        handle :: Handle
        handle = _handle . s_handler $ local

        writeRequest :: Request -> IO ()
        writeRequest = writeChan (s_writerChan local) . BL.toStrict . encode

    -- thread to sequence writes
    (recordChild (s_handler local) =<<) . forkIO . forever $ do
        line <- readChan (s_writerChan local)
        B8.hPutStrLn handle line

    -- subscribe to mining
    infoM "server" "Sending mining subscription"
    writeRequest $ Request (Number 1) Subscribe

    -- wait for subscription response
    (extraNonce1, originalEn2Size) <- process handle $ \case
        Just (Response (Number 1) (Initalise en1 oen2s)) -> finish (en1, oen2s)
        _ -> continue

    infoM "server" "Received subscription response"
    -- verify nonce configuration
    when (originalEn2Size /= (_extraNonce2Size . _settings $ global) + (_extraNonce3Size . _settings $ global)) $ error $ "Invalid nonce sizes specified, must add up to " ++ show originalEn2Size

    -- authorize
    infoM "server" "Sending authorization"
    writeRequest $ Request (Number 2) $ Authorize (_username . _settings $ global) (_password . _settings $ global)

    -- wait for authorization response
    process handle $ \case
        Just (Response (Number 2) (General (Right _))) -> finish ()
        Just (Response (Number 2) (General (Left _)))  -> error "Upstream authorisation failed"
        _ -> continue

    infoM "server" "Upstream authorized"

    -- thread to listen for server notifications
    (recordChild (s_handler local) =<<) . forkIO $ do
        process handle $ liftIO . \case
            Just (Response _ wn@(WorkNotify{})) -> do
                case fromWorkNotify wn of
                    Just work -> do
                        writeIORef (_currentWork global) work
                        writeChan (_notifyChan global) $ wn { wn_extraNonce1 = extraNonce1, wn_originalEn2Size = originalEn2Size }
                    Nothing   -> errorM "server" "Invalid upstream work received"
            Just (Response _ (SetDifficulty diff)) -> atomicWriteIORef (_upstreamDiff global) (diff / 65536)
            Just (Response (Number _) (General (Right _))) -> debugM "share" $ "Upstream share accepted"
            Just (Response (Number _) (General (Left  _))) -> debugM "share" $ "Upstream share rejected"
            _ -> return ()

    -- thread to listen to client requests (forever)
    forever $ readChan (_upstreamChan global) >>= writeRequest

finaliseServer :: ServerState -> IO ()
finaliseServer = finaliseHandler . s_handler
