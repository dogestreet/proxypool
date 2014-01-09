{-# LANGUAGE OverloadedStrings #-}
import ProxyPool.Stratum

import qualified Data.ByteString as BS
import Data.Aeson

import Test.Hspec

main :: IO ()
main = hspec $ do
    describe "JSON parser test with valid data" $ do
        it "parses subscription initalisation correctly" $ do
            let subscription = "{\"id\": 2, \"method\": \"mining.subscribe\", \"params\": []}"
                request      = decodeStrict subscription :: Maybe Request

            case request of
                Nothing -> expectationFailure "Parse failed"
                Just (Request _ _) -> True `shouldBe` True
