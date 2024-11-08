module JPTest where

import Codec.Picture (DynamicImage(..), convertRGB8, readImageWithMetadata)
import Codec.Picture.JPEGTurbo qualified as JT
import Data.ByteString qualified as B

unit_rgb :: IO ()
unit_rgb = do
  (imgIn, metaIn) <- readImageWithMetadata inFile >>= either error pure
  print (pixelFormat imgIn, metaIn)
  JT.encodeRGB 1 (convertRGB8 imgIn) >>= B.writeFile outFile
  (imgOut, metaOut) <- readImageWithMetadata outFile >>= either error pure
  print (pixelFormat imgOut, metaOut)
  where
    inFile = "../fixtures/lv.png"
    outFile = "../fixtures/lv-out.jpg"

-- TODO: unit_rgba etc
-- TODO: unit_yuv

pixelFormat :: DynamicImage -> String
pixelFormat = \case
  ImageY8 _ -> "Pixel8"
  ImageY16 _ -> "Pixel16"
  ImageY32 _ -> "Pixel32"
  ImageYF _ -> "PixelF"
  ImageYA8 _ -> "PixelYA8"
  ImageYA16 _ -> "PixelYA16"
  ImageRGB8 _ -> "PixelRGB8"
  ImageRGB16 _ -> "PixelRGB16"
  ImageRGBF _ -> "PixelRGBF"
  ImageRGBA8 _ -> "PixelRGBA8"
  ImageRGBA16 _ -> "PixelRGBA16"
  ImageYCbCr8 _ -> "PixelYCbCr8"
  ImageCMYK8 _ -> "PixelCMYK8"
  ImageCMYK16 _ -> "PixelCMYK16"
