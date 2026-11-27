module Codec.Picture.Sandbox
  ( ImageFormat(..)
  , ImageHeader(..)
  , Limits(..)
  , defaultLimits
  , DecodeOptions(..)
  , Metadata(..)
  , decodeImage
  , Budget(..)
  , defaultBudget
  , unlimitedBudget
  , Counted(..)
  , decodeImageCounted
  , loadSandboxByte
  , spinSandbox
  , treeSandbox
  , readSandboxHeader
  , readSandboxOutput
  ) where

import Codec.Picture (DynamicImage(..), Image(..))
import Control.Exception (bracket)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT(..), except, runExceptT, throwE)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Unsafe qualified as BU
import Data.Maybe (listToMaybe)
import Data.List (sortOn)
import Data.Vector.Storable qualified as V
import Data.Word (Word32, Word64, Word8)
import Foreign (Ptr, allocaBytes, castPtr, finalizerFree, free, newForeignPtr, nullPtr, peek, peekByteOff, pokeByteOff, with)
import Foreign.C.String (CString, peekCAString)
import Foreign.C.Types (CInt(..), CSize(..))

#include "sandbox.h"

data ImageFormat = JPEG | PNG | WebP
  deriving (Eq, Show)

data ImageHeader = ImageHeader
  { format :: ImageFormat
  , width :: Int
  , height :: Int
  }
  deriving (Eq, Show)

data Limits = Limits
  { memoryLimitMB :: Int
  , timeoutMs :: Int
  , checkInterval :: Word32
  }
  deriving (Eq, Show)

defaultLimits :: Limits
defaultLimits = Limits {memoryLimitMB = 256, timeoutMs = 10000, checkInterval = 4096}

data DecodeOptions = DecodeOptions
  { limits :: Limits
  , maxPixels :: Int
  , outputSize :: ImageHeader -> Either String (Int, Int)
  }

data Metadata = Metadata
  { iccProfile :: Maybe ByteString
  , exif :: Maybe ByteString
  }
  deriving (Eq, Show)

data Budget = Budget
  { base :: Word64
  , perByte :: Word64
  , perPixel :: ImageFormat -> Word64
  }

defaultBudget :: Budget
defaultBudget = Budget {base = 1048576, perByte = 16, perPixel = defaultPerPixel}

defaultPerPixel :: ImageFormat -> Word64
defaultPerPixel = \case
  JPEG -> 256
  PNG -> 64
  WebP -> 64

unlimitedBudget :: Budget
unlimitedBudget = Budget {base = 0, perByte = 0, perPixel = const 0}

data Counted = Counted
  { decoded :: Either String (DynamicImage, Metadata)
  , iterations :: Word64
  , linearMemoryBytes :: Word64
  }

decodeImage :: DecodeOptions -> ByteString -> IO (Either String (DynamicImage, Metadata))
decodeImage options input = decoded <$> decodeImageCounted defaultBudget options input

decodeImageCounted :: Budget -> DecodeOptions -> ByteString -> IO Counted
decodeImageCounted budget@Budget {perPixel} DecodeOptions {limits, maxPixels, outputSize} input =
  BU.unsafeUseAsCStringLen input \(buf, len) -> withLimits limits budget \l ->
    with nullPtr \sessionPtr -> allocaBytes #{size sandbox_header} \header ->
      bracket (sandboxOpen (castPtr buf) (fromIntegral len) l sessionPtr header) (const $ peek sessionPtr >>= sandboxClose) \status -> do
        session <- peek sessionPtr
        result <- runExceptT do
          checkStatus session status
          imageHeader@ImageHeader {format, width, height} <- liftIO (readHeader header) >>= except
          when (toInteger width * toInteger height > toInteger maxPixels) $ throwE "image is too large"
          (width', height') <- except $ outputSize imageHeader
          when (width' < 1 || width' > width || height' < 1 || height' > height) $ throwE "invalid decode options"
          ExceptT $ allocaBytes #{size sandbox_image} \image -> runExceptT do
            decodeStatus <- liftIO $ sandboxDecode session (fromIntegral width') (fromIntegral height') (perPixel format) image
            checkStatus session decodeStatus
            liftIO $ readImage format input image
        counted <- if session == nullPtr then pure 0 else sandboxIterations session
        memory <- if session == nullPtr then pure 0 else sandboxMemoryBytes session
        pure Counted {decoded = result, iterations = counted, linearMemoryBytes = memory}

readHeader :: Ptr () -> IO (Either String ImageHeader)
readHeader header = do
  formatCode <- #{peek sandbox_header, format} header :: IO Word32
  width <- fromIntegral @Word32 <$> #{peek sandbox_header, width} header
  height <- fromIntegral @Word32 <$> #{peek sandbox_header, height} header
  pure $ case formatCode of
    1 -> Right $ ImageHeader JPEG width height
    2 -> Right $ ImageHeader PNG width height
    3 -> Right $ ImageHeader WebP width height
    _ -> Left "invalid sandbox output"

readImage :: ImageFormat -> ByteString -> Ptr () -> IO (DynamicImage, Metadata)
readImage format input image = do
  pixels <- #{peek sandbox_image, pixels} image
  width <- fromIntegral @Word32 <$> #{peek sandbox_image, width} image
  height <- fromIntegral @Word32 <$> #{peek sandbox_image, height} image
  layout <- #{peek sandbox_image, layout} image :: IO Word32
  icc <- bytes #{peek sandbox_image, icc} #{peek sandbox_image, icc_size}
  exifTiff <- bytes #{peek sandbox_image, exif} #{peek sandbox_image, exif_size}
  let channels = case layout of
        1 -> 1
        4 -> 4
        3 -> 4
        _ -> 3
  samples <- (\fp -> V.unsafeFromForeignPtr0 fp (width * height * channels)) <$> newForeignPtr finalizerFree (pixels :: Ptr Word8)
  let dynamic = case layout of
        1 -> ImageY8 (Image width height samples)
        3 -> ImageRGBA8 (Image width height samples)
        4 -> ImageCMYK8 (Image width height samples)
        _ -> ImageRGB8 (Image width height samples)
      metadata = case format of
        JPEG -> Metadata {iccProfile = jpegIccProfile segments, exif = jpegExif segments}
        _ -> Metadata {iccProfile = icc, exif = exifTiff}
  pure (dynamic, metadata)
  where
    segments = jpegSegments $ B.drop 2 input
    bytes peekAddress peekSize = do
      address <- peekAddress image :: IO (Ptr Word8)
      size <- peekSize image :: IO Word32
      if address == nullPtr
        then pure Nothing
        else Just <$> B.packCStringLen (castPtr address, fromIntegral size) <* free address

jpegExif :: [(Word8, ByteString)] -> Maybe ByteString
jpegExif segments = listToMaybe [B.drop 6 segment | (0xE1, segment) <- segments, "Exif\0\0" `B.isPrefixOf` segment]

jpegIccProfile :: [(Word8, ByteString)] -> Maybe ByteString
jpegIccProfile segments = do
  chunks <- sortOn (\(n, _, _) -> n) <$> mapM iccChunk iccSegments
  let profile = B.concat [chunk | (_, _, chunk) <- chunks]
  if [n | (n, _, _) <- chunks] == [1 .. length chunks] && all (\(_, count, _) -> count == length chunks) chunks && not (B.null profile)
    then Just profile
    else Nothing
  where
    iccSegments = [segment | (0xE2, segment) <- segments, "ICC_PROFILE\0" `B.isPrefixOf` segment]
    iccChunk segment
      | B.length segment < 14 = Nothing
      | otherwise = Just (fromIntegral $ B.index segment 12, fromIntegral $ B.index segment 13, B.drop 14 segment)

jpegSegments :: ByteString -> [(Word8, ByteString)]
jpegSegments s
  | B.length s < 4 || B.index s 0 /= 0xFF || marker == 0xDA = []
  | otherwise = (marker, B.take (len - 2) $ B.drop 4 s) : jpegSegments (B.drop (2 + len) s)
  where
    marker = B.index s 1
    len = fromIntegral (B.index s 2) * 256 + fromIntegral (B.index s 3)

checkStatus :: Ptr Sandbox -> CInt -> ExceptT String IO ()
checkStatus session status = when (status /= 0) $ liftIO (statusMessage session status) >>= throwE

statusMessage :: Ptr Sandbox -> CInt -> IO String
statusMessage session status
  | session /= nullPtr = sandboxMessage session >>= peekCAString
  | otherwise = pure $ case status of
      #{const SANDBOX_INVALID_ARGUMENT} -> "invalid argument"
      _ -> "out of memory"

withLimits :: Limits -> Budget -> (Ptr () -> IO a) -> IO a
withLimits Limits {memoryLimitMB, timeoutMs, checkInterval} Budget {base, perByte} action =
  allocaBytes #{size sandbox_limits} \limits -> do
    now <- sandboxNowNs
    #{poke sandbox_limits, memory_limit} limits (fromIntegral memoryLimitMB * 1048576 :: Word64)
    #{poke sandbox_limits, deadline_ns} limits (if timeoutMs > 0 then now + fromIntegral timeoutMs * 1000000 else 0 :: Word64)
    #{poke sandbox_limits, budget_base} limits base
    #{poke sandbox_limits, budget_per_byte} limits perByte
    #{poke sandbox_limits, check_interval} limits checkInterval
    action limits

testCall :: Limits -> Word64 -> (Ptr () -> CString -> IO CInt) -> IO (Either String ())
testCall limits budget call = withLimits limits unlimitedBudget {base = budget} \l -> allocaBytes #{const SANDBOX_MESSAGE_SIZE} \message -> do
  pokeByteOff message 0 (0 :: Word8)
  status <- call l message
  if status == 0 then pure (Right ()) else Left <$> peekCAString message

loadSandboxByte :: Limits -> Word32 -> IO (Either String Word32)
loadSandboxByte limits address = with 0 \value -> do
  r <- testCall limits 0 \l message -> sandboxLoad l address value message
  traverse (const $ peek value) r

spinSandbox :: Limits -> Word64 -> IO (Either String ())
spinSandbox limits budget = testCall limits budget sandboxSpin

treeSandbox :: Limits -> Word64 -> Word32 -> IO (Either String Word32)
treeSandbox limits budget depth = with 0 \value -> do
  r <- testCall limits budget \l message -> sandboxTree l depth value message
  traverse (const $ peek value) r

readSandboxHeader :: Limits -> Word32 -> ByteString -> IO (Either String ImageHeader)
readSandboxHeader limits address bytes = BU.unsafeUseAsCStringLen bytes \(buf, len) -> allocaBytes #{size sandbox_header} \header -> do
  r <- testCall limits 0 \l message -> sandboxReadHeader l address (castPtr buf) (fromIntegral len) header message
  either (pure . Left) (const $ readHeader header) r

readSandboxOutput :: Limits -> Word32 -> Word32 -> (Word32, Word32) -> Word32 -> ByteString -> IO (Either String ())
readSandboxOutput limits size format (width, height) address bytes = BU.unsafeUseAsCStringLen bytes \(buf, len) ->
  testCall limits 0 \l message -> sandboxReadOutput l size format width height address (castPtr buf) (fromIntegral len) message

data Sandbox

foreign import ccall unsafe "sandbox_now_ns" sandboxNowNs :: IO Word64

foreign import ccall safe "sandbox_open" sandboxOpen :: Ptr Word8 -> CSize -> Ptr () -> Ptr (Ptr Sandbox) -> Ptr () -> IO CInt

foreign import ccall safe "sandbox_decode" sandboxDecode :: Ptr Sandbox -> Word32 -> Word32 -> Word64 -> Ptr () -> IO CInt

foreign import ccall safe "sandbox_close" sandboxClose :: Ptr Sandbox -> IO ()

foreign import ccall unsafe "sandbox_message" sandboxMessage :: Ptr Sandbox -> IO CString

foreign import ccall unsafe "sandbox_iterations" sandboxIterations :: Ptr Sandbox -> IO Word64

foreign import ccall unsafe "sandbox_memory_bytes" sandboxMemoryBytes :: Ptr Sandbox -> IO Word64

foreign import ccall safe "sandbox_load" sandboxLoad :: Ptr () -> Word32 -> Ptr Word32 -> CString -> IO CInt

foreign import ccall safe "sandbox_spin" sandboxSpin :: Ptr () -> CString -> IO CInt

foreign import ccall safe "sandbox_tree" sandboxTree :: Ptr () -> Word32 -> Ptr Word32 -> CString -> IO CInt

foreign import ccall safe "sandbox_read_header" sandboxReadHeader :: Ptr () -> Word32 -> Ptr Word8 -> Word32 -> Ptr () -> CString -> IO CInt

foreign import ccall safe "sandbox_read_output" sandboxReadOutput :: Ptr () -> Word32 -> Word32 -> Word32 -> Word32 -> Word32 -> Ptr Word8 -> Word32 -> CString -> IO CInt
