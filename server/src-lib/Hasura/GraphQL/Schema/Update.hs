{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE TemplateHaskell #-}

-- | This module provides common building blocks for composing Schema Parsers
-- used in the schema of Update Mutations.
module Hasura.GraphQL.Schema.Update
  ( UpdateOperator (..),
    updateOperator,
    buildUpdateOperators,
    presetColumns,
    setOp,
    incOp,
  )
where

import Data.Has (Has (getter))
import Data.HashMap.Strict.Extended qualified as HashMap
import Data.List.NonEmpty qualified as NE
import Data.Text.Casing (GQLNameIdentifier, fromAutogeneratedName)
import Data.Text.Extended ((<>>))
import Hasura.Base.ToErrorValue
import Hasura.GraphQL.Schema.Backend (BackendSchema (..), MonadBuildSchema, columnParser)
import Hasura.GraphQL.Schema.Common
import Hasura.GraphQL.Schema.Parser qualified as P
import Hasura.GraphQL.Schema.Table (getTableIdentifierName, tableUpdateColumns)
import Hasura.GraphQL.Schema.Typename
import Hasura.Prelude
import Hasura.RQL.IR.Value
import Hasura.RQL.Types.Backend (Backend (..))
import Hasura.RQL.Types.Column (ColumnInfo (..), isNumCol)
import Hasura.RQL.Types.Source
import Hasura.RQL.Types.SourceCustomization
import Hasura.RQL.Types.Table
import Language.GraphQL.Draft.Syntax (Description (..), Nullability (..), litName)

-- | @UpdateOperator b m n op@ represents one single update operator for a
-- backend @b@.
--
-- The type variable @op@ is the backend-specific data type that represents
-- update operators, typically in the form of a sum-type with an
-- @UnpreparedValue b@ in each constructor.
--
-- The @UpdateOperator b m n@ is a @Functor@. There exist building blocks of
-- common update operators (such as 'setOp', etc.) which have @op ~
-- UnpreparedValue b@. The Functor instance lets you wrap the generic update
-- operators in backend-specific tags.
data UpdateOperator b r m n op = UpdateOperator
  { updateOperatorApplicableColumn :: ColumnInfo b -> Bool,
    updateOperatorParser ::
      GQLNameIdentifier ->
      TableName b ->
      NonEmpty (ColumnInfo b) ->
      SchemaT r m (P.InputFieldsParser n (HashMap (Column b) op))
  }
  deriving (Functor)

-- | The top-level component for building update operators parsers.
--
-- * It implements the @preset@ functionality from Update Permissions (see
--   <https://hasura.io/docs/latest/graphql/core/auth/authorization/permission-rules.html#column-presets
--   Permissions user docs>). Use the 'presetColumns' function to extract those from the update permissions.
-- * It validates that that the update fields parsed are sound when taken as a
--   whole, i.e. that some changes are actually specified (either in the
--   mutation query text or in update preset columns) and that each column is
--   only used in one operator.
buildUpdateOperators ::
  forall b r m n op.
  MonadBuildSchema b r m n =>
  -- | Columns with @preset@ expressions
  (HashMap (Column b) op) ->
  -- | Update operators to include in the Schema
  [UpdateOperator b r m n op] ->
  TableInfo b ->
  SchemaT r m (P.InputFieldsParser n (HashMap (Column b) op))
buildUpdateOperators presetCols ops tableInfo = do
  parsers :: P.InputFieldsParser n [HashMap (Column b) op] <-
    sequenceA . catMaybes <$> traverse (runUpdateOperator tableInfo) ops
  pure $
    parsers
      `P.bindFields` ( \opExps -> do
                         let withPreset = presetCols : opExps
                         mergeDisjoint @b withPreset
                     )

-- | The columns that have 'preset' definitions applied to them. (see
-- <https://hasura.io/docs/latest/graphql/core/auth/authorization/permission-rules.html#column-presets
-- Permissions user docs>)
presetColumns :: UpdPermInfo b -> HashMap (Column b) (UnpreparedValue b)
presetColumns = fmap partialSQLExpToUnpreparedValue . upiSet

-- | Produce an InputFieldsParser from an UpdateOperator, but only if the operator
-- applies to the table (i.e., it admits a non-empty column set).
runUpdateOperator ::
  forall b r m n op.
  MonadBuildSchema b r m n =>
  TableInfo b ->
  UpdateOperator b r m n op ->
  SchemaT
    r
    m
    ( Maybe
        ( P.InputFieldsParser
            n
            (HashMap (Column b) op)
        )
    )
runUpdateOperator tableInfo UpdateOperator {..} = do
  let tableName = tableInfoName tableInfo
  tableGQLName <- getTableIdentifierName tableInfo
  roleName <- retrieve scRole
  let columns = tableUpdateColumns roleName tableInfo

  let applicableCols :: Maybe (NonEmpty (ColumnInfo b)) =
        nonEmpty . filter updateOperatorApplicableColumn $ columns

  (sequenceA :: Maybe (SchemaT r m a) -> SchemaT r m (Maybe a))
    (applicableCols <&> updateOperatorParser tableGQLName tableName)

-- | Merge the results of parsed update operators. Throws an error if the same
-- column has been specified in multiple operators.
mergeDisjoint ::
  forall b m t.
  (Backend b, P.MonadParse m) =>
  [HashMap (Column b) t] ->
  m (HashMap (Column b) t)
mergeDisjoint parsedResults = do
  let unioned = HashMap.unionsAll parsedResults
      duplicates = HashMap.keys $ HashMap.filter (not . null . NE.tail) unioned

  unless (null duplicates) $
    P.parseError
      ( "Column found in multiple operators: "
          <> toErrorValue duplicates
          <> "."
      )

  return $ HashMap.map NE.head unioned

-- | Construct a parser for a single update operator.
--
-- @updateOperator _ "op" fp MkOp ["col1","col2"]@ gives a parser that accepts
-- objects in the shape of:
--
-- > op: {
-- >   col1: "x",
-- >   col2: "y"
-- > }
--
-- And (morally) parses into values:
--
-- > HashMap.fromList [("col1", MkOp (fp "x")), ("col2", MkOp (fp "y"))]
updateOperator ::
  forall n r m b a.
  MonadBuildSchema b r m n =>
  GQLNameIdentifier ->
  GQLNameIdentifier ->
  GQLNameIdentifier ->
  (ColumnInfo b -> SchemaT r m (P.Parser 'P.Both n a)) ->
  NonEmpty (ColumnInfo b) ->
  Description ->
  Description ->
  SchemaT r m (P.InputFieldsParser n (HashMap (Column b) a))
updateOperator tableGQLName opName opFieldName mkParser columns opDesc objDesc = do
  sourceInfo :: SourceInfo b <- asks getter
  let customization = _siCustomization sourceInfo
      tCase = _rscNamingConvention customization
      mkTypename = runMkTypename $ _rscTypeNames customization
  fieldParsers :: NonEmpty (P.InputFieldsParser n (Maybe (Column b, a))) <-
    for columns \columnInfo -> do
      let fieldName = ciName columnInfo
          fieldDesc = ciDescription columnInfo
      fieldParser <- mkParser columnInfo
      pure $
        P.fieldOptional fieldName fieldDesc fieldParser
          `mapField` \value -> (ciColumn columnInfo, value)
  let objName = mkTypename $ applyTypeNameCaseIdentifier tCase $ mkTableOperatorInputTypeName tableGQLName opName
  pure $
    fmap (HashMap.fromList . (fold :: Maybe [(Column b, a)] -> [(Column b, a)])) $
      P.fieldOptional (applyFieldNameCaseIdentifier tCase opFieldName) (Just opDesc) $
        P.object objName (Just objDesc) $
          (catMaybes . toList) <$> sequenceA fieldParsers
{-# ANN updateOperator ("HLint: ignore Use tuple-section" :: String) #-}

setOp ::
  forall b n r m.
  MonadBuildSchema b r m n =>
  UpdateOperator b r m n (UnpreparedValue b)
setOp = UpdateOperator {..}
  where
    updateOperatorApplicableColumn = const True

    updateOperatorParser tableGQLName tableName columns = do
      let typedParser columnInfo =
            fmap mkParameter
              <$> columnParser
                (ciType columnInfo)
                (Nullability $ ciIsNullable columnInfo)

      updateOperator
        tableGQLName
        (fromAutogeneratedName $$(litName "set"))
        (fromAutogeneratedName $$(litName "_set"))
        typedParser
        columns
        "sets the columns of the filtered rows to the given values"
        (Description $ "input type for updating data in table " <>> tableName)

incOp ::
  forall b m n r.
  MonadBuildSchema b r m n =>
  UpdateOperator b r m n (UnpreparedValue b)
incOp = UpdateOperator {..}
  where
    updateOperatorApplicableColumn = isNumCol

    updateOperatorParser tableGQLName tableName columns = do
      let typedParser columnInfo =
            fmap mkParameter
              <$> columnParser
                (ciType columnInfo)
                (Nullability $ ciIsNullable columnInfo)

      updateOperator
        tableGQLName
        (fromAutogeneratedName $$(litName "inc"))
        (fromAutogeneratedName $$(litName "_inc"))
        typedParser
        columns
        "increments the numeric columns with given value of the filtered values"
        (Description $ "input type for incrementing numeric columns in table " <>> tableName)
