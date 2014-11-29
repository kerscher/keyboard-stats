{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}

-- | Generate keyboard typing statistics.

module Keyboard.Stats where

import           Control.Lens (view,over,set)
import           Control.Lens.TH (makeLenses)
import           Control.Monad
import           Control.Monad.Trans.Resource
import qualified Data.CSV.Conduit as CSV
import           Data.Conduit
import qualified Data.Conduit.Binary as CB
import qualified Data.Conduit.List as CL
import qualified Data.Conduit.Text as CT
import           Data.List
import           Data.Text (Text)
import           Data.Text.Read
import           Data.Time.Clock
import           Data.Time.Clock.POSIX
import           Lucid
import           System.Environment

-- | Keyboard event.
data Event
  = Press
  | Release
  deriving (Enum,Eq,Show)

-- | Processing state.
data State =
  State {_stateCount :: !Int
        ,_stateLastTs :: !(Maybe (NominalDiffTime,Event,Int))
        ,_stateClusters :: ![Cluster]
        ,_stateCluster :: !Cluster}
  deriving (Show)

data Cluster =
  Cluster {_clusterStart :: !UTCTime
          ,_clusterEnd :: !UTCTime
          ,_clusterAvgDelay :: !NominalDiffTime
          ,_clusterPresses :: !Int
          ,_clusterRecords :: ![(NominalDiffTime,Event,Int)]
          ,_clusterKeys :: ![Int]}
  deriving (Show)

$(makeLenses ''State)
$(makeLenses ''Cluster)

defaultCluster :: Cluster
defaultCluster = Cluster emptyUTCTime emptyUTCTime 0 0 [] []

emptyUTCTime :: UTCTime
emptyUTCTime = UTCTime (toEnum 0) 0

main :: IO ()
main =
  do fp:_ <- getArgs
     r <- fmap (finalize .
                flip push 0)
               (runResourceT
                  (CB.sourceFile fp $= CT.decodeUtf8 $=
                   CSV.intoCSV CSV.defCSVSettings $=
                   takeN 20000 $=
                   CL.mapMaybe parse $$
                   CL.fold process (State 0 Nothing [] defaultCluster)))
     forM_ (view stateClusters r)
           (\c -> putStrLn (showCluster c))
     renderToFile "/tmp/keyboard-stats.html"
                  (doctypehtml_ (return ()))
  where takeN = go
          where go 0 = return ()
                go n =
                  do m <- await
                     case m of
                       Just p ->
                         do yield p
                            go (n - 1)
                       Nothing -> return ()

finalize =
  over stateClusters
       (reverse .
        drop 1 .
        map (over clusterKeys reverse .
             over clusterRecords reverse))

showCluster cluster@(Cluster start end avgDelay presses records keys) =
  "Cluster: " ++
  "start: " ++ show start++ "(" ++ show (round (utcTimeToPOSIXSeconds start * 1000)) ++ ")"  ++ ", " ++
  "end: " ++ show end ++ "(" ++ show (round (utcTimeToPOSIXSeconds end * 1000)) ++ ")" ++ ", " ++
  "duration: " ++
  showNomDiff duration ++
  ", avg delay: " ++
  (showNomDiff avgDelay) ++
  ", keys pressed: " ++
  (show presses) ++
  ", wpm: " ++ show (wpm cluster) ++ "\n" ++
  " keys: " ++ join (map showKey keys)
  where duration = diffUTCTime end start

wpm (Cluster start end avgDelay presses records keys) =
  if duration > 0
     then round (((60 / toRational duration) *
                  fromIntegral presses) /
                 5)
     else 0
  where duration = diffUTCTime end start

showCluster' (Cluster start end avgDelay presses records keys) =
  "[" ++ intercalate "," [show (round (utcTimeToPOSIXSeconds start * 1000)),show wpm] ++ "],"
  where duration = diffUTCTime end start
        wpm = if duration > 0
                 then round (((60 / toRational duration) * fromIntegral presses) / 5)
                 else 0

parse :: [Text] -> Maybe (NominalDiffTime,Event,Int)
parse [timestamp,event,keycode :: Text] =
  Just (case do t <- decimal timestamp
                k <- decimal keycode
                return (t,k) of
          Right ((t,_),(k,_)) ->
            (fromRational (toRational (t :: Integer) / 1000)
            ,if event == "p"
                then Press
                else Release
            ,k)
          Left err -> error err)
parse [""]   = Nothing
parse r = error ("Bad row: " ++ show r)

process :: State -> (NominalDiffTime, Event, Int) -> State
process state record@(ts,event,_key) =
  recluster (over stateCount (+ eventToCount) (set stateLastTs (Just record) state))
  where eventToCount =
          case event of
            Press -> 1
            _ -> 0
        recluster s =
          case _stateLastTs state of
            Nothing -> s
            Just record'@(ts',_,_) ->
              let delay = ts - ts'
              in case event of
                   Press ->
                     if delay < 1
                        then over stateCluster (updateCluster delay record record') s
                        else push s ts
                   _ -> s

updateCluster :: NominalDiffTime
              -> (NominalDiffTime,Event,Int)
              -> (NominalDiffTime,Event,Int)
              -> Cluster
              -> Cluster
updateCluster delay record@(_,_,code) record'@(ts,_,_) c = updates c'
  where updates =
          over clusterKeys (code :) .
          over clusterPresses (+ 1) .
          over clusterAvgDelay
               (\avg ->
                  let cnt =
                        fromIntegral (_clusterPresses c' - 1)
                  in (delay + avg * cnt) /
                     (cnt + 1)) .
          over clusterRecords (record :) .
          over clusterRecords
               (\xs ->
                  if null xs
                     then [record']
                     else xs) .
          over clusterStart
               (\s ->
                  if s == emptyUTCTime
                     then posixSecondsToUTCTime ts
                     else s)
        c' = over clusterPresses (max 1) c

push :: State -> NominalDiffTime -> State
push s endt =
  if _clusterPresses (_stateCluster s) ==
     0
     then s
     else set stateCluster
               defaultCluster
               (over stateClusters
                     (addEnd (_stateCluster s) :)
                     s)
  where addEnd c =
          set clusterEnd (posixSecondsToUTCTime endt) c

showNomDiff :: NominalDiffTime -> String
showNomDiff i =
  if i < 1
     then show (round (fromRational (toRational i * 1000) :: Double)) ++
          "ms"
     else show i

showKey :: Int -> String
showKey i =
  case lookup i mapping of
    Nothing -> "\\" ++ show i
    Just s -> s

mapping :: [(Int, String)]
mapping =
  [(50,"{Left-shift}")
  ,(62,"{Shift}")
  ,(37,"{Left-ctrl}")
  ,(105,"{Ctrl}")
  ,(64,"{Left-alt}")
  ,(108,"{Alt}")
  ,(133,"{Super}")
  ,(24,"q")
  ,(25,"w")
  ,(26,"e")
  ,(27,"r")
  ,(28,"t")
  ,(29,"y")
  ,(30,"u")
  ,(31,"i")
  ,(32,"o")
  ,(33,"p")
  ,(34,"[")
  ,(35,"]")
  ,(51,"\\")
  ,(38,"a")
  ,(39,"s")
  ,(40,"d")
  ,(41,"f")
  ,(42,"g")
  ,(43,"h")
  ,(44,"j")
  ,(45,"k")
  ,(46,"l")
  ,(47,";")
  ,(48,"'")
  ,(36,"{Return}")
  ,(52,"z")
  ,(53,"x")
  ,(54,"c")
  ,(55,"v")
  ,(56,"b")
  ,(57,"n")
  ,(58,"m")
  ,(59,",")
  ,(60,".")
  ,(61,"/")
  ,(49,"`")
  ,(10,"1")
  ,(11,"2")
  ,(12,"3")
  ,(13,"4")
  ,(14,"5")
  ,(15,"6")
  ,(16,"7")
  ,(17,"8")
  ,(18,"9")
  ,(19,"0")
  ,(20,"-")
  ,(21,"+")
  ,(65," ")
  ,(90,"{Num-0}")
  ,(87,"{Num-1}")
  ,(88,"{Num-2}")
  ,(89,"{Num-3}")
  ,(83,"{Num-4}")
  ,(84,"{Num-5}")
  ,(85,"{Num-6}")
  ,(79,"{Num-7}")
  ,(80,"{Num-8}")
  ,(81,"{Num-9}")
  ,(106,"{Num-/}")
  ,(63,"{Num-*}")
  ,(82,"{Num--}")
  ,(86,"{Num-+}")
  ,(67,"{F1}")
  ,(68,"{F2}")
  ,(69,"{F3}")
  ,(70,"{F4}")
  ,(71,"{F5}")
  ,(72,"{F6}")
  ,(73,"{F7}")
  ,(74,"{F8}")
  ,(75,"{F9}")
  ,(76,"{F10}")
  ,(95,"{F11}")
  ,(96,"{F12}")
  ,(9,"{Esc}")
  ,(22,"{Backspace}")
  ,(77,"{Num Lock}")
  ,(107,"{Print Scr}")
  ,(118,"{Insert}")
  ,(119,"{Delete}")
  ,(110,"{Home}")
  ,(112,"{Pg Up}")
  ,(117,"{Pg Dn}")
  ,(115,"{End}")
  ,(111,"{Up}")
  ,(116,"{Down}")
  ,(113,"{Left}")
  ,(114,"{Right}")
  ,(135,"{Menu}")
  ,(23,"{Tab}")
  ,(66,"{Caps Lock}")]
