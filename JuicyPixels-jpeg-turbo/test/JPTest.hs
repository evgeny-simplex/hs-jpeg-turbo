module JPTest where

import Codec.Picture (Image(..), PixelRGB8(..), decodeJpeg, dynamicMap, generateImage)
import Codec.Picture.JPEGTurbo qualified as JT
import Control.Exception (ErrorCall(..), try)
import Control.Monad (forM_)
import Test.Tasty.HUnit (Assertion, assertFailure, (@?=))

unit_rgb :: IO ()
unit_rgb = do
  decoded <- JT.encodeRGB 1 image >>= either error pure . decodeJpeg
  (dynamicMap imageWidth decoded, dynamicMap imageHeight decoded) @?= (imageWidth image, imageHeight image)

unit_shortBuffer :: IO ()
unit_shortBuffer = assertRejected "encodeRGB: invalid image data length" $ JT.encodeRGB 1 (image {imageHeight = imageHeight image + 1} :: Image PixelRGB8)

unit_badQuality :: IO ()
unit_badQuality = forM_ [-1, 101, 2 ^ (32 :: Int) + 50] \q -> assertRejected "encodeRGB: invalid quality" $ JT.encodeRGB q image

-- TODO: unit_rgba etc
-- TODO: unit_yuv

image :: Image PixelRGB8
image = generateImage (\x y -> PixelRGB8 (fromIntegral x) (fromIntegral y) (fromIntegral (x * y))) 37 23

assertRejected :: String -> IO a -> Assertion
assertRejected expected action =
  try action >>= \case
    Left (ErrorCall e) -> e @?= expected
    Right _ -> assertFailure "accepted"
