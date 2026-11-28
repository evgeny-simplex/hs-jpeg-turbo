module SandboxTest where

import Codec.Picture (DynamicImage(..), Image(..), Palette, Pixel8, PixelCMYK8(..), PixelRGB8(..), PixelRGBA8(..), convertRGBA8, generateImage)
import Codec.Picture.Gif (GifDisposalMethod(..), GifEncode(..), GifFrame(..), GifLooping(..), encodeComplexGifImage)
import Codec.Picture.Jpg (encodeDirectJpegAtQualityWithMetadata)
import Codec.Picture.Types (convertImage, extractLumaPlane)
import Codec.Picture.JPEGTurbo qualified as JPEG
import Codec.Picture.Sandbox
import Codec.Picture.Spng qualified as Spng
import Codec.Picture.Webp qualified as Webp
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, newMVar, putMVar, takeMVar, withMVar)
import Control.Exception (bracket, evaluate)
import Control.Monad (forM, forM_, replicateM, unless)
import Data.Bits (shiftL, shiftR, xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Unsafe qualified as BU
import Data.Char (isSpace)
import Data.Either (isLeft, isRight)
import Data.List (dropWhileEnd, foldl', isSuffixOf, sort, transpose, zip4)
import Data.Maybe (catMaybes, fromMaybe)
import Data.Vector.Storable qualified as V
import Data.Vector.Storable.Mutable qualified as VM
import Data.Word (Word32, Word8)
import Foreign (Ptr, castPtr, copyBytes, nullPtr, peek, with)
import Foreign.C.String (CString, peekCAString)
import Foreign.C.Types (CSize(..))
import GHC.Clock (getMonotonicTimeNSec)
import System.IO.Unsafe (unsafePerformIO)
import System.Directory (listDirectory)
import System.Environment (getEnv, lookupEnv)
import System.FilePath ((</>))
import System.Info (arch)
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
  testImages <- mapM (\file -> (file,) <$> B.readFile file) files
  forM_ testImages compareScales
  forM_ (generated <> encoded) \input@(name, _) -> compareScales input >>= assertBool (name <> ": refused natively") . all isRight
  where
    compareScales (file, jpeg) =
      JPEG.readJpegHeader jpeg >>= \case
        Left e -> [Left e] <$ (sandboxed (fullSize jpeg) jpeg >>= assertBool (file <> ": refused natively, " <> e) . isLeft)
        Right JPEG.JpegHeader {JPEG.jpegWidth, JPEG.jpegHeight} ->
          forM [(JPEG.Full, 1), (JPEG.Half, 2), (JPEG.Quarter, 4), (JPEG.Eighth, 8)] \(scale, d) -> do
            let size = (scaled d jpegWidth, scaled d jpegHeight)
            native <- fmap samples <$> JPEG.decodeJpeg (JPEG.DecodeOptions scale maxImagePixels 1024) jpeg
            sandbox <- fmap (samples . fst) <$> sandboxed (const $ Right size) jpeg
            native <$ sameResult (file <> " at 1/" <> show d) native sandbox
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
  let images = [((16384, 16), [(4096, 4), (1, 1)], Nothing), ((16, 16384), [(4, 4096)], Nothing), ((8641, 3), [(4320, 2), (4320, 1), (4321, 2)], Nothing), ((37, 23), [(11, 7)], Just profile)]
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
  let scaledTolerance = if nativeNeon then 3 else 0
  forM_ files \file -> do
    webp <- B.readFile file
    forM_ [(0 :: Int, Right), (scaledTolerance, \(w, h) -> Right ((w + 1) `div` 2, (h + 1) `div` 2)), (scaledTolerance, \(w, h) -> Right (max 1 $ w `div` 7, max 1 $ h `div` 5))] \(tolerance, size) -> do
      native <- Webp.decodeWebp (Webp.DecodeOptions 128 size) webp
      sandbox <- sandboxed (size . headerSize) webp
      case (native, sandbox) of
        (Right (n, Webp.Metadata {Webp.iccProfile = icc, Webp.exif = payload}), Right (s, metadata)) -> do
          assertBool (file <> " at " <> show (dims n) <> ": " <> difference (samples n) (samples s) <> ", more than " <> show tolerance) $ closeTo tolerance (samples n) (samples s)
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
  neon <- nativeJpegNeon
  forM_ [("JPEG", jpeg, if neon then 255 else 0), ("PNG", png, 0), ("WebP", webp, 0)] \(name, input, changedTolerance) -> do
    let n = B.length input
        truncated = [(0, "truncated to " <> show (n * k `div` 32), B.take (n * k `div` 32) input) | k <- [0 .. 31]]
        changed = [(changedTolerance, "bit " <> show (k `mod` 8) <> " flipped at " <> show (n * k `div` 32), flipBit (n * k `div` 32) k input) | k <- [0 .. 31]]
    forM_ (truncated <> changed) \(tolerance, change, input') -> do
      sandbox <- sandboxed (fullSize input') input'
      native <- nativeDecode input'
      case (native, sandbox) of
        (Right n', Right (s, _)) -> assertBool (name <> " " <> change <> ": " <> difference n' (samples s)) $ closeTo tolerance n' (samples s)
        (_, Left _) -> pure ()
        (Left e, Right _) -> assertFailure $ name <> " " <> change <> ": decoded in the sandbox, refused natively: " <> e

unit_limits :: IO ()
unit_limits = do
  png <- largePng
  sandboxedWith defaultLimits {memoryLimitMB = 16} Right png >>= (@?= Left "image is too large") . void'
  sandboxedWith defaultLimits Right png >>= assertBool "decoded within 256 MiB" . not . isLeft
  let rgb = generateImage (\x y -> PixelRGB8 (fromIntegral x) (fromIntegral y) (fromIntegral $ x + y)) 2000 1000
  progressive <- turboJpeg TJ2.TJPF_RGB TJ2.TJSAMP_444 TJ2.TJFLAG_PROGRESSIVE (2000, 1000) (imageData rgb)
  sandboxedWith defaultLimits {memoryLimitMB = 16} Right progressive >>= (@?= Left "image is too large") . void'
  sandboxedWith defaultLimits Right progressive >>= assertBool "progressive JPEG decoded within 256 MiB" . not . isLeft
  sandboxedWith defaultLimits {timeoutMs = 1} Right png >>= (@?= Left "deadline exceeded") . void'
  counted <- decodeImageCounted defaultBudget {base = 1000, perByte = 0, perPixel = const 0} (options defaultLimits Right) png
  void' (decoded counted) @?= Left "budget exceeded"
  sandboxedWith defaultLimits (\(w, h) -> Right (w + 1, h)) png >>= (@?= Left "invalid decode options") . void'
  jpeg <- B.readFile $ jpegDir </> "testorig.jpg"
  sandboxedWith defaultLimits (\(w, h) -> Right (w - 1, h)) jpeg >>= (@?= Left "invalid decode options") . void'
  decodeImage (options defaultLimits Right) {maxPixels = maxBound} (jpegOfSize (37838, 37838) jpeg) >>= (@?= Left "image is too large") . void'
  sandboxedWith defaultLimits Right "BM" >>= (@?= Left "unsupported image format") . void'
  ok <- decodeImageCounted defaultBudget (options defaultLimits Right) jpeg
  assertBool "iterations counted" $ iterations ok > 0
  (\(header, _, _) -> header) <$> decoded ok @?= Right (ImageHeader JPEG 227 149 1 1)
  where
    void' = fmap (const ())

unit_traps :: IO ()
unit_traps = do
  loadSandboxByte defaultLimits {memoryLimitMB = 16} 0 >>= (@?= Right 0)
  loadSandboxByte defaultLimits {memoryLimitMB = 16} maxBound >>= (@?= Left "sandbox trap 1")
  treeSandbox defaultLimits {memoryLimitMB = 16} 0 200 >>= (@?= Left "sandbox trap 10")

unit_moduleOutputChecks :: IO ()
unit_moduleOutputChecks = do
  header [0, 1, 100, 200, 1, 1] "" >>= (@?= Right (ImageHeader JPEG 100 200 1 1))
  header [0, 4, 100, 200, 3, 0] "" >>= (@?= Right (ImageHeader GIF 100 200 3 0))
  header [at + 24, 1, 1, 1, 1, 1] "unsupported image format\0" >>= (@?= Left "unsupported image format")
  forM_
    [[0, 0, 1, 1, 1, 1], [0, 5, 1, 1, 1, 1], [0, 3, 0, 1, 1, 1], [0, 3, 65536, 1, 1, 1], [0, 3, 1, 0, 1, 1], [0, 3, 1, 65536, 1, 1], [0, 4, 1, 1, 0, 1], [maxBound, 1, 1, 1, 1, 1], [at + 24, 1, 1, 1, 1, 1]]
    \fields -> header fields "\0" >>= (@?= Left "invalid sandbox output")
  readSandboxHeader limits maxBound (words32 [0, 1, 1, 1, 1, 1]) >>= (@?= Left "invalid sandbox output")
  forM_ [(1, 1), (1, 2), (1, 4), (2, 2), (2, 3), (3, 2), (3, 3), (4, 3)] \(format, layout) ->
    output 0 format (2, 3) [0, 2, 3, layout, pixels, 0, 0, 0, 0] "" >>= (@?= Right ())
  output 16 3 (2, 3) [0, 2, 3, 2, pixels, pixels, 16, pixels, 16] "" >>= (@?= Right ())
  output 0 1 (2, 3) [at + 36, 2, 3, 2, pixels, 0, 0, 0, 0] "invalid decode options\0" >>= (@?= Left "invalid decode options")
  forM_
    [ (0, 1, (2, 3), [0, 2, 3, 3, pixels, 0, 0, 0, 0])
    , (0, 2, (2, 3), [0, 2, 3, 1, pixels, 0, 0, 0, 0])
    , (0, 2, (2, 3), [0, 2, 3, 4, pixels, 0, 0, 0, 0])
    , (0, 3, (2, 3), [0, 2, 3, 1, pixels, 0, 0, 0, 0])
    , (0, 3, (2, 3), [0, 2, 3, 4, pixels, 0, 0, 0, 0])
    , (0, 4, (2, 3), [0, 2, 3, 1, pixels, 0, 0, 0, 0])
    , (0, 4, (2, 3), [0, 2, 3, 2, pixels, 0, 0, 0, 0])
    , (0, 4, (2, 3), [0, 2, 3, 4, pixels, 0, 0, 0, 0])
    , (0, 1, (2, 3), [0, 2, 3, 0, pixels, 0, 0, 0, 0])
    , (0, 1, (2, 3), [0, 2, 3, 5, pixels, 0, 0, 0, 0])
    , (0, 2, (3, 3), [0, 2, 3, 2, pixels, 0, 0, 0, 0])
    , (0, 2, (2, 2), [0, 2, 3, 2, pixels, 0, 0, 0, 0])
    , (0, 2, (2, 3), [0, 2, 3, 2, maxBound - 8, 0, 0, 0, 0])
    , (0, 3, (65535, 65535), [0, 65535, 65535, 3, pixels, 0, 0, 0, 0])
    , (0, 2, (2, 3), [0, 2, 3, 2, pixels, pixels, 64 * 1048576 + 1, 0, 0])
    , (0, 2, (2, 3), [0, 2, 3, 2, pixels, maxBound, 16, 0, 0])
    , (15, 3, (2, 3), [0, 2, 3, 2, pixels, 0, 0, pixels, 16])
    , (16, 3, (2, 3), [0, 2, 3, 2, pixels, 0, 0, maxBound, 16])
    , (0, 1, (2, 3), [maxBound, 2, 3, 2, pixels, 0, 0, 0, 0])
    , (0, 1, (2, 3), [at + 36, 2, 3, 2, pixels, 0, 0, 0, 0])
    ]
    \(size, format, request, fields) -> output size format request fields "\0" >>= (@?= Left "invalid sandbox output")
  readSandboxOutput limits 0 2 (2, 3) maxBound (words32 [0, 2, 3, 2, pixels, 0, 0, 0, 0]) >>= (@?= Left "invalid sandbox output")
  forM_ [(0, [0, 0, 0, 0, 0, 0]), (0, [0, 1, 0, 0, 0, 0]), (16, [0, 1, pixels, 16, pixels, 16])] \(size, fields) -> start size fields "" >>= (@?= Right ())
  start 0 [at + 24, 0, 0, 0, 0, 0] "invalid WebP frame\0" >>= (@?= Left "invalid WebP frame")
  forM_
    [ (0, [0, 2, 0, 0, 0, 0])
    , (0, [0, 0, maxBound, 16, 0, 0])
    , (0, [0, 0, pixels, 64 * 1048576 + 1, 0, 0])
    , (15, [0, 0, 0, 0, pixels, 16])
    , (16, [0, 0, 0, 0, maxBound, 16])
    , (0, [maxBound, 0, 0, 0, 0, 0])
    , (0, [at + 24, 0, 0, 0, 0, 0])
    ]
    \(size, fields) -> start size fields "\0" >>= (@?= Left "invalid sandbox output")
  readSandboxStart limits 0 maxBound (words32 [0, 0, 0, 0, 0, 0]) >>= (@?= Left "invalid sandbox output")
  frame (2, 3) [0, 2, 3, pixels, 40] "" >>= (@?= Right ())
  frame (2, 3) [at + 20, 2, 3, pixels, 40] "bad code\0" >>= (@?= Left "bad code")
  forM_
    [ ((2, 3), [0, 3, 3, pixels, 40])
    , ((2, 3), [0, 2, 2, pixels, 40])
    , ((2, 3), [0, 2, 3, maxBound - 8, 40])
    , ((1024, 1024), [0, 1024, 1024, pixels, 40])
    , ((2, 3), [maxBound, 2, 3, pixels, 40])
    , ((2, 3), [at + 20, 2, 3, pixels, 40])
    ]
    \(size, fields) -> frame size fields "\0" >>= (@?= Left "invalid sandbox output")
  readSandboxFrame limits (2, 3) maxBound (words32 [0, 2, 3, pixels, 40]) >>= (@?= Left "invalid sandbox output")
  where
    limits = defaultLimits {memoryLimitMB = 16}
    at = 65536
    pixels = at + 64
    header fields text = readSandboxHeader limits at (words32 fields <> text)
    output size format request fields text = readSandboxOutput limits size format request at (words32 fields <> text)
    start size fields text = readSandboxStart limits size at (words32 fields <> text)
    frame size fields text = readSandboxFrame limits size at (words32 fields <> text)
    words32 = foldMap (le 4 . fromIntegral)

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

unit_stillFrames :: IO ()
unit_stillFrames = do
  jpeg <- B.readFile $ jpegDir </> "testorig.jpg"
  pngs <- mapM (B.readFile . (pngDir </>)) ["basn6a08.png", "basn2c08.png", "basn0g08.png", "tbrn2c08.png"]
  webps <- mapM (\file -> B.readFile . (</> file) =<< getEnv "WEBP_TEST_DATA") ["test.webp", "lossy_alpha1.webp", "lossless1.webp"]
  animatedWebp <- head <$> webpAnimations
  let cmyk = BL.toStrict $ encodeDirectJpegAtQualityWithMetadata 90 mempty (generateImage (\x y -> PixelCMYK8 (fromIntegral $ x * 7) (fromIntegral $ y * 11) 40 (fromIntegral $ x + y)) 37 23)
      jpegSizes = [id, \(w, h) -> ((w + 1) `div` 2, (h + 1) `div` 2)]
      sizes = [id, \(w, h) -> (max 1 $ w `div` 2, max 1 $ h `div` 2), \(w, h) -> (min 11 w, min 7 h)]
      inputs = [(jpeg, jpegSizes), (cmyk, jpegSizes)] <> map (,sizes) (pngs <> webps <> [animatedWebp] <> generatedGifs)
  forM_ inputs \(input, scales) -> forM_ scales \scale -> do
    let decodeOptions = options defaultLimits (Right . scale)
    (header, image, metadata) <- either assertFailure pure =<< decodeImage decodeOptions input
    frames <- either assertFailure pure =<< openFrames decodeOptions (const Still) input
    let size = scale $ headerSize header
        name = show header <> " at " <> show size
    assertEqual (name <> ": header") header (framesHeader frames)
    assertEqual (name <> ": metadata") metadata (framesMetadata frames)
    assertEqual (name <> ": alpha") (hasAlpha image) (framesAlpha frames)
    rgba <- readFrame frames PremultipliedRGBA size
    bgra <- readFrame frames PremultipliedBGRA size
    closeFrames frames
    assertEqual (name <> ": RGBA") (Right (premultiplied image, 0)) rgba
    assertEqual (name <> ": BGRA") (Right (swapRedBlue $ premultiplied image, 0)) bgra
  where
    hasAlpha = \case
      ImageRGBA8 _ -> True
      _ -> False

unit_frameRows :: IO ()
unit_frameRows = do
  png <- B.readFile $ pngDir </> "basn6a08.png"
  let (w, h) = (32, 32)
      stride = w * 4 + 12
      still = openFrames (options defaultLimits Right) (const Still) png >>= either assertFailure pure
  frames <- still
  expected <- readFrame frames PremultipliedRGBA (w, h) >>= either assertFailure (pure . fst)
  buffer <- VM.replicate (stride * h) 0xA5
  VM.unsafeWith buffer (\p -> nextFrame frames PremultipliedRGBA p stride) >>= (@?= Right 0)
  rows <- V.freeze buffer
  forM_ [0 .. h - 1] \y -> do
    V.slice (y * stride) (w * 4) rows @?= V.slice (y * w * 4) (w * 4) expected
    V.slice (y * stride + w * 4) 12 rows @?= V.replicate 12 0xA5
  closeFrames frames
  withoutResult <$> readFrame frames PremultipliedRGBA (w, h) >>= (@?= Left "image is closed")
  stopped <- still
  VM.unsafeWith buffer (\p -> nextFrame stopped PremultipliedRGBA p (w * 4 - 1)) >>= (@?= Left "invalid argument")
  withoutResult <$> readFrame stopped PremultipliedRGBA (w, h) >>= (@?= Left "invalid argument")
  jpeg <- B.readFile $ jpegDir </> "testorig.jpg"
  withoutResult <$> openFrames (options defaultLimits Right) (const Animation) jpeg >>= (@?= Left "invalid decode options")

unit_webpAnimation :: IO ()
unit_webpAnimation = do
  animations <- webpAnimations
  assertBool "WebP animations of the conformance files" $ length animations >= 20
  forM_ (zip [1 :: Int ..] animations) \(n, webp) -> do
    let name = "animation " <> show n
    Webp.Animation {Webp.canvasWidth, Webp.canvasHeight, Webp.loopCount = loops, Webp.frames = native} <-
      either (assertFailure . ((name <> ": refused natively, ") <>)) pure =<< Webp.decodeWebpAnimation 256 webp
    full <- sandboxFrames id webp
    assertEqual (name <> " at full size") (Right (ImageHeader WebP canvasWidth canvasHeight (length native) loops, native)) full
    half <- sandboxFrames halve webp >>= either assertFailure (pure . snd)
    forM_ (zip3 [1 :: Int ..] native half) \(k, (canvas, duration), (scaled, duration')) -> do
      duration' @?= duration
      let largest = V.maximum $ halfDifferences canvasWidth canvas scaled
      assertBool (name <> ", frame " <> show k <> " at half size: samples differ from the averages of the native frame by up to " <> show largest) $ largest <= 2

unit_gifConformance :: IO ()
unit_gifConformance = do
  dir <- getEnv "GIF_TEST_SUITE"
  names <- filter (not . null) . lines <$> readFile (dir </> "TESTS")
  assertBool "GIF test suite" $ length names >= 80
  problems <- forM names \name -> do
    conf <- parseConf <$> readFile (dir </> name <> ".conf")
    gif <- B.readFile $ dir </> setting conf "config" "input"
    expected <- forM (expectedFrames conf) \frame -> (,10 * maybe 0 read (lookupSetting conf frame "delay")) <$> expectedPixels dir conf frame
    sandbox <- sandboxFrames id gif
    pure (name, conformance conf (lookup name gifSeparateImages) expected sandbox)
  let failing = [(name, issue) | (name, Just issue) <- problems]
  assertEqual ("GIF conformance: " <> show failing) gifDeviations (map fst failing)
  where
    conformance conf separate expected = \case
      Left e
        | null expected -> Nothing
        | otherwise -> Just $ "refused: " <> e
      Right (ImageHeader {width, height, frameCount, loopCount}, frames)
        | null expected -> Just $ "decoded " <> show frameCount <> " frames, expected none"
        | (width, height) /= (read $ setting conf "config" "width", read $ setting conf "config" "height") -> Just $ "size " <> show (width, height)
        | loopCount /= expectedLoops (length expected) (setting conf "config" "loop-count") -> Just $ "loop count " <> show loopCount
        | Just (images, shown) <- separate, length frames /= images || map (frames !!) shown /= expected -> Just $ "frames of the separate images differ"
        | Nothing <- separate, frames /= expected -> Just $ "frames differ: " <> show [k | (k, a, b) <- zip3 [0 :: Int ..] frames expected, a /= b] <> " of " <> show (length frames, length expected)
        | otherwise -> Nothing
    expectedLoops frames loops
      | frames <= 1 = 1
      | loops == "infinite" = 0
      | otherwise = read loops + 1

unit_gifNative :: IO ()
unit_gifNative = do
  dir <- getEnv "GIF_TEST_SUITE"
  suite <- mapM (B.readFile . (dir </>)) . sort . filter (".gif" `isSuffixOf`) =<< listDirectory dir
  let tolerance = if nativeNeon then 3 else 0
  forM_ (zip [1 :: Int ..] $ suite <> generatedGifs) \(n, gif) -> forM_ [(0, id), (tolerance, halve), (tolerance, \(w, h) -> (min 11 w, min 7 h))] \(close, scale) ->
    sandboxFrameResults scale gif >>= \case
      Left e -> nativeGifFrames (1, 1) 0 gif >>= assertBool ("GIF " <> show n <> ": refused in the sandbox, " <> e <> ", opened natively") . isLeft
      Right (header@ImageHeader {frameCount}, frames) -> do
        let name = "GIF " <> show n <> " at " <> show (scale $ headerSize header)
        native <- nativeGifFrames (scale $ headerSize header) frameCount gif >>= either (assertFailure . ((name <> ": refused natively, ") <>)) pure
        assertEqual (name <> ": frames decoded natively and in the sandbox") (length native) (length frames)
        forM_ (zip3 [1 :: Int ..] native frames) \(k, a, b) -> case (a, b) of
          (Right (x, d), Right (y, d')) -> do
            d' @?= d
            assertBool (name <> ", frame " <> show k <> ": differs from the native frame by more than " <> show close) $
              V.and (V.zipWith (\p q -> abs (fromIntegral p - fromIntegral q :: Int) <= close) x y)
          (Left _, Left _) -> pure ()
          _ -> assertFailure $ name <> ", frame " <> show k <> ": native " <> outcome a <> ", sandbox " <> outcome b

unit_frameLimits :: IO ()
unit_frameLimits = do
  let dots = gifOf (1024, 1024) LoopingForever $ replicate 100 (gifFrame (0, 0) (1, 1) Nothing DisposalAny \_ _ -> 7) <> [gifFrame (0, 0) (1024, 1024) Nothing DisposalAny noise]
  budgeted <- either assertFailure pure =<< openFramesWithBudget unlimitedBudget {base = 500000} (options defaultLimits {timeoutMs = 0} Right) (const Animation) dots
  small <- replicateM 100 $ readFrame budgeted PremultipliedRGBA (1024, 1024)
  assertBool "each 1x1 frame decoded within its own budget" $ all isRight small
  replicateM 2 (withoutResult <$> readFrame budgeted PremultipliedRGBA (1024, 1024)) >>= (@?= replicate 2 (Left "budget exceeded"))
  slow <- evaluate $ gifOf (2048, 2048) LoopingForever [gifFrame (0, 0) (1, 1) Nothing DisposalAny \_ _ -> 7, gifFrame (0, 0) (2048, 2048) Nothing DisposalAny noise]
  let openSlow timeout = openFrames (options defaultLimits {timeoutMs = timeout} Right) (const Animation) slow >>= either assertFailure pure
  (unbounded, opening) <- timed $ openSlow 0
  _ <- readFrame unbounded PremultipliedRGBA (2048, 2048)
  (_, decoding) <- timedFrame unbounded (2048, 2048)
  closeFrames unbounded
  let timeout = round ((opening * 2 + decoding) * 500) :: Int
  assertBool ("the noise frame decoded in " <> show decoding <> " s, the session opened in " <> show opening <> " s") $ opening * 2 < decoding
  deadlined <- openSlow timeout
  (first, t1) <- timedFrame deadlined (2048, 2048)
  assertBool ("the 1x1 frame decoded within its own deadline, " <> show t1 <> " s") $ isRight first
  (second, t2) <- timedFrame deadlined (2048, 2048)
  second @?= Left "deadline exceeded"
  assertBool ("deadline stop after " <> show t2 <> " s, the frame decoded in " <> show decoding <> " s") $ t2 * 1000 >= fromIntegral timeout && t2 < decoding
  animation <- evaluate $ gifOf (64, 48) LoopingForever [gifFrame (0, 0) (64, 48) Nothing DisposalAny \x y -> fromIntegral (x + y + k) | k <- [0 .. 9]]
  long <- either assertFailure pure =<< openFrames (options defaultLimits {timeoutMs = 50} Right) (const Animation) animation
  (read', t3) <- timed $ replicateM 10 (readFrame long PremultipliedRGBA (64, 48) <* threadDelay 20000)
  assertBool ("an animation read in " <> show t3 <> " s, longer than one deadline") $ t3 > 0.05
  assertBool "every frame decoded" $ all isRight read'
  where
    timedFrame frames size = timed $ withoutResult <$> readFrame frames PremultipliedRGBA size
    noise x y = fromIntegral ((x * 1103515245 + y * 12345 + x * y * 2654435761) `shiftR` 11)

unit_frameSessions :: IO ()
unit_frameSessions = do
  animated <- (: generatedGifs) . head <$> webpAnimations
  expected <- mapM (sandboxFrames id) animated
  frames <- forM animated \input -> either assertFailure pure =<< openFrames (options defaultLimits Right) (const Animation) input
  interleaved <- forM [0 .. 2 * maximum (map (frameCount . framesHeader) frames) - 1] \_ -> forM frames \f -> readFrame f PremultipliedRGBA (headerSize $ framesHeader f)
  forM_ (zip3 [1 :: Int ..] expected (transpose interleaved)) \(n, decoded, frames') ->
    case decoded of
      Right (_, single) -> assertEqual ("animation " <> show n <> " read with the others, twice") (map Right $ take (length frames') $ cycle single) frames'
      Left e -> assertFailure e
  forM_ frames \f -> do
    rewindFrames f
    first <- readFrame f PremultipliedRGBA (headerSize $ framesHeader f)
    _ <- readFrame f PremultipliedRGBA (headerSize $ framesHeader f)
    rewindFrames f
    again <- readFrame f PremultipliedRGBA (headerSize $ framesHeader f)
    again @?= first
    closeFrames f
  results <- replicateM 8 do
    done <- newEmptyMVar
    _ <- forkIO $ putMVar done . (== expected) =<< mapM (sandboxFrames id) animated
    pure done
  forM_ results \done -> takeMVar done >>= assertBool "every animation read on 8 threads as alone"

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
sandboxed size input = fmap withoutHeader <$> decodeImage DecodeOptions {limits = defaultLimits, maxPixels = maxImagePixels, outputSize = size} input

sandboxedWith :: Limits -> ((Int, Int) -> Either String (Int, Int)) -> ByteString -> IO (Either String (DynamicImage, Metadata))
sandboxedWith l size input = fmap withoutHeader <$> decodeImage (options l size) input

withoutHeader :: (ImageHeader, DynamicImage, Metadata) -> (DynamicImage, Metadata)
withoutHeader (_, img, metadata) = (img, metadata)

fullSize :: ByteString -> ImageHeader -> Either String (Int, Int)
fullSize _ = Right . headerSize

headerSize :: ImageHeader -> (Int, Int)
headerSize ImageHeader {width, height} = (width, height)

nativeNeon :: Bool
nativeNeon = arch `elem` ["aarch64", "arm"]

nativeJpegNeon :: IO Bool
nativeJpegNeon = do
  forceNone <- lookupEnv "JSIMD_FORCENONE"
  pure $ nativeNeon && forceNone /= Just "1"

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

difference :: Samples -> Samples -> String
difference (f, w, h, a) (f', w', h', b)
  | (f, w, h) /= (f', w', h') = "native " <> show (f, w, h) <> ", sandbox " <> show (f', w', h')
  | otherwise = "samples differ by up to " <> show largest <> " in " <> show count <> " of " <> show (V.length a)
  where
    differences = V.filter (> 0) $ V.zipWith (\x y -> abs (fromIntegral x - fromIntegral y :: Int)) a b
    largest = if V.null differences then 0 else V.maximum differences
    count = V.length differences

flipBit :: Int -> Int -> ByteString -> ByteString
flipBit i k input = case B.splitAt i input of
  (before, after) -> before <> B.map (`xor` (1 `shiftL` (k `mod` 8))) (B.take 1 after) <> B.drop 1 after

jpegOfSize :: (Int, Int) -> ByteString -> ByteString
jpegOfSize (w, h) jpeg = go 2
  where
    go i
      | B.index jpeg (i + 1) `elem` [0xC0, 0xC1, 0xC2] = B.take (i + 5) jpeg <> be16 h <> be16 w <> B.drop (i + 9) jpeg
      | otherwise = go (i + 2 + 256 * fromIntegral (B.index jpeg (i + 2)) + fromIntegral (B.index jpeg (i + 3)))
    be16 v = B.pack [fromIntegral (v `shiftR` 8), fromIntegral v]

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

withoutResult :: Either String a -> Either String ()
withoutResult = fmap (const ())

readFrame :: Frames -> PixelFormat -> (Int, Int) -> IO (Either String (V.Vector Word8, Int))
readFrame frames pixelFormat (w, h) = do
  buffer <- VM.new (w * h * 4)
  duration <- VM.unsafeWith buffer \p -> nextFrame frames pixelFormat p (w * 4)
  pixels <- V.freeze buffer
  pure $ (pixels,) <$> duration

sandboxFrames :: ((Int, Int) -> (Int, Int)) -> ByteString -> IO (Either String (ImageHeader, [(V.Vector Word8, Int)]))
sandboxFrames scale input = (>>= \(header, decoded) -> (header,) <$> sequence decoded) <$> sandboxFrameResults scale input

sandboxFrameResults :: ((Int, Int) -> (Int, Int)) -> ByteString -> IO (Either String (ImageHeader, [Either String (V.Vector Word8, Int)]))
sandboxFrameResults scale input =
  openFrames (options defaultLimits (Right . scale)) (const Animation) input >>= \case
    Left e -> pure $ Left e
    Right frames -> do
      let header@ImageHeader {frameCount} = framesHeader frames
      decoded <- replicateM frameCount $ readFrame frames PremultipliedRGBA (scale $ headerSize header)
      closeFrames frames
      pure $ Right (header, upToFailure decoded)

upToFailure :: [Either e a] -> [Either e a]
upToFailure results = let (decoded, failures) = span isRight results in decoded <> take 1 failures

nativeGifFrames :: (Int, Int) -> Int -> ByteString -> IO (Either String [Either String (V.Vector Word8, Int)])
nativeGifFrames (w, h) count gif = withMVar nativeLock \_ -> BU.unsafeUseAsCStringLen gif \(buf, len) -> do
  failure <- nativeGifStart (castPtr buf) (fromIntegral len) (fromIntegral w) (fromIntegral h)
  if failure /= nullPtr then Left <$> peekCAString failure else Right . upToFailure <$> replicateM count frame <* nativeFramesClose
  where
    frame = with nullPtr \pixels -> with 0 \duration -> do
      failure <- nativeFramesNext 0 pixels duration
      if failure /= nullPtr
        then Left <$> peekCAString failure
        else do
          source <- peek pixels
          copied <- VM.new (w * h * 4)
          VM.unsafeWith copied \destination -> copyBytes destination source (w * h * 4)
          canvas <- V.freeze copied
          Right . (canvas,) . fromIntegral <$> peek duration

nativeLock :: MVar ()
nativeLock = unsafePerformIO $ newMVar ()
{-# NOINLINE nativeLock #-}

premultiplied :: DynamicImage -> V.Vector Word8
premultiplied = premultipliedSamples . imageData . convertRGBA8

premultipliedSamples :: V.Vector Word8 -> V.Vector Word8
premultipliedSamples rgba = V.imap channel rgba
  where
    channel i c
      | i `mod` 4 == 3 = c
      | otherwise = fromIntegral ((fromIntegral c * fromIntegral (rgba V.! (i - i `mod` 4 + 3)) + 127) `div` (255 :: Int))

swapRedBlue :: V.Vector Word8 -> V.Vector Word8
swapRedBlue rgba = V.imap (\i _ -> rgba V.! (i - i `mod` 4 + [2, 1, 0, 3] !! (i `mod` 4))) rgba

halve :: (Int, Int) -> (Int, Int)
halve (w, h) = (max 1 $ w `div` 2, max 1 $ h `div` 2)

halfDifferences :: Int -> V.Vector Word8 -> V.Vector Word8 -> V.Vector Double
halfDifferences w canvas = V.imap deviation
  where
    half = w `div` 2
    deviation i s = abs (sum [sample (2 * x + dx) (2 * y + dy) | dx <- [0, 1], dy <- [0, 1]] / 4 - fromIntegral s)
      where
        (pixel, c) = i `divMod` 4
        (y, x) = pixel `divMod` half
        sample x' y' = fromIntegral (canvas V.! ((y' * w + x') * 4 + c))

webpAnimations :: IO [ByteString]
webpAnimations = do
  stills <- fmap catMaybes . mapM still =<< webpFiles
  pure $ map animation $ chunksOf 4 stills
  where
    still file = do
      webp <- B.readFile file
      either (const Nothing) (\(image, _) -> Just (dims image, imageChunks webp)) <$> Webp.decodeWebp (Webp.DecodeOptions 128 Right) webp
    animation group =
      let placed = zip4 [(0, 0), (2, 0), (0, 2), (4, 4)] [0, 1, 2, 3] [100, 0, 10, 1000] group
          extent (x, y) (w, h) = (x + w, y + h)
          sides = [extent offset size | (offset, _, _, (size, _)) <- placed]
          canvas = (evenSide $ maximum $ map fst sides, evenSide $ maximum $ map snd sides)
       in webpAnimation canvas [(offset, size, flags, duration, payload) | (offset, flags, duration, (size, payload)) <- placed]
    evenSide n = n + n `mod` 2
    chunksOf n = takeWhile (not . null) . map (take n) . iterate (drop n)

webpAnimation :: (Int, Int) -> [((Int, Int), (Int, Int), Word8, Int, ByteString)] -> ByteString
webpAnimation size frames = riff $ [vp8x 0x12 size, chunk "ANIM" (le 4 0 <> le 2 3)] <> map anmf frames
  where
    anmf ((x, y), (w, h), flags, duration, payload) = chunk "ANMF" $ le 3 (x `div` 2) <> le 3 (y `div` 2) <> le 3 (w - 1) <> le 3 (h - 1) <> le 3 duration <> B.singleton flags <> payload

imageChunks :: ByteString -> ByteString
imageChunks = chunks . B.drop 12
  where
    chunks s
      | B.length s < 8 = B.empty
      | otherwise = (if B.take 4 s `elem` ["ALPH", "VP8 ", "VP8L"] then B.take total s else B.empty) <> chunks (B.drop total s)
      where
        size = B.foldr' (\b n -> n * 256 + fromIntegral b) 0 (B.take 4 $ B.drop 4 s)
        total = 8 + size + size `mod` 2

gifOf :: (Int, Int) -> GifLooping -> [GifFrame] -> ByteString
gifOf (w, h) looping frames =
  either error BL.toStrict $ encodeComplexGifImage GifEncode {geWidth = w, geHeight = h, gePalette = Just gifPalette, geBackground = Nothing, geLooping = looping, geFrames = frames}

gifPalette :: Palette
gifPalette = generateImage (\i _ -> PixelRGB8 (fromIntegral i) (fromIntegral $ i * 7) (fromIntegral $ i * 13)) 256 1

gifFrame :: (Int, Int) -> (Int, Int) -> Maybe Int -> GifDisposalMethod -> (Int -> Int -> Pixel8) -> GifFrame
gifFrame (x, y) (w, h) transparent disposal pixel =
  GifFrame {gfXOffset = x, gfYOffset = y, gfPalette = Nothing, gfTransparent = transparent, gfDelay = 4, gfDisposal = disposal, gfPixels = generateImage pixel w h}

generatedGifs :: [ByteString]
generatedGifs =
  [ gifOf
      (64, 48)
      LoopingForever
      [ gifFrame (0, 0) (64, 48) Nothing DisposalDoNot \x y -> fromIntegral (x * 3 + y * 5)
      , gifFrame (8, 4) (20, 10) (Just 9) DisposalRestoreBackground \x y -> fromIntegral (x * y `mod` 17)
      , gifFrame (30, 20) (30, 20) (Just 0) DisposalRestorePrevious \x y -> fromIntegral ((x + y) `mod` 5)
      , gifFrame (1, 1) (10, 10) Nothing DisposalAny \x y -> fromIntegral (x `xor` y)
      ]
  , gifOf (301, 199) (LoopingRepeat 2) [gifFrame (0, 0) (301, 199) (Just 255) DisposalRestoreBackground \x y -> fromIntegral (x * 31 + y * 17 + k) | k <- [0, 64, 128]]
  ]

type Conf = [(String, [(String, String)])]

parseConf :: String -> Conf
parseConf = reverse . map (fmap reverse) . foldl' entry [] . lines
  where
    entry sections line = case trim line of
      '[' : name -> (takeWhile (/= ']') name, []) : sections
      setting'
        | (key, '=' : value) <- break (== '=') setting', (name, settings) : others <- sections -> (name, (trim key, trim value) : settings) : others
      _ -> sections
    trim = dropWhileEnd isSpace . dropWhile isSpace

lookupSetting :: Conf -> String -> String -> Maybe String
lookupSetting conf section key = lookup section conf >>= lookup key

setting :: Conf -> String -> String -> String
setting conf section = fromMaybe "" . lookupSetting conf section

expectedFrames :: Conf -> [String]
expectedFrames conf = words [if c == ',' then ' ' else c | c <- setting conf "config" "frames"]

expectedPixels :: FilePath -> Conf -> String -> IO (V.Vector Word8)
expectedPixels dir conf frame = case (lookupSetting conf frame "pixels", lookupSetting conf frame "image") of
  (Just raw, _) -> premultipliedSamples . V.fromList . B.unpack <$> B.readFile (dir </> raw)
  (_, Just png) -> B.readFile (dir </> png) >>= Spng.decodePng (Spng.DecodeOptions maxImagePixels 128 Right) >>= either assertFailure (pure . premultiplied . fst)
  _ -> assertFailure $ frame <> ": no expected pixels"

gifSeparateImages :: [(String, (Int, [Int]))]
gifSeparateImages =
  [ ("dispose-restore-previous", (5, [1, 2, 3, 4]))
  , ("animation-multi-image", (7, [0, 2, 4, 6]))
  , ("animation-multi-image-explicit-zero-delay", (7, [0, 2, 4, 6]))
  , ("images-combine", (4, [3]))
  , ("images-overlap", (2, [1]))
  , ("high-color", (4, [3]))
  ]

gifDeviations :: [String]
gifDeviations =
  [ "no-data"
  , "image-zero-width"
  , "image-zero-height"
  , "image-zero-size"
  , "image-overlap-bg"
  , "image-outside-bg"
  , "invalid-colors"
  , "max-width"
  , "max-height"
  , "max-codes"
  , "plain-text"
  , "gif87a-animation"
  ]

foreign import ccall safe "native_gif_frames" nativeGifStart :: Ptr Word8 -> CSize -> Word32 -> Word32 -> IO CString

foreign import ccall safe "frames_next" nativeFramesNext :: Word32 -> Ptr (Ptr Word8) -> Ptr Word32 -> IO CString

foreign import ccall unsafe "frames_close" nativeFramesClose :: IO ()
