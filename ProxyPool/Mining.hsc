{-# Language CPP, ForeignFunctionInterface, OverloadedStrings, ScopedTypeVariables #-}
module ProxyPool.Mining (
    scrypt
  , getPOW
  , packBlockHeader
  , merkleRoot
  , fromHex
  , toHex
  , fromWorkNotify
  , unpackIntLE
  , unpackBE
  , packIntLE
  , targetToDifficulty
  , ah2d
  , hd2a
  , ad2h
  , emptyWork
  , checksumAddress
  , validateAddress
  , Work (..)
) where

import ProxyPool.Stratum

import Foreign hiding (unsafePerformIO)
import Foreign.C.Types

import System.IO.Unsafe (unsafePerformIO)

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Base16 as B16

import qualified Data.ByteString.Lazy.Builder as B
import qualified Data.ByteString.Unsafe as B

import qualified Data.Text as T
import qualified Data.Text.Encoding as T

import Data.Monoid ((<>), mempty, mconcat)
import Data.Aeson
import Data.Word ()
import Data.Char (ord)

import qualified Data.IntMap as IM

import qualified Crypto.Hash.SHA256 as S

#include "scrypt.h"

foreign import ccall "scrypt_1024_1_1_256" c_scrypt :: Ptr CChar -> Ptr CChar -> IO ()

data Work
    = Work { w_job             :: T.Text
           , w_prevHash        :: B.ByteString
           , w_coinbase1       :: B.ByteString
           , w_coinbase2       :: B.ByteString
           , w_merkle          :: [B.ByteString]
           , w_blockVersion    :: Word32
           , w_nBit            :: B.ByteString
           } deriving (Show, Eq)

fromWorkNotify :: StratumResponse -> Maybe Work
fromWorkNotify wn@(WorkNotify{}) = do
    merkle <- case fromJSON $ Array $ wn_merkle wn of
        Success x -> Just x
        Error _   -> Nothing

    return $ Work (T.copy $ wn_job wn)
                  (unpackBE $ fromHex $ wn_prevHash wn)
                  (fromHex $ wn_coinbase1 wn)
                  (fromHex $ wn_coinbase2 wn)
                  (map fromHex merkle)
                  (fromInteger $ unpackIntBE $ fromHex $ wn_blockVersion wn)
                  (unpackBE $ fromHex $ wn_nBit wn)

fromWorkNotify _ = Nothing

emptyWork :: Work
emptyWork = Work ""
                 (B.replicate 32 0)
                 "blank"
                 "blank"
                 []
                 0
                 (B.replicate 4 0)

-- | Get the the share bits from submission
getPOW :: StratumRequest -> Work -> B.ByteString -> (Integer, Int) -> Int -> (B.ByteString -> Integer) -> Integer
getPOW sb@(Submit{}) work en1 en2 en3Size f = f $ packBlockHeader work en1 en2 (en3, en3Size) ntime nonce
    where en3    = unpackIntLE . fromHex $ s_extraNonce2 sb
          ntime  = unpackIntBE . fromHex $ s_nTime sb
          nonce  = unpackIntBE . fromHex $ s_nonce sb

getPOW _ _ _ _ _ _ = 0

-- | Scrypt proof of work algorithm, expect input to be exactly 80 bytes
scrypt :: B.ByteString -> Integer
scrypt header = unsafePerformIO $ do
    packed <- allocaBytes 32 $ \result -> do
        B.unsafeUseAsCString header $ flip c_scrypt result
        B.packCStringLen (result, 32)

    return . unpackIntLE $ packed

packIntLE :: Integer -> Int -> B.Builder
packIntLE _ 0 = mempty
packIntLE x 1 = B.word8 $ fromInteger x
packIntLE x n = B.word8 (fromInteger $ x .&. 255) <> packIntLE (shiftR x 8) (n - 1)

unpackIntLE :: B.ByteString -> Integer
unpackIntLE = B.foldr' (\byte acc -> acc * 256 + (fromIntegral byte)) 0

unpackIntBE :: B.ByteString -> Integer
unpackIntBE = unpackIntLE . B.reverse

unpackBE :: B.ByteString -> B.ByteString
unpackBE xs = BL.toStrict $ B.toLazyByteString $ mconcat $ take (B.length xs `quot` 4) $ map (B.byteString . B.reverse . B.take 4) $ iterate (B.drop 4) xs

-- | Generates an 80 byte block header
packBlockHeader :: Work -> B.ByteString -> (Integer, Int) -> (Integer, Int) -> Integer -> Integer -> B.ByteString
packBlockHeader work en1 en2 en3 ntime nonce
    = let coinbase = BL.toStrict $ B.toLazyByteString $ B.byteString (w_coinbase1 work)         <>
                                                        (B.byteString . fst . B16.decode $ en1) <>
                                                        uncurry packIntLE en2                   <>
                                                        uncurry packIntLE en3                   <>
                                                        B.byteString (w_coinbase2 work)

          merkleHash = merkleRoot coinbase $ w_merkle work

      in  BL.toStrict $ B.toLazyByteString $ B.word32LE (w_blockVersion work) <>
                                             B.byteString (w_prevHash work)   <>
                                             B.byteString merkleHash          <>
                                             B.word32LE (fromIntegral ntime)  <>
                                             B.byteString (w_nBit work)       <>
                                             B.word32LE (fromIntegral nonce)

-- | Create merkle root
merkleRoot :: B.ByteString -> [B.ByteString] -> B.ByteString
merkleRoot coinbase branches = foldl (\acc x -> doubleSHA $ acc <> x) (doubleSHA coinbase) branches

doubleSHA :: B.ByteString -> B.ByteString
doubleSHA = S.hash . S.hash

-- | Change Text hex string to bytes
fromHex :: T.Text -> B.ByteString
fromHex = fst . B16.decode . T.encodeUtf8

toHex :: B.ByteString -> T.Text
toHex = T.decodeUtf8 . B16.encode

-- | Hashrate, accepts per minute, difficulty conversion functions
ah2d :: Double -> Double -> Double
ah2d a h = (15 * h) / (1073741824 * a)

hd2a :: Double -> Double -> Double
hd2a h d = (15 * h) / (1073741824 * d)

ad2h :: Double -> Double -> Double
ad2h a d = (1073741824 * a * d) / 15

targetToDifficulty :: Integer -> Double
targetToDifficulty target = 26959535291011309493156476344723991336010898738574164086137773096961.0 / (fromInteger target + 1.0)

b58Map :: IM.IntMap Integer
b58Map = IM.fromList $ zip (map ord "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz") [0..]

-- | Verifies the validity of a base58 encoded address using the checksum
checksumAddress :: Word8 -> B.ByteString -> Bool
checksumAddress version bs = B.head bytes == version && B.take 4 (doubleSHA (B.take 21 bytes)) == B.drop 21 bytes
    where value :: Integer = B.foldl' (\acc byte -> acc * 58 + (b58Map IM.! (fromIntegral byte))) 0 bs
          bytes = B.reverse $ BL.toStrict $ B.toLazyByteString $ packIntLE value 25

-- | Check if the miner's address is valid
validateAddress :: Word8 -> B.ByteString -> Bool
validateAddress prepend address = len >= 27 && len <= 34 && B.all (charCheck . fromIntegral) address && checksumAddress prepend address
    where len = B.length address
          -- | Verify that only the allowed b58 chars are in the string
          charCheck :: Int -> Bool
          charCheck c | c /= ord '0' && c /= ord 'O' && c /= ord 'I' && c /= ord 'l'
                      = (c >= ord '1' && c <= ord '9') || (c >= ord 'A' && c <= ord 'Z') || (c >= ord 'a' && c <= ord 'z')
          charCheck _ = False
