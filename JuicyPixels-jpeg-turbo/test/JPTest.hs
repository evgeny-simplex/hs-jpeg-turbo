module JPTest where

import Codec.Picture (Image(..), PixelRGB8(..), PixelRGBA8(..), decodeJpeg, dynamicMap, generateImage)
import Codec.Picture.JPEGTurbo qualified as JT
import Control.Exception (ErrorCall(..), try)
import Control.Monad (forM_)
import Data.ByteString qualified as B
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, (@?=))
import TurboJPEG2 qualified as TJ2

instance JT.EncodableRGB PixelRGBA8 where
  jtPixelFormat _ = TJ2.TJPF_RGBA

unit_rgb :: IO ()
unit_rgb = do
  decoded <- JT.encodeRGB 1 image >>= either error pure . decodeJpeg
  (dynamicMap imageWidth decoded, dynamicMap imageHeight decoded) @?= (imageWidth image, imageHeight image)

unit_rgbaLength :: IO ()
unit_rgbaLength = do
  encoded <- JT.encodeRGB 100 rgba
  assertBool "RGBA image encoded" (not (B.null encoded))
  assertRejected "encodeRGB: invalid image data length" $ JT.encodeRGB 100 (rgba {imageWidth = imageWidth rgba + 1} :: Image PixelRGBA8)
  where
    rgba = generateImage (\x y -> PixelRGBA8 (fromIntegral x) (fromIntegral y) (fromIntegral (x + y)) 255) 37 23

unit_shortBuffer :: IO ()
unit_shortBuffer = assertRejected "encodeRGB: invalid image data length" $ JT.encodeRGB 1 (image {imageHeight = imageHeight image + 1} :: Image PixelRGB8)

unit_badQuality :: IO ()
unit_badQuality = forM_ [-1, 101, 2 ^ (32 :: Int) + 50] \q -> assertRejected "encodeRGB: invalid quality" $ JT.encodeRGB q image

unit_wideImage :: IO ()
unit_wideImage = assertRejected "encodeRGB: invalid image dimensions" $ JT.encodeRGB 100 (generateImage (\_ _ -> PixelRGB8 0 0 0) 65501 1)

-- TODO: unit_rgba etc
-- TODO: unit_yuv

image :: Image PixelRGB8
image = generateImage (\x y -> PixelRGB8 (fromIntegral x) (fromIntegral y) (fromIntegral (x * y))) 37 23

assertRejected :: String -> IO a -> Assertion
assertRejected expected action =
  try action >>= \case
    Left (ErrorCall e) -> e @?= expected
    Right _ -> assertFailure "accepted"
