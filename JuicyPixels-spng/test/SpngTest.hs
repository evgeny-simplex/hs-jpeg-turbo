module SpngTest where

import Codec.Compression.Zlib qualified as Z
import Codec.Picture (DynamicImage(..), Image(..), PixelRGBA8(..), convertRGB8, convertRGBA8, dynamicMap, generateImage)
import Codec.Picture qualified as JP
import Codec.Picture.Spng
import Control.Monad (forM_)
import Data.Bifunctor (first)
import Data.Bits (complement, shiftR, testBit, xor)
import Data.ByteString qualified as B
import Data.ByteString.Builder qualified as BB
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft, isRight)
import Data.Vector.Storable qualified as V
import Data.Word (Word32, Word64, Word8)
import Test.Tasty.HUnit (assertBool, assertFailure, (@?=))

unit_header :: IO ()
unit_header = do
  headers <- mapM (\name -> B.readFile (suiteImage name) >>= readPngHeader) ["basn6a16", "basi3p08", "basn0g08"]
  headers @?= map Right [PngHeader 32 32 16 6 0, PngHeader 32 32 8 3 1, PngHeader 32 32 8 0 0]

unit_sameAsJuicyPixels :: IO ()
unit_sameAsJuicyPixels = forM_ suite \(name, transparent) -> do
  bytes <- B.readFile (suiteImage name)
  decoded <- decodePng options bytes
  let reference = either error id $ JP.decodePng bytes
      expected
        | transparent = ImageRGBA8 (convertRGBA8 reference)
        | otherwise = ImageRGB8 (convertRGB8 reference)
  assertBool name $ fmap (first samples) decoded == Right (samples expected, Nothing)

unit_sameOnEveryPlatform :: IO ()
unit_sameOnEveryPlatform = do
  images <- mapM (\(name, _) -> B.readFile (suiteImage name) >>= decodePng options >>= either assertFailure pure) suite
  foldl (V.foldl' fnv1a) fnvOffset (map (snd . samples . fst) images) @?= 512529522448376465

unit_encodeRoundTrip :: IO ()
unit_encodeRoundTrip = forM_ encodings \(size, filtering) -> do
  let image = gradient size
  decoded <- encodePng (EncodeOptions 9 filtering Nothing) image >>= either assertFailure (decodePng options)
  fmap (first samples) decoded @?= Right (("RGBA8", imageData image), Nothing)

unit_encodeSameOnEveryPlatform :: IO ()
unit_encodeSameOnEveryPlatform = do
  pngs <- mapM (\(size, filtering) -> encodePng (EncodeOptions 9 filtering Nothing) (gradient size) >>= either assertFailure pure) encodings
  foldl (B.foldl' fnv1a) fnvOffset pngs @?= 2357105111401705807

unit_encodeInvalid :: IO ()
unit_encodeInvalid = do
  encodePng (EncodeOptions 10 True Nothing) (gradient (2, 2)) >>= (@?= Left "invalid encode options")
  encodePng (EncodeOptions (-1) True Nothing) (gradient (2, 2)) >>= (@?= Left "invalid encode options")
  encodePng (EncodeOptions 9 True Nothing) (Image 0 0 V.empty) >>= assertBool "0x0 image encoded" . isLeft
  encodePng (EncodeOptions 9 True Nothing) (Image 2 2 (V.replicate 15 0)) >>= assertBool "short image data encoded" . isLeft
  encodePng (EncodeOptions 9 True (Just "")) (gradient (2, 2)) >>= (@?= Left "invalid chunk length")

unit_iccProfile :: IO ()
unit_iccProfile = do
  let profile = fst $ B.unfoldrN 1048576 (\b -> Just (b, b + 1)) (0 :: Word8)
      image = gradient (7, 5)
      pixels = idat (B.pack [0, 10, 20, 0, 30, 40])
  decodePng options (png [ihdr 2 2 8 0, iccp profile, pixels, iend]) >>= (@?= Right (Just profile)) . fmap snd
  encoded <- encodePng (EncodeOptions 9 True (Just profile)) image >>= either assertFailure pure
  assertBool "profile named ICC Profile" $ "iCCPICC Profile\0\0" `B.isInfixOf` encoded
  decodePng options encoded >>= (@?= Right (("RGBA8", imageData image), Just profile)) . fmap (first samples)
  decodePng options (png [ihdr 2 2 8 0, iccp (B.replicate (1048576 + 1) 0), pixels, iend]) >>= (@?= Left "reached chunk/cache limits") . fmap snd

unit_compressedTextLimit :: IO ()
unit_compressedTextLimit = do
  let pngWithTexts size = png $ [ihdr 2 2 8 0] <> replicate 1000 (invalidText size) <> [idat (B.pack [0, 10, 20, 0, 30, 40]), iend]
      invalidText size = ("zTXt", "Comment\0\0" <> flipLastByte (BL.toStrict $ Z.compress $ BL.replicate size 0))
      flipLastByte bytes = flipByte (B.length bytes - 1) bytes
  decodePng options (pngWithTexts 524288) >>= assertBool "PNG with 1000 invalid zTXt chunks not decoded" . isRight
  decodePng options (pngWithTexts (524288 + 1)) >>= (@?= Left "reached chunk/cache limits") . fmap snd

unit_generated :: IO ()
unit_generated = do
  decoded <- decodePng options $ png [ihdr 2 2 8 0, idat (B.pack [0, 10, 20, 0, 30, 40]), iend]
  fmap (samples . fst) decoded @?= Right ("RGB8", V.fromList [10, 10, 10, 20, 20, 20, 30, 30, 30, 40, 40, 40])

unit_malformed :: IO ()
unit_malformed = do
  valid <- B.readFile (suiteImage "basn2c08")
  let generated = png [ihdr 16 16 8 0, idat (B.replicate (16 * 17) 0), iend]
      (idat1, idat2) = B.splitAt 3 $ snd $ idat (B.replicate (16 * 17) 0)
      split = png [ihdr 16 16 8 0, ("IDAT", idat1), ("IDAT", idat2), iend]
      huge = png [ihdr 65537 65537 8 0, idat (B.replicate 2 0), iend]
      errors =
        [ (png [ihdr 2048 2048 8 0, idat (B.replicate 2049 0), iend], "IDAT stream too short")
        , (huge, "image width exceeds user limit")
        , (flipByte 32 generated, "invalid chunk checksum")
        , (flipByte (B.length (png [ihdr 16 16 8 0, ("IDAT", idat1)]) - 1) split, "invalid chunk checksum")
        , (flipByte (B.length generated - 13) generated, "invalid chunk checksum")
        , (B.take (B.length generated - 12) generated, "end of stream")
        , (png [ihdr 16 16 8 0, iend], "invalid chunk position")
        ]
      truncated = [B.take n valid | n <- [0 .. B.length valid - 5]]
      iendCrcTruncated = [B.take n valid | n <- [B.length valid - 4 .. B.length valid - 1]]
  mapM (decodePng options) [generated, split] >>= assertBool "valid generated PNGs" . all isRight
  forM_ errors \(input, err) -> decodePng options input >>= (@?= Left err) . fmap (samples . fst)
  forM_ truncated \input -> decodePng options input >>= assertBool ("truncated to " <> show (B.length input)) . isLeft
  forM_ iendCrcTruncated \input -> decodePng options input >>= assertBool ("IEND CRC truncated to " <> show (B.length input)) . isRight
  readPngHeader huge >>= (@?= Left "image width exceeds user limit")

unit_memoryLimit :: IO ()
unit_memoryLimit = do
  let header = png [ihdr 16384 16384 16 6, idat (B.replicate 2 0), iend]
  decodePng (DecodeOptions maxBound 1 Right) header >>= (@?= Left "image is too large") . fmap (samples . fst)
  decodePng (DecodeOptions maxBound 0 Right) header >>= (@?= Left "invalid decode options") . fmap (samples . fst)
  decodePng (DecodeOptions 0 64 Right) header >>= (@?= Left "invalid decode options") . fmap (samples . fst)

unit_scaledMemoryLimit :: IO ()
unit_scaledMemoryLimit = forM_ limits \(input, size, accepted) -> do
  let decode memory = fmap (dimensions . fst) <$> decodePng (DecodeOptions maxBound memory (const $ Right size)) input
  decode accepted >>= (@?= Right size)
  decode (accepted - 1) >>= (@?= Left "image is too large")
  where
    limits =
      [ (blank, (2048, 2048), 16)
      , (blank, (1024, 1024), 4)
      , (blankInterlaced, (2048, 2048), 16)
      , (blankInterlaced, (1024, 1024), 20)
      ]
    blank = png [ihdr 2048 2048 8 6, idat (B.replicate (2048 * (1 + 2048 * 4)) 0), iend]
    blankInterlaced = png [interlaced (ihdr 2048 2048 8 6), idat (B.replicate (adam7Bytes 2048 2048 4) 0), iend]

unit_maxPixels :: IO ()
unit_maxPixels = do
  let input = png [ihdr 2048 1024 8 0, idat (B.replicate (1024 * (1 + 2048)) 0), iend]
      decode limit = fmap (dimensions . fst) <$> decodePng (DecodeOptions limit 64 (const $ Right (512, 256))) input
  decode (2048 * 1024) >>= (@?= Right (512, 256))
  decode (2048 * 1024 - 1) >>= (@?= Left "image is too large")

unit_outputSize :: IO ()
unit_outputSize = do
  bytes <- B.readFile (suiteImage "basn2c08")
  let decode size = fmap (dimensions . fst) <$> decodePng (DecodeOptions maxBound 64 size) bytes
  decode (const $ Left "image does not fit") >>= (@?= Left "image does not fit")
  forM_ [(0, 32), (32, 0), (33, 32), (32, 33)] \size -> decode (const $ Right size) >>= (@?= Left "invalid decode options")
  decode (\(w, h) -> Right (w `div` 2, h)) >>= (@?= Right (16, 32))

unit_scaledAsAreaAverage :: IO ()
unit_scaledAsAreaAverage = forM_ suite \(name, _) -> do
  bytes <- B.readFile (suiteImage name)
  Right (full, _) <- decodePng options bytes
  let (format, pixels) = samples full
      channels = if format == "RGBA8" then 4 else 3
  forM_ [(16, 16), (11, 7), (1, 1), (32, 5), (3, 31), (31, 32)] \size -> do
    Right (scaled, _) <- decodePng (DecodeOptions maxBound 64 (const $ Right size)) bytes
    assertBool (name <> " at " <> show size) $ samples scaled == (format, areaAverage channels (dimensions full) size pixels)

unit_scaledSolidColour :: IO ()
unit_scaledSolidColour = forM_ inputs \(input, size, pixel) -> do
  decoded <- decodePng (DecodeOptions maxBound 64 (const $ Right size)) input
  fmap (first samples) decoded @?= Right ((channelsOf pixel, V.concat (replicate (uncurry (*) size) (V.fromList pixel))), Nothing)
  where
    inputs =
      [ (solid 16384 16 [200, 100, 50, 128], (4096, 4), [200, 100, 50, 128])
      , (solid 16 16384 [255, 255, 255, 255], (4, 4096), [255, 255, 255, 255])
      , (solid 16384 16 [200, 100, 50], (4321, 5), [200, 100, 50])
      , (solid 8641 3 [255, 255, 255], (4320, 1), [255, 255, 255])
      ]
    solid width height pixel = png [ihdr width height 8 (if length pixel == 4 then 6 else 2), idat (B.concat $ replicate (fromIntegral height) $ B.pack $ 0 : concat (replicate (fromIntegral width) pixel)), iend]
    channelsOf pixel = if length pixel == 4 then "RGBA8" else "RGB8"

unit_scaledMalformed :: IO ()
unit_scaledMalformed = forM_ ["basn2c08", "basi2c08"] \name -> do
  valid <- B.readFile (suiteImage name)
  let decode = decodePng (DecodeOptions maxBound 64 (const $ Right (11, 7)))
  forM_ [B.take n valid | n <- [0 .. B.length valid - 5]] \input -> decode input >>= assertBool (name <> " truncated to " <> show (B.length input)) . isLeft
  forM_ [B.take n valid | n <- [B.length valid - 4 .. B.length valid]] \input -> decode input >>= assertBool (name <> " IEND CRC truncated to " <> show (B.length input)) . isRight

suite :: [(String, Bool)]
suite =
  [ ("basn0g08", False)
  , ("basn0g16", False)
  , ("basn4a08", True)
  , ("basn4a16", True)
  , ("basn2c08", False)
  , ("basn2c16", False)
  , ("basn6a08", True)
  , ("basn6a16", True)
  , ("basn3p08", False)
  , ("tbbn3p08", True)
  , ("tp1n3p08", True)
  , ("basi0g08", False)
  , ("basi2c08", False)
  , ("basi3p08", False)
  , ("basi4a08", True)
  , ("basi6a16", True)
  ]

encodings :: [((Int, Int), Bool)]
encodings = [(size, filtering) | size <- [(1, 1), (2, 1), (3, 3), (7, 5), (31, 17), (64, 48), (255, 3)], filtering <- [True, False]]

gradient :: (Int, Int) -> Image PixelRGBA8
gradient (w, h) = generateImage (\x y -> PixelRGBA8 (fromIntegral $ x * 7 + y * 3) (fromIntegral $ x * y) (fromIntegral $ x + y * 11) (fromIntegral $ x * 5 + y * 13)) w h

fnv1a :: Word64 -> Word8 -> Word64
fnv1a h b = (h `xor` fromIntegral b) * 1099511628211

fnvOffset :: Word64
fnvOffset = 14695981039346656037

suiteImage :: String -> FilePath
suiteImage name = "cbits/libspng/tests/images/" <> name <> ".png"

options :: DecodeOptions
options = DecodeOptions maxBound 64 Right

samples :: DynamicImage -> (String, V.Vector Word8)
samples = \case
  ImageRGB8 Image {imageData} -> ("RGB8", imageData)
  ImageRGBA8 Image {imageData} -> ("RGBA8", imageData)
  _ -> ("other", V.empty)

dimensions :: DynamicImage -> (Int, Int)
dimensions = dynamicMap \image -> (imageWidth image, imageHeight image)

areaAverage :: Int -> (Int, Int) -> (Int, Int) -> V.Vector Word8 -> V.Vector Word8
areaAverage channels (width, height) (width', height') pixels = V.fromList $ concat [pixel x' y' | y' <- [0 .. height' - 1], x' <- [0 .. width' - 1]]
  where
    pixel x' y' = map (fromInteger . rounded) $ take 3 [(colour c, if channels == 4 then weight else area) | c <- [0 ..]] <> [(weight, area) | channels == 4]
      where
        covered = [(x, y, wx * wy) | (x, wx) <- overlaps width width' x', (y, wy) <- overlaps height height' y']
        sample x y c = toInteger $ pixels V.! ((y * width + x) * channels + c)
        alpha x y = if channels == 4 then sample x y 3 else 1
        colour c = sum [sample x y c * alpha x y * w | (x, y, w) <- covered]
        weight = sum [alpha x y * w | (x, y, w) <- covered]
    area = toInteger $ width * height
    rounded (s, d) = if d == 0 then 0 else (s + d `div` 2) `div` d
    overlaps side side' i = [(x, toInteger overlap) | x <- [0 .. side - 1], let overlap = min ((x + 1) * side') ((i + 1) * side) - max (x * side') (i * side), overlap > 0]

interlaced :: (B.ByteString, B.ByteString) -> (B.ByteString, B.ByteString)
interlaced (name, body) = (name, B.init body <> "\1")

adam7Bytes :: Int -> Int -> Int -> Int
adam7Bytes width height pixelBytes = sum [h * (1 + w * pixelBytes) | (x0, y0, dx, dy) <- passes, let w = (width - x0 + dx - 1) `div` dx, let h = (height - y0 + dy - 1) `div` dy, w > 0, h > 0]
  where
    passes = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]

png :: [(B.ByteString, B.ByteString)] -> B.ByteString
png chunks = "\x89PNG\r\n\x1a\n" <> foldMap chunk chunks
  where
    chunk (name, body) = word32 (fromIntegral $ B.length body) <> name <> body <> word32 (crc32 $ name <> body)

ihdr :: Word32 -> Word32 -> Word8 -> Word8 -> (B.ByteString, B.ByteString)
ihdr width height depth colorType = ("IHDR", word32 width <> word32 height <> B.pack [depth, colorType, 0, 0, 0])

idat :: B.ByteString -> (B.ByteString, B.ByteString)
idat scanlines = ("IDAT", BL.toStrict $ Z.compress $ BL.fromStrict scanlines)

iccp :: B.ByteString -> (B.ByteString, B.ByteString)
iccp profile = ("iCCP", "Display P3\0\0" <> BL.toStrict (Z.compress $ BL.fromStrict profile))

iend :: (B.ByteString, B.ByteString)
iend = ("IEND", "")

word32 :: Word32 -> B.ByteString
word32 = BL.toStrict . BB.toLazyByteString . BB.word32BE

crc32 :: B.ByteString -> Word32
crc32 = complement . B.foldl' (\c b -> iterate step (c `xor` fromIntegral b) !! 8) 0xffffffff
  where
    step c = if testBit c 0 then 0xedb88320 `xor` shiftR c 1 else shiftR c 1

flipByte :: Int -> B.ByteString -> B.ByteString
flipByte i bytes = B.take i bytes <> B.singleton (complement $ B.index bytes i) <> B.drop (i + 1) bytes
