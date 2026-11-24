module Codec.Picture.WebpSandbox
  ( Decoder (..)
  , Decoded (..)
  , decodeWebp
  , loadSandboxByte
  ) where

import Codec.Picture (DynamicImage (..), Image (..))
import Data.ByteString (ByteString)
import Data.ByteString.Unsafe qualified as BU
import Data.Vector.Storable qualified as V
import Data.Word (Word32, Word64, Word8)
import Foreign (Ptr, allocaBytes, castPtr, finalizerFree, newForeignPtr, peek, peekByteOff, with)
import Foreign.C.Types (CInt (..), CSize (..))

#include "sandbox.h"

data Decoder = Native | Sandboxed Int
  deriving (Eq, Show)

data Decoded = Decoded
  { image :: DynamicImage
  , linearMemoryBytes :: Word64
  }

data WebpResult

decodeWebp :: Decoder -> Int -> ByteString -> IO (Either String Decoded)
decodeWebp decoder maxSide webp =
  BU.unsafeUseAsCStringLen webp \(buf, len) -> allocaBytes #{size webp_result} \result -> do
    status <- case decoder of
      Native -> webpNativeDecode (castPtr buf) (fromIntegral len) (fromIntegral maxSide) result
      Sandboxed mb -> webpSandboxDecode (castPtr buf) (fromIntegral len) (fromIntegral maxSide) (fromIntegral mb * 1048576) result
    trap <- #{peek webp_result, trap} result
    memory <- #{peek webp_result, memory_bytes} result
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
        pure $ Right Decoded {image = dynamic, linearMemoryBytes = memory}

loadSandboxByte :: Int -> Word32 -> IO (Either String Word32)
loadSandboxByte memoryLimitMB address =
  with 0 \value -> allocaBytes #{size webp_result} \result -> do
    status <- webpSandboxLoad address (fromIntegral memoryLimitMB * 1048576) value result
    trap <- #{peek webp_result, trap} result
    if status /= 0 then pure $ Left $ statusError status trap else Right <$> peek value

statusError :: CInt -> Word32 -> String
statusError status trap = case status of
  #{const WEBP_SANDBOX_TRAP} -> "sandbox trap " <> show trap
  #{const WEBP_SANDBOX_INVALID_OUTPUT} -> "invalid sandbox output"
  #{const WEBP_SANDBOX_OUT_OF_MEMORY} -> "out of host memory"
  #{const WEBP_SANDBOX_INVALID_ARGUMENT} -> "invalid argument"
  1 -> "out of memory"
  2 -> "invalid parameter"
  3 -> "bitstream error"
  4 -> "unsupported feature"
  5 -> "decoding status 5"
  6 -> "output aborted"
  7 -> "not enough data"
  _ -> "decoding status " <> show status

foreign import ccall safe "webp_native_decode" webpNativeDecode :: Ptr Word8 -> CSize -> CInt -> Ptr WebpResult -> IO CInt

foreign import ccall safe "webp_sandbox_decode" webpSandboxDecode :: Ptr Word8 -> CSize -> CInt -> Word64 -> Ptr WebpResult -> IO CInt

foreign import ccall safe "webp_sandbox_load" webpSandboxLoad :: Word32 -> Word64 -> Ptr Word32 -> Ptr WebpResult -> IO CInt
