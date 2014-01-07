-- | JSON-RPC v1.0 implementation, specialised for stratum
{-# LANGUAGE OverloadedStrings, ScopedTypeVariables, InstanceSigs #-}
module ProxyPool.Stratum where

import Prelude hiding (String)
import Control.Monad (mzero)

import Data.Text
import Data.Aeson

import Control.Applicative ((<$>), (<*>), (<|>))

-- | JSON-RPC request
data Request
    = Request { _rid    :: Value -- ^ value is null if notify
              , _method :: Text
              , _params :: Array
              }

-- | JSON-RPC response
data Response
    = Response { _sid    :: Value
               , _result :: Value
               , _error  :: Value
               }
    | Notify   { _nmethod :: Text
               , _nparams :: Array
               }

-- | Client to server
data StratumRequest
    = Subscribe                          -- ^ mining.subscribe
    | Authorize Text Text                -- ^ mining.authorize
     -- | mining.submit
    | Submit { _worker      :: Text
             , _job         :: Text
             , _extraNonce2 :: Text
             , _nTime       :: Text
             , _nonce       :: Text
             }

-- | Server to client
data StratumResponse
    -- | mining.notify
    = WorkNotify { _newJob      :: Text
                 , _prevHash    :: Text
                 , _coinbase1   :: Text
                 , _coinbase2   :: Text
                 , _merkle      :: Array
                 , _clean       :: Bool
                 }
    -- | mining.set_difficulty
    | SetDifficulty Double

instance ToJSON Request where
    toJSON :: Request -> Value
    toJSON (Request rid method params)
        = object [ "id"     .= toJSON rid
                 , "method" .= toJSON method
                 , "params" .= toJSON params
                 ]

instance ToJSON Response where
    toJSON :: Response -> Value
    toJSON (Response sid result err)
        = object [ "id"     .= toJSON sid
                 , "result" .= toJSON result
                 , "error"  .= toJSON err
                 ]

    toJSON (Notify method params)
        = object [ "id"     .= Null
                 , "method" .= toJSON method
                 , "params" .= toJSON params
                 ]

instance FromJSON Request where
    parseJSON (Object v) = Request       <$>
                           v .: "id"     <*>
                           v .: "method" <*>
                           v .: "params"
    parseJSON _          = mzero

instance FromJSON Response where
    parseJSON (Object v) = parseResponse <|> parseNotify
        where parseResponse = Response      <$>
                              v .: "id"     <*>
                              v .: "result" <*>
                              v .: "error"

              parseNotify   = Notify        <$>
                              v .: "method" <*>
                              v .: "params"

    parseJSON _          = mzero

{-instance FromJSON StratumRequest where-}
    {-parseJSON (Object v) = do-}
        {-(method :: Text)    <- v .: "method"-}
        {-(params :: [Value]) <- v .: "params"-}

        {-case method of-}
            {-"mining.subscribe" -> return Subscribe-}
            {-"mining.authorize" -> case params of-}
                {-((String user):(String pass):[]) -> return $ Authorize user pass-}
                {-_                          -> mzero-}
            {-"mining.submit"    -> case params of-}
                {-((String w):(String j):(String e2):(String nt):(String no):[]) -> return $ Submit w j e2 nt no-}
                {-_                                                              -> mzero-}
            {-_                  -> mzero-}

    {-parseJSON _          = mzero-}

{-instance FromJSON StratumResponse where-}
    {-parseJSON (Object v) = do-}
        {-(method :: Text)    <- v .: "method"-}
        {-(params :: [Value]) <- v .: "params"-}

        {-case method of-}
            {-"mining.notify"         -> case params of-}
                {-((String j):(String ph):(String cb1):(String cb2):(Array merkle):(Bool c):[]) -> return $ WorkNotify j ph cb1 cb2 merkle c-}
                {-_                                                                             -> mzero-}
            {-"mining.set_difficulty" -> case params of-}
                {-[Number diff] -> return . SetDifficulty . fromRational . toRational $ diff-}
                {-_             -> mzero-}
            {-_                       -> mzero-}

    {-parseJSON _          = mzero-}
