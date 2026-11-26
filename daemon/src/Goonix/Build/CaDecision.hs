{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The single CA goal decision, ported from nix/libstore/build-ca.cc.
--
-- prepareGoonixGoal and prepareResolvedBuild decide the action and the output
-- names together.  A choice which is not valid yet is a substitution candidate,
-- not permission to build at the placeholder.  The original derivation path
-- remains the choice key after inputs have been resolved.
module Goonix.Build.CaDecision
  ( CaDecisionInput (..)
  , CaOutputChoice (..)
  , CaGoalAction (..)
  , CaGoalDecision (..)
  , prepareCaGoal
  , waitsForExistingInputs
  ) where

import qualified Data.Map.Strict as Map

data CaOutputChoice = CaOutputChoice
  { choicePath :: !String
  , choiceValid :: !Bool
  , choiceSelected :: !Bool
  } deriving (Eq, Show)

data CaDecisionInput = CaDecisionInput
  { decisionNormal :: !Bool
  , decisionResolved :: !Bool
  , decisionTopGoal :: !Bool
  , decisionGraphRequested :: !Bool
  , decisionGraphAvailable :: !Bool
  , decisionInputsRealised :: !Bool
  , decisionSubstitutionSettled :: !Bool
  , decisionChoices :: !(Map.Map String CaOutputChoice)
  } deriving (Eq, Show)

data CaGoalAction = CaDone | CaGraph | CaSubstituteOutputs | CaSubstituteInputs | CaBuild | CaLocalBuild
  deriving (Eq, Show)

data CaGoalDecision = CaGoalDecision
  { decisionAction :: !CaGoalAction
  , decisionOutputs :: !(Map.Map String String)
  } deriving (Eq, Show)

-- | prepareGoonixGoal, with the graph decision made by goonixHaveDerivation
-- immediately before it.  A graph miss does not imply that a locally realised
-- output is absent.  Resolved content outputs use the selected path even when
-- it still needs fetching; only a later failed fetch restores the token.
-- 'decisionSubstitutionSettled' says that this goal has asked for its selected
-- outputs to be substituted and that request has settled (C++
-- goonixSubstitutionRequested); 'decisionInputsRealised' that its input goals
-- have settled.  For an unresolved derivation 'CaBuild' means: resolve, then
-- build unless the resolved derivation is already realised.
prepareCaGoal :: CaDecisionInput -> CaGoalDecision
prepareCaGoal input = CaGoalDecision action (Map.map choicePath (decisionChoices input))
  where
    choices = Map.elems (decisionChoices input)
    hasChoice choice = choiceSelected choice && not (null (choicePath choice))
    validChoice choice = hasChoice choice && choiceValid choice
    missingChoice choice = hasChoice choice && not (choiceValid choice)
    action
      | decisionNormal input && not (decisionResolved input)
          && not (decisionGraphRequested input)
          && decisionTopGoal input && decisionGraphAvailable input
          && not (any hasChoice choices) = CaGraph
      | decisionSubstitutionSettled input && decisionInputsRealised input
          && any missingChoice choices && not (decisionResolved input) = CaLocalBuild
      | decisionSubstitutionSettled input && any missingChoice choices
          && not (decisionResolved input) = CaSubstituteInputs
      | decisionNormal input && any missingChoice choices = CaSubstituteOutputs
      | decisionNormal input && not (decisionResolved input)
          && not (decisionGraphRequested input)
          && decisionTopGoal input && decisionGraphAvailable input
          && not (all validChoice choices) = CaGraph
      | not (decisionResolved input) =
          -- An unresolved goal is finished by its choices only when it asked
          -- for them to be substituted (goonixSelectedOutputsSubstituted).
          -- Valid choices alone do not finish it: prepareGoonixGoal sends
          -- every other unresolved goal to its inputs, in every mode, and the
          -- goal is done, or built for a check, only as the resolved
          -- derivation.  So an input whose output was collected is realised
          -- again when its dependent is requested, and resolving never meets
          -- an input that is not realised.
          if decisionNormal input && decisionSubstitutionSettled input
              && all validChoice choices then CaDone
          else if decisionInputsRealised input then CaBuild else CaSubstituteInputs
      | decisionNormal input && all validChoice choices = CaDone
      | any missingChoice choices = CaSubstituteOutputs
      | otherwise = CaBuild

-- | goonixHaveDerivation, after prepareGoonixGoal: once its graph lookup has
-- settled, an unresolved goal that is not already done waits for the input
-- goals that exist in its request before it acts on the decision.  An input
-- being built here may supersede the choice the graph named; the goal decides
-- again when those inputs have settled.  The arguments are: the graph lookup
-- of this goal has settled, the derivation is resolved, and the decision.
waitsForExistingInputs :: Bool -> Bool -> CaGoalAction -> Bool
waitsForExistingInputs graphSettled resolved action =
  graphSettled && not resolved && action /= CaDone
