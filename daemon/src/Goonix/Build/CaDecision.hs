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
          if decisionNormal input && all validChoice choices then CaDone
          -- Check/repair must still resolve and run the builder; its valid
          -- ordinary choice is not a completed reproducibility check.
          else if not (decisionNormal input) && all validChoice choices then CaBuild
          else if decisionInputsRealised input then CaBuild else CaSubstituteInputs
      | decisionNormal input && all validChoice choices = CaDone
      | any missingChoice choices = CaSubstituteOutputs
      | otherwise = CaBuild
