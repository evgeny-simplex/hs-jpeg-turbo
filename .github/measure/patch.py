import sys

REPLACEMENTS = [
    (
        "import GHC.Float.RealFracMethods (floorDoubleInt)\n",
        "import GHC.Float.RealFracMethods (floorDoubleInt)\n"
        "import System.Environment (lookupEnv)\n"
        "import System.IO.Unsafe (unsafePerformIO)\n",
    ),
    (
        "maxDecodeMemoryMB :: Int\n"
        "#if defined(mobileBuild)\n"
        "maxDecodeMemoryMB = 512\n"
        "#else\n"
        "maxDecodeMemoryMB = 1024\n"
        "#endif\n",
        "maxDecodeMemoryMB :: Int\n"
        "maxDecodeMemoryMB = unsafePerformIO $ maybe 1024 read <$> lookupEnv \"MAX_DECODE_MB\"\n"
        "{-# NOINLINE maxDecodeMemoryMB #-}\n"
        "\n"
        "sharpenKept :: Bool\n"
        "sharpenKept = unsafePerformIO $ maybe False (const True) <$> lookupEnv \"SHARPEN_KEPT\"\n"
        "{-# NOINLINE sharpenKept #-}\n",
    ),
    (
        "scaleRGB8 img size\n"
        "  | hasSize size img = img\n",
        "scaleRGB8 img size\n"
        "  | hasSize size img = if sharpenKept then img {imageData = sharpen 3 size $ imageData img} else img\n",
    ),
    (
        "    scale size\n"
        "      | hasSize size img = img\n",
        "    scale size\n"
        "      | hasSize size img = if sharpenKept then pixelMap unpremultiply $ premultiplied {imageData = sharpen 4 size $ imageData premultiplied} else img\n",
    ),
]

PROVISIONAL = (
    "      | \"\\x89PNG\\r\\n\\x1a\\n\" `B.isPrefixOf` s = ExceptT $ Spng.decodePng (Spng.DecodeOptions $ maxDecodeMemoryMB `div` 2) s\n",
    "      | \"\\x89PNG\\r\\n\\x1a\\n\" `B.isPrefixOf` s = ExceptT $ Spng.decodePng (Spng.DecodeOptions (2 ^ (28 :: Int)) (maxDecodeMemoryMB `div` 2) (\\(w, h) -> maybe imageDoesNotFit (Right . snd) $ displaySize w h)) s\n",
)

path, *options = sys.argv[1:]
if options == ["--provisional"]:
    REPLACEMENTS.append(PROVISIONAL)
with open(path) as f:
    source = f.read()
for old, new in REPLACEMENTS:
    count = source.count(old)
    if count != 1:
        sys.exit(f"{path}: {count} occurrences of {old!r}, 1 expected")
    source = source.replace(old, new)
with open(path, "w") as f:
    f.write(source)
print(f"{path}: {len(REPLACEMENTS)} replacements applied")
