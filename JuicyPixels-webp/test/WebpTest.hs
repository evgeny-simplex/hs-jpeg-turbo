module WebpTest where

import Codec.Picture (DynamicImage(..), Image(..), PixelRGB8(..), PixelRGBA8(..), generateImage, pixelAt)
import Codec.Picture.Webp
import Control.Monad (forM_)
import Crypto.Hash.MD5 qualified as MD5
import Data.Bits (shiftR)
import Data.ByteString qualified as B
import Data.ByteString.Builder qualified as BB
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Either (isRight)
import Data.List (nub)
import Data.Vector.Storable qualified as V
import Data.Word (Word8)
import System.Environment (lookupEnv)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, (@?=))

unit_conformance :: IO ()
unit_conformance = do
  sums <- map md5Entry . lines . filter (/= '\r') . BC.unpack <$> testFile "libwebp_tests.md5"
  let files = nub [file | (name, _) <- sums, let (file, ext) = splitAt (length name - 4) name, ext `elem` [".pam", ".ppm"]]
  length files @?= 96
  forM_ files \file -> do
    decoded <- testFile file >>= decodeWebp options
    case decoded of
      Right (image, _) | Just (ext, netpbm) <- netpbmFile image -> assertEqual file (lookup (file <> ext) sums) (Just $ md5Hex netpbm)
      Right _ -> assertFailure $ file <> ": decoded neither as RGB8 nor as RGBA8"
      Left e -> assertFailure $ file <> ": " <> e
  where
    md5Entry line = let (md5, name) = break (== ' ') line in (drop 2 name, md5)

unit_animation :: IO ()
unit_animation = do
  still <- testFile "test.webp"
  small <- testFile "small_31x13.webp"
  Right (ImageRGB8 frame, _) <- decodeWebp options still
  let webp = animation (160, 150) [((16, 8), (128, 128), still), ((0, 0), (31, 13), small)]
      expected = generateImage (canvasPixel frame) 160 150
      canvasPixel img x y
        | x >= 16 && x < 144 && y >= 8 && y < 136, PixelRGB8 r g b <- pixelAt img (x - 16) (y - 8) = PixelRGBA8 r g b 255
        | otherwise = PixelRGBA8 0 0 0 0
  decodeWebp options webp >>= (@?= Right ("RGBA8", imageData expected)) . fmap (samples . fst)

unit_iccProfile :: IO ()
unit_iccProfile = do
  still <- testFile "test.webp"
  let profile = B.pack $ take 1001 $ cycle [0 .. 255]
  decodeWebp options (riff [vp8x 0x20 (128, 128), chunk "ICCP" profile, B.drop 12 still]) >>= (@?= Right (Just profile)) . fmap snd
  decodeWebp options still >>= (@?= Right Nothing) . fmap snd

unit_limits :: IO ()
unit_limits = do
  small <- testFile "small_1x1.webp"
  let canvas size = animation size [((0, 0), (1, 1), small)]
  decodeWebp (DecodeOptions 1) (canvas (512, 512)) >>= assertBool "512x512 RGBA canvas refused" . isRight
  decodeWebp (DecodeOptions 1) (canvas (513, 512)) >>= (@?= Left "image is too large") . fmap (samples . fst)
  decodeWebp options (canvas (16385, 16)) >>= (@?= Left "image side exceeds 16384") . fmap (samples . fst)
  decodeWebp (DecodeOptions 0) small >>= (@?= Left "invalid decode options") . fmap (samples . fst)

unit_malformed :: IO ()
unit_malformed = do
  still <- testFile "test.webp"
  let riffSizeAbove = B.take 4 still <> le 4 (B.length still - 7) <> B.drop 8 still
      notWebp = "RIFF" <> le 4 24 <> "WAVEfmt " <> B.replicate 16 0
      inputs = ["", notWebp, riffSizeAbove] <> [B.take n still | n <- [1 .. B.length still - 1]]
  forM_ inputs \input -> decodeWebp options input >>= (@?= Left "invalid WebP container") . fmap (samples . fst)

testFile :: FilePath -> IO B.ByteString
testFile name = lookupEnv "WEBP_TEST_DATA" >>= maybe (assertFailure "WEBP_TEST_DATA is not set") (\dir -> B.readFile $ dir <> "/" <> name)

options :: DecodeOptions
options = DecodeOptions 64

samples :: DynamicImage -> (String, V.Vector Word8)
samples = \case
  ImageRGB8 Image {imageData} -> ("RGB8", imageData)
  ImageRGBA8 Image {imageData} -> ("RGBA8", imageData)
  _ -> ("other", V.empty)

netpbmFile :: DynamicImage -> Maybe (String, B.ByteString)
netpbmFile = \case
  ImageRGB8 Image {imageWidth, imageHeight, imageData} ->
    Just (".ppm", BC.pack ("P6\n" <> show imageWidth <> " " <> show imageHeight <> "\n255\n") <> bytes imageData)
  ImageRGBA8 Image {imageWidth, imageHeight, imageData} ->
    Just (".pam", BC.pack ("P7\nWIDTH " <> show imageWidth <> "\nHEIGHT " <> show imageHeight <> "\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n") <> bytes imageData)
  _ -> Nothing
  where
    bytes = B.pack . V.toList

md5Hex :: B.ByteString -> String
md5Hex = BC.unpack . BL.toStrict . BB.toLazyByteString . BB.byteStringHex . MD5.hash

animation :: (Int, Int) -> [((Int, Int), (Int, Int), B.ByteString)] -> B.ByteString
animation size frames = riff $ [vp8x 0x12 size, chunk "ANIM" (le 4 0 <> le 2 0)] <> map anmf frames
  where
    anmf ((x, y), (w, h), still) = chunk "ANMF" $ le 3 (x `div` 2) <> le 3 (y `div` 2) <> le 3 (w - 1) <> le 3 (h - 1) <> le 3 100 <> "\0" <> B.drop 12 still

vp8x :: Word8 -> (Int, Int) -> B.ByteString
vp8x flags (w, h) = chunk "VP8X" $ B.pack [flags, 0, 0, 0] <> le 3 (w - 1) <> le 3 (h - 1)

riff :: [B.ByteString] -> B.ByteString
riff chunks = "RIFF" <> le 4 (4 + B.length body) <> "WEBP" <> body
  where
    body = B.concat chunks

chunk :: B.ByteString -> B.ByteString -> B.ByteString
chunk fourcc payload = fourcc <> le 4 (B.length payload) <> payload <> B.replicate (B.length payload `mod` 2) 0

le :: Int -> Int -> B.ByteString
le n v = B.pack [fromIntegral (v `shiftR` (8 * i)) | i <- [0 .. n - 1]]
