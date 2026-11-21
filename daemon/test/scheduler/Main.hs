{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (forM_, unless)
import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import Goonix.Build.Scheduler

assert :: String -> Bool -> IO ()
assert name condition = unless condition (error ("scheduler property failed: " ++ name))

chain :: Int -> Bool -> State
chain slots keepGoing = foldl add (initialState slots Nothing keepGoing) [1 .. 5 :: Int]
  where
    add state n = either error id (addJob (label n) BuildJob (if n == 1 then [] else [label (n - 1)]) state)
    label n = fromIntegral n `seq` (if n == 1 then "one" else if n == 2 then "two" else if n == 3 then "three" else if n == 4 then "four" else "five")

running :: State -> Int
running state = Map.size (Map.filter ((== Running) . status) (jobs state))

main :: IO ()
main = do
  let initial = chain 1 True
      (one, actions1) = step Tick initial
  assert "one initial start" (actions1 == [Start "one"])
  assert "slot limit" (running one <= 1)
  let (two, actions2) = step (Completed "one") one
  assert "dependency released" (actions2 == [Start "two"])
  let (failed, actions3) = step (FailedEvent "two") two
      blocked = failed
  assert "failure blocks dependent" (status (jobs blocked Map.! "three") == Blocked)
  assert "failure is reported" (Fail "three" `elem` actions3)
  let independent = either error id (addJob "independent" BuildJob [] (initialState 1 Nothing True))
      (withoutSlots, noStart) = step Tick independent
  assert "job runs" (noStart == [Start "independent"])
  let (failedIndependent, _) = step (FailedEvent "independent") withoutSlots
      (stopped, _) = step Tick (failedIndependent { keepGoing = False })
  assert "failure reaches terminal state" (status (jobs stopped Map.! "independent") == Failed)
  forM_ [0 .. 3] $ \limit -> do
    let state = initialState limit Nothing True
    assert "nonnegative slots" (running state <= limit)
  let lazy = either error id (addJob "top" BuildJob [] (initialState 1 Nothing True))
      (started, starts) = step Tick lazy
      (waiting, waitActions) = step (NeedsDependencies "top" ["input"]) started
  assert "lazy job starts" (starts == [Start "top"])
  assert "waiting releases slot" (running waiting == 0 && null waitActions)
  assert "dependency blocks continuation" (null (snd (step Tick waiting)))
  withDependencies <- either (error . ("add lazy dependency: " ++)) pure
    (addDependencyJobs ["input"] waiting)
  let (inputRunning, inputStarts) = step Tick withDependencies
  assert "new dependency starts" (inputStarts == [Start "input"])
  let (topWaiting, topStarts) = step (Completed "input") inputRunning
  assert "continuation starts only after dependency" (topStarts == [Start "top"])
  let downloads = either error id $ do
        withBuild <- addJob "z-build" BuildJob [] (initialState 1 Nothing True)
        addJob "a-download" DownloadJob [] withBuild
      (_, defaultStarts) = step Tick downloads
  assert "default request order controls shared slot" (defaultStarts == [Start "z-build"])
  separate <- either (error . ("add separate jobs: " ++)) pure $ do
    withBuild <- addJob "z-build" BuildJob [] (initialState 1 (Just 1) True)
    addJob "a-download" DownloadJob [] withBuild
  let (_, separateStarts) = step Tick separate
  assert "separate download slot overlaps build" (separateStarts == [Start "z-build", Start "a-download"])
  merged <- either (error . ("merge shared job: " ++)) pure $
    addJob "build" BuildJob [] (initialState 1 (Just 1) True)
  let (mergedRunning, _) = step Tick merged
  mergedAgain <- either (error . ("merge running shared job: " ++)) pure $
    addJob "build" BuildJob [] mergedRunning
  let (_, mergedStarts) = step Tick mergedAgain
  assert "shared job does not start twice" (null mergedStarts)
  putStrLn "scheduler properties: PASS"
