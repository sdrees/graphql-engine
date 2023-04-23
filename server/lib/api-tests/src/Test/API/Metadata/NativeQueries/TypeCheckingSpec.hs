{-# LANGUAGE AllowAmbiguousTypes #-}

-- | Check the typechecking validation of native query's logical models.
module Test.API.Metadata.NativeQueries.TypeCheckingSpec where

import Data.List.NonEmpty qualified as NE
import Harness.Backend.Citus qualified as Citus
import Harness.Backend.Cockroach qualified as Cockroach
import Harness.Backend.Postgres qualified as Postgres
import Harness.Exceptions (SomeException, catch)
import Harness.GraphqlEngine qualified as GraphqlEngine
import Harness.Quoter.Yaml (yaml)
import Harness.Schema qualified as Schema
import Harness.Test.BackendType qualified as BackendType
import Harness.Test.Fixture qualified as Fixture
import Harness.TestEnvironment (GlobalTestEnvironment, TestEnvironment, getBackendTypeConfig)
import Harness.Yaml (shouldAtLeastBe, shouldReturnYaml)
import Hasura.Prelude
import Test.Hspec (SpecWith, describe, it)
import Test.QuickCheck

featureFlagForNativeQueries :: String
featureFlagForNativeQueries = "HASURA_FF_NATIVE_QUERY_INTERFACE"

spec :: SpecWith GlobalTestEnvironment
spec = do
  Fixture.hgeWithEnv [(featureFlagForNativeQueries, "True")] do
    Fixture.run
      ( NE.fromList
          [ (Fixture.fixture $ Fixture.Backend Postgres.backendTypeMetadata)
              { Fixture.setupTeardown = \(testEnv, _) ->
                  [ Postgres.setupTablesAction schema testEnv
                  ]
              },
            (Fixture.fixture $ Fixture.Backend Citus.backendTypeMetadata)
              { Fixture.setupTeardown = \(testEnv, _) ->
                  [ Citus.setupTablesAction schema testEnv
                  ]
              }
          ]
      )
      (tests postgresDifferences)
    Fixture.run
      ( NE.fromList
          [ (Fixture.fixture $ Fixture.Backend Cockroach.backendTypeMetadata)
              { Fixture.setupTeardown = \(testEnv, _) ->
                  [ Cockroach.setupTablesAction schema testEnv
                  ]
              }
          ]
      )
      (tests cockroachDifferences)

-- ** Setup and teardown

logicalModel :: Text -> Schema.ScalarType
logicalModel txt =
  Schema.TCustomType
    Schema.defaultBackendScalarType
      { Schema.bstPostgres = Just txt,
        Schema.bstCitus = Just txt,
        Schema.bstCockroach = Just txt
      }

schema :: [Schema.Table]
schema =
  [ (Schema.table "stuff")
      { Schema.tableColumns =
          (\t -> Schema.column t (logicalModel t)) <$> types
      }
  ]
    <> fmap
      ( \t ->
          (Schema.table ("stuff_" <> t))
            { Schema.tableColumns =
                [Schema.column t (logicalModel t)]
            }
      )
      types

allTypesLogicalModel :: Schema.LogicalModel
allTypesLogicalModel =
  (Schema.logicalModel "stuff_type")
    { Schema.logicalModelColumns =
        (\t -> Schema.logicalModelScalar t (logicalModel t)) <$> types
    }

types :: [Text]
types =
  [ "int2",
    "smallint",
    "integer",
    "bigint",
    "int8",
    "real",
    "float8",
    "numeric",
    "bool",
    "char",
    "varchar",
    "text",
    "date",
    "timestamp",
    "timestamptz",
    "timetz",
    "json",
    "jsonb",
    "uuid"
  ]

-- ** Tests

tests :: BackendDifferences -> SpecWith TestEnvironment
tests BackendDifferences {..} = do
  describe "Validation succeeds tracking a native query" do
    it "for all supported types" $
      \testEnvironment -> do
        let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
            sourceName = BackendType.backendSourceName backendTypeMetadata

        let simpleQuery :: Text
            simpleQuery = "SELECT * FROM stuff"

        let nativeQuery :: Schema.NativeQuery
            nativeQuery =
              (Schema.nativeQuery "typed_model" simpleQuery "stuff_type")

        Schema.trackLogicalModel sourceName allTypesLogicalModel testEnvironment

        shouldReturnYaml
          testEnvironment
          ( GraphqlEngine.postMetadata
              testEnvironment
              (Schema.trackNativeQueryCommand sourceName backendTypeMetadata nativeQuery)
          )
          [yaml|
          message: success
        |]

  describe "Validation fails tracking a native query" do
    it "when there's a type mismatch" $ \testEnvironment ->
      withMaxSuccess maxSuccesses $
        forAll (generator isDifferentTypeThan) $ \DifferentTypes {..} -> do
          let backendTypeMetadata = fromMaybe (error "Unknown backend") $ getBackendTypeConfig testEnvironment
              sourceName = BackendType.backendSourceName backendTypeMetadata

          let wrongQuery :: Text
              wrongQuery = "SELECT " <> tableType <> " AS " <> customtypeType <> " FROM stuff_" <> tableType

          let nativeQuery :: Schema.NativeQuery
              nativeQuery =
                (Schema.nativeQuery ("typed_model_" <> customtypeType) wrongQuery ("stuff_type_" <> customtypeType))

          -- Possible cleanup after last test that may have tracked this logical model
          _ <- Schema.untrackNativeQuery sourceName nativeQuery testEnvironment `catch` \(_ :: SomeException) -> pure ()
          _ <- Schema.untrackLogicalModel sourceName (mkLogicalModel customtypeType) testEnvironment `catch` \(_ :: SomeException) -> pure ()
          Schema.trackLogicalModel sourceName (mkLogicalModel customtypeType) testEnvironment

          let message :: Text
              message =
                "Return column '"
                  <> customtypeType
                  <> "' has a type mismatch. The expected type is '"
                  <> logicalModelNameMapping customtypeType
                  <> "', but the actual type is '"
                  <> tableTypeNameMapping tableType
                  <> "'."
              expected =
                [yaml|
                    code: validation-failed
                    error: Failed to validate query
                    internal: *message
                |]

          actual <-
            GraphqlEngine.postMetadataWithStatus
              400
              testEnvironment
              (Schema.trackNativeQueryCommand sourceName backendTypeMetadata nativeQuery)
          actual `shouldAtLeastBe` expected

-- ** Utils

mkLogicalModel :: Text -> Schema.LogicalModel
mkLogicalModel typ =
  (Schema.logicalModel ("stuff_type_" <> typ))
    { Schema.logicalModelColumns =
        [Schema.logicalModelScalar typ (logicalModel typ)]
    }

-- | Match a column from a table type and the logical model.
data DifferentTypes = DifferentTypes {tableType :: Text, customtypeType :: Text}
  deriving (Show)

-- | Differences between different backends required for testing.
data BackendDifferences = BackendDifferences
  { maxSuccesses :: Int,
    isDifferentTypeThan :: Text -> Text -> Bool,
    logicalModelNameMapping :: Text -> Text,
    tableTypeNameMapping :: Text -> Text
  }

-- | Generator a pair of columns with a type mismatch.
--   One from the table, and another from the logical model.
generator :: (Text -> Text -> Bool) -> Gen DifferentTypes
generator isDifferentTypeThan =
  uncurry DifferentTypes
    <$> suchThat ((,) <$> elements types <*> elements types) (uncurry isDifferentTypeThan)

-- | Postgres parameters.
postgresDifferences :: BackendDifferences
postgresDifferences =
  BackendDifferences
    { maxSuccesses = 100,
      isDifferentTypeThan = isDifferentTypeThanPg,
      logicalModelNameMapping = tableTypeNameMapping postgresDifferences,
      tableTypeNameMapping = \case
        "bool" -> "boolean"
        "char" -> "bpchar"
        "int2" -> "smallint"
        "int8" -> "bigint"
        t -> t
    }

isDifferentTypeThanPg :: Text -> Text -> Bool
isDifferentTypeThanPg a b
  | a == b = False
  | ["int2", "smallint"] == sort [a, b] = False
  | ["bigint", "int8"] == sort [a, b] = False
  | otherwise = True

-- | Cockroach parameters.
cockroachDifferences :: BackendDifferences
cockroachDifferences =
  BackendDifferences
    { maxSuccesses = 30,
      isDifferentTypeThan = isDifferentTypeThanRoach,
      logicalModelNameMapping = \case
        "bool" -> "boolean"
        "char" -> "bpchar"
        "int2" -> "smallint"
        "int8" -> "bigint"
        t -> t,
      tableTypeNameMapping = \case
        "bool" -> "boolean"
        "char" -> "bpchar"
        "int2" -> "smallint"
        "integer" -> "bigint"
        "int8" -> "bigint"
        "json" -> "jsonb"
        t -> t
    }

isDifferentTypeThanRoach :: Text -> Text -> Bool
isDifferentTypeThanRoach a b
  | a == b = False
  | sort ["smallint", "int2"] == sort [a, b] = False
  | sort ["integer", "int8"] == sort [a, b] = False
  | sort ["bigint", "int8"] == sort [a, b] = False
  | sort ["bigint", "integer"] == sort [a, b] = False
  | sort ["json", "jsonb"] == sort [a, b] = False
  | otherwise = True
