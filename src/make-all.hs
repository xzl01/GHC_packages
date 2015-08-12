{-# LANGUAGE GeneralizedNewtypeDeriving, DeriveDataTypeable, RecordWildCards #-}
import qualified Data.Map as M
import qualified Data.Set as S
import Control.Applicative hiding (many)
import qualified Data.Text as T
import Data.List
import Data.List.Split
import Data.Maybe
import Control.Monad
import Text.Read
import qualified System.Directory
import System.Directory.Extra (listFiles)
import System.Exit

import Options.Applicative hiding (many)
import qualified Options.Applicative as O
import Options.Applicative.Types (readerAsk)

import Development.Shake
import Development.Shake.Classes
import Development.Shake.FilePath

import Debian.Relation.Common
import Debian.Control.String
import Debian.Control.Policy

import Text.Parsec hiding (option, oneOf)
import Text.Parsec.String

-- Option parsing
data Conf = Conf
    { distribution :: String
    , excludedPackages :: [String]
    , targetDir :: FilePath
    , jobs :: Int
    , schrootName :: String
    , shakeVerbosity' :: Verbosity
    , keepGoing :: Bool
    , targets :: [String]
    }

confSpec :: O.Parser Conf
confSpec = Conf
 <$> strOption (
    long "distribution" <>
    metavar "DIST" <>
    help "Distribution to build for (passed to sbuild)" <>
    showDefault <>
    value "unstable"
    )
 <*> option parseCommaOrSpace (
    long "excluded-packages" <>
    metavar "PKG,PKG,..." <>
    help "comma or space separated list of source package names to ignore" <>
    value defaultExcludedPackages <>
    showDefaultWith (intercalate ", ")
    )
 <*> strOption (
    long "output" <>
    short 'o' <>
    metavar "DIR" <>
    help "output directory" <>
    showDefault <>
    value "lab"
    )
 <*> option parseNat (
    long "jobs" <>
    short 'j' <>
    metavar "INT" <>
    help "number of parallel jobs" <>
    showDefault <>
    value 1
    )
 <*> strOption  (
    long "chroot" <>
    short 'j' <>
    metavar "SCHROOT" <>
    help "name of the schroot to use" <>
    showDefault <>
    value "haskell"
    )
 <*> option readOption  (
    long "shake-verbosity" <>
    metavar "VERBOSITY" <>
    help "verbosity for shake (Silent, Quiet, Normal, Loud, Chatty or Diagnostic)" <>
    showDefault <>
    value Normal
    )
 <*> switch  (
    long "keep-going" <>
    help "keep going even if there are errors" <>
    showDefault
    )
  <*> O.many (argument str (metavar "TARGET..."))

parseCommaOrSpace:: ReadM [String]
parseCommaOrSpace = do
    s <- readerAsk
    return $ split (dropBlanks $ dropDelims $ oneOf ";, ") s

readOption :: Read a => ReadM a
readOption  = do
    s <- readerAsk
    case readMaybe s of
        Nothing -> fail $ "Cannot parse " ++ s
        Just n -> return n

parseNat :: ReadM Int
parseNat  = do
    s <- readerAsk
    case readMaybe s of
        Nothing -> fail "Not a number"
        Just n | n < 0 -> fail "I cannot do a negative number of jobs"
               | otherwise -> return n

-- dpkg-parsechangelog is slow, so here is a quick hack
-- TODO: Ensure this is not run unnecessarily often
versionOfSource :: String -> Action String
versionOfSource s = do
    let f = "p" </> s </> "debian" </> "changelog"
    need [f]
    ret <- liftIO $ parseFromFile p f
    case ret of
        Left e -> fail (show e)
        Right s -> return s
  where
    p = do
        many $ noneOf "("
        char '('
        v <- many1 $ noneOf ")"
        char ')'
        return (removeEpoch v)

ensureVersion :: String -> String -> Action ()
ensureVersion s v = do
    ex <- doesFileExist $ "p" </> s </> "debian" </> "changelog"
    unless ex $ do
        fail $ "I do not know about package " ++ s
    v' <- versionOfSource s
    when (v /= v') $ do
        fail $ "Cannot build " ++ s ++ " version " ++ v ++ ", as we have " ++ v' ++ "."

removeEpoch :: String -> String
removeEpoch s | ':' `elem` s = tail $ dropWhile (/= ':') s
              | otherwise    = s


changesFileName s v = s ++ "_" ++ v ++ "_amd64.changes"
logFileName s v = s ++ "_" ++ v ++ "_amd64.build"
sourceFileName s v = s ++ "_" ++ v ++ ".dsc"

binaryPackagesOfSource :: String -> Action [(String, String)]
binaryPackagesOfSource s = do
    let controlFile = "p" </> s </> "debian" </> "control"
    need [controlFile]
    ret <- liftIO $ parseDebianControlFromFile controlFile
    case ret of
        Left e -> fail (show e)
        Right dc -> forM (debianBinaryParagraphs dc) $  \bp -> do
            p <- maybe (fail "No Package field") (return . T.unpack) $ fieldValue "Package" bp
            a <- maybe (fail "No Arch field") (return . T.unpack) $ fieldValue "Architecture" bp
            return (p, if a == "all" then a else "amd64")

dependsOfDsc :: FilePath -> IO [String]
dependsOfDsc f = do
    ret <- parseControlFromFile f
    case ret of
        Left e -> fail (show e)
        Right (Control (p:_)) -> do
            deps <- case fieldValue "Build-Depends" (p:: Paragraph) of
                Nothing -> fail "no Build-Depends"
                Just depV -> return $ nub $ parseFlatRel depV
            ideps <- case fieldValue "Build-Depends-Indep" (p:: Paragraph) of
                Nothing -> return []
                Just depV -> return $ nub $ parseFlatRel depV
            return $ deps ++ ideps


-- Parsing package relations with flattening
-- (this could be faster than flatRels . parseRels)
parseFlatRel :: String -> [String]
parseFlatRel = flatRels . parseRels
  where
    flatRels :: Relations -> [String]
    flatRels = map (\(Rel (BinPkgName n) _ _) -> n) . join

    parseRels :: String -> Relations
    parseRels s = case parseRelations s of
      Left pe ->  error $ "Failed to parse relations " ++ (show pe)
      Right rel -> rel

fixupScript :: [String] -> String
fixupScript pkgs = unlines $
    [ "#!/bin/bash"
    -- I disable locking in the schroot. I have /var/cache/apt/archives bind-mounted
    -- via /etc/schroot/default/fstab, so with locking, I could not run
    -- multiple sbuilds at the same time
    , "echo 'Debug::NoLocking \"true\";' > /etc/apt/apt.conf.d/no-locking"
    ] ++ ignoreArchiveDepends pkgs

ignoreArchiveDepends :: [String] -> [String]
ignoreArchiveDepends [] = []
ignoreArchiveDepends pkgs =
    [ "#!/bin/bash"
    , "apt-get install dctrl-tools" -- Just in case it is not installed in the base schroot
    , "for f in /var/lib/apt/lists/*_Packages"
    , "do"
    , "grep-dctrl -v -F Package -X \\( " ++ disj ++ " \\) < \"$f\" > \"$f\".tmp"
    , "mv \"$f\".tmp \"$f\""
    , "done"
    ]
  where disj = intercalate " -o " pkgs


debFileNameToPackage filename =
    let [pkgname,_version,_] = splitOn "_" filename
    in pkgname

defaultExcludedPackages = words "ghc ghc-testsuite haskell-devscripts haskell98-report haskell-platform"
newtype GetExcludedSources = GetExcludedSources () deriving (Show,Typeable,Eq,Hashable,Binary,NFData)

newtype GetBuiltBy = GetBuiltBy String  deriving (Show,Typeable,Eq,Hashable,Binary,NFData)

main = execParser opts >>= run
  where
    opts = info (helper <*> confSpec)
        ( fullDesc
       <> progDesc "Rebuilds a set of packages"
       <> header "make-all - Rebuilds a set of packages" )

    run conf = shake (makeShakeOptions conf) (shakeMain conf)

makeShakeOptions :: Conf -> ShakeOptions
makeShakeOptions Conf{..} = shakeOptions
    { shakeFiles = targetDir </> ".shake"
    , shakeThreads = jobs
    , shakeVerbosity = shakeVerbosity'
    , shakeChange = ChangeModtimeAndDigestInput
    , shakeStaunch = keepGoing
    }

shakeMain conf@(Conf {..}) = do
    if null targets then want ["all"] else want targets

    getExcludedSources <- addOracle $ \GetExcludedSources{} ->
        return $ excludedPackages

    targetDir </> "cache/sources.txt" %> \out -> do
        sources <- getDirectoryDirs "p"
        excluded <- getExcludedSources (GetExcludedSources ())
        let sources' = filter (`notElem` excluded) sources
        writeFileChanged out (unlines sources')

    targetDir </> "cache/all-binaries.txt" %> \out -> do
        sources <- readFileLines $ targetDir </> "cache/sources.txt"
        binaries <- concat <$> mapM readFileLines
            [ targetDir </> "cache" </> "binaries" </> s <.> "txt" | s <- sources ]
        writeFileChanged out $ unlines binaries

    targetDir </> "cache/built-by.txt" %> \out -> do
        sources <- readFileLines $ targetDir </> "cache/sources.txt"
        builtBy <- liftM (sort . concat) $ forM sources $ \s -> do
            pkgs <- readFileLines $ targetDir </> "cache/binaries/" ++ s ++ ".txt"
            return [(pkg,s) | pkg <- pkgs]
        writeFileChanged out $ unlines [ unwords [pkg,s] | (pkg,s) <- builtBy ]

    builtByMap <- newCache $ \() -> do
        builtBy <- readFileLines $ targetDir </> "cache/built-by.txt"
        return $ M.fromList [ (p,s) | [p,s] <- words <$> builtBy ]

    getBuiltBy <- addOracle $ \(GetBuiltBy bin) -> do
        map <- builtByMap ()
        return $ M.lookup bin map

    let builtBy :: String -> Action (Maybe String)
        builtBy = getBuiltBy . GetBuiltBy

    targetDir </> "cache/all-changes-files.txt" %> \out -> do
        sources <- readFileLines $ targetDir </> "cache/sources.txt"
        versioned <- forM sources $ \s -> do
            v <- versionOfSource s
            return (s,v)
        writeFileChanged out $ unlines $ map (uncurry changesFileName) versioned

    targetDir </> "cache/binaries/*.txt" %> \out -> do
        let s = dropExtension $ takeFileName $ out
        pkgs <- binaryPackagesOfSource s
        v <- versionOfSource s

        writeFileChanged out $ unlines [ p ++ "_" ++ v ++ "_" ++ a ++ ".deb" | (p,a) <- pkgs]

    "all" ~> do
        changesFiles <- readFileLines $ targetDir </> "cache/all-changes-files.txt"
        need [ targetDir </>  l | l <- changesFiles]

    -- Binary packages depend on the corresponding changes file log
    targetDir </> "*.deb" %> \out -> do
        let filename = takeFileName out
        let [pkgname,version,_] = splitOn "_" filename
        sourceMB <- builtBy pkgname
        case sourceMB of
            Nothing -> fail $ "Binary " ++ show pkgname ++ " not built by us."
            Just source -> need [targetDir </> changesFileName source version]

    -- Changes files depend on the corresponding log file
    targetDir </> "*.changes" %> \out -> do
        let filename = takeFileName out
        let [source,version,_] = splitOn "_" filename
        need [targetDir </> logFileName source version]

    -- Build log depends on the corresponding source, and the dependencies
    targetDir </> "*.build" %> \out -> do
        let filename = takeFileName out
        let [source,version,_] = splitOn "_" filename
        let changes = changesFileName source version

        ensureVersion source version

        -- To build something, we need the source
        let dsc = sourceFileName source version
        need [targetDir </> dsc]

        -- This ensures all dependencies are up-to-date
        deps <- liftIO $ dependsOfDsc $ targetDir </> dsc
        depSources <- catMaybes <$> mapM builtBy deps
        depChanges <- forM depSources $ \s -> do
            v <- versionOfSource s
            return $ targetDir </> changesFileName s v

        -- For the sake of packages like alex, uuagc etc, we exclude ourselves
        -- from this, thus allowing the use of the binary from the archive to
        -- bootstrap.
        need $ filter (/= targetDir </> changesFileName source version) depChanges

        -- What files do we have built locally?
        -- Make sure the build uses only them
        expectedDeps <- S.fromList <$> readFileLines (targetDir </> "cache" </> "all-binaries.txt")
        localDebs <-
            filter (`S.member` expectedDeps) .
            map (makeRelative targetDir) <$>
            liftIO (listFiles targetDir)
        let localDepPkgs = map debFileNameToPackage localDebs

        withTempDir $ \tmpdir -> do
            -- Now monkey-patch dependencies out of the package lists
            let fixup = tmpdir </> "fixup.sh"
            liftIO $ writeFile fixup  $ fixupScript localDepPkgs

            -- Run sbuild
            Exit c <- cmd (Cwd targetDir) (EchoStdout False)
                ["sbuild", "-c", schrootName,"-A","--no-apt-update","--dist", distribution, "--chroot-setup-commands=bash "++fixup, dsc] ["--extra-package="++d | d <- localDebs ]
            unless (c == ExitSuccess) $ do
                putNormal $ "Failed to build " ++ source ++ "_" ++ version
                ex <- liftIO $ System.Directory.doesFileExist out
                putNormal $ "See " ++ out ++ " for details."

            -- Add the sources to the changes file. We do not simply pass
            -- "-s" to sbuild, as it would make sbuild re-create and override the .dsc file
            -- which confuses the build system.
            unit $ cmd "changestool" (targetDir </> changes) "adddsc" (targetDir </> dsc)


    -- Build log depends on the corresponding source, and the dependencies
    targetDir </> "*.dsc" %> \out -> do
        let filename = dropExtension $ takeFileName out
        let [source,version] = splitOn "_" filename
        ensureVersion source version
        sourceFiles <- getDirectoryFiles ("p" </> source) ["debian//*"]
        need [ "p" </> source </> f | f <- sourceFiles]
        unit $ cmd  (EchoStdout False) "./debian2dsc.sh" "-o" targetDir ("p" </> source </> "debian")


