{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Monad (forM_, unless)
import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Goonix.Build.Scheduler
import Goonix.Build.Runtime (JobSpec (..), Outcome (..), runScheduledShared)
import System.Timeout (timeout)

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
      (waiting, waitActions) = step (WaitForDependencies "top" ["input"]) started
  assert "lazy job starts" (starts == [Start "top"])
  assert "waiting releases slot" (running waiting == 0 && null waitActions)
  assert "dependency blocks continuation" (null (snd (step Tick waiting)))
  withDependencies <- either (error . ("add lazy dependency: " ++)) pure
    (addDependencyJobs ["input"] waiting)
  let (inputRunning, inputStarts) = step Tick withDependencies
  assert "new dependency starts" (inputStarts == [Start "input"])
  let (topWaiting, topStarts) = step (Completed "input") inputRunning
  assert "continuation starts only after dependency" (topStarts == [Start "top"])
  -- A graph is an auxiliary dependency, not the completion of its CA goal.
  -- Mirror Runtime: NeedsDependencies first, then add the graph job, Tick,
  -- Completed graph.  The original CA job must run again and only then finish.
  let graphPath = "ca.drv\0graph"
      graphInitial = either error id
        (addJob "ca.drv" BuildJob [] (initialState 1 Nothing True))
      (graphStarted, graphInitialActions) = step Tick graphInitial
      (graphWaiting, graphWaitActions) =
        step (NeedsDependencies "ca.drv" [graphPath]) graphStarted
  assert "graph CA initially starts" (graphInitialActions == [Start "ca.drv"])
  assert "graph CA waits" (running graphWaiting == 0 && null graphWaitActions)
  withGraph <- either (error . ("add graph dependency: " ++)) pure
    (addDependencyJobsWithKinds [(graphPath, GraphJob)] graphWaiting)
  let (graphRunning, graphStarts) = step Tick withGraph
  assert "graph runs without consuming the build slot" (graphStarts == [Start graphPath])
  let (graphResumed, graphResumeActions) = step (Completed graphPath) graphRunning
  assert "graph completion resumes the CA goal"
    (graphResumeActions == [Start "ca.drv"])
  let (graphFinished, graphFinishActions) = step (Completed "ca.drv") graphResumed
      unfinished = Map.filter (\job -> status job == Waiting || status job == Running)
        (jobs graphFinished)
  assert "completed CA leaves no unfinished graph jobs"
    (null graphFinishActions && Map.null unfinished)
  -- Even an auxiliary path equal to its requester must not make a self-cycle.
  let collisionInitial = either error id
        (addJob "same" BuildJob [] (initialState 1 Nothing True))
  let (collisionRunning, _) = step Tick collisionInitial
      (collisionWaiting, _) = step (NeedsDependencies "same" ["same"]) collisionRunning
  collision <- either (error . ("same-name graph dependency: " ++)) pure
    (addDependencyJobsWithKinds [("same", GraphJob)] collisionWaiting)
  assert "same-name graph dependency cannot be scheduled"
    (status (jobs collision Map.! "same") == Waiting &&
      dependencies (jobs collision Map.! "same") == ["same"])
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
  -- Drive the real event loop with fake jobs.  The CA job's first result
  -- requests the graph, the graph returns Done, and the resumed CA job must
  -- run and return Done.  Record the actual order at this boundary.
  calls <- newIORef []
  caCalls <- newIORef (0 :: Int)
  let discover name _wanted kind = pure JobSpec
        { jobId = name, jobWanted = Set.empty, jobKind = kind
        , jobRun = \_ _ -> do
            atomicModifyIORef' calls (\seen -> (seen ++ [name], ()))
            if kind == GraphJob
              then pure Done
              else do
                n <- atomicModifyIORef' caCalls (\n -> (n + 1, n))
                pure (if n == 0 then Need [(graphPath, Set.empty, GraphJob)] else Done)
        }
  initial <- discover "ca.drv" Set.empty BuildJob
  runtimeResult <- timeout 5000000
    (runScheduledShared Nothing 1 Nothing True discover [initial] (threadDelay 5000000))
  assert "graph runtime completes" (runtimeResult == Just ())
  callOrder <- readIORef calls
  caCount <- readIORef caCalls
  assert "graph runtime resumes its CA job"
    (callOrder == ["ca.drv", graphPath, "ca.drv"] && caCount == 2)
  -- After a graph miss, the input may already have succeeded.  The next
  -- Need names that Succeeded dependency and must resume the parent once,
  -- not leave an active job or spin in the event loop.
  missCalls <- newIORef []
  missParentCalls <- newIORef (0 :: Int)
  let missDiscover name _wanted kind = pure JobSpec
        { jobId = name, jobWanted = Set.empty, jobKind = kind
        , jobRun = \_ _ -> do
            atomicModifyIORef' missCalls (\seen -> (seen ++ [name], ()))
            case kind of
              GraphJob -> pure Done
              _ | name == "input.drv" -> pure Done
              _ -> do
                n <- atomicModifyIORef' missParentCalls (\n -> (n + 1, n))
                pure $ case n of
                  0 -> Need [(graphPath, Set.empty, GraphJob)]
                  1 -> Need [("input.drv", Set.singleton "out", BuildJob)]
                  _ -> Done
        }
  missInitial <- missDiscover "parent.drv" Set.empty BuildJob
  missResult <- timeout 1000000
    (runScheduledShared Nothing 1 Nothing True missDiscover [missInitial] (threadDelay 1000000))
  assert "graph miss followed by completed input completes" (missResult == Just ())
  missOrder <- readIORef missCalls
  missCount <- readIORef missParentCalls
  assert "graph miss resumes parent exactly twice before completion"
    (missOrder == ["parent.drv", graphPath, "parent.drv", "input.drv", "parent.drv"] && missCount == 3)
  -- The first pass discovers and completes the input.  After the graph miss,
  -- Need names that already-completed input; the parent must resume exactly
  -- once rather than restarting early and losing its dependency wait.
  completedCalls <- newIORef []
  completedParent <- newIORef (0 :: Int)
  let completedDiscover name _wanted kind = pure JobSpec
        { jobId = name, jobWanted = Set.empty, jobKind = kind
        , jobRun = \_ _ -> do
            atomicModifyIORef' completedCalls (\seen -> (seen ++ [name], ()))
            case (name, kind) of
              (_, GraphJob) -> pure Done
              (_, DownloadJob) -> pure Done
              ("input.drv", _) -> pure Done
              _ -> do
                n <- atomicModifyIORef' completedParent (\n -> (n + 1, n))
                pure $ case n of
                  0 -> Need [("input.drv", Set.empty, BuildJob), ("source", Set.empty, DownloadJob)]
                  1 -> Need [(graphPath, Set.empty, GraphJob)]
                  2 -> Need [("input.drv", Set.empty, BuildJob)]
                  _ -> Done
        }
  completedInitial <- completedDiscover "parent.drv" Set.empty BuildJob
  completedResult <- timeout 1000000
    (runScheduledShared Nothing 1 Nothing True completedDiscover [completedInitial] (threadDelay 1000000))
  assert "completed input is reusable after graph import" (completedResult == Just ())
  completedOrder <- readIORef completedCalls
  assert "post-graph input wait resumes the parent exactly once"
    (completedOrder == ["parent.drv", "input.drv", "source", "parent.drv", graphPath, "parent.drv", "parent.drv"])
  -- A graph wait releases the build slot.  The input's source closure is
  -- fetched before the held input builder starts, while the graph is still
  -- outstanding; this is the C++ addWaitee ordering, not a graph barrier.
  let ordered = either error id $ do
        withGraph <- addJob graphPath GraphJob [] (initialState 2 Nothing True)
        withInput <- addJob "input.drv" BuildJob [graphPath] withGraph
        addDependencyJobsWithKinds [("source", DownloadJob), ("target", DownloadJob)] withInput
      (orderedStart, orderedStarts) = step Tick ordered
  assert "input source closure starts before the input builder"
    (orderedStarts == [Start graphPath, Start "source", Start "target"])
  let (sourceDone, _) = step (Completed "source") orderedStart
      (targetDone, _) = step (Completed "target") sourceDone
      (graphDone, graphActions) = step (Completed graphPath) targetDone
  assert "held input starts only after source closure and graph"
    (graphActions == [Start "input.drv"])
  -- The join in the pure model: a dependency on a job that is already running
  -- starts nothing and leaves that job alone; its completion starts the
  -- dependent again.
  let joinInitial = either error id $ do
        withInput <- addJob "held-input.drv" BuildJob [] (initialState 2 Nothing True)
        addJob "dependent.drv" BuildJob [] withInput
      (joinRunning, joinStarts) = step Tick joinInitial
      (joinWaiting, joinActions) =
        step (NeedsDependencies "dependent.drv" ["held-input.drv"]) joinRunning
      (_, joinResumed) = step (Completed "held-input.drv") joinWaiting
  assert "the input and the dependent start together"
    (joinStarts == [Start "held-input.drv", Start "dependent.drv"])
  assert "joining a running input starts nothing"
    (null joinActions && status (jobs joinWaiting Map.! "held-input.drv") == Running
      && status (jobs joinWaiting Map.! "dependent.drv") == Waiting)
  assert "the settled input starts the dependent again"
    (joinResumed == [Start "dependent.drv"])
  -- After graph import, only an already-existing unresolved input is joined.
  -- Its completion re-enters the dependent so it revalidates its choice.  No
  -- job is created by this wait (C++ goonixHaveDerivation).  The input is
  -- really held: it ends only when the dependent has seen it pending.
  let holdGraph = "dependent.drv\0graph"
  heldCalls <- newIORef []
  heldParentCalls <- newIORef (0 :: Int)
  heldDiscoveries <- newIORef []
  heldRelease <- newEmptyMVar
  let heldDiscover name _wanted kind = do
       atomicModifyIORef' heldDiscoveries (\seen -> (seen ++ [name], ()))
       pure JobSpec
        { jobId = name, jobWanted = Set.empty, jobKind = kind
        , jobRun = \_ pendingInput -> do
            atomicModifyIORef' heldCalls (\seen -> (seen ++ [name], ()))
            case (name, kind) of
              (_, GraphJob) -> pure Done
              ("held-input.drv", BuildJob) -> do
                readMVar heldRelease
                pure Done
              ("dependent.drv", BuildJob) -> do
                n <- atomicModifyIORef' heldParentCalls (\n -> (n + 1, n))
                if n == 0
                  then pure (Need [(holdGraph, Set.empty, GraphJob)])
                  else do
                    held <- pendingInput "held-input.drv"
                    case n of
                      1 -> do
                        assert "dependent joins the already-running input" held
                        putMVar heldRelease ()
                        pure (Need [("held-input.drv", Set.empty, BuildJob)])
                      _ -> do
                        assert "settled input lets revalidation proceed" (not held)
                        pure Done
              _ -> error ("unexpected job discovery: " ++ show (name, kind))
        }
  heldInput <- heldDiscover "held-input.drv" Set.empty BuildJob
  heldInitial <- heldDiscover "dependent.drv" Set.empty BuildJob
  heldResult <- timeout 3000000
    (runScheduledShared Nothing 2 Nothing True heldDiscover [heldInput, heldInitial] (threadDelay 3000000))
  assert "held input wait completes after revalidation" (heldResult == Just ())
  heldOrder <- readIORef heldCalls
  heldJobs <- readIORef heldDiscoveries
  -- The input and the dependent start together, so only the dependent's own
  -- sequence is ordered: graph, the join, and the pass after the input.
  assert "the dependent decides again after the joined input"
    (filter (/= "held-input.drv") heldOrder == ["dependent.drv", holdGraph, "dependent.drv", "dependent.drv"])
  assert "the joined input runs once" (length (filter (== "held-input.drv") heldOrder) == 1)
  assert "the wait creates no job" (heldJobs == ["held-input.drv", "dependent.drv", holdGraph])
  -- The ordinary graph-sharing case has no input goal in this worker.  The
  -- imported choice is used directly; no absent input or download is created.
  let plainGraph = "plain.drv\0graph"
  plainCalls <- newIORef []
  plainParentCalls <- newIORef (0 :: Int)
  plainDiscoveries <- newIORef []
  let plainDiscover name _wanted kind = do
        atomicModifyIORef' plainDiscoveries (\seen -> (seen ++ [name], ()))
        pure JobSpec
          { jobId = name, jobWanted = Set.empty, jobKind = kind
          , jobRun = \_ pendingInput -> do
              atomicModifyIORef' plainCalls (\seen -> (seen ++ [name], ()))
              case (name, kind) of
                (_, GraphJob) -> pure Done
                ("plain.drv", BuildJob) -> do
                  n <- atomicModifyIORef' plainParentCalls (\n -> (n + 1, n))
                  if n == 0
                    then pure (Need [(plainGraph, Set.empty, GraphJob)])
                    else do
                      absent <- pendingInput "absent-input.drv"
                      assert "an absent input is not joined" (not absent)
                      pure Done
                _ -> error ("unexpected job: " ++ show (name, kind))
          }
  plainInitial <- plainDiscover "plain.drv" Set.empty BuildJob
  plainResult <- timeout 1000000
    (runScheduledShared Nothing 1 Nothing True plainDiscover [plainInitial] (threadDelay 1000000))
  assert "plain graph sharing completes without input work" (plainResult == Just ())
  plainOrder <- readIORef plainCalls
  plainJobs <- readIORef plainDiscoveries
  assert "plain sharing runs the graph then uses its answer"
    (plainOrder == ["plain.drv", plainGraph, "plain.drv"])
  assert "plain sharing discovers no input or download" (plainJobs == ["plain.drv", plainGraph])
  putStrLn "scheduler properties: PASS"
