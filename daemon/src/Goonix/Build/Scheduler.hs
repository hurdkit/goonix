{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE OverloadedStrings #-}
module Goonix.Build.Scheduler
  ( JobId
  , JobKind (..)
  , Event (..)
  , Action (..)
  , State (..)
  , Job (..)
  , Status (..)
  , initialState
  , addJob
  , addDependencyJobs
  , addDependencyJobsWithKinds
  , step
  ) where

import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import Control.Monad (foldM)

-- Pure per-request scheduling. Nothing here is shared between client
-- connections. Download slots default to the build slots, as in C++.
type JobId = ByteString

data JobKind = BuildJob | DownloadJob deriving (Eq, Ord, Show)
data Status = Waiting | Running | Succeeded | Failed | Blocked
  deriving (Eq, Ord, Show)

data Job = Job
  { dependencies :: ![JobId]
  , status :: !Status
  , kind :: !JobKind
  } deriving (Eq, Show)

data State = State
  { jobs :: !(Map.Map JobId Job)
  , slots :: !Int
  , downloadSlots :: !(Maybe Int)
  , keepGoing :: !Bool
  , jobOrder :: ![JobId]
  } deriving (Eq, Show)

data Event = Tick | Completed JobId | FailedEvent JobId | NeedsDependencies JobId [JobId]
  deriving (Eq, Show)

data Action = Start JobId | Finish JobId | Fail JobId | ReportFailure JobId
  deriving (Eq, Show)

initialState :: Int -> Maybe Int -> Bool -> State
initialState slots downloads keepGoing = State Map.empty (max 0 slots) (max 0 <$> downloads) keepGoing []

addJob :: JobId -> JobKind -> [JobId] -> State -> Either String State
addJob name kind required state
  | Map.member name (jobs state) = Right state { jobs = Map.adjust merge name (jobs state) }
  | name `elem` required = Left "self-dependent derivation job"
  | any (`Map.notMember` jobs state) required = Left "unknown dependency"
  | otherwise = Right state
      { jobs = Map.insert name (Job required Waiting kind) (jobs state)
      , jobOrder = jobOrder state ++ [name]
      }
  where
    merge job
      | status job == Waiting = job { dependencies = dependencies job ++ filter (`notElem` dependencies job) required }
      | otherwise = job

addDependencyJobs :: [JobId] -> State -> Either String State
addDependencyJobs = addDependencyJobsWithKinds . map (, BuildJob)

addDependencyJobsWithKinds :: [(JobId, JobKind)] -> State -> Either String State
addDependencyJobsWithKinds names state = foldM add state names
  where add current (name, kind) = addJob name kind [] current

step :: Event -> State -> (State, [Action])
step event state = schedule $ case event of
  Completed name -> update name Succeeded state
  FailedEvent name -> update name Failed state
  NeedsDependencies name required -> waitFor name required state
  Tick -> state
  where
    update name result current = case Map.lookup name (jobs current) of
      Just job | status job == Running -> current { jobs = Map.insert name job { status = result } (jobs current) }
      _ -> current
    waitFor name required current = case Map.lookup name (jobs current) of
      Just job | status job == Running ->
        current { jobs = Map.insert name job
          { status = Waiting, dependencies = dependencies job ++ filter (`notElem` dependencies job) required } (jobs current) }
      _ -> current

schedule :: State -> (State, [Action])
schedule state =
  let candidates = [name | name <- jobOrder state, Just job <- [Map.lookup name (jobs state)], status job == Waiting,
        all (succeeded state) (dependencies job)]
      (chosen, _) = choose state [] candidates
      state' = state { jobs = foldl (\js name -> Map.adjust (\job -> job { status = Running }) name js) (jobs state) chosen }
      failedDependents = [name | (name, job) <- Map.toList (jobs state'), status job == Waiting,
        any (failed state') (dependencies job)]
      state'' = state' { jobs = foldl (\js name -> Map.adjust (\job -> job { status = Blocked }) name js) (jobs state') failedDependents }
  in (state'', map Start chosen ++ map Fail failedDependents)
  where
    succeeded s name = maybe False ((== Succeeded) . status) (Map.lookup name (jobs s))
    failed s name = maybe False ((`elem` [Failed, Blocked]) . status) (Map.lookup name (jobs s))

    choose _ started [] = (reverse started, [])
    choose current started (name:rest)
      | fits current name = choose (start current name) (name:started) rest
      | otherwise = choose current started rest

    fits current name =
      let job = jobs current Map.! name
          builds = runningCount current BuildJob
          downloads = runningCount current DownloadJob
      in if separateDownloads current && kind job == DownloadJob
        then downloads < maybe 0 id (downloadSlots current)
        else builds + downloads < slots current

    start current name =
      let job = jobs current Map.! name
      in current { jobs = Map.insert name job { status = Running } (jobs current) }

    runningCount current wanted = Map.size $ Map.filter (\job -> status job == Running && kind job == wanted) (jobs current)
    separateDownloads current = downloadSlots current /= Nothing
