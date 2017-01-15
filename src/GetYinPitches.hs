module GetYinPitches
  -- (_extractPitchTo)
  where

import Data.List
import qualified Turtle as T
import Prelude hiding (FilePath)
import Filesystem.Path.CurrentOS as Path
import Data.Monoid ((<>))
import TextShow
import Numeric (showFFloat)

import CalculatePitchLocation
-- import Utils.MediaConversion
import Utils.Misc (toTxt)


parseOutput x = T.match (T.decimal `T.sepBy` ",") x !! 0


_formatDouble :: Int -> Double -> T.Text
_formatDouble numOfDecimals floatNum = showt $ showFFloat (Just numOfDecimals) floatNum ""

_createWav :: T.FilePath -> T.FilePath -> T.Text
_createWav filePath outputPath =
  "ffmpeg -loglevel error "
  <> " -i " <> (toTxt filePath)
  <> " "    <> (toTxt outputPath)

_spliceFile :: T.FilePath -> T.Text -> T.Text -> T.FilePath -> T.Text
_spliceFile filePath startTime duration outputPath =
  "ffmpeg -loglevel error "
  <> " -ss " <> startTime
  <> " -i "  <> (toTxt filePath)
  <> " -t "  <> duration
  <> " "     <> (toTxt outputPath)

_createMonoAudio :: T.FilePath -> T.FilePath -> T.Text
_createMonoAudio filePath outputPath =
    "ffmpeg -loglevel error "
    <> " -i " <> (toTxt filePath)
    <> " -ar 44.1k -ac 1 " <> (toTxt outputPath)

pythonPath = "/usr/local/bin/python"


_getPitches_yin :: T.FilePath -> T.FilePath -> IO (Either T.Text [[Double]])
_getPitches_yin filePath tempPath = do
  let monoFilePath = tempPath `replaceExtension` ".wav"
      monoAudioCmd = _createMonoAudio filePath monoFilePath
      yinCmd       = ["yin_pitch.py", (toTxt monoFilePath)]

  cmdOutput <- T.shellStrict monoAudioCmd T.empty
  case cmdOutput of
    (T.ExitFailure n, err)  -> return (Left (err <> " (createMonoAudio)"))
    (T.ExitSuccess, stdout) -> do

                      yin_pitches <- T.procStrict pythonPath yinCmd T.empty
                      case yin_pitches of
                        (T.ExitFailure n, err)   -> return (Left (err <> " (yin_pitch.py)"))
                        (T.ExitSuccess, pitches) -> do

                                            let bins = groupByEq (parseOutput pitches)
                                            return (Right bins)



-- extractPitchTo :: FilePath -> FilePath -> FilePath -> FilePath -> IO ()
_extractPitchTo :: T.FilePath -> T.FilePath -> T.FilePath -> T.FilePath -> IO ()
_extractPitchTo outputDir outputWavDir tempDir filePath = do
  let fileName = filename filePath
      tempPath = tempDir </> fileName
      fNameTxt = toTxt fileName
      errMsg e = T.echo $ "× " <> fNameTxt <> " Error:\n  " <> e

  bins <- _getPitches_yin filePath tempPath
  case bins of
    Left yinErr -> errMsg yinErr
    Right bins -> do
        let segment     = longestPitchSeg bins
            startTime   = pitchStartTime bins
            duration    = computeTime segment
            noteName    = _pitchNoteNameMIDI segment
            outputName  = noteName <> "__" <> fNameTxt
            outputPath  = outputDir </> (Path.fromText outputName)
            wavFilePath = outputWavDir </> (Path.fromText outputName) `replaceExtension` ".wav"

        case startTime of
          Just time -> case (duration > 0.3) of
                True  -> do
                          let _time     = showt time
                              _duration = showt duration
                              _segment  = showt segment
                          spliceCmd <- T.shellStrict (_spliceFile filePath _time _duration outputPath) T.empty
                          case spliceCmd of
                            (T.ExitFailure n, err)  -> errMsg err
                            (T.ExitSuccess, stdout) -> do
                                                        crtWavCmd <- T.shellStrict (_createWav outputPath wavFilePath) T.empty
                                                        case crtWavCmd of
                                                          (T.ExitFailure n, err)  -> errMsg err
                                                          (T.ExitSuccess, stdout) -> do
                                                                                      T.echo $ "✔ " <> outputName
                                                                                      T.echo $ "     time: " <> _formatDouble 2 time
                                                                                      T.echo $ " duration: " <> _formatDouble 2 duration
                                                                                      T.echo $ "  segment: " <> _segment
                False -> do
                          T.echo $ "× " <> fNameTxt
                          T.echo   " skipping: duration too short"
          Nothing -> errMsg "longestBin not found"
