module SandboxTest where

import Codec.Picture (DynamicImage(..), Image(..), PixelCMYK8, PixelRGBA8(..), generateImage)
import Codec.Picture.Jpg (encodeDirectJpegAtQualityWithMetadata)
import Codec.Picture.Types (convertImage, extractLumaPlane)
import Codec.Picture.JPEGTurbo qualified as JPEG
import Codec.Picture.Sandbox
import Codec.Picture.Spng qualified as Spng
import Codec.Picture.Webp qualified as Webp
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket)
import Control.Monad (forM, forM_, replicateM, unless)
import Data.Bits (shiftL, shiftR, xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.List (isSuffixOf, sort)
import Data.Vector.Storable qualified as V
import Data.Word (Word8)
import Foreign (castPtr, nullPtr, peek, with)
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (listDirectory)
import System.Environment (getEnv)
import System.FilePath ((</>))
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, (@?=))
import TurboJPEG2 qualified as TJ2

type Samples = (String, Int, Int, V.Vector Word8)

unit_jpeg :: IO ()
unit_jpeg = do
  files <- testFiles jpegDir ".jpg"
  assertBool "JPEG test images" $ length files >= 4
  original <- B.readFile $ jpegDir </> "testorig.jpg"
  Right (ImageRGB8 rgb) <- JPEG.decodeJpeg (JPEG.DecodeOptions JPEG.Full maxImagePixels 1024) original
  let grey = extractLumaPlane rgb
      cmyk = convertImage rgb :: Image PixelCMYK8
      turbo name pixelFormat subsamp flags pixels = (name,) <$> turboJpeg pixelFormat subsamp flags (imageWidth rgb, imageHeight rgb) pixels
      generated =
        [ ("grey", BL.toStrict $ encodeDirectJpegAtQualityWithMetadata 90 mempty grey)
        , ("CMYK", BL.toStrict $ encodeDirectJpegAtQualityWithMetadata 90 mempty cmyk)
        ]
  encoded <-
    sequence
      [ turbo "YCCK" TJ2.TJPF_CMYK TJ2.TJSAMP_444 mempty (imageData cmyk)
      , turbo "YCCK 4:2:0, progressive" TJ2.TJPF_CMYK TJ2.TJSAMP_420 TJ2.TJFLAG_PROGRESSIVE (imageData cmyk)
      , turbo "progressive" TJ2.TJPF_RGB TJ2.TJSAMP_420 TJ2.TJFLAG_PROGRESSIVE (imageData rgb)
      , turbo "4:4:4, progressive" TJ2.TJPF_RGB TJ2.TJSAMP_444 TJ2.TJFLAG_PROGRESSIVE (imageData rgb)
      , turbo "grey, progressive" TJ2.TJPF_GRAY TJ2.TJSAMP_GRAY TJ2.TJFLAG_PROGRESSIVE (imageData grey)
      ]
  inputs <- (<> generated <> encoded) <$> mapM (\file -> (file,) <$> B.readFile file) files
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

unit_jpegMetadata :: IO ()
unit_jpegMetadata = do
  jpeg <- B.readFile $ jpegDir </> "testorig.jpg"
  profile <- B.readFile $ jpegDir </> "test3.icc"
  let (part1, part2) = B.splitAt (B.length profile `div` 2) profile
      tiff = "MM\0*\0\0\0\8" <> B.replicate 6 0
      icc n part = (0xE2, "ICC_PROFILE\0" <> B.pack [n, 2] <> part)
      app0End = 4 + fromIntegral (B.index jpeg 4) * 256 + fromIntegral (B.index jpeg 5)
      segment (marker, body) = let len = B.length body + 2 in B.pack [0xFF, marker, fromIntegral (len `shiftR` 8), fromIntegral len] <> body
      metadata segments = fmap snd <$> sandboxed (fullSize jpeg) (B.take app0End jpeg <> foldMap segment segments <> B.drop app0End jpeg)
  metadata [(0xE1, "Exif\0\0" <> tiff), icc 2 part2, icc 1 part1] >>= (@?= Right (Metadata (Just profile) (Just tiff)))
  metadata [icc 1 part1] >>= (@?= Right (Metadata Nothing Nothing))
  metadata [] >>= (@?= Right (Metadata Nothing Nothing))

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

unit_pngGenerated :: IO ()
unit_pngGenerated = do
  profile <- B.readFile $ jpegDir </> "test3.icc"
  let images = [((16384, 16), [(4096, 4), (1, 1)], Nothing), ((16, 16384), [(4, 4096)], Nothing), ((8641, 3), [(4320, 1), (4321, 2)], Nothing), ((37, 23), [(11, 7)], Just profile)]
  forM_ images \(imageSize, sizes, icc) -> do
    png <- either assertFailure pure =<< Spng.encodePng (Spng.EncodeOptions 6 True icc) (gradient imageSize)
    forM_ (imageSize : sizes) \size -> do
      native <- Spng.decodePng (Spng.DecodeOptions maxImagePixels 128 (const $ Right size)) png
      sandbox <- sandboxed (const $ Right size) png
      sameResult (show imageSize <> " at " <> show size) (samples . fst <$> native) (samples . fst <$> sandbox)
      fmap snd native @?= Right icc
      fmap (iccProfile . snd) sandbox @?= Right icc

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

unit_webpMetadata :: IO ()
unit_webpMetadata = do
  still <- B.readFile . (</> "test.webp") =<< getEnv "WEBP_TEST_DATA"
  let profile = B.pack $ take 1001 $ cycle [0 .. 255]
      payload = B.pack $ take 101 $ cycle [255, 254 .. 0]
      webp flags = riff [vp8x flags (128, 128), chunk "ICCP" profile, B.drop 12 still, chunk "EXIF" payload]
  forM_ [(0x28, Metadata (Just profile) (Just payload)), (0, Metadata Nothing Nothing)] \(flags, expected) -> do
    native <- Webp.decodeWebp (Webp.DecodeOptions 128 Right) (webp flags)
    sandbox <- sandboxed (fullSize $ webp flags) (webp flags)
    fmap (\(_, Webp.Metadata icc payload') -> Metadata icc payload') native @?= Right expected
    fmap snd sandbox @?= Right expected

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
  (recursionDeadline, t4) <- timed $ treeSandbox defaultLimits {timeoutMs = 100} 0 30
  recursionDeadline @?= Left "deadline exceeded"
  assertBool ("recursion deadline stop after " <> show t4) $ t4 >= 0.1 && t4 < 1

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

gradient :: (Int, Int) -> Image PixelRGBA8
gradient (w, h) = generateImage (\x y -> PixelRGBA8 (fromIntegral $ x * 7 + y * 3) (fromIntegral $ x * y) (fromIntegral $ x + y * 11) (fromIntegral $ x * 5 + y * 13)) w h

turboJpeg :: TJ2.TJPF -> TJ2.TJSAMP -> TJ2.TJFLAG -> (Int, Int) -> V.Vector Word8 -> IO ByteString
turboJpeg pixelFormat subsamp flags (w, h) pixels =
  bracket TJ2.tjInitCompress TJ2.tjDestroy \tj -> with nullPtr \jpegPtr -> with 0 \sizePtr -> V.unsafeWith pixels \source -> do
    rc <- TJ2.tjCompress2 tj (castPtr source) (fromIntegral w) 0 (fromIntegral h) pixelFormat jpegPtr sizePtr subsamp 90 flags
    jpeg <- peek jpegPtr
    size <- peek sizePtr
    bytes <- if rc == 0 then B.packCStringLen (castPtr jpeg, fromIntegral size) else pure B.empty
    TJ2.tjFree jpeg
    if rc == 0 then pure bytes else assertFailure "JPEG encoding failed"

riff :: [ByteString] -> ByteString
riff chunks = "RIFF" <> le 4 (4 + B.length body) <> "WEBP" <> body
  where
    body = B.concat chunks

vp8x :: Word8 -> (Int, Int) -> ByteString
vp8x flags (w, h) = chunk "VP8X" $ B.pack [flags, 0, 0, 0] <> le 3 (w - 1) <> le 3 (h - 1)

chunk :: ByteString -> ByteString -> ByteString
chunk fourcc payload = fourcc <> le 4 (B.length payload) <> payload <> B.replicate (B.length payload `mod` 2) 0

le :: Int -> Int -> ByteString
le n v = B.pack [fromIntegral (v `shiftR` (8 * i)) | i <- [0 .. n - 1]]

timed :: IO a -> IO (a, Double)
timed action = do
  start <- getMonotonicTimeNSec
  result <- action
  end <- getMonotonicTimeNSec
  pure (result, fromIntegral (end - start) / 1e9)
