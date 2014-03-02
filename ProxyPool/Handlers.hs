{-# LANGUAGE OverloadedStrings, LambdaCase, BangPatterns, DeriveDataTypeable, DeriveFunctor, MultiWayIf #-}
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

import Control.Monad (forever, join, when, unless, mzero, forM_)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Trans.Either

import Control.Exception hiding (handle)

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Concurrent.MVar
import Control.Concurrent.Chan
import Control.Concurrent.Async

import Data.IORef
import Data.Aeson
import Data.Word
import Data.Typeable
import Data.Monoid ((<>), mconcat, mempty)

import Data.Time.Clock.POSIX

import qualified Data.HashSet as S
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
                  , c_writerChan       :: Chan Notice
                  , c_nonce            :: IORef Integer
                  , c_prevNonce        :: IORef Integer
                  -- | Current job
                  , c_currentWork      :: IORef (Maybe B.Builder)
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
                     , s_vardiffInitial      :: Double
                     -- | Number of shares before vardiff is forced to activate, varidiff runs if the number of shares submitted is > this or _vardiffRetargetTime seconds have elapsed
                     , s_vardiffShares       :: Int
                     , s_logLevel            :: String
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
                           v .: "vardiffInitial"      <*>
                           v .: "vardiffShares"       <*>
                           v .: "logLevel"

    parseJSON _          = mzero

data GlobalState
    = GlobalState { g_clientCounter  :: IORef Integer
                  , g_nonceCounter   :: IORef Integer
                  , g_matchCounter   :: IORef Integer
                  , g_upstreamDiff   :: IORef Double
                  , g_work           :: IORef (Work, B.Builder, B.Builder)
                  -- | Submit stales since they are still useful for p2pool
                  , g_prevWork       :: IORef (Work, B.Builder, B.Builder)
                  -- | Prevent duplicate share submission
                  , g_used           :: MVar (S.HashSet T.Text)
                  -- | Channel for work notifications
                  , g_notifyChan     :: SkipChan ()
                  -- | Channel for upstream requests
                  , g_upstreamChan   :: Chan Request
                  -- | List of shares
                  , g_shareList      :: IORef [B.ByteString]
                  , g_settings       :: ServerSettings
                  }

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

data ProxyPoolException = KillClientException { _id :: Integer, _host :: String, _reason :: String }
                        | KillServerException { _reason :: String }
                        deriving (Show, Typeable)

instance Exception ProxyPoolException

data Notice = NewWork | NewReply !B.ByteString

-- | Skip chan from http://hackage.haskell.org/package/base-4.5.1.0/docs/Control-Concurrent-MVar.html
data SkipChan a = SkipChan (MVar (a, [MVar ()])) (MVar ())

newSkipChan :: IO (SkipChan a)
newSkipChan = do
    sem <- newEmptyMVar
    main <- newMVar (undefined, [sem])
    return $ SkipChan main sem

putSkipChan :: SkipChan a -> a -> IO ()
putSkipChan (SkipChan main _) v = do
    (_, sems) <- takeMVar main
    putMVar main (v, [])
    mapM_ (\sem -> putMVar sem ()) sems

getSkipChan :: SkipChan a -> IO a
getSkipChan (SkipChan main sem) = do
    takeMVar sem
    (v, sems) <- takeMVar main
    putMVar main (v, sem:sems)
    return v

dupSkipChan :: SkipChan a -> IO (SkipChan a)
dupSkipChan (SkipChan main _) = do
    sem <- newEmptyMVar
    (v, sems) <- takeMVar main
    putMVar main (v, sem:sems)
    return $ SkipChan main sem

-- | Increments an IORef counter
incr :: IORef Integer -> IO Integer
incr counter = atomicModifyIORef' counter $ join (&&&) (1+)

initaliseGlobal :: ServerSettings -> IO GlobalState
initaliseGlobal settings = GlobalState                          <$>
                           newIORef 0                           <*>
                           newIORef 0                           <*>
                           -- start at 3 since the server sends the 1st two messages
                           newIORef 3                           <*>
                           newIORef 0                           <*>
                           newIORef (emptyWork, mempty, mempty) <*>
                           newIORef (emptyWork, mempty, mempty) <*>
                           newMVar S.empty                      <*>
                           newSkipChan                          <*>
                           newChan                              <*>
                           newIORef []                          <*>
                           return settings

initaliseHandler :: a -> IO (HandlerState a)
initaliseHandler handle = HandlerState <$> return handle <*> newIORef []

finaliseHandler :: HandlerState Handle -> IO ()
finaliseHandler state = do
    hClose $ h_handle state
    readIORef (h_children state) >>= mapM_ cancel
    writeIORef (h_children state) []

-- | Initalises client state
initaliseClient :: Handle -> String -> GlobalState -> IO ClientState
initaliseClient handle host global = ClientState                   <$>
                                     initaliseHandler handle       <*>
                                     newChan                       <*>
                                     newIORef  0                   <*>
                                     newIORef  0                   <*>
                                     newIORef Nothing              <*>
                                     newTVarIO (s_vardiffInitial . g_settings $ global) <*>
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
        writeResponse rid resp = writeChan (c_writerChan local) $ NewReply $ BL.toStrict $ encode $ Response rid resp

        writeNewJob :: B.Builder -> IO ()
        writeNewJob !builder = do
            atomicModifyIORef' (c_currentWork local) $ const (Just builder, ())
            writeChan (c_writerChan local) NewWork

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

        -- | Disconnects the client by throwing an exception
        killClient :: String -> IO ()
        killClient = throwIO . KillClientException (c_id local) (c_host local)

    infoM "client" $ "Client (" ++ show (c_id local) ++ ") from " ++ show (c_host local) ++ " connected"

    -- thread to sequence writes
    (linkChild (c_handler local) =<<) . async . forever $ do
        notice <- readChan (c_writerChan local)
        case notice of
            NewReply line -> B8.hPutStrLn handle line
            NewWork       -> do
                result <- atomicModifyIORef' (c_currentWork local) $ (,) Nothing
                maybe (return ()) (\bytes -> B.hPutBuilder handle $ bytes <> B.char8 '\n') result

    -- wait for mining.subscription call
    initalised <- timeout (30 * 10^(6 :: Int)) $ process handle $ \case
        Just (Request rid Subscribe) -> do
            -- reply with initalisation, set extraNonce1 as empty
            -- it'll be reinserted by the work notification
            liftIO $ writeResponse rid $ Initalise "" $ s_extraNonce3Size . g_settings $ global
            finish ()
        _ -> continue

    maybe (killClient "Took too long to initalise") (const $ return ()) initalised

    -- proxy server notifications
    (linkChild (c_handler local) =<<) . async $ do
        -- duplicate server notification channel
        localNotifyChan <- dupSkipChan $ g_notifyChan global

        let sendJob = do
                upstreamDiff <- readIORef $ g_upstreamDiff global

                -- cap local difficulty at upstream diff
                newDiff <- atomically $ do
                    diff <- readTVar $ c_difficulty local
                    let newDiff = min diff upstreamDiff
                    writeTVar (c_difficulty local) newDiff
                    return newDiff

                (_, part1, part2) <- readIORef $ g_work global

                -- generate unique client nonce
                nonce <- atomicModifyIORef' (g_nonceCounter global) $ join (&&&) $ \x -> (x + 1) `mod` (2 ^ (8 * en2Size))

                -- save the previous nonce
                writeIORef (c_prevNonce local) =<< readIORef (c_nonce local)
                writeIORef (c_nonce local) nonce

                -- send the new job with the difficulty adjustment
                writeResponse Null $ SetDifficulty $ newDiff * 65536
                writeNewJob $ part1 <> (B.lazyByteString . packEn2 $ nonce) <> part2

        -- immediately send a job to the client if possible
        (work, _, _) <- readIORef $ g_work global
        when (work /= emptyWork) sendJob

        forever $ getSkipChan localNotifyChan >>= const sendJob

    -- wait for mining.authorization call
    user <- process handle $ \case
        Just (Request rid (Authorize user _)) -> do
            -- check if the address they are using is a valid address
            if validateAddress (s_publickeyByte . g_settings $ global) $ T.encodeUtf8 user
                then do
                    liftIO $ writeResponse rid $ General $ Right $ Bool True
                    finish user
                else liftIO $ writeResponse rid $ General $ Left $ Array $ V.fromList [ Number (-2), String "Username is not a valid address" ]

        _ -> continue

    infoM "client" $ "Client (" ++ show (c_id local) ++ ") authorized - " ++ T.unpack user ++ " from " ++ show (c_host local)

    vardiffTrigger <- newEmptyMVar
    getPOSIXTime >>= atomically . writeTVar (c_lastVardiff local)

    -- vardiff trigger thread
    (linkChild (c_handler local) =<<) . async . forever $ do
        threadDelay $ (s_vardiffRetargetTime . g_settings $ global) * 10^(6 :: Integer)
        putMVar vardiffTrigger ()

    -- vardiff/kick thread
    (linkChild (c_handler local) =<<) . async . forever $ do
        -- wait till trigger
        _ <- takeMVar vardiffTrigger

        let setDiff diff = writeResponse Null $ SetDifficulty $ diff * 65536
            kickClient   = killClient "Too many dead shares submitted"
            doNothing    = return ()

        currentTime  <- getPOSIXTime
        upstreamDiff <- readIORef $ g_upstreamDiff global

        -- run vardiff inside the transaction
        join $ atomically $ do
            lastTime <- readTVar $ c_lastVardiff local

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
                    if | lastShares > target && (fromIntegral lastSharesDead / fromIntegral lastShares :: Double) >= 0.9 -> return kickClient

                    -- otherwise, check if hashrate is in vardiff allowance
                       | currentHash * (1 - targetAllowance) > estimatedHash || estimatedHash > currentHash * (1 + targetAllowance) -> do
                              -- cap difficulty to min and upstream
                              let newDiff = min (max minDifficulty $ ah2d (fromIntegral target * (60 / fromIntegral elapsedTime)) estimatedHash) upstreamDiff

                              writeTVar (c_difficulty local) newDiff
                              return $ setDiff newDiff

                       | otherwise -> return doNothing
                else return doNothing

    -- process workers submissions (forever)
    process handle $ \case
        Just (Request rid sub@(Submit{})) -> liftIO $ do
            -- doesn't really matter if this race conditions
            diff             <- readTVarIO $ c_difficulty local
            nonce            <- readIORef $ c_nonce local
            prevNonce        <- readIORef $ c_prevNonce local
            (work, _, _)     <- readIORef $ g_work global
            (prevWork, _, _) <- readIORef $ g_prevWork global
            upstreamDiff     <- readIORef $ g_upstreamDiff global

            -- make sure the share's valid
            when (T.length (s_extraNonce2 sub) /= (s_extraNonce3Size . g_settings $ global) * 2
                     || T.length (s_nTime sub) /= 8
                     || T.length (s_nonce sub) /= 8
                 ) $ killClient "Malformed share received"

            -- check if the share was already submitted
            let rawShare = s_extraNonce2 sub <> s_nTime sub <> s_nonce sub <> T.pack (show nonce)
            duplicate <- withMVar (g_used global) $ return . S.member rawShare

            (submitDiff, fresh) <-
                if | s_job sub == w_job work && not duplicate ->
                       return (targetToDifficulty $ getPOW sub work (nonce, en2Size) (s_extraNonce3Size . g_settings $ global) scrypt, True)
                   | s_job sub == w_job prevWork ->
                       return (targetToDifficulty $ getPOW sub prevWork (prevNonce, en2Size) (s_extraNonce3Size . g_settings $ global) scrypt, False)
                   | otherwise -> return (0, False)

            -- verify job and share difficulty
            if | duplicate -> liftIO $ writeResponse rid $ General $ Left $ Array $ V.fromList [Number (-5), String "Duplicate"]
               | submitDiff >= diff ->
                    liftIO $ do
                        -- submit share to upstream even if it's stale. Since stales in P2Pool can still be blocks
                        when (submitDiff >= upstreamDiff) $ upstreamRequest $ sub { s_worker = (s_username . g_settings $ global), s_extraNonce2 = (T.decodeUtf8 . BL.toStrict . packEn2 $ nonce) <> s_extraNonce2 sub }

                        if fresh
                            then do
                                modifyMVar_ (g_used global) $ return . S.insert rawShare
                                writeResponse rid $ General $ Right $ Bool True
                            else writeResponse rid $ General $ Left $ Array $ V.fromList [Number (-4), String "Stale"]

                -- didn't meet the difficulty requirement or job is too far back
               | otherwise -> liftIO $ writeResponse rid $ General $ Left $ Array $ V.fromList [Number (-3), String "Invalid share"]

            -- log the share
            atomicModifyIORef' (g_shareList global) $ \xs -> ((BL.toStrict $ encode $ Share user diff (s_serverName . g_settings $ global) fresh) : xs, ())

            -- record shares for vardiff
            atomically $ do
                modifyTVar' (c_lastShares local) (1+)
                unless fresh $ modifyTVar' (c_lastSharesDead local) (1+)

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
        writeRequest !req = writeChan (s_writerChan local) . BL.toStrict . encode $ req

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
            finish en1
        _ -> continue

    debugM "server" $ "extraNonce1: " ++ T.unpack extraNonce1

    -- authorize
    infoM "server" "Sending authorization"
    writeRequest $ Request (Number 2) $ Authorize (s_username . g_settings $ global) (s_password . g_settings $ global)

    -- thread to listen for server notifications
    (linkChild (s_handler local) =<<) . async $ do
        process handle $ liftIO . \case
            -- sometimes the upstream server doesn't strictly obey JSON RPC
            Just (Response (Number 2) (General (Right (Bool True))))  -> infoM "server" "Upstream authorized"
            Just (Response (Number 2) (General (Right Null)))         -> infoM "server" "Upstream authorized (non standard response)"
            Just (Response (Number 2) (General (Right (Bool False)))) -> throwIO $ KillServerException "Upstream authorisation failed (non standard response)"
            Just (Response (Number 2) (General (Left _)))             -> throwIO $ KillServerException "Upstream authorisation failed"
            Just (Response _ wn@(WorkNotify job prev cb1 cb2 merkle bv nbit ntime clean)) ->
                case fromWorkNotify wn extraNonce1 of
                    Just work -> do
                        -- set the work
                        let fromParts = mconcat . map B.byteString
                            !part1    = fromParts [ "{\"id\":null,\"error\":null,\"method\":\"mining.notify\",\"params\":[\""
                                                  , T.encodeUtf8 job, "\",\""
                                                  , T.encodeUtf8 prev, "\",\""
                                                  , T.encodeUtf8 cb1
                                                  , T.encodeUtf8 extraNonce1
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

                        -- clear the submitted shares
                        _ <- swapMVar (g_used global) S.empty

                        -- save the previous work item so we can still validate shares
                        writeIORef (g_prevWork global) =<< readIORef (g_work global)
                        writeIORef (g_work global) (work, part1, part2)

                        -- notify listeners
                        putSkipChan (g_notifyChan global) ()

                    Nothing -> errorM "server" "Invalid upstream work received"
            Just (Response _ (SetDifficulty diff)) -> do
                debugM "server" $ "Upstream set difficulty to: " ++ show diff
                -- save the upstream diff
                let newDiff = diff / 65536
                writeIORef (g_upstreamDiff global) newDiff
            Just (Response (Number _) (General (Right _)))  -> debugM "share" $ "Upstream share accepted"
            Just (Response (Number _) (General (Left err))) -> debugM "share" $ "Upstream share rejected: " ++ show err
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
        conn    = h_handle . d_handler $ local

    -- test connection first
    _ <- R.runRedis conn R.ping
    infoM "db" "Redis connected"

    -- handle share logging
    forever $ do
        shares  <- atomicModifyIORef' (g_shareList global) $ (,) []
        results <- R.runRedis conn $ mapM (R.publish channel) $ reverse shares

        forM_ results $ \case
            Right _ -> return ()
            Left  _ -> errorM "db" $ "Error while publishing share (" ++ show shares ++ ")"

        threadDelay $ 2 * 10^(6 :: Integer)

finaliseDB :: DBState -> IO ()
finaliseDB local = readIORef (h_children . d_handler $ local) >>= mapM_ cancel
