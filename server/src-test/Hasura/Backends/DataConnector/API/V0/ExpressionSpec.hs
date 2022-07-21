{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE QuasiQuotes #-}

module Hasura.Backends.DataConnector.API.V0.ExpressionSpec
  ( spec,
    genBinaryComparisonOperator,
    genBinaryArrayComparisonOperator,
    genUnaryComparisonOperator,
    genComparisonValue,
    genExpression,
  )
where

import Autodocodec.Extended
import Data.Aeson.QQ.Simple (aesonQQ)
import Hasura.Backends.DataConnector.API.V0
import Hasura.Backends.DataConnector.API.V0.ColumnSpec (genColumnName)
import Hasura.Backends.DataConnector.API.V0.RelationshipsSpec (genRelationshipName)
import Hasura.Backends.DataConnector.API.V0.Scalar.ValueSpec (genValue)
import Hasura.Prelude
import Hedgehog
import Hedgehog.Gen qualified as Gen
import Hedgehog.Internal.Range
import Test.Aeson.Utils (jsonOpenApiProperties, testToFromJSONToSchema)
import Test.Autodocodec.Extended (genValueWrapper, genValueWrapper2, genValueWrapper3)
import Test.Hspec

spec :: Spec
spec = do
  describe "BinaryComparisonOperator" $ do
    describe "LessThan" $
      testToFromJSONToSchema LessThan [aesonQQ|"less_than"|]

    describe "LessThanOrEqual" $
      testToFromJSONToSchema LessThanOrEqual [aesonQQ|"less_than_or_equal"|]

    describe "GreaterThan" $
      testToFromJSONToSchema GreaterThan [aesonQQ|"greater_than"|]

    describe "GreaterThanOrEqual" $
      testToFromJSONToSchema GreaterThanOrEqual [aesonQQ|"greater_than_or_equal"|]

    describe "Equal" $
      testToFromJSONToSchema Equal [aesonQQ|"equal"|]

    describe "CustomBinaryComparisonOperator" $
      testToFromJSONToSchema (CustomBinaryComparisonOperator "foo") [aesonQQ|"foo"|]

    jsonOpenApiProperties genBinaryComparisonOperator

  describe "BinaryArrayComparisonOperator" $ do
    describe "In" $
      testToFromJSONToSchema In [aesonQQ|"in"|]

    describe "CustomBinaryArrayComparisonOperator" $
      testToFromJSONToSchema (CustomBinaryArrayComparisonOperator "foo") [aesonQQ|"foo"|]

    jsonOpenApiProperties genBinaryArrayComparisonOperator

  describe "UnaryComparisonOperator" $ do
    describe "IsNull" $
      testToFromJSONToSchema IsNull [aesonQQ|"is_null"|]

    describe "CustomUnaryComparisonOperator" $
      testToFromJSONToSchema (CustomUnaryComparisonOperator "foo") [aesonQQ|"foo"|]

    jsonOpenApiProperties genUnaryComparisonOperator

  describe "ComparisonColumn" $ do
    testToFromJSONToSchema
      (ComparisonColumn [RelationshipName "table1", RelationshipName "table2"] (ColumnName "column_name"))
      [aesonQQ|{"path": ["table1", "table2"], "name": "column_name"}|]

    jsonOpenApiProperties genComparisonColumn

  describe "ComparisonValue" $ do
    describe "AnotherColumn" $
      testToFromJSONToSchema
        (AnotherColumn $ ValueWrapper (ComparisonColumn [] (ColumnName "my_column_name")))
        [aesonQQ|{"type": "column", "column": {"path": [], "name": "my_column_name"}}|]
    describe "ScalarValue" $
      testToFromJSONToSchema
        (ScalarValue . ValueWrapper $ String "scalar value")
        [aesonQQ|{"type": "scalar", "value": "scalar value"}|]

    jsonOpenApiProperties genComparisonValue

  describe "Expression" $ do
    let comparisonColumn = ComparisonColumn [] (ColumnName "my_column_name")
    let scalarValue = ScalarValue . ValueWrapper $ String "scalar value"
    let scalarValues = [String "scalar value"]
    let unaryComparisonExpression = ApplyUnaryComparisonOperator $ ValueWrapper2 IsNull comparisonColumn

    describe "And" $ do
      testToFromJSONToSchema
        (And $ ValueWrapper [unaryComparisonExpression])
        [aesonQQ|
          {
            "type": "and",
            "expressions": [
              {
                "type": "unary_op",
                "operator": "is_null",
                "column": { "path": [], "name": "my_column_name" }
              }
            ]
          }
        |]

    describe "Or" $ do
      testToFromJSONToSchema
        (Or $ ValueWrapper [unaryComparisonExpression])
        [aesonQQ|
          {
            "type": "or",
            "expressions": [
              {
                "type": "unary_op",
                "operator": "is_null",
                "column": { "path": [], "name": "my_column_name" }
              }
            ]
          }
        |]

    describe "Not" $ do
      testToFromJSONToSchema
        (Not $ ValueWrapper unaryComparisonExpression)
        [aesonQQ|
          {
            "type": "not",
            "expression": {
              "type": "unary_op",
              "operator": "is_null",
              "column": { "path": [], "name": "my_column_name" }
            }
          }
        |]
    describe "BinaryComparisonOperator" $ do
      testToFromJSONToSchema
        (ApplyBinaryComparisonOperator $ ValueWrapper3 Equal comparisonColumn scalarValue)
        [aesonQQ|
          {
            "type": "binary_op",
            "operator": "equal",
            "column": { "path": [], "name": "my_column_name" },
            "value": {"type": "scalar", "value": "scalar value"}
          }
        |]

    describe "BinaryArrayComparisonOperator" $ do
      testToFromJSONToSchema
        (ApplyBinaryArrayComparisonOperator $ ValueWrapper3 In comparisonColumn scalarValues)
        [aesonQQ|
          {
            "type": "binary_arr_op",
            "operator": "in",
            "column": { "path": [], "name": "my_column_name" },
            "values": ["scalar value"]
          }
        |]

    describe "UnaryComparisonOperator" $ do
      testToFromJSONToSchema
        unaryComparisonExpression
        [aesonQQ|
          {
            "type": "unary_op",
            "operator": "is_null",
            "column": { "path": [], "name": "my_column_name" }
          }
        |]

    jsonOpenApiProperties genExpression

genBinaryComparisonOperator :: MonadGen m => m BinaryComparisonOperator
genBinaryComparisonOperator =
  Gen.choice
    [ Gen.element [LessThan, LessThanOrEqual, GreaterThan, GreaterThanOrEqual, Equal],
      CustomBinaryComparisonOperator <$> Gen.text (linear 0 5) Gen.unicode
    ]

genBinaryArrayComparisonOperator :: MonadGen m => m BinaryArrayComparisonOperator
genBinaryArrayComparisonOperator =
  Gen.choice
    [ pure In,
      CustomBinaryArrayComparisonOperator <$> Gen.text (linear 0 5) Gen.unicode
    ]

genUnaryComparisonOperator :: MonadGen m => m UnaryComparisonOperator
genUnaryComparisonOperator =
  Gen.choice
    [ pure IsNull,
      CustomUnaryComparisonOperator <$> Gen.text (linear 0 5) Gen.unicode
    ]

genComparisonColumn :: MonadGen m => m ComparisonColumn
genComparisonColumn =
  ComparisonColumn
    <$> Gen.list (linear 0 5) genRelationshipName
    <*> genColumnName

genComparisonValue :: MonadGen m => m ComparisonValue
genComparisonValue =
  Gen.choice
    [ AnotherColumn <$> genValueWrapper genComparisonColumn,
      ScalarValue <$> genValueWrapper genValue
    ]

genExpression :: MonadGen m => m Expression
genExpression =
  Gen.recursive
    Gen.choice
    [ ApplyBinaryComparisonOperator <$> genValueWrapper3 genBinaryComparisonOperator genComparisonColumn genComparisonValue,
      ApplyBinaryArrayComparisonOperator <$> genValueWrapper3 genBinaryArrayComparisonOperator genComparisonColumn (Gen.list (linear 0 1) genValue),
      ApplyUnaryComparisonOperator <$> genValueWrapper2 genUnaryComparisonOperator genComparisonColumn
    ]
    [ And <$> genValueWrapper genExpressions,
      Or <$> genValueWrapper genExpressions,
      Not <$> genValueWrapper genExpression
    ]
  where
    genExpressions = Gen.list (linear 0 1) genExpression
