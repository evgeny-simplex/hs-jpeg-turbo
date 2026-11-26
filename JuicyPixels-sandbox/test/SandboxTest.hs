module SandboxTest where

import Codec.Picture (DynamicImage(..), Image(..), PixelCMYK8, PixelRGBA8(..), convertImage, extractLumaPlane, generateImage)
import Codec.Picture.Jpg (encodeDirectJpegAtQualityWithMetadata)
import Codec.Picture.JPEGTurbo qualified as JPEG
import Codec.Picture.Sandbox
import Codec.Picture.Spng qualified as Spng
import Codec.Picture.Webp qualified as Webp
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM, forM_, replicateM, unless)
import Data.Bits (shiftL, xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.List (isSuffixOf, sort)
import Data.Vector.Storable qualified as V
import Data.Word (Word8)
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (listDirectory)
import System.Environment (getEnv)
import System.FilePath ((</>))
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, (@?=))

type Samples = (String, Int, Int, V.Vector Word8)

unit_jpeg :: IO ()
unit_jpeg = do
  files <- testFiles jpegDir ".jpg"
  assertBool "JPEG test images" $ length files >= 4
  original <- B.readFile $ jpegDir </> "testorig.jpg"
  Right (ImageRGB8 rgb) <- JPEG.decodeJpeg (JPEG.DecodeOptions JPEG.Full maxImagePixels 1024) original
  let generated =
        [ ("grey", BL.toStrict $ encodeDirectJpegAtQualityWithMetadata 90 mempty $ extractLumaPlane rgb)
        , ("CMYK", BL.toStrict $ encodeDirectJpegAtQualityWithMetadata 90 mempty (convertImage rgb :: Image PixelCMYK8))
        ]
  inputs <- (<> generated) <$> mapM (\file -> (file,) <$> B.readFile file) files
  forM_ inputs \(file, jpeg) ->
    JPEG.readJpegHeader jpeg >>= \case
      Left e -> sandboxed (fullSize jpeg) jpeg >>= assertBool (file <> ": refused natively, " <> e) . isLeft
      Right JPEG.JpegHeader {JPEG.jpegWidth, JPEG.jpegHeight} ->
        forM_ [(JPEG.Full, 1), (JPEG.Half, 2), (JPEG.Quarter, 4), (JPEG.Eighth, 8)] \(scale, d) -> do
          let size = (scaled d jpegWidth, scaled d jpegHeight)
          native <- fmap samples <$> JPEG.decodeJpeg (JPEG.DecodeOptions scale maxImagePixels 1024) jpeg
          sandbox <- fmap (samples . fst) <$> sandboxed (const $ Right size) jpeg
          sameResult (file <> " at 1/" <> show d) native sandbox
  where
    scaled d side = (side + d - 1) `div` d

unit_png :: IO ()
unit_png = do
  files <- testFiles pngDir ".png"
  assertBool "PngSuite" $ length files >= 100
  forM_ files \file -> do
    png <- B.readFile file
    forM_ pngSizes \size -> do
      native <- Spng.decodePng (Spng.DecodeOptions maxImagePixels 128 size) png
      sandbox <- sandboxed (size . headerSize) png
      sameResult (file <> " " <> show (either (const Nothing) (Just . dims . fst) native)) (samples . fst <$> native) (samples . fst <$> sandbox)
      case (native, sandbox) of
        (Right (_, icc), Right (_, Metadata {iccProfile})) -> assertEqual (file <> ": ICC profile") icc iccProfile
        _ -> pure ()
  where
    pngSizes = [Right, \(w, h) -> Right (max 1 $ w `div` 2, max 1 $ h `div` 2), \(w, h) -> Right (min 11 w, min 7 h), const $ Right (1, 1)]

unit_webp :: IO ()
unit_webp = do
  files <- webpFiles
  assertBool "libwebp conformance files" $ length files >= 96
  forM_ files \file -> do
    webp <- B.readFile file
    forM_ [(0 :: Int, Right), (2, \(w, h) -> Right ((w + 1) `div` 2, (h + 1) `div` 2)), (2, \(w, h) -> Right (max 1 $ w `div` 7, max 1 $ h `div` 5))] \(tolerance, size) -> do
      native <- Webp.decodeWebp (Webp.DecodeOptions 128 size) webp
      sandbox <- sandboxed (size . headerSize) webp
      case (native, sandbox) of
        (Right (n, Webp.Metadata {Webp.iccProfile = icc, Webp.exif = payload}), Right (s, metadata)) -> do
          assertBool (file <> ": samples differ by more than " <> show tolerance) $ closeTo tolerance (samples n) (samples s)
          assertEqual (file <> ": metadata") (Metadata icc payload) metadata
        (Left _, Left _) -> pure ()
        _ -> assertFailure $ file <> ": native " <> outcome native <> ", sandbox " <> outcome sandbox

unit_truncatedAndChanged :: IO ()
unit_truncatedAndChanged = do
  jpeg <- B.readFile $ jpegDir </> "testorig.jpg"
  png <- B.readFile $ pngDir </> "basn6a08.png"
  webp <- B.readFile . (</> "test.webp") =<< getEnv "WEBP_TEST_DATA"
  forM_ [jpeg, png, webp] \input -> do
    let n = B.length input
    forM_ ([B.take (n * k `div` 32) input | k <- [0 .. 31]] <> [flipBit (n * k `div` 32) k input | k <- [0 .. 31]]) \changed -> do
      sandbox <- sandboxed (fullSize changed) changed
      native <- nativeDecode changed
      case (native, sandbox) of
        (Right n', Right (s, _)) -> assertBool "the same pixels" $ closeTo 0 n' (samples s)
        (_, Left _) -> pure ()
        (Left e, Right _) -> assertFailure $ "decoded in the sandbox, refused natively: " <> e

unit_limits :: IO ()
unit_limits = do
  png <- largePng
  sandboxedWith defaultLimits {memoryLimitMB = 16} Right png >>= (@?= Left "image is too large") . void'
  sandboxedWith defaultLimits Right png >>= assertBool "decoded within 256 MiB" . not . isLeft
  sandboxedWith defaultLimits {timeoutMs = 1} Right png >>= (@?= Left "deadline exceeded") . void'
  counted <- decodeImageCounted defaultBudget {base = 1000, perByte = 0, perPixel = const 0} (options defaultLimits Right) png
  void' (decoded counted) @?= Left "budget exceeded"
  sandboxedWith defaultLimits (\(w, h) -> Right (w + 1, h)) png >>= (@?= Left "invalid decode options") . void'
  jpeg <- B.readFile $ jpegDir </> "testorig.jpg"
  sandboxedWith defaultLimits (\(w, h) -> Right (w - 1, h)) jpeg >>= (@?= Left "invalid decode options") . void'
  sandboxedWith defaultLimits Right "GIF89a" >>= (@?= Left "unsupported image format") . void'
  ok <- decodeImageCounted defaultBudget (options defaultLimits Right) jpeg
  assertBool "iterations counted" $ iterations ok > 0
  where
    void' = fmap (const ())

unit_traps :: IO ()
unit_traps = do
  loadSandboxByte defaultLimits {memoryLimitMB = 16} 0 >>= (@?= Right 0)
  loadSandboxByte defaultLimits {memoryLimitMB = 16} maxBound >>= (@?= Left "sandbox trap 1")

unit_neverEnding :: IO ()
unit_neverEnding = do
  (budget, t1) <- timed $ spinSandbox defaultLimits {timeoutMs = 0} 100000000
  budget @?= Left "budget exceeded"
  assertBool ("budget stop after " <> show t1) $ t1 < 10
  (deadline, t2) <- timed $ spinSandbox defaultLimits {timeoutMs = 100} 0
  deadline @?= Left "deadline exceeded"
  assertBool ("deadline stop after " <> show t2) $ t2 >= 0.1 && t2 < 1
  (recursion, t3) <- timed $ treeSandbox defaultLimits {timeoutMs = 0} 1000000 30
  recursion @?= Left "budget exceeded"
  assertBool ("recursion stop after " <> show t3) $ t3 < 1

unit_concurrent :: IO ()
unit_concurrent = do
  inputs <- mapM B.readFile . take 8 =<< testFiles pngDir ".png"
  expected <- forM inputs \input -> fmap (samples . fst) <$> sandboxedWith defaultLimits Right input
  results <- replicateM 8 do
    done <- newEmptyMVar
    _ <- forkIO $ putMVar done =<< forM [1 :: Int .. 40] \i ->
      if even i
        then (== Left "sandbox trap 1") <$> loadSandboxByte defaultLimits {memoryLimitMB = 16} maxBound
        else (== expected) <$> forM inputs \input -> fmap (samples . fst) <$> sandboxedWith defaultLimits Right input
    pure done
  forM_ results \done -> takeMVar done >>= assertBool "every trap and decode as expected" . and

jpegDir, pngDir :: FilePath
jpegDir = "../jpeg-turbo/cbits/mozjpeg/testimages"
pngDir = "../JuicyPixels-spng/cbits/libspng/tests/images"

maxImagePixels :: Int
maxImagePixels = 2 ^ (28 :: Int)

testFiles :: FilePath -> String -> IO [FilePath]
testFiles dir ext = map (dir </>) . sort . filter (ext `isSuffixOf`) <$> listDirectory dir

webpFiles :: IO [FilePath]
webpFiles = do
  dir <- getEnv "WEBP_TEST_DATA"
  testFiles dir ".webp"

options :: Limits -> ((Int, Int) -> Either String (Int, Int)) -> DecodeOptions
options l size = DecodeOptions {limits = l, maxPixels = maxImagePixels, outputSize = size . headerSize}

sandboxed :: (ImageHeader -> Either String (Int, Int)) -> ByteString -> IO (Either String (DynamicImage, Metadata))
sandboxed size = decodeImage DecodeOptions {limits = defaultLimits, maxPixels = maxImagePixels, outputSize = size}

sandboxedWith :: Limits -> ((Int, Int) -> Either String (Int, Int)) -> ByteString -> IO (Either String (DynamicImage, Metadata))
sandboxedWith l size = decodeImage (options l size)

fullSize :: ByteString -> ImageHeader -> Either String (Int, Int)
fullSize _ = Right . headerSize

headerSize :: ImageHeader -> (Int, Int)
headerSize ImageHeader {width, height} = (width, height)

nativeDecode :: ByteString -> IO (Either String Samples)
nativeDecode input
  | "\xFF\xD8" `B.isPrefixOf` input = fmap samples <$> JPEG.decodeJpeg (JPEG.DecodeOptions JPEG.Full maxImagePixels 1024) input
  | "\x89PNG" `B.isPrefixOf` input = fmap (samples . fst) <$> Spng.decodePng (Spng.DecodeOptions maxImagePixels 128 Right) input
  | otherwise = fmap (samples . fst) <$> Webp.decodeWebp (Webp.DecodeOptions 128 Right) input

samples :: DynamicImage -> Samples
samples = \case
  ImageY8 (Image w h v) -> ("Y8", w, h, v)
  ImageRGB8 (Image w h v) -> ("RGB8", w, h, v)
  ImageRGBA8 (Image w h v) -> ("RGBA8", w, h, v)
  ImageCMYK8 (Image w h v) -> ("CMYK8", w, h, v)
  _ -> ("other", 0, 0, V.empty)

dims :: DynamicImage -> (Int, Int)
dims image = let (_, w, h, _) = samples image in (w, h)

sameResult :: String -> Either String Samples -> Either String Samples -> IO ()
sameResult name native sandbox = case (native, sandbox) of
  (Right n, Right s) -> unless (n == s) $ assertFailure $ name <> ": samples differ"
  (Left _, Left _) -> pure ()
  _ -> assertFailure $ name <> ": native " <> outcome native <> ", sandbox " <> outcome sandbox

outcome :: Either String a -> String
outcome = either ("Left " <>) (const "Right")

closeTo :: Int -> Samples -> Samples -> Bool
closeTo tolerance (f, w, h, a) (f', w', h', b) = (f, w, h) == (f', w', h') && V.and (V.zipWith (\x y -> abs (fromIntegral x - fromIntegral y :: Int) <= tolerance) a b)

flipBit :: Int -> Int -> ByteString -> ByteString
flipBit i k input = case B.splitAt i input of
  (before, after) -> before <> B.map (`xor` (1 `shiftL` (k `mod` 8))) (B.take 1 after) <> B.drop 1 after

largePng :: IO ByteString
largePng = either fail pure =<< Spng.encodePng (Spng.EncodeOptions 1 False Nothing) image
  where
    image = generateImage (\x y -> PixelRGBA8 (fromIntegral x) (fromIntegral y) 0 255) 4096 4096

timed :: IO a -> IO (a, Double)
timed action = do
  start <- getMonotonicTimeNSec
  result <- action
  end <- getMonotonicTimeNSec
  pure (result, fromIntegral (end - start) / 1e9)
