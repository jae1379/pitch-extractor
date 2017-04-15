module PitchExtractor where

import Data.List
import Data.Text as Text     (pack, unpack, replace, head, Text)
import qualified Control.Foldl as F
import qualified Turtle as T
import Prelude hiding        (FilePath, head)
import Filesystem.Path.CurrentOS as Path
import Data.Monoid           ((<>))
import Control.Monad         (unless)
import Control.Concurrent

import Yin                   (extractPitchTo)
import YouTube               (searchYoutube, download)
import Util.Media            (convertToMp4, normalizeVidsIfPresent)
import Util.Misc             (toTxt, exec, dropDotFiles, mkdirDestructive, successData, uniqPathName)
import Types


runPitchExtractor :: IO ()
runPitchExtractor = do
  args <- T.arguments
  currentDir <- T.pwd
  -------- File system setup --------
  let searchQuery     = args !! 0
      maxTotalResults = args !! 1
      searchQueryName = T.fromText (replace " " "_" searchQuery)
      outputBase      = currentDir </> "vid-output"

  outputDir <- uniqPathName (outputBase </> searchQueryName)
  let
      outputName   = T.basename outputDir
      tempPrefix   = ".temp--" :: Text
      tempBase     = currentDir </> T.fromText (tempPrefix <> (toTxt outputName))
      tempDir      =   tempBase </> "temp-wav"
      sourceDir    =   tempBase </> "vid-source-download"
      sourceMp4Dir =   tempBase </> "vid-source-mp4"


  T.echo "files system setup..."
  baseAlreadyExists <- T.testdir outputBase
  unless baseAlreadyExists (T.mkdir outputBase)

  mkdirDestructive outputDir
  mkdirDestructive tempBase
  mkdirDestructive tempDir
  mkdirDestructive sourceDir
  mkdirDestructive sourceMp4Dir


  T.view $ T.inshell "which youtube-dl" T.empty
  T.view $ T.inshell "which ffmpeg" T.empty
  T.view $ T.inshell "which python" T.empty
  T.view $ T.inshell "which ffmpeg-normalize" T.empty


  -------- Get video ids --------
  T.echo "\nlooking for vids..."
  videoIds <- searchYoutube searchQuery maxTotalResults

  let lessHugeThing :: VideoId -> IO ()
      lessHugeThing = hugeThing outputDir sourceDir sourceMp4Dir tempDir

      -------- Download --------
      produce :: Chan (Maybe VideoId) -> VideoId -> IO ()
      produce ch videoId = do
        T.echo $ "  downloading: " <> (fromId videoId)
        dldVid <- download sourceDir videoId
        case dldVid of
          (T.ExitFailure _, err)  -> T.echo $ "Download error: " <> (fromId videoId)
          (T.ExitSuccess, stdout) -> writeChan ch (Just videoId)

      -------- Process --------
      consume :: Chan (Maybe VideoId) -> IO Text
      consume ch = do
        maybeStr <- readChan ch
        case maybeStr of
          Just videoId -> do
            T.echo $ "  processing: " <> (fromId videoId)
            lessHugeThing videoId
            consume ch
          Nothing -> return "Done."

  mapM_ print videoIds

  chan <- newChan
  p <- forkJoin $ mapM_ (produce chan) videoIds >>
                  writeChan chan Nothing
  c <- forkJoin $ consume chan
  takeMVar c >>= T.echo

  -------- Normalize --------
  T.echo "normalizing..."
  normalizeVidsIfPresent outputDir

  -------- Cleanup --------
  T.echo "cleanup..."
  T.rmtree tempBase

  T.echo $ "Successful videos extracted to: " <> (toTxt outputDir)


-- todo: make this a record
hugeThing :: T.FilePath ->
             T.FilePath ->
             T.FilePath ->
             T.FilePath ->
             VideoId -> IO ()
hugeThing outputDir sourceDir sourceMp4Dir tempDir videoId = do
  -------- Convert source to 44.1k mp4 --------
  srcPath <- T.fold (T.find (T.has $ T.text (fromId videoId)) sourceDir) F.head
  case srcPath of
    Nothing -> T.echo $ "Video file not found: " <> (fromId videoId)
    Just path -> do
      let sourceDirFiles   = [T.filename path]
          sourcePathsOrig  = map (sourceDir </>) sourceDirFiles
          sourcePathsMp4   = map (\x -> sourceMp4Dir </> x `replaceExtension` "mp4") sourceDirFiles
          sourcePathsInOut = zip sourcePathsOrig sourcePathsMp4

      mp4ConversionOutputs <- mapM convertToMp4 sourcePathsInOut

      let successfulMp4Paths = successData mp4ConversionOutputs :: [T.FilePath]

      -------- Pitch extraction from source-mp4 --------
      mapM_ (extractPitchTo outputDir tempDir) successfulMp4Paths



forkJoin :: IO a -> IO (MVar a)
forkJoin task = do
  mv <- newEmptyMVar
  forkIO (task >>= putMVar mv)
  return mv
