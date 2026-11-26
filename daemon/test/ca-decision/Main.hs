{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (forM_, unless)
import Goonix.Build.CaDecision
import qualified Data.Map.Strict as Map

assert :: String -> Bool -> IO ()
assert name condition = unless condition (error ("CA decision failed: " ++ name))

base :: CaDecisionInput
base = CaDecisionInput True False True False True True False
  (Map.fromList [("out", CaOutputChoice "" False False)])

choice :: String -> Bool -> Map.Map String CaOutputChoice
choice path valid = Map.singleton "out" (CaOutputChoice path valid True)
token :: Map.Map String CaOutputChoice
token = Map.singleton "out" (CaOutputChoice "token" False False)

main :: IO ()
main = do
  let cases =
        [ ("top-level missing output requests graph once", base, CaGraph)
        , ("already requested graph does not repeat", base { decisionGraphRequested = True, decisionInputsRealised = False }, CaSubstituteInputs)
        , ("discovered input does not request graph", base { decisionTopGoal = False, decisionInputsRealised = False }, CaSubstituteInputs)
        , ("unavailable graph uses ordinary inputs", base { decisionGraphAvailable = False, decisionInputsRealised = False }, CaSubstituteInputs)
        , ("empty cache list uses ordinary inputs", base { decisionGraphAvailable = False, decisionInputsRealised = False }, CaSubstituteInputs)
        , ("graph miss with realised inputs resolves", base { decisionGraphRequested = True, decisionInputsRealised = True }, CaBuild)
        , ("graph miss with pending inputs waits", base { decisionGraphRequested = True, decisionInputsRealised = False }, CaSubstituteInputs)
        , ("no-cache leaf resolves", base { decisionResolved = True, decisionGraphAvailable = False, decisionInputsRealised = False }, CaBuild)
        -- An unresolved goal is not finished by valid choices: it goes to its
        -- inputs, then resolves (build-ca.cc prepareGoonixGoal).  Only the
        -- goal that asked for its selected outputs is finished by them.
        , ("valid unresolved choice realises its inputs first",
            base { decisionInputsRealised = False, decisionChoices = choice "chosen" True }, CaSubstituteInputs)
        , ("valid unresolved choice of an input realises its inputs first",
            base { decisionTopGoal = False, decisionInputsRealised = False, decisionChoices = choice "chosen" True }, CaSubstituteInputs)
        , ("valid unresolved choice resolves once its inputs are realised", base { decisionChoices = choice "chosen" True }, CaBuild)
        , ("substituted selected outputs finish the unresolved goal",
            base { decisionInputsRealised = False, decisionSubstitutionSettled = True,
                   decisionChoices = choice "chosen" True }, CaDone)
        , ("check of unresolved valid choice realises its inputs first",
            base { decisionNormal = False, decisionInputsRealised = False, decisionChoices = choice "chosen" True }, CaSubstituteInputs)
        , ("check of unresolved valid choice is not finished by a substitution",
            base { decisionNormal = False, decisionInputsRealised = False, decisionSubstitutionSettled = True,
                   decisionChoices = choice "chosen" True }, CaSubstituteInputs)
        , ("check of unresolved valid choice resolves and builds", base { decisionNormal = False, decisionChoices = choice "chosen" True }, CaBuild)
        , ("missing chosen output is substituted", base { decisionChoices = choice "chosen" False }, CaSubstituteOutputs)
        , ("settled missing selected output falls back to local build",
            base { decisionChoices = choice "chosen" False, decisionSubstitutionSettled = True,
                   decisionInputsRealised = True }, CaLocalBuild)
        , ("valid resolved choice is done", base { decisionResolved = True, decisionChoices = choice "chosen" True }, CaDone)
        , ("missing resolved chosen output is substituted", base { decisionResolved = True, decisionChoices = choice "chosen" False }, CaSubstituteOutputs)
        , ("unselected resolved output builds", base { decisionResolved = True, decisionChoices = token }, CaBuild)
        , ("check of resolved output builds", base { decisionNormal = False, decisionResolved = True, decisionChoices = choice "chosen" True }, CaBuild)
        ]
  forM_ cases $ \(name, input, expected) ->
    assert name (decisionAction (prepareCaGoal input) == expected)
  let two = Map.fromList [("out", CaOutputChoice "one" True True), ("dev", CaOutputChoice "two" False True)]
      decision = prepareCaGoal base { decisionChoices = two }
  assert "one incomplete output selects substitution" (decisionAction decision == CaSubstituteOutputs)
  assert "selected output names survive preparation" (decisionOutputs decision == Map.map choicePath two)
  -- The wait for input goals that already exist: arguments are graph settled,
  -- derivation resolved, decision.
  let waits =
        [ ("imported choice waits for inputs being built here", True, False, CaSubstituteOutputs, True)
        , ("graph miss waits for inputs being built here", True, False, CaSubstituteInputs, True)
        , ("unresolved build waits for inputs being built here", True, False, CaBuild, True)
        , ("nothing is joined before the graph has settled", False, False, CaSubstituteOutputs, False)
        , ("a goal without a graph lookup joins nothing", False, False, CaSubstituteInputs, False)
        , ("a resolved derivation joins nothing", True, True, CaSubstituteOutputs, False)
        , ("a finished goal joins nothing", True, False, CaDone, False)
        ]
  forM_ waits $ \(name, settled, resolved, action, expected) ->
    assert name (waitsForExistingInputs settled resolved action == expected)
  putStrLn "CA decision table: PASS"
