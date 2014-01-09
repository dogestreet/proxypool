-- | JSON-RPC v1.0 implementation, specialised for stratum
{-# LANGUAGE OverloadedStrings, ScopedTypeVariables, InstanceSigs #-}
module ProxyPool.Stratum (
    Request(..), Response(..),
    StratumRequest(..), StratumResponse(..)
) where

import Prelude hiding (String)
import Control.Monad (mzero)

import Data.Text (Text)

import Data.Aeson
import Data.Aeson.Types

import qualified Data.Vector as V

import Control.Applicative ((<|>))

data Request  = Request Value StratumRequest
data Response = Response Value StratumResponse

-- | Client to server
data StratumRequest
    -- | mining.subscribe
    = Subscribe
    -- | mining.authorize - username, pass
    | Authorize Text Text
    -- | mining.submit - worker, job, extraNonce1 extraNonce2, ntime, nonce
    | Submit Text Text Text Text Text

-- | Server to client
data StratumResponse
    -- | mining.notify
    = WorkNotify Text Text Text Text Array Bool
    -- | mining.set_difficulty
    | SetDifficulty Double
    -- | Initial server response - extranonce1 and extranonce2
    | Initalise Text Int
    -- | General response to request - either the error or the result
    | General (Either Value Bool)

instance FromJSON Request where
    parseJSON (Object v) = do
        (rid    :: Value)   <- v .: "id"
        (method :: Text)    <- v .: "method"
        (params :: [Value]) <- v .: "params"

        case method of
            "mining.subscribe" -> return $ Request rid Subscribe
            "mining.authorize" -> case params of
                [String user, String pass] -> return $ Request rid $ Authorize user pass
                _                          -> mzero
            "mining.submit"    -> case params of
                [String w, String j, String e2, String nt, String no] -> return $ Request rid $ Submit w j e2 nt no
                _                                                     -> mzero
            _                  -> mzero

    parseJSON _          = mzero

parseNotify :: Object -> Parser Response
parseNotify v = do
    (method :: Text)    <- v .: "method"
    (rid    :: Value)   <- v .: "id"

    case method of
        "mining.notify" -> do
            (params :: [Value]) <- v .: "params"
            case params of
                [String j, String ph, String cb1, String cb2, Array merkle, Bool c] ->
                    return $ Response rid $ WorkNotify j ph cb1 cb2 merkle c
                _ -> mzero
        "mining.set_difficulty" -> do
            (params :: [Double]) <- v .: "params"
            return $ Response rid $ SetDifficulty $ head params
        _ -> mzero

parseResponse :: Object -> Parser Response
parseResponse v = do
    (rid    :: Value) <- v .: "id"
    (err    :: Value) <- v .: "error"
    (result :: Value) <- v .: "result"

    case (err, result) of
        (Null, Array arr) -> case V.toList arr of
                                 [_, String en1, en2size] -> do
                                    (en2 :: Int) <- parseJSON en2size
                                    return $ Response rid $ Initalise en1 en2
                                 _                        -> mzero
        (Null, Bool x)    -> return $ Response rid $ General $ Right x
        (err', Null)      -> return $ Response rid $ General $ Left err'
        _                 -> mzero

instance FromJSON Response where
    -- parse reponses separately
    parseJSON (Object v) = parseNotify v <|> parseResponse v
    parseJSON _          = mzero

requestTemplate :: Value -> Text -> Value -> Value
requestTemplate rid method params =
    object [ "id"     .= rid
           , "method" .= method
           , "params" .= params
           ]

responseTemplate :: Value -> Either Value Value -> Value
responseTemplate rid (Left x) =
    object [ "id"     .= rid
           , "error"  .= x
           , "result" .= Null
           ]
responseTemplate rid (Right x) =
    object [ "id"     .= rid
           , "error"  .= Null
           , "result" .= x
           ]

notifyTemplate :: Text -> Value -> Value
notifyTemplate = requestTemplate Null

instance ToJSON Request where
    toJSON (Request rid Subscribe) =
        requestTemplate rid "mining.subscribe" $ Array V.empty
    toJSON (Request rid (Authorize user pass)) =
        requestTemplate rid "mining.authorize" $ toJSON [user, pass]
    toJSON (Request rid (Submit worker job en2 ntime nonce)) =
        requestTemplate rid "mining.submit" $ toJSON [worker, job, en2, ntime, nonce]

instance ToJSON Response where
    toJSON (Response _   (WorkNotify job prevhash cb1 cb2 merkle clean)) =
        notifyTemplate "mining.notify" $ toJSON [String job, String prevhash, String cb1, String cb2, Array merkle, Bool clean]
    toJSON (Response _   (SetDifficulty diff)) =
        notifyTemplate "mining.set_difficulty" $ toJSON [Number $ fromRational . toRational $ diff]
    toJSON (Response rid (Initalise en size)) =
        responseTemplate rid $ Right $ toJSON [String "mining.notify", String "ae6812eb4cd7735a302a8a9dd95cf71f", String en, Number $ fromRational . toRational $ size]
    toJSON (Response rid (General result)) =
        responseTemplate rid $ fmap Bool result
