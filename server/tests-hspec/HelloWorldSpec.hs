-- | A starting point feature test.
module HelloWorldSpec (spec) where

import Harness.Feature qualified as Feature
import Harness.State (State)
import Test.Hspec
import Prelude

--------------------------------------------------------------------------------
-- Preamble

spec :: SpecWith State
spec =
  Feature.feature
    Feature.Feature
      { Feature.backends = [],
        Feature.tests = tests
      }

--------------------------------------------------------------------------------
-- Tests

tests :: SpecWith State
tests = it "No-op" (const (shouldBe () ()))
