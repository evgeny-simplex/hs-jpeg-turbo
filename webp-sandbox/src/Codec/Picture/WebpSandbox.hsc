module Codec.Picture.WebpSandbox
  ( Decoder (..)
  , Decoded (..)
  , Limits (..)
  , defaultLimits
  , decodeWebp
  , loadSandboxByte
  , spinSandbox
  , treeSandbox
  ) where

import Codec.Picture (DynamicImage (..), Image (..))
import Data.ByteString (ByteString)
import Data.ByteString.Unsafe qualified as BU
import Data.Vector.Storable qualified as V
import Data.Word (Word32, Word64, Word8)
import Foreign (Ptr, allocaBytes, castPtr, finalizerFree, newForeignPtr, peek, peekByteOff, pokeByteOff, with)
import Foreign.C.Types (CInt (..), CSize (..))

#include "sandbox.h"

data Decoder = Native | Sandboxed Limits
  deriving (Eq, Show)

data Limits = Limits
  { memoryLimitMB :: Int
  , budgetBase :: Word64
  , budgetPerByte :: Word64
  , budgetPerPixel :: Word64
  , timeoutMs :: Int
  , checkInterval :: Word32
  }
  deriving (Eq, Show)

data Decoded = Decoded
  { image :: DynamicImage
  , linearMemoryBytes :: Word64
  , iterations :: Word64
  }

data WebpResult

data WebpLimits

defaultLimits :: Limits
defaultLimits =
  Limits
    { memoryLimitMB = 256
    , budgetBase = 1048576
    , budgetPerByte = 16
    , budgetPerPixel = 64
    , timeoutMs = 0
    , checkInterval = 4096
    }

decodeWebp :: Decoder -> Int -> ByteString -> IO (Either String Decoded)
decodeWebp decoder maxSide webp =
  BU.unsafeUseAsCStringLen webp \(buf, len) -> allocaBytes #{size webp_result} \result -> do
    status <- case decoder of
      Native -> webpNativeDecode (castPtr buf) (fromIntegral len) (fromIntegral maxSide) result
      Sandboxed limits -> withLimits limits \l -> webpSandboxDecode (castPtr buf) (fromIntegral len) (fromIntegral maxSide) l result
    trap <- #{peek webp_result, trap} result
    memory <- #{peek webp_result, memory_bytes} result
    counted <- #{peek webp_result, iterations} result
    if status /= 0
      then pure $ Left $ statusError status trap
      else do
        pixels <- #{peek webp_result, pixels} result
        width <- fromIntegral @Word32 <$> #{peek webp_result, width} result
        height <- fromIntegral @Word32 <$> #{peek webp_result, height} result
        channels <- fromIntegral @Word32 <$> #{peek webp_result, channels} result
        samples <- (\fp -> V.unsafeFromForeignPtr0 fp (width * height * channels)) <$> newForeignPtr finalizerFree pixels
        let dynamic
              | channels == 4 = ImageRGBA8 (Image width height samples)
              | otherwise = ImageRGB8 (Image width height samples)
        pure $ Right Decoded {image = dynamic, linearMemoryBytes = memory, iterations = counted}

loadSandboxByte :: Limits -> Word32 -> IO (Either String Word32)
loadSandboxByte limits address =
  with 0 \value -> allocaBytes #{size webp_result} \result -> do
    status <- withLimits limits \l -> webpSandboxLoad address l value result
    trap <- #{peek webp_result, trap} result
    if status /= 0 then pure $ Left $ statusError status trap else Right <$> peek value

spinSandbox :: Limits -> IO (Either String Word64)
spinSandbox limits =
  allocaBytes #{size webp_result} \result -> do
    status <- withLimits limits \l -> webpSandboxSpin l result
    trap <- #{peek webp_result, trap} result
    if status /= 0 then pure $ Left $ statusError status trap else Right <$> #{peek webp_result, iterations} result

treeSandbox :: Limits -> Word32 -> IO (Either String Word32)
treeSandbox limits depth =
  with 0 \value -> allocaBytes #{size webp_result} \result -> do
    status <- withLimits limits \l -> webpSandboxTree depth l value result
    trap <- #{peek webp_result, trap} result
    if status /= 0 then pure $ Left $ statusError status trap else Right <$> peek value

withLimits :: Limits -> (Ptr WebpLimits -> IO a) -> IO a
withLimits Limits {memoryLimitMB, budgetBase, budgetPerByte, budgetPerPixel, timeoutMs, checkInterval} action =
  allocaBytes #{size webp_limits} \limits -> do
    now <- webpSandboxNowNs
    #{poke webp_limits, memory_limit} limits (fromIntegral memoryLimitMB * 1048576 :: Word64)
    #{poke webp_limits, budget_base} limits budgetBase
    #{poke webp_limits, budget_per_byte} limits budgetPerByte
    #{poke webp_limits, budget_per_pixel} limits budgetPerPixel
    #{poke webp_limits, deadline_ns} limits (if timeoutMs > 0 then now + fromIntegral timeoutMs * 1000000 else 0 :: Word64)
    #{poke webp_limits, check_interval} limits checkInterval
    action limits

statusError :: CInt -> Word32 -> String
statusError status trap = case status of
  #{const WEBP_SANDBOX_TRAP} -> "sandbox trap " <> show trap
  #{const WEBP_SANDBOX_INVALID_OUTPUT} -> "invalid sandbox output"
  #{const WEBP_SANDBOX_OUT_OF_MEMORY} -> "out of memory"
  #{const WEBP_SANDBOX_INVALID_ARGUMENT} -> "invalid argument"
  #{const WEBP_SANDBOX_BUDGET} -> "budget exceeded"
  #{const WEBP_SANDBOX_DEADLINE} -> "deadline exceeded"
  1 -> "out of memory"
  2 -> "invalid parameter"
  3 -> "bitstream error"
  4 -> "unsupported feature"
  5 -> "decoding status 5"
  6 -> "output aborted"
  7 -> "not enough data"
  _ -> "decoding status " <> show status

foreign import ccall unsafe "webp_sandbox_now_ns" webpSandboxNowNs :: IO Word64

foreign import ccall safe "webp_native_decode" webpNativeDecode :: Ptr Word8 -> CSize -> CInt -> Ptr WebpResult -> IO CInt

foreign import ccall safe "webp_sandbox_decode" webpSandboxDecode :: Ptr Word8 -> CSize -> CInt -> Ptr WebpLimits -> Ptr WebpResult -> IO CInt

foreign import ccall safe "webp_sandbox_load" webpSandboxLoad :: Word32 -> Ptr WebpLimits -> Ptr Word32 -> Ptr WebpResult -> IO CInt

foreign import ccall safe "webp_sandbox_spin" webpSandboxSpin :: Ptr WebpLimits -> Ptr WebpResult -> IO CInt

foreign import ccall safe "webp_sandbox_tree" webpSandboxTree :: Word32 -> Ptr WebpLimits -> Ptr Word32 -> Ptr WebpResult -> IO CInt
