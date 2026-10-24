module Codec.Picture.JPEGTurbo
  ( encodeRGB
  , EncodableRGB(..)
  ) where

import Codec.Picture (Image(..), Pixel, PixelBaseComponent, PixelRGB8)
import Control.Exception (bracket, finally)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.Vector.Storable qualified as V
import Data.Word (Word8)
import Foreign (castPtr, peek, with, nullPtr)
import Foreign.C.String (peekCString)
import Foreign.C.Types (CInt)
import TurboJPEG2 qualified as TJ2

class (Pixel px, PixelBaseComponent px ~ Word8) => EncodableRGB px where
  jtPixelFormat :: Image px -> TJ2.TJPF

instance EncodableRGB PixelRGB8 where
  jtPixelFormat _ = TJ2.TJPF_RGB

-- XXX: Use tjCompressFromYUV instead
-- instance EncodableRGB PixelYCbCr8 where
--   jtPixelFormat _ = TJ2.TJPF_RGB

encodeRGB :: EncodableRGB px => Int -> Image px -> IO ByteString
encodeRGB jpegQual image@Image{imageWidth, imageHeight, imageData} = do
  unless (validDimension imageWidth && validDimension imageHeight) $ error "encodeRGB: invalid image dimensions"
  unless (toInteger (V.length imageData) == toInteger imageWidth * toInteger imageHeight * 3) $ error "encodeRGB: invalid image data length"
  unless (0 <= jpegQual && jpegQual <= 100) $ error "encodeRGB: invalid quality"
  bracket TJ2.tjInitCompress TJ2.tjDestroy \jt ->
    V.unsafeWith imageData \bufPtr ->
      with nullPtr \jpegBufPtr ->
        with 0 \jpegSizePtr -> do
          rc <- TJ2.tjCompress2 jt (castPtr bufPtr) (fromIntegral imageWidth) 0 (fromIntegral imageHeight) pixelFormat jpegBufPtr jpegSizePtr jpegSubsamp (fromIntegral jpegQual) flags
          jpegBuf <- peek jpegBufPtr
          flip finally (TJ2.tjFree jpegBuf) do
            unless (rc == 0) $ peekCString (TJ2.tjGetErrorStr2 jt) >>= error
            jpegSize <- peek jpegSizePtr
            B.packCStringLen (castPtr jpegBuf, fromIntegral jpegSize)
  where
    validDimension d = 1 <= d && d <= fromIntegral (maxBound :: CInt)
    flags = TJ2.TJFLAG_PROGRESSIVE <> TJ2.TJFLAG_STOPONWARNING
    pixelFormat = jtPixelFormat image
    jpegSubsamp = TJ2.TJSAMP_420
