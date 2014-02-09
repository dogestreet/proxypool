{-# LANGUAGE OverloadedStrings, LambdaCase, BangPatterns, DeriveDataTypeable, MultiWayIf #-}
module ProxyPool.Handlers (
    initaliseGlobal
  , initaliseClient
  , handleClient
  , finaliseClient

  , initaliseServer
  , handleServer
  , finaliseServer

  , initaliseDB
  , handleDB
  , finaliseDB

  , GlobalState
  , ServerSettings(..)

  , ProxyPoolException
) where

import ProxyPool.Stratum
import ProxyPool.Mining

import System.IO (Handle, hClose)
import System.Log.Logger
import System.Timeout

import Control.Applicative ((<$>), (<*>))
import Control.Arrow ((&&&))

import Control.Monad (forever, join, when, unless, mzero)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Trans.Either

import Control.Exception hiding (handle)

import Control.Concurrent.STM

import Control.Concurrent (threadDelay)
import Control.Concurrent.Chan
import Control.Concurrent.Async

import Control.Concurrent.MVar

import Data.IORef
import Data.Aeson
import Data.Word
import Data.Typeable
import Data.Monoid ((<>), mconcat, mempty)

import Data.Time.Clock.POSIX

import qualified Data.Vector as V

import qualified Data.Text as T
import qualified Data.Text.Encoding as T

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy.Builder as B
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Base16.Lazy as BL16

import qualified Database.Redis as R

data HandlerState a
    = HandlerState { h_handle   :: a
                   , h_children :: IORef [Async ()]
                   }

data ServerState
    = ServerState { s_handler    :: HandlerState Handle
                  , s_writerChan :: Chan B.ByteString
                  }

data ClientState
    = ClientState { c_handler          :: HandlerState Handle
                  , c_writerChan       :: Chan B.Builder
                  , c_nonce            :: IORef Integer
                  -- | Local difficulty managed by vardiff
                  , c_difficulty       :: TVar Double
                  -- | Number of shares submitted by the client since last vardiff retarget
                  , c_lastShares       :: TVar Int
                  -- | Number of dead shares submitted by the client since last vardiff retarget
                  , c_lastSharesDead   :: TVar Int
                  -- | When was the last vardiff run
                  , c_lastVardiff      :: TVar POSIXTime
                  -- | Uniquely identifies this client
                  , c_id               :: !Integer
                  -- | Hostname of the client
                  , c_host             :: String
                  }

data DBState
    = DBState { d_handler :: HandlerState R.Connection
              }

data ServerSettings
    = ServerSettings { s_serverName          :: T.Text
                     -- | Host name of the upstream pool
                     , _upstreamHost         :: T.Text
                     -- | Port of the upstream pool
                     , _upstreamPort         :: Word16
                     -- | Port to listen to for workers
                     , _localPort            :: Word16
                     -- | Username to login to upstream pool
                     , s_username            :: T.Text
                     -- | Password to login to upstream pool
                     , s_password            :: T.Text
                     -- | Using redis to pubsub shares
                     , _redisHost            :: T.Text
                     -- | Authentication for redis
                     , _redisAuth            :: Maybe T.Text
                     -- | The redis channel to publish to
                     , s_redisChanName       :: T.Text
                     -- | The byte prepended to the public key, used to verify miner addresses, 0 for Bitcoin, 30 for Dogecoin
                     , s_publickeyByte       :: Word8
                     -- | Size of the new en2
                     , s_extraNonce2Size     :: Int
                     -- | Size of the new en3
                     , s_extraNonce3Size     :: Int
                     -- | Time (s) between vardiff updates
                     , s_vardiffRetargetTime :: Int
                     -- | Target shares retarget time
                     , s_vardiffTarget       :: Int
                     -- | Allow variances to be within this range
                     , s_vardiffAllowance    :: Double
                     -- | Minimum allowable difficulty
                     , s_vardiffMin          :: Double
                     -- | Number of shares before vardiff is forced to activate, varidiff runs if the number of shares submitted is > this or _vardiffRetargetTime seconds have elapsed
                     , s_vardiffShares       :: Int
                     -- | How many minutes does ban take to expire
                     , s_banExpiry           :: Int
                     } deriving (Show)

instance FromJSON ServerSettings where
    parseJSON (Object v) = ServerSettings             <$>
                           v .: "serverName"          <*>
                           v .: "upstreamHost"        <*>
                           v .: "upstreamPort"        <*>
                           v .: "localPort"           <*>
                           v .: "username"            <*>
                           v .: "password"            <*>
                           v .: "redisHost"           <*>
                           v .: "redisAuth"           <*>
                           v .: "redisChanName"       <*>
                           v .: "publicKeyByte"       <*>
                           v .: "extraNonce2Size"     <*>
                           v .: "extraNonce3Size"     <*>
                           v .: "vardiffRetargetTime" <*>
                           v .: "vardiffTarget"       <*>
                           v .: "vardiffAllowance"    <*>
                           v .: "vardiffMin"          <*>
                           v .: "vardiffShares"       <*>
                           v .: "banExpiry"

    parseJSON _          = mzero

data GlobalState
    = GlobalState { g_clientCounter  :: IORef Integer
                  , g_nonceCounter   :: IORef Integer
                  , g_matchCounter   :: IORef Integer
                  , g_extraNonce1    :: IORef B.ByteString
                  , g_upstreamDiff   :: IORef Double
                  , g_work           :: IORef (Work, B.Builder, B.Builder)
                  -- | Channel for work notifications
                  , g_notifyChan     :: Chan JobNotify
                  -- | Channel for upstream requests
                  , g_upstreamChan   :: Chan Request
                  -- | Channel for share logging broadcasts
                  , g_shareChan      :: Chan Share
                  -- | Channel used to ban hosts
                  , g_banChan        :: Chan String
                  -- | Channel used to request checks on the host
                  , g_checkChan      :: Chan (String, Bool -> IO ())
                  , g_settings       :: ServerSettings
                  }

data JobNotify = JobNotify | DiffNotify

data Share
    = Share { _sh_submitter  :: {-# UNPACK #-} !T.Text
            , _sh_difficulty :: {-# UNPACK #-} !Double
            , _sh_server     :: {-# UNPACK #-} !T.Text
            , _sh_valid      ::                !Bool
            }
    deriving (Show, Typeable)

instance ToJSON Share where
    toJSON (Share sub diff srv valid) = object [ "sub"   .= sub
                                               , "diff"  .= diff
                                               , "srv"   .= srv
                                               , "valid" .= valid
                                               ]

data ProxyPoolException = KillClientException { _reason :: String }
                        | KillServerException { _reason :: String }
                        deriving (Show, Typeable)

instance Exception ProxyPoolException

-- | Increments an IORef counter
incr :: IORef Integer -> IO Integer
incr counter = atomicModifyIORef' counter $ join (&&&) (1+)

initaliseGlobal :: ServerSettings -> IO GlobalState
initaliseGlobal settings = GlobalState                          <$>
                           newIORef 0                           <*>
                           newIORef 0                           <*>
                           newIORef 0                           <*>
                           newIORef ""                          <*>
                           newIORef 0                           <*>
                           newIORef (emptyWork, mempty, mempty) <*>
                           newChan                              <*>
                           newChan                              <*>
                           newChan                              <*>
                           newChan                              <*>
                           newChan                              <*>
                           return settings

initaliseHandler :: a -> IO (HandlerState a)
initaliseHandler handle = HandlerState <$> return handle <*> newIORef []

finaliseHandler :: HandlerState Handle -> IO ()
finaliseHandler state = do
    hClose $ h_handle state
    readIORef (h_children state) >>= mapM_ cancel

-- | Initalises client state
initaliseClient :: Handle -> String -> GlobalState -> IO ClientState
initaliseClient handle host global = ClientState                   <$>
                                     initaliseHandler handle       <*>
                                     newChan                       <*>
                                     newIORef  0                   <*>
                                     newTVarIO 0.000488            <*>
                                     newTVarIO 0                   <*>
                                     newTVarIO 0                   <*>
                                     newTVarIO 0                   <*>
                                     incr (g_clientCounter global) <*>
                                     return host

-- | Record child threads as well as ensuring child thread death triggers an exception on the parent
linkChild :: HandlerState a -> Async () -> IO ()
linkChild handler asy = modifyIORef' (h_children $ handler) (asy:) >> link asy

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
        writeResponse rid resp = writeResponseRaw $ B.lazyByteString $ encode $ Response rid resp

        writeResponseRaw :: B.Builder -> IO ()
        writeResponseRaw = writeChan (c_writerChan local)

        en2Size :: Int
        en2Size = s_extraNonce2Size . g_settings $ global

        packEn2 :: Integer -> BL.ByteString
        packEn2 = BL16.encode . B.toLazyByteString . flip packIntLE en2Size

        handle :: Handle
        handle = h_handle . c_handler $ local

        -- | Send request to upstream, taking the request and a callback
        upstreamRequest :: StratumRequest -> IO ()
        upstreamRequest request = do
            -- generate a new request ID
            rid <- incr $ g_matchCounter global
            -- send request to the upstream listener
            writeChan (g_upstreamChan global) $ Request (Number . fromInteger $ rid) request

    infoM "client" $ "Client (" ++ show (c_id local) ++ ") from " ++ show (c_host local) ++ " connected"

    -- thread to sequence writes
    (linkChild (c_handler local) =<<) . async . forever $ do
        line <- readChan (c_writerChan local)
        B.hPutBuilder handle $ line <> B.char8 '\n'

    -- check if the IP is banned
    banned <- liftIO $ do
        waiter <- newEmptyMVar
        writeChan (g_checkChan global) (c_host local, putMVar waiter)
        takeMVar waiter

    -- wait for mining.subscription call
    initalised <- timeout (30 * 10^(6 :: Int)) $ process handle $ \case
        Just (Request rid Subscribe) -> do
            -- reply with initalisation, set extraNonce1 as empty
            -- it'll be reinserted by the work notification
            liftIO $ writeResponse rid $ Initalise "" $ s_extraNonce3Size . g_settings $ global
            finish ()
        _ -> continue

    maybe (throwIO $ KillClientException "Took too long to initalise") (const $ return ()) initalised

    -- proxy server notifications
    (linkChild (c_handler local) =<<) . async $ unless banned $ do
        -- duplicate server notification channel
        localNotifyChan <- dupChan (g_notifyChan global)

        let writeJobNotify = do
                (_, part1, part2) <- readIORef $ g_work global

                -- get generate unique client nonce
                nonce <- atomicModifyIORef' (g_nonceCounter global) $ join (&&&) $ \x -> (x + 1) `mod` (2 ^ (8 * en2Size))
                writeIORef (c_nonce local) nonce

                writeResponseRaw $ part1 <> (B.lazyByteString . packEn2 $ nonce) <> part2
            writeDiffNotify = do
                upstreamDiff <- readIORef $ g_upstreamDiff global
                -- cap local difficulty at upstream diff
                newDiff <- atomically $ do
                    diff <- readTVar $ c_difficulty local
                    let newDiff = min diff upstreamDiff
                    writeTVar (c_difficulty local) newDiff
                    return newDiff
                writeResponse Null $ SetDifficulty $ newDiff * 65536

        -- immediately send a job to the client if possible
        (work, _, _) <- readIORef $ g_work global
        when (work /= emptyWork) $ do
            writeDiffNotify
            writeJobNotify

        forever $ readChan localNotifyChan >>= \case
            JobNotify  -> writeJobNotify
            DiffNotify -> writeDiffNotify

    -- wait for mining.authorization call
    user <- process handle $ \case
        Just (Request rid (Authorize user _)) -> do
            -- check if the address they are using is a valid address
            let valid = validateAddress (s_publickeyByte . g_settings $ global) $ T.encodeUtf8 user

            if | banned -> liftIO $ writeResponse rid $ General $ Left $ Array $ V.fromList [ Number (-1), String $ "Your IP address is banned for too many invalid share submissions, the ban expires in " <> (T.pack . show . s_banExpiry . g_settings $ global) <> " minutes" ]
               | valid  -> do
                     liftIO $ writeResponse rid $ General $ Right $ Bool True
                     finish user
               | otherwise -> liftIO $ writeResponse rid $ General $ Left $ Array $ V.fromList [ Number (-2), String "Username is not a valid address" ]

        _ -> continue

    infoM "client" $ "Client (" ++ show (c_id local) ++ ") authorized - " ++ T.unpack user

    vardiffTrigger <- newEmptyMVar
    getPOSIXTime >>= atomically . writeTVar (c_lastVardiff local)

    -- vardiff trigger thread
    (linkChild (c_handler local) =<<) . async . forever $ do
        threadDelay $ (s_vardiffRetargetTime . g_settings $ global) * 10^(6 :: Integer)
        putMVar vardiffTrigger ()

    -- vardiff/ban thread
    (linkChild (c_handler local) =<<) . async . forever $ do
        -- wait till trigger
        _ <- takeMVar vardiffTrigger

        -- find out when was vardiff last triggered
        currentTime <- getPOSIXTime

        let setDiff diff = do
                debugM "vardiff" $ "Vardiff client diff adjust: " ++ show (diff * 65536)
                writeResponse Null $ SetDifficulty $ diff * 65536
            banClient = do
                writeChan (g_banChan global) $ c_host local
                infoM "client" $ "Banned " ++ c_host local ++ " for too many dead shares"
                throw $ KillClientException "Too many dead shares submitted"
            doNothing = return ()

        upstreamDiff   <- readIORef $ g_upstreamDiff global

        -- run computations inside the transaction
        join $ atomically $ do
            lastTime    <- readTVar $ c_lastVardiff local

            let elapsedTime      = round $ currentTime - lastTime :: Integer
                retargetTime     = s_vardiffRetargetTime . g_settings $ global
                target           = s_vardiffTarget       . g_settings $ global
                targetAllowance  = s_vardiffAllowance    . g_settings $ global
                minDifficulty    = s_vardiffMin          . g_settings $ global

            lastShares     <- readTVar $ c_lastShares local
            lastSharesDead <- readTVar $ c_lastSharesDead local
            currentDiff    <- readTVar $ c_difficulty local

            -- clear the share counters
            writeTVar (c_lastShares local) 0
            writeTVar (c_lastSharesDead local) 0
            writeTVar (c_lastVardiff local) currentTime

            -- only run vardiff if it's time to do so, or we are over target
            if lastShares > target || elapsedTime >= fromIntegral retargetTime - 5
                then do
                    -- convert shares, difficulty to hashrate
                    let estimatedHash = ad2h (fromIntegral lastShares * (60 / fromIntegral elapsedTime)) currentDiff
                        currentHash   = ad2h (fromIntegral target     * (60 / fromIntegral elapsedTime)) currentDiff

                    -- ban the client if 90% of submitted shares are dead
                    if | lastShares > target && (fromIntegral lastSharesDead / fromIntegral lastShares :: Double) >= 0.9 -> return banClient

                    -- otherwise, check if hashrate is in vardiff allowance
                       | currentHash * (1 - targetAllowance) < estimatedHash && estimatedHash < currentHash * (1 + targetAllowance) -> do
                              -- cap difficulty to min and upstream
                              let newDiff = min (max minDifficulty $ ah2d (fromIntegral target * (60 / fromIntegral elapsedTime)) estimatedHash) upstreamDiff

                              writeTVar (c_difficulty local) newDiff
                              return $ setDiff newDiff

                       | otherwise -> return doNothing
                else do
                    -- do nothing if no adjustment is required
                    return doNothing

    -- process workers submissions (forever)
    process handle $ \case
        Just (Request rid sub@(Submit{})) -> liftIO $ do
            -- doesn't really matter if this race conditions
            diff          <- readTVarIO $ c_difficulty local
            nonce         <- readIORef $ c_nonce local
            (work, _, _)  <- readIORef $ g_work global
            en1           <- readIORef $ g_extraNonce1 global
            upstreamDiff  <- readIORef $ g_upstreamDiff global

            let submitDiff = targetToDifficulty $ getPOW sub work en1 (nonce, en2Size) (s_extraNonce3Size . g_settings $ global) scrypt

            -- verify job and share difficulty
            let valid = s_job sub == w_job work && submitDiff >= diff
            if valid
                then liftIO $ do
                    -- submit share to upstream
                    when (submitDiff >= upstreamDiff) $ upstreamRequest $ sub { s_worker = (s_username . g_settings $ global), s_extraNonce2 = (T.decodeUtf8 . BL.toStrict . packEn2 $ nonce) <> s_extraNonce2 sub }

                    -- write response
                    writeResponse rid $ General $ Right $ Bool True
                else liftIO $ do
                    -- stale or invalid
                    writeResponse rid $ General $ Left $ Array $ V.fromList [Number (-3), String "Invalid share"]

            -- log the share
            writeChan (g_shareChan global) $ Share user diff (s_serverName . g_settings $ global) valid

            -- record shares for vardiff
            atomically $ do
                modifyTVar' (c_lastShares local) (1+)
                unless valid $ modifyTVar' (c_lastSharesDead local) (1+)

            -- trigger vardiff if we are over target
            lastShares <- readTVarIO (c_lastShares local)
            when (lastShares >= (s_vardiffShares . g_settings $ global)) $ putMVar vardiffTrigger ()

        _ -> continue

finaliseClient :: ClientState -> IO ()
finaliseClient local = finaliseHandler . c_handler $ local

initaliseServer :: Handle -> IO ServerState
initaliseServer handle = ServerState <$> initaliseHandler handle <*> newChan

handleServer :: GlobalState -> ServerState -> IO ()
handleServer global local = do
    let
        handle :: Handle
        handle = h_handle . s_handler $ local

        writeRequest :: Request -> IO ()
        writeRequest = writeChan (s_writerChan local) . BL.toStrict . encode

    -- thread to sequence writes
    (linkChild (s_handler local) =<<) . async . forever $ do
        line <- readChan (s_writerChan local)
        B8.hPutStrLn handle line

    -- subscribe to mining
    infoM "server" "Sending mining subscription"
    writeRequest $ Request (Number 1) Subscribe

    -- wait for subscription response
    extraNonce1 <- process handle $ \case
        Just (Response (Number 1) (Initalise en1 oen2s)) -> do
            -- verify nonce configuration
            when (oen2s /= (s_extraNonce2Size . g_settings $ global) + (s_extraNonce3Size . g_settings $ global)) $ liftIO $ throwIO $ KillServerException $ "Invalid nonce sizes specified, must add up to " ++ show oen2s

            -- save the original nonce
            let en1Bytes = T.encodeUtf8 en1
            liftIO $ writeIORef (g_extraNonce1 global) en1Bytes
            finish en1Bytes

        _ -> continue

    -- authorize
    infoM "server" "Sending authorization"
    writeRequest $ Request (Number 2) $ Authorize (s_username . g_settings $ global) (s_password . g_settings $ global)

    -- wait for authorization response
    process handle $ \case
        Just (Response (Number 2) (General (Right _))) -> finish ()
        Just (Response (Number 2) (General (Left _)))  -> error "Upstream authorisation failed"
        _ -> continue

    infoM "server" "Upstream authorized"

    -- thread to listen for server notifications
    (linkChild (s_handler local) =<<) . async $ do
        process handle $ liftIO . \case
            Just (Response _ wn@(WorkNotify job prev cb1 cb2 merkle bv nbit ntime clean)) ->
                case fromWorkNotify wn of
                    Just work -> do
                        -- set the work
                        let fromParts = mconcat . map B.byteString
                            !part1    = fromParts [ "{\"id\":null,\"error\":null,\"method\":\"mining.notify\",\"params\":[\""
                                                  , T.encodeUtf8 job, "\",\""
                                                  , T.encodeUtf8 prev, "\",\""
                                                  , T.encodeUtf8 cb1
                                                  , extraNonce1
                                                  ]
                            !part2a   = fromParts [ "\",\"", T.encodeUtf8 cb2, "\"," ]
                            !part2b   = B.lazyByteString $ encode merkle
                            !part2c   = fromParts [ ",\""
                                                  , T.encodeUtf8 bv, "\",\""
                                                  , T.encodeUtf8 nbit, "\",\""
                                                  , T.encodeUtf8 ntime, "\","
                                                  , if clean then "true" else "false", "]}"
                                                  ]
                            !part2    = part2a <> part2b <> part2c

                        writeIORef (g_work global) (work, part1, part2)

                        -- notify listeners
                        writeChan (g_notifyChan global) JobNotify
                    Nothing   -> errorM "server" "Invalid upstream work received"
            Just (Response _ (SetDifficulty diff)) -> do
                -- save the upstream diff
                let newDiff = diff / 65536
                writeIORef (g_upstreamDiff global) newDiff
                writeChan (g_notifyChan global) DiffNotify
            Just (Response (Number _) (General (Right _))) -> debugM "share" $ "Upstream share accepted"
            Just (Response (Number _) (General (Left  _))) -> debugM "share" $ "Upstream share rejected"
            _ -> return ()

    -- thread to listen to client requests (forever)
    forever $ readChan (g_upstreamChan global) >>= writeRequest

finaliseServer :: ServerState -> IO ()
finaliseServer = finaliseHandler . s_handler

initaliseDB :: R.Connection -> IO DBState
initaliseDB conn = DBState <$> initaliseHandler conn

-- | Handle database queries
handleDB :: GlobalState -> DBState -> IO ()
handleDB global local = do
    let channel = T.encodeUtf8 $ s_redisChanName . g_settings $ global
        conn = h_handle . d_handler $ local

    -- test connection first
    _ <- R.runRedis conn R.ping
    infoM "db" "Redis connected"

    -- handle share logging
    (linkChild (d_handler local) =<<) $ async $ forever $ readChan (g_shareChan global) >>= \share -> do
        result <- R.runRedis conn $ R.publish channel $ BL.toStrict $ encode share
        case result of
            Right _ -> return ()
            Left  _ -> errorM "db" $ "Error while publishing share (" ++ show share ++ ")"

    -- checking IPs
    (linkChild (d_handler local) =<<) $ async $ forever $ readChan (g_checkChan global) >>= \(host, callback) -> do
        result <- R.runRedis conn $ R.exists $ "ipban:" <> B8.pack host
        case result of
            Right val -> callback val
            _         -> callback False

    -- banning IPs
    forever $ readChan (g_banChan global) >>= \host -> do
        _ <- R.runRedis conn $ R.setex ("ipban:" <> B8.pack host) (60 * (fromIntegral . s_banExpiry . g_settings $ global)) ""
        return ()

finaliseDB :: DBState -> IO ()
finaliseDB local = readIORef (h_children . d_handler $ local) >>= mapM_ cancel
