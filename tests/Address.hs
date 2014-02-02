{-# LANGUAGE OverloadedStrings #-}
module Address (tests) where

import ProxyPool.Mining (validateAddress)

import Test.Tasty
import Test.Tasty.Hspec

tests :: TestTree
tests = testGroup "Address" [ testCase "validateAddress" validateAddressSpec ]

validateAddressSpec :: Spec
validateAddressSpec = describe "Correct validation of addresses" $ do
    it "Sample valid Bitcoin addresses" $ do
        mapM_ (\addr -> validateAddress 0 addr `shouldBe` True) [ "1MLxjL47W49UMhiLQ6ieSwf7txgDYzDBc6", "1JRYNuPNsWdQ1vx3BmL8wYNZvvV2psV3VZ", "1MYiq7UGv5VVKSDNMQ17U7w17rm1S6Yrn9", "17Lisb7ZGGLBjdWTPqnYZA1DqqKn3bMhoG", "1CiqaDs1X6Eg5cqJZLu2cyt1jnxx2CHZpW", "1DctiX2wAtwik2rYo18eoi2P5FdoJ1bq6M" ]
    it "Sample valid Dogecoin addresses" $ do
        mapM_ (\addr -> validateAddress 30 addr `shouldBe` True) [ "DBsxLKzmxZgArKzSLoqoGzvg7vFgRqnXXX", "D8gq3EiwxkysSfKMXv3eoCMZTJvvSkt1UR", "DD3AhTdraFq3Ew4TxMHoVRTrak9xc96GSv" , "DL6FFLtPTXGLtNrBwQSouDXu6KnPB2qVjA" , "DPCJG1rS4Pet9AjzycDDcx7BS7enwL87CU" , "DJH9oLV7Bx4vL8R8SoKa4crAuqvU1JUTfh" , "DQPY4ArDgqeL5ucGRbyr7bjgBgkDLFSAYa" , "D7S7ooAKRZ4WcJAKmh3C4zVZHMdHDy47BD" , "DHfnc9Sd3ShEkHtmryGNbHo7jY5XBRegbU" , "DBWXFnm9F96VZnZPBdrEddJGmRiop9GVCh" ]

    it "Sample invalid Bitcoin addresses" $ do
        validateAddress 0 "ablahhdha" `shouldBe` False
        validateAddress 0 "1`wefswei923!!" `shouldBe` False
        validateAddress 0 "1MLxjL47W49UMhiLQ6ieSwf7txgDYzDBc7" `shouldBe` False
        validateAddress 0 "1mLxjL47W49UMhiLQ6ieSwf7txgDYzDBc6" `shouldBe` False

