module Codec.Picture.Sandbox
  ( ImageFormat(..)
  , ImageHeader(..)
  , Limits(..)
  , defaultLimits
  , DecodeOptions(..)
  , Metadata(..)
  , decodeImage
  , Playback(..)
  , PixelFormat(..)
  , Frames
  , framesHeader
  , framesAlpha
  , framesMetadata
  , openFrames
  , nextFrame
  , rewindFrames
  , closeFrames
  , Budget(..)
  , defaultBudget
  , unlimitedBudget
  , Counted(..)
  , decodeImageCounted
  , openFramesWithBudget
  , loadSandboxByte
  , spinSandbox
  , treeSandbox
  , readSandboxHeader
  , readSandboxOutput
  ) where

import Codec.Picture (DynamicImage(..), Image(..))
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, withMVar)
import Control.Exception (bracket, bracketOnError)
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
import Foreign (FinalizerPtr, ForeignPtr, Ptr, allocaBytes, castPtr, finalizeForeignPtr, finalizerFree, free, newForeignPtr, nullPtr, peek, peekByteOff, pokeByteOff, with, withForeignPtr)
import Foreign.C.String (CString, peekCAString)
import Foreign.C.Types (CInt(..), CSize(..))

#include "sandbox.h"

data ImageFormat = JPEG | PNG | WebP | GIF
  deriving (Eq, Show)

data ImageHeader = ImageHeader
  { format :: ImageFormat
  , width :: Int
  , height :: Int
  , frameCount :: Int
  , loopCount :: Int
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

data Playback = Still | Animation
  deriving (Eq, Show)

data PixelFormat = PremultipliedRGBA | PremultipliedBGRA
  deriving (Eq, Show)

data Frames = Frames
  { framesHeader :: ImageHeader
  , framesAlpha :: Bool
  , framesMetadata :: Metadata
  , framesSession :: MVar (Maybe (ForeignPtr Sandbox))
  , framesTimeoutMs :: Int
  , framesRate :: Word64
  }

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
  GIF -> 64

unlimitedBudget :: Budget
unlimitedBudget = Budget {base = 0, perByte = 0, perPixel = const 0}

data Counted = Counted
  { decoded :: Either String (ImageHeader, DynamicImage, Metadata)
  , iterations :: Word64
  , linearMemoryBytes :: Word64
  }

decodeImage :: DecodeOptions -> ByteString -> IO (Either String (ImageHeader, DynamicImage, Metadata))
decodeImage options input = decoded <$> decodeImageCounted defaultBudget options input

decodeImageCounted :: Budget -> DecodeOptions -> ByteString -> IO Counted
decodeImageCounted budget@Budget {perPixel} DecodeOptions {limits, maxPixels, outputSize} input =
  BU.unsafeUseAsCStringLen input \(buf, len) -> withLimits limits budget \l ->
    with nullPtr \sessionPtr -> allocaBytes #{size sandbox_header} \header ->
      bracket (sandboxOpen (castPtr buf) (fromIntegral len) l sessionPtr header) (const $ peek sessionPtr >>= sandboxClose) \status -> do
        session <- peek sessionPtr
        result <- runExceptT do
          (imageHeader@ImageHeader {format}, (width', height')) <- checkedHeader maxPixels outputSize session status header
          ExceptT $ allocaBytes #{size sandbox_image} \image -> runExceptT do
            decodeStatus <- liftIO $ sandboxDecode session (fromIntegral width') (fromIntegral height') (perPixel format) image
            checkStatus session decodeStatus
            liftIO $ readImage imageHeader input image
        counted <- if session == nullPtr then pure 0 else sandboxIterations session
        memory <- if session == nullPtr then pure 0 else sandboxMemoryBytes session
        pure Counted {decoded = result, iterations = counted, linearMemoryBytes = memory}

checkedHeader :: Int -> (ImageHeader -> Either String (Int, Int)) -> Ptr Sandbox -> CInt -> Ptr () -> ExceptT String IO (ImageHeader, (Int, Int))
checkedHeader maxPixels outputSize session status header = do
  checkStatus session status
  imageHeader@ImageHeader {width, height} <- liftIO (readHeader header) >>= except
  when (toInteger width * toInteger height > toInteger maxPixels) $ throwE "image is too large"
  size@(width', height') <- except $ outputSize imageHeader
  when (width' < 1 || width' > width || height' < 1 || height' > height) $ throwE "invalid decode options"
  pure (imageHeader, size)

openFrames :: DecodeOptions -> (ImageHeader -> Playback) -> ByteString -> IO (Either String Frames)
openFrames = openFramesWithBudget defaultBudget

openFramesWithBudget :: Budget -> DecodeOptions -> (ImageHeader -> Playback) -> ByteString -> IO (Either String Frames)
openFramesWithBudget budget@Budget {perPixel} DecodeOptions {limits, maxPixels, outputSize} playback input =
  BU.unsafeUseAsCStringLen input \(buf, len) -> withLimits limits budget \l ->
    with nullPtr \sessionPtr -> allocaBytes #{size sandbox_header} \header ->
      bracketOnError (open sessionPtr =<< sandboxOpen (castPtr buf) (fromIntegral len) l sessionPtr header) (finalizeForeignPtr . snd) \(status, session) ->
        withForeignPtr session (runExceptT . start session status header) >>= either (\e -> Left e <$ finalizeForeignPtr session) (pure . Right)
  where
    open sessionPtr status = (status,) <$> (peek sessionPtr >>= newForeignPtr sandboxCloseFinalizer)
    start session status header s = do
      (imageHeader@ImageHeader {format}, (width', height')) <- checkedHeader maxPixels outputSize s status header
      ExceptT $ allocaBytes #{size sandbox_frames} \frames -> runExceptT do
        deadline <- liftIO $ deadlineAfter (timeoutMs limits)
        startStatus <- liftIO $ sandboxStart s (fromIntegral width') (fromIntegral height') (playbackCode $ playback imageHeader) deadline (perPixel format) frames
        checkStatus s startStatus
        alpha <- liftIO (#{peek sandbox_frames, alpha} frames :: IO Word32)
        icc <- liftIO $ takeBytes frames #{peek sandbox_frames, icc} #{peek sandbox_frames, icc_size}
        exifTiff <- liftIO $ takeBytes frames #{peek sandbox_frames, exif} #{peek sandbox_frames, exif_size}
        framesSession <- liftIO $ newMVar (Just session)
        pure
          Frames
            { framesHeader = imageHeader
            , framesAlpha = alpha /= 0
            , framesMetadata = imageMetadata format input icc exifTiff
            , framesSession
            , framesTimeoutMs = timeoutMs limits
            , framesRate = perPixel format
            }
    playbackCode = \case
      Still -> #{const PLAYBACK_STILL}
      Animation -> #{const PLAYBACK_ANIMATION}

nextFrame :: Frames -> PixelFormat -> Ptr Word8 -> Int -> IO (Either String Int)
nextFrame Frames {framesSession, framesTimeoutMs, framesRate} pixelFormat pixels rowBytes = withMVar framesSession \case
  Nothing -> pure $ Left "image is closed"
  Just session -> withForeignPtr session \s -> with 0 \duration -> do
    deadline <- deadlineAfter framesTimeoutMs
    status <- sandboxNext s deadline framesRate (pixelCode pixelFormat) pixels (fromIntegral rowBytes) duration
    if status == 0 then Right . fromIntegral @Word32 <$> peek duration else Left <$> statusMessage s status
  where
    pixelCode = \case
      PremultipliedRGBA -> #{const PIXELS_RGBA}
      PremultipliedBGRA -> #{const PIXELS_BGRA}

rewindFrames :: Frames -> IO ()
rewindFrames Frames {framesSession} = withMVar framesSession $ mapM_ (`withForeignPtr` sandboxRewind)

closeFrames :: Frames -> IO ()
closeFrames Frames {framesSession} = modifyMVar_ framesSession \session -> Nothing <$ mapM_ finalizeForeignPtr session

readHeader :: Ptr () -> IO (Either String ImageHeader)
readHeader header = do
  formatCode <- #{peek sandbox_header, format} header :: IO Word32
  width <- fromIntegral @Word32 <$> #{peek sandbox_header, width} header
  height <- fromIntegral @Word32 <$> #{peek sandbox_header, height} header
  frameCount <- fromIntegral @Word32 <$> #{peek sandbox_header, frames} header
  loopCount <- fromIntegral @Word32 <$> #{peek sandbox_header, loops} header
  let imageHeader format = ImageHeader {format, width, height, frameCount, loopCount}
  pure $ case formatCode of
    #{const FORMAT_JPEG} -> Right $ imageHeader JPEG
    #{const FORMAT_PNG} -> Right $ imageHeader PNG
    #{const FORMAT_WEBP} -> Right $ imageHeader WebP
    #{const FORMAT_GIF} -> Right $ imageHeader GIF
    _ -> Left "invalid sandbox output"

readImage :: ImageHeader -> ByteString -> Ptr () -> IO (ImageHeader, DynamicImage, Metadata)
readImage header@ImageHeader {format} input image = do
  pixels <- #{peek sandbox_image, pixels} image
  width <- fromIntegral @Word32 <$> #{peek sandbox_image, width} image
  height <- fromIntegral @Word32 <$> #{peek sandbox_image, height} image
  layout <- #{peek sandbox_image, layout} image :: IO Word32
  icc <- takeBytes image #{peek sandbox_image, icc} #{peek sandbox_image, icc_size}
  exifTiff <- takeBytes image #{peek sandbox_image, exif} #{peek sandbox_image, exif_size}
  let (channels, dynamic) = case layout of
        #{const LAYOUT_Y8} -> (1, ImageY8 . Image width height)
        #{const LAYOUT_RGBA8} -> (4, ImageRGBA8 . Image width height)
        #{const LAYOUT_CMYK8} -> (4, ImageCMYK8 . Image width height)
        _ -> (3, ImageRGB8 . Image width height)
  samples <- (\fp -> V.unsafeFromForeignPtr0 fp (width * height * channels)) <$> newForeignPtr finalizerFree (pixels :: Ptr Word8)
  pure (header, dynamic samples, imageMetadata format input icc exifTiff)

takeBytes :: Ptr () -> (Ptr () -> IO (Ptr Word8)) -> (Ptr () -> IO Word32) -> IO (Maybe ByteString)
takeBytes record peekAddress peekSize = do
  address <- peekAddress record
  size <- peekSize record
  if address == nullPtr
    then pure Nothing
    else Just <$> B.packCStringLen (castPtr address, fromIntegral size) <* free address

imageMetadata :: ImageFormat -> ByteString -> Maybe ByteString -> Maybe ByteString -> Metadata
imageMetadata format input icc exifTiff = case format of
  JPEG -> Metadata {iccProfile = jpegIccProfile segments, exif = jpegExif segments}
  _ -> Metadata {iccProfile = icc, exif = exifTiff}
  where
    segments = jpegSegments $ B.drop 2 input

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
    #{poke sandbox_limits, memory_limit} limits (fromIntegral memoryLimitMB * 1048576 :: Word64)
    deadlineAfter timeoutMs >>= #{poke sandbox_limits, deadline_ns} limits
    #{poke sandbox_limits, budget_base} limits base
    #{poke sandbox_limits, budget_per_byte} limits perByte
    #{poke sandbox_limits, check_interval} limits checkInterval
    action limits

deadlineAfter :: Int -> IO Word64
deadlineAfter timeoutMs
  | timeoutMs > 0 = (+ fromIntegral timeoutMs * 1000000) <$> sandboxNowNs
  | otherwise = pure 0

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

foreign import ccall safe "sandbox_start" sandboxStart :: Ptr Sandbox -> Word32 -> Word32 -> Word32 -> Word64 -> Word64 -> Ptr () -> IO CInt

foreign import ccall safe "sandbox_next" sandboxNext :: Ptr Sandbox -> Word64 -> Word64 -> Word32 -> Ptr Word8 -> CSize -> Ptr Word32 -> IO CInt

foreign import ccall unsafe "sandbox_rewind" sandboxRewind :: Ptr Sandbox -> IO ()

foreign import ccall safe "sandbox_close" sandboxClose :: Ptr Sandbox -> IO ()

foreign import ccall "&sandbox_close" sandboxCloseFinalizer :: FinalizerPtr Sandbox

foreign import ccall unsafe "sandbox_message" sandboxMessage :: Ptr Sandbox -> IO CString

foreign import ccall unsafe "sandbox_iterations" sandboxIterations :: Ptr Sandbox -> IO Word64

foreign import ccall unsafe "sandbox_memory_bytes" sandboxMemoryBytes :: Ptr Sandbox -> IO Word64

foreign import ccall safe "sandbox_load" sandboxLoad :: Ptr () -> Word32 -> Ptr Word32 -> CString -> IO CInt

foreign import ccall safe "sandbox_spin" sandboxSpin :: Ptr () -> CString -> IO CInt

foreign import ccall safe "sandbox_tree" sandboxTree :: Ptr () -> Word32 -> Ptr Word32 -> CString -> IO CInt

foreign import ccall safe "sandbox_read_header" sandboxReadHeader :: Ptr () -> Word32 -> Ptr Word8 -> Word32 -> Ptr () -> CString -> IO CInt

foreign import ccall safe "sandbox_read_output" sandboxReadOutput :: Ptr () -> Word32 -> Word32 -> Word32 -> Word32 -> Word32 -> Ptr Word8 -> Word32 -> CString -> IO CInt
