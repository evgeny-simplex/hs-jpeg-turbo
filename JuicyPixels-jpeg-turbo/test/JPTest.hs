module JPTest where

import Codec.Picture (Image(..), PixelRGB8(..), decodeJpeg, dynamicMap, generateImage)
import Codec.Picture.JPEGTurbo qualified as JT
import Test.Tasty.HUnit ((@?=))

unit_rgb :: IO ()
unit_rgb = do
  decoded <- JT.encodeRGB 1 image >>= either error pure . decodeJpeg
  (dynamicMap imageWidth decoded, dynamicMap imageHeight decoded) @?= (imageWidth image, imageHeight image)

-- TODO: unit_rgba etc
-- TODO: unit_yuv

image :: Image PixelRGB8
image = generateImage (\x y -> PixelRGB8 (fromIntegral x) (fromIntegral y) (fromIntegral (x * y))) 37 23
