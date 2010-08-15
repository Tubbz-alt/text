{-# LANGUAGE BangPatterns, CPP, Rank2Types #-}

-- |
-- Module      : Data.Text.Lazy.Encoding.Fusion
-- Copyright   : (c) Bryan O'Sullivan 2009
--
-- License     : BSD-style
-- Maintainer  : bos@serpentine.com, rtomharper@googlemail.com, 
--               duncan@haskell.org
-- Stability   : experimental
-- Portability : portable
--
-- Fusible 'Stream'-oriented functions for converting between lazy
-- 'Text' and several common encodings.

module Data.Text.Lazy.Encoding.Fusion
    (
    -- * Streaming
    --  streamASCII
     streamUtf8
    --, streamUtf16LE
    --, streamUtf16BE
    --, streamUtf32LE
    --, streamUtf32BE

    -- * Unstreaming
    , unstream

    , module Data.Text.Encoding.Fusion.Common
    ) where

import Data.ByteString.Lazy.Internal (ByteString(..), defaultChunkSize)
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as B
import Data.Text.Encoding.Fusion.Common
import Data.Text.Encoding.Error
import Data.Text.Fusion (Step(..), Stream(..))
import Data.Text.Fusion.Size
import Data.Text.UnsafeChar (unsafeChr8)
import Data.Word (Word8)
import qualified Data.Text.Encoding.Utf8 as U8
import System.IO.Unsafe (unsafePerformIO)
import Foreign.ForeignPtr (withForeignPtr, ForeignPtr)
import Foreign.Storable (pokeByteOff)
import Data.ByteString.Internal (mallocByteString, memcpy)
#if defined(ASSERTS)
import Control.Exception (assert)
#endif
import qualified Data.ByteString.Internal as B

data S = S0
       | S1 {-# UNPACK #-} !Word8
       | S2 {-# UNPACK #-} !Word8 {-# UNPACK #-} !Word8
       | S3 {-# UNPACK #-} !Word8 {-# UNPACK #-} !Word8 {-# UNPACK #-} !Word8
       | S4 {-# UNPACK #-} !Word8 {-# UNPACK #-} !Word8 {-# UNPACK #-} !Word8 {-# UNPACK #-} !Word8

data T = T {-# UNPACK #-} !ByteString {-# UNPACK #-} !S {-# UNPACK #-} !Int

-- | /O(n)/ Convert a lazy 'ByteString' into a 'Stream Char', using
-- UTF-8 encoding.
streamUtf8 :: OnDecodeError -> ByteString -> Stream Char
streamUtf8 onErr bs0 = Stream next (T bs0 S0 0) unknownSize
  where
    next (T bs@(Chunk ps _) S0 i)
      | i < len && U8.validate1 a =
          Yield (unsafeChr8 a)    (T bs S0 (i+1))
      | i + 1 < len && U8.validate2 a b =
          Yield (U8.chr2 a b)     (T bs S0 (i+2))
      | i + 2 < len && U8.validate3 a b c =
          Yield (U8.chr3 a b c)   (T bs S0 (i+3))
      | i + 3 < len && U8.validate4 a b c d =
          Yield (U8.chr4 a b c d) (T bs S0 (i+4))
      where len = B.length ps
            a = B.unsafeIndex ps i
            b = B.unsafeIndex ps (i+1)
            c = B.unsafeIndex ps (i+2)
            d = B.unsafeIndex ps (i+3)
    next st@(T bs s i) =
      case s of
        S1 a       | U8.validate1 a       -> Yield (unsafeChr8 a)    es
        S2 a b     | U8.validate2 a b     -> Yield (U8.chr2 a b)     es
        S3 a b c   | U8.validate3 a b c   -> Yield (U8.chr3 a b c)   es
        S4 a b c d | U8.validate4 a b c d -> Yield (U8.chr4 a b c d) es
        _ -> consume st
       where es = T bs S0 i
    consume (T bs@(Chunk ps rest) s i)
        | i >= B.length ps = consume (T rest s 0)
        | otherwise =
      case s of
        S0         -> next (T bs (S1 x)       (i+1))
        S1 a       -> next (T bs (S2 a x)     (i+1))
        S2 a b     -> next (T bs (S3 a b x)   (i+1))
        S3 a b c   -> next (T bs (S4 a b c x) (i+1))
        S4 a b c d -> decodeError "streamUtf8" "UTF-8" onErr (Just a)
                           (T bs (S3 b c d)   (i+1))
        where x = B.unsafeIndex ps i
    consume (T Empty S0 _) = Done
    consume st             = decodeError "streamUtf8" "UTF-8" onErr Nothing st
{-# INLINE [0] streamUtf8 #-}

-- | /O(n)/ Convert a 'Stream' 'Word8' to a lazy 'ByteString'.
unstreamChunks :: Int -> Stream Word8 -> ByteString
unstreamChunks chunkSize (Stream next s0 len0) = chunk s0 (upperBound 4 len0)
  where chunk s1 len1 = unsafePerformIO $ do
          let len = max 4 (min len1 chunkSize)
          mallocByteString len >>= loop len 0 s1
          where
            loop !n !off !s fp = case next s of
                Done | off == 0 -> return Empty
                     | otherwise -> return $! Chunk (trimUp fp off) Empty
                Skip s' -> loop n off s' fp
                Yield x s'
                    | off == chunkSize -> do
                      let !newLen = n - off
                      return $! Chunk (trimUp fp off) (chunk s newLen)
                    | off == n -> realloc fp n off s' x
                    | otherwise -> do
                      withForeignPtr fp $ \p -> pokeByteOff p off x
                      loop n (off+1) s' fp
            {-# NOINLINE realloc #-}
            realloc fp n off s x = do
              let n' = min (n+n) chunkSize
              fp' <- copy0 fp n n'
              withForeignPtr fp' $ \p -> pokeByteOff p off x
              loop n' (off+1) s fp'
            trimUp fp off = B.PS fp 0 off
            copy0 :: ForeignPtr Word8 -> Int -> Int -> IO (ForeignPtr Word8)
            copy0 !src !srcLen !destLen =
#if defined(ASSERTS)
              assert (srcLen <= destLen) $
#endif
              do
                dest <- mallocByteString destLen
                withForeignPtr src  $ \src'  ->
                    withForeignPtr dest $ \dest' ->
                        memcpy dest' src' (fromIntegral srcLen)
                return dest

-- | /O(n)/ Convert a 'Stream' 'Word8' to a lazy 'ByteString'.
unstream :: Stream Word8 -> ByteString
unstream = unstreamChunks defaultChunkSize

decodeError :: forall s. String -> String -> OnDecodeError -> Maybe Word8
            -> s -> Step s Char
decodeError func kind onErr mb i =
    case onErr desc mb of
      Nothing -> Skip i
      Just c  -> Yield c i
    where desc = "Data.Text.Lazy.Encoding.Fusion." ++ func ++ ": Invalid " ++
                 kind ++ " stream"
