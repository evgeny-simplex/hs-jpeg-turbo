module Codec.Picture.Webp
  ( DecodeOptions(..)
  , Metadata(..)
  , decodeWebp
  ) where

import Codec.Picture (DynamicImage(..), Image(..))
import Control.Exception (bracket)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT(..), except, runExceptT, throwE)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Unsafe qualified as BU
import Data.Vector.Storable qualified as V
import Data.Vector.Storable.Mutable qualified as MV
import Data.Word (Word32, Word8)
import Foreign (Ptr, allocaBytes, castPtr, minusPtr, nullPtr, peekByteOff, plusPtr, pokeByteOff)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt(..), CSize(..))

#include "src/webp/decode.h"
#include "src/webp/demux.h"

data DecodeOptions = DecodeOptions
  { maxMemoryMB :: Int
  , outputSize :: (Int, Int) -> Either String (Int, Int)
  }

data Metadata = Metadata
  { iccProfile :: Maybe ByteString
  , exif :: Maybe ByteString
  }
  deriving (Eq, Show)

decodeWebp :: DecodeOptions -> ByteString -> IO (Either String (DynamicImage, Metadata))
decodeWebp DecodeOptions{maxMemoryMB, outputSize} webp
  | maxMemoryMB < 1 = pure $ Left "invalid decode options"
  | otherwise = withDemuxer webp \input demux -> do
      width <- canvasSide demux #{const WEBP_FF_CANVAS_WIDTH}
      height <- canvasSide demux #{const WEBP_FF_CANVAS_HEIGHT}
      when (width > maxSide || height > maxSide) $ throwE "image side exceeds 16384"
      (width', height') <- except $ outputSize (width, height)
      when (width' < 1 || width' > width || height' < 1 || height' > height) $ throwE "invalid decode options"
      flags <- liftIO $ webPDemuxGetI demux #{const WEBP_FF_FORMAT_FLAGS}
      let animated = flags .&. #{const ANIMATION_FLAG} /= 0
      image <-
        withIterator #{size WebPIterator} (webPDemuxGetFrame demux 1) webPDemuxReleaseIterator (decodeFrame (width, height) (width', height') animated)
          >>= maybe (throwE "invalid WebP container") pure
      let chunk fourcc = withIterator #{size WebPChunkIterator} (getChunk demux fourcc) webPDemuxReleaseChunkIterator (chunkPayload input)
      (image,) <$> (Metadata <$> chunk "ICCP" <*> chunk "EXIF")
  where
    decodeFrame (width, height) (width', height') animated iter = do
      fragment <- liftIO $ #{peek WebPIterator, fragment.bytes} iter
      fragmentSize <- liftIO $ #{peek WebPIterator, fragment.size} iter
      x <- liftIO (#{peek WebPIterator, x_offset} iter :: IO CInt)
      y <- liftIO (#{peek WebPIterator, y_offset} iter :: IO CInt)
      withDecoderConfig \config -> do
        checkStatus =<< liftIO (webPGetFeaturesInternal fragment fragmentSize (#{ptr WebPDecoderConfig, input} config) #{const WEBP_DECODER_ABI_VERSION})
        frameWidth <- liftIO (#{peek WebPDecoderConfig, input.width} config :: IO CInt)
        frameHeight <- liftIO (#{peek WebPDecoderConfig, input.height} config :: IO CInt)
        hasAlpha <- liftIO (#{peek WebPDecoderConfig, input.has_alpha} config :: IO CInt)
        format <- liftIO (#{peek WebPDecoderConfig, input.format} config :: IO CInt)
        let (mode, channels, image)
              | animated || hasAlpha /= 0 = (#{const MODE_RGBA}, 4, ImageRGBA8 . Image width' height')
              | otherwise = (#{const MODE_RGB}, 3, ImageRGB8 . Image width' height')
            (x', w') = scaledSpan width width' (fromIntegral x) (fromIntegral frameWidth)
            (y', h') = scaledSpan height height' (fromIntegral y) (fromIntegral frameHeight)
            stride = width' * channels
            size = stride * height'
            offset = y' * stride + x' * channels
        when (decoderMemory format hasAlpha frameWidth frameHeight + toInteger size > toInteger maxMemoryMB * 1048576) $ throwE "image is too large"
        pixels <- liftIO $ if animated then MV.replicate size 0 else MV.unsafeNew size
        checkStatus =<< liftIO (MV.unsafeWith pixels \buf -> do
          #{poke WebPDecoderConfig, output.colorspace} config (mode :: CInt)
          #{poke WebPDecoderConfig, output.is_external_memory} config (1 :: CInt)
          #{poke WebPDecoderConfig, output.u.RGBA.rgba} config (buf `plusPtr` offset)
          #{poke WebPDecoderConfig, output.u.RGBA.stride} config (fromIntegral stride :: CInt)
          #{poke WebPDecoderConfig, output.u.RGBA.size} config (fromIntegral (size - offset) :: CSize)
          when ((w', h') /= (fromIntegral frameWidth, fromIntegral frameHeight)) do
            #{poke WebPDecoderConfig, options.use_scaling} config (1 :: CInt)
            #{poke WebPDecoderConfig, options.scaled_width} config (fromIntegral w' :: CInt)
            #{poke WebPDecoderConfig, options.scaled_height} config (fromIntegral h' :: CInt)
          webPDecode fragment fragmentSize config)
        image <$> liftIO (V.unsafeFreeze pixels)
    chunkPayload input iter = liftIO do
      bytes <- #{peek WebPChunkIterator, chunk.bytes} iter
      size <- #{peek WebPChunkIterator, chunk.size} iter
      pure $ B.take (fromIntegral @CSize size) $ B.drop ((bytes :: Ptr Word8) `minusPtr` input) webp

scaledSpan :: Int -> Int -> Int -> Int -> (Int, Int)
scaledSpan side side' offset size = (start, end - start)
  where
    start = offset * side' `div` side
    end = ((offset + size) * side' + side - 1) `div` side

decoderMemory :: CInt -> CInt -> CInt -> CInt -> Integer
decoderMemory format hasAlpha width height
  | format == losslessFormat = rows + lossless
  | hasAlpha /= 0 = rows + alphaPlanes + lossless
  | otherwise = rows
  where
    pixels = toInteger width * toInteger height
    lossless = 4 * pixels + subsampledImages + huffmanTables
    subsampledImages = 3 * pixels `div` 4
    huffmanTables = 2 * maxAllocable + maxAllocable `div` 16
    alphaPlanes = 2 * pixels
    rows = 4 * 1048576
    maxAllocable = #{const WEBP_MAX_ALLOCABLE_MEMORY}

losslessFormat :: CInt
losslessFormat = 2

maxSide :: Int
maxSide = 16384

data WebPDemuxer

data WebPIterator

data WebPChunkIterator

data WebPDecoderConfig

data WebPBitstreamFeatures

data WebPData

withDemuxer :: ByteString -> (Ptr Word8 -> Ptr WebPDemuxer -> ExceptT String IO a) -> IO (Either String a)
withDemuxer webp action =
  BU.unsafeUseAsCStringLen webp \(buf, len) -> do
    let input = castPtr buf
    bracket (demux input len) webPDemuxDelete \dmux ->
      runExceptT $ if dmux == nullPtr then throwE "invalid WebP container" else action input dmux
  where
    demux input len = allocaBytes #{size WebPData} \webpData -> do
      #{poke WebPData, bytes} webpData input
      #{poke WebPData, size} webpData (fromIntegral len :: CSize)
      webPDemuxInternal webpData 0 nullPtr #{const WEBP_DEMUX_ABI_VERSION}

canvasSide :: Ptr WebPDemuxer -> CInt -> ExceptT String IO Int
canvasSide demux feature = liftIO $ fromIntegral @Word32 <$> webPDemuxGetI demux feature

getChunk :: Ptr WebPDemuxer -> ByteString -> Ptr WebPChunkIterator -> IO CInt
getChunk demux fourcc iter = B.useAsCString fourcc \cFourcc -> webPDemuxGetChunk demux cFourcc 1 iter

withIterator :: Int -> (Ptr i -> IO CInt) -> (Ptr i -> IO ()) -> (Ptr i -> ExceptT String IO a) -> ExceptT String IO (Maybe a)
withIterator size get release action = ExceptT $ allocaBytes size \iter ->
  bracket (get iter) (\found -> when (found /= 0) $ release iter) \found ->
    if found /= 0 then runExceptT (Just <$> action iter) else pure (Right Nothing)

withDecoderConfig :: (Ptr WebPDecoderConfig -> ExceptT String IO a) -> ExceptT String IO a
withDecoderConfig action = ExceptT $ allocaBytes #{size WebPDecoderConfig} \config -> do
  initialised <- webPInitDecoderConfigInternal config #{const WEBP_DECODER_ABI_VERSION}
  if initialised == 0 then pure $ Left (statusError #{const VP8_STATUS_INVALID_PARAM}) else runExceptT (action config)

checkStatus :: CInt -> ExceptT String IO ()
checkStatus status = when (status /= #{const VP8_STATUS_OK}) $ throwE (statusError status)

statusError :: CInt -> String
statusError = \case
  #{const VP8_STATUS_OUT_OF_MEMORY} -> "out of memory"
  #{const VP8_STATUS_INVALID_PARAM} -> "invalid parameter"
  #{const VP8_STATUS_BITSTREAM_ERROR} -> "bitstream error"
  #{const VP8_STATUS_UNSUPPORTED_FEATURE} -> "unsupported feature"
  #{const VP8_STATUS_USER_ABORT} -> "output aborted"
  #{const VP8_STATUS_NOT_ENOUGH_DATA} -> "not enough data"
  status -> "decoding status " <> show status

foreign import ccall "src/webp/demux.h WebPDemuxInternal" webPDemuxInternal :: Ptr WebPData -> CInt -> Ptr CInt -> CInt -> IO (Ptr WebPDemuxer)

foreign import ccall "src/webp/demux.h WebPDemuxDelete" webPDemuxDelete :: Ptr WebPDemuxer -> IO ()

foreign import ccall "src/webp/demux.h WebPDemuxGetI" webPDemuxGetI :: Ptr WebPDemuxer -> CInt -> IO Word32

foreign import ccall "src/webp/demux.h WebPDemuxGetFrame" webPDemuxGetFrame :: Ptr WebPDemuxer -> CInt -> Ptr WebPIterator -> IO CInt

foreign import ccall "src/webp/demux.h WebPDemuxReleaseIterator" webPDemuxReleaseIterator :: Ptr WebPIterator -> IO ()

foreign import ccall "src/webp/demux.h WebPDemuxGetChunk" webPDemuxGetChunk :: Ptr WebPDemuxer -> CString -> CInt -> Ptr WebPChunkIterator -> IO CInt

foreign import ccall "src/webp/demux.h WebPDemuxReleaseChunkIterator" webPDemuxReleaseChunkIterator :: Ptr WebPChunkIterator -> IO ()

foreign import ccall "src/webp/decode.h WebPInitDecoderConfigInternal" webPInitDecoderConfigInternal :: Ptr WebPDecoderConfig -> CInt -> IO CInt

foreign import ccall "src/webp/decode.h WebPGetFeaturesInternal" webPGetFeaturesInternal :: Ptr Word8 -> CSize -> Ptr WebPBitstreamFeatures -> CInt -> IO CInt

foreign import ccall "src/webp/decode.h WebPDecode" webPDecode :: Ptr Word8 -> CSize -> Ptr WebPDecoderConfig -> IO CInt
