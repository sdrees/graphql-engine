module Hasura.Backends.DataConnector.Plan.QueryPlan
  ( -- Main external interface
    mkQueryPlan,
    -- Internals reused by other plan modules
    translateAnnSimpleSelectToQueryRequest,
    translateAnnAggregateSelectToQueryRequest,
    translateAnnFields,
    reshapeSimpleSelectRows,
    reshapeTableAggregateFields,
    reshapeAnnFields,
  )
where

--------------------------------------------------------------------------------

import Data.Aeson qualified as J
import Data.Aeson.Encoding qualified as JE
import Data.Bifunctor (Bifunctor (bimap))
import Data.Has
import Data.HashMap.Strict qualified as HashMap
import Data.List.NonEmpty qualified as NE
import Data.Semigroup (Min (..))
import Data.Set qualified as Set
import Data.Text.Extended (toTxt)
import Hasura.Backends.DataConnector.API qualified as API
import Hasura.Backends.DataConnector.Adapter.Backend
import Hasura.Backends.DataConnector.Adapter.Types
import Hasura.Backends.DataConnector.Plan.Common
import Hasura.Base.Error
import Hasura.Function.Cache qualified as Function
import Hasura.Prelude
import Hasura.RQL.IR.BoolExp
import Hasura.RQL.IR.OrderBy
import Hasura.RQL.IR.Select
import Hasura.RQL.IR.Value
import Hasura.RQL.Types.BackendType
import Hasura.RQL.Types.Column
import Hasura.RQL.Types.Common
import Hasura.Session
import Language.GraphQL.Draft.Syntax qualified as G
import Witch qualified

--------------------------------------------------------------------------------

data FieldsAndAggregates = FieldsAndAggregates
  { _faaFields :: Maybe (HashMap FieldName API.Field),
    _faaAggregates :: Maybe (HashMap FieldName API.Aggregate)
  }
  deriving stock (Show, Eq)

instance Semigroup FieldsAndAggregates where
  left <> right =
    FieldsAndAggregates
      (_faaFields left <> _faaFields right)
      (_faaAggregates left <> _faaAggregates right)

instance Monoid FieldsAndAggregates where
  mempty = FieldsAndAggregates Nothing Nothing

--------------------------------------------------------------------------------

-- | Map a 'QueryDB 'DataConnector' term into a 'Plan'
mkQueryPlan ::
  forall m r.
  ( MonadError QErr m,
    MonadReader r m,
    Has API.ScalarTypesCapabilities r,
    Has SessionVariables r
  ) =>
  QueryDB 'DataConnector Void (UnpreparedValue 'DataConnector) ->
  m (Plan API.QueryRequest API.QueryResponse)
mkQueryPlan ir = do
  queryRequest <- translateQueryDB ir
  pure $ Plan queryRequest (reshapeResponseToQueryShape ir)
  where
    translateQueryDB ::
      QueryDB 'DataConnector Void (UnpreparedValue 'DataConnector) ->
      m API.QueryRequest
    translateQueryDB =
      \case
        QDBMultipleRows simpleSelect -> translateAnnSimpleSelectToQueryRequest simpleSelect
        QDBSingleRow simpleSelect -> translateAnnSimpleSelectToQueryRequest simpleSelect
        QDBAggregation aggregateSelect -> translateAnnAggregateSelectToQueryRequest aggregateSelect

translateAnnSimpleSelectToQueryRequest ::
  forall m r.
  ( MonadError QErr m,
    MonadReader r m,
    Has API.ScalarTypesCapabilities r,
    Has SessionVariables r
  ) =>
  AnnSimpleSelectG 'DataConnector Void (UnpreparedValue 'DataConnector) ->
  m API.QueryRequest
translateAnnSimpleSelectToQueryRequest simpleSelect =
  translateAnnSelectToQueryRequest (translateAnnFieldsWithNoAggregates noPrefix) simpleSelect

translateAnnAggregateSelectToQueryRequest ::
  forall m r.
  ( MonadError QErr m,
    MonadReader r m,
    Has API.ScalarTypesCapabilities r,
    Has SessionVariables r
  ) =>
  AnnAggregateSelectG 'DataConnector Void (UnpreparedValue 'DataConnector) ->
  m API.QueryRequest
translateAnnAggregateSelectToQueryRequest aggregateSelect =
  translateAnnSelectToQueryRequest translateTableAggregateFields aggregateSelect

translateAnnSelectToQueryRequest ::
  forall m r fieldType.
  ( MonadError QErr m,
    MonadReader r m,
    Has API.ScalarTypesCapabilities r,
    Has SessionVariables r
  ) =>
  ( forall state m2.
    ( MonadState state m2,
      Has TableRelationships state,
      Has RedactionExpressionState state,
      MonadError QErr m2,
      MonadReader r m2,
      Has API.ScalarTypesCapabilities r,
      Has SessionVariables r
    ) =>
    API.TargetName ->
    Fields (fieldType (UnpreparedValue 'DataConnector)) ->
    m2 FieldsAndAggregates
  ) ->
  AnnSelectG 'DataConnector fieldType (UnpreparedValue 'DataConnector) ->
  m API.QueryRequest
translateAnnSelectToQueryRequest translateFieldsAndAggregates selectG = do
  case _asnFrom selectG of
    FromIdentifier _ -> throw400 NotSupported "AnnSelectG: FromIdentifier not supported"
    FromNativeQuery {} -> throw400 NotSupported "AnnSelectG: FromNativeQuery not supported"
    FromStoredProcedure {} -> throw400 NotSupported "AnnSelectG: FromStoredProcedure not supported"
    FromTable tableName -> do
      (query, (TableRelationships tableRelationships, redactionExpressionState)) <-
        flip runStateT (mempty, RedactionExpressionState mempty) $ translateAnnSelect translateFieldsAndAggregates (API.TNTable (Witch.into tableName)) selectG
      let relationships = mkRelationships <$> HashMap.toList tableRelationships
      pure
        $ API.QRTable
          API.TableRequest
            { _trTable = Witch.into tableName,
              _trRelationships = Set.fromList relationships,
              _trRedactionExpressions = translateRedactionExpressions redactionExpressionState,
              _trQuery = query,
              _trForeach = Nothing
            }
    FromFunction fn@(FunctionName functionName) argsExp _dListM -> do
      args <- mkArgs argsExp fn
      (query, (redactionExpressionState, TableRelationships tableRelationships)) <-
        flip runStateT (RedactionExpressionState mempty, mempty) $ translateAnnSelect translateFieldsAndAggregates (API.TNFunction (Witch.into functionName)) selectG
      let relationships = mkRelationships <$> HashMap.toList tableRelationships
      pure
        $ API.QRFunction
          API.FunctionRequest
            { _frFunction = Witch.into functionName,
              _frRelationships = Set.fromList relationships,
              _frRedactionExpressions = translateRedactionExpressions redactionExpressionState,
              _frQuery = query,
              _frFunctionArguments = args
            }

mkRelationships :: (API.TargetName, (HashMap API.RelationshipName API.Relationship)) -> API.Relationships
mkRelationships (API.TNFunction functionName, relationships) = API.RFunction (API.FunctionRelationships functionName relationships)
mkRelationships (API.TNTable tableName, relationships) = API.RTable (API.TableRelationships tableName relationships)

mkArgs ::
  forall r m.
  ( MonadError QErr m,
    MonadReader r m,
    Has SessionVariables r
  ) =>
  Function.FunctionArgsExpG (ArgumentExp (UnpreparedValue 'DataConnector)) ->
  FunctionName ->
  m [API.FunctionArgument]
mkArgs (Function.FunctionArgsExp ps ns) functionName = do
  unless (null ps) $ throw400 NotSupported $ "Positional arguments not supported in function " <> toTxt functionName
  getNamed
  where
    getNamed = mapM mkArg (HashMap.toList ns)
    mkArg (n, input) = (API.NamedArgument n . API.ScalarArgumentValue) <$> getValue input

    getValue (AEInput x) = case x of
      UVLiteral _ -> throw400 NotSupported "Literal not supported in Data Connector function args."
      UVSessionVar _ _ -> throw400 NotSupported "SessionVar not supported in Data Connector function args."
      UVParameter _ (ColumnValue t v) -> pure (API.ScalarValue v (coerce (toTxt t)))
      UVSession -> do
        (sessionVariables :: SessionVariables) <- asks getter
        pure (API.ScalarValue (J.toJSON sessionVariables) (API.ScalarType "json"))

translateAnnSelect ::
  ( MonadState state m,
    Has TableRelationships state,
    Has RedactionExpressionState state,
    MonadError QErr m,
    MonadReader r m,
    Has API.ScalarTypesCapabilities r,
    Has SessionVariables r
  ) =>
  (API.TargetName -> Fields (fieldType (UnpreparedValue 'DataConnector)) -> m FieldsAndAggregates) ->
  API.TargetName ->
  AnnSelectG 'DataConnector fieldType (UnpreparedValue 'DataConnector) ->
  m API.Query
translateAnnSelect translateFieldsAndAggregates entityName selectG = do
  FieldsAndAggregates {..} <- translateFieldsAndAggregates entityName (_asnFields selectG)
  let whereClauseWithPermissions =
        case _saWhere (_asnArgs selectG) of
          Just expr -> BoolAnd [expr, _tpFilter (_asnPerm selectG)]
          Nothing -> _tpFilter (_asnPerm selectG)
  whereClause <- translateBoolExpToExpression entityName whereClauseWithPermissions
  orderBy <- traverse (translateOrderBy entityName) (_saOrderBy $ _asnArgs selectG)
  pure
    API.Query
      { _qFields = mapFieldNameHashMap <$> _faaFields,
        _qAggregates = mapFieldNameHashMap <$> _faaAggregates,
        _qAggregatesLimit = _saLimit (_asnArgs selectG) <* _faaAggregates, -- Only include the aggregates limit if we actually have aggregrates
        _qLimit =
          fmap getMin
            $ foldMap
              (fmap Min)
              [ _saLimit (_asnArgs selectG),
                _tpLimit (_asnPerm selectG)
              ],
        _qOffset = fmap fromIntegral (_saOffset (_asnArgs selectG)),
        _qWhere = whereClause,
        _qOrderBy = orderBy
      }

translateOrderBy ::
  ( MonadState state m,
    Has TableRelationships state,
    Has RedactionExpressionState state,
    MonadError QErr m,
    MonadReader r m,
    Has API.ScalarTypesCapabilities r,
    Has SessionVariables r
  ) =>
  API.TargetName ->
  NE.NonEmpty (AnnotatedOrderByItemG 'DataConnector (UnpreparedValue 'DataConnector)) ->
  m API.OrderBy
translateOrderBy sourceName orderByItems = do
  orderByElementsAndRelations <- for orderByItems \OrderByItemG {..} -> do
    let orderDirection = maybe API.Ascending Witch.from obiType
    translateOrderByElement sourceName orderDirection [] obiColumn
  relations <- mergeOrderByRelations $ snd <$> orderByElementsAndRelations
  pure
    API.OrderBy
      { _obRelations = relations,
        _obElements = fst <$> orderByElementsAndRelations
      }

translateOrderByElement ::
  ( MonadState state m,
    Has TableRelationships state,
    Has RedactionExpressionState state,
    MonadError QErr m,
    MonadReader r m,
    Has API.ScalarTypesCapabilities r,
    Has SessionVariables r
  ) =>
  API.TargetName ->
  API.OrderDirection ->
  [API.RelationshipName] ->
  AnnotatedOrderByElement 'DataConnector (UnpreparedValue 'DataConnector) ->
  m (API.OrderByElement, HashMap API.RelationshipName API.OrderByRelation)
translateOrderByElement sourceName orderDirection targetReversePath = \case
  AOCColumn ColumnInfo {..} redactionExp -> do
    redactionExpName <- recordRedactionExpression sourceName redactionExp
    pure
      ( API.OrderByElement
          { _obeTargetPath = reverse targetReversePath,
            _obeTarget = API.OrderByColumn (Witch.from ciColumn) redactionExpName,
            _obeOrderDirection = orderDirection
          },
        mempty
      )
  AOCObjectRelation relationshipInfo filterExp orderByElement -> do
    (relationshipName, API.Relationship {..}) <- recordTableRelationshipFromRelInfo sourceName relationshipInfo
    (translatedOrderByElement, subOrderByRelations) <- translateOrderByElement (API.TNTable _rTargetTable) orderDirection (relationshipName : targetReversePath) orderByElement

    targetTableWhereExp <- translateBoolExpToExpression (API.TNTable _rTargetTable) filterExp
    let orderByRelations = HashMap.fromList [(relationshipName, API.OrderByRelation targetTableWhereExp subOrderByRelations)]

    pure (translatedOrderByElement, orderByRelations)
  AOCArrayAggregation relationshipInfo filterExp aggregateOrderByElement -> do
    (relationshipName, API.Relationship {..}) <- recordTableRelationshipFromRelInfo sourceName relationshipInfo
    orderByTarget <- case aggregateOrderByElement of
      AAOCount ->
        pure API.OrderByStarCountAggregate
      AAOOp AggregateOrderByColumn {_aobcColumn = ColumnInfo {..}, ..} -> do
        redactionExpName <- recordRedactionExpression sourceName _aobcRedactionExpression
        aggFunction <- translateSingleColumnAggregateFunction _aobcAggregateFunctionName
        let resultScalarType = Witch.from $ columnTypeToScalarType _aobcAggregateFunctionReturnType
        pure . API.OrderBySingleColumnAggregate $ API.SingleColumnAggregate aggFunction (Witch.from ciColumn) redactionExpName resultScalarType

    let translatedOrderByElement =
          API.OrderByElement
            { _obeTargetPath = reverse (relationshipName : targetReversePath),
              _obeTarget = orderByTarget,
              _obeOrderDirection = orderDirection
            }

    targetTableWhereExp <- translateBoolExpToExpression (API.TNTable _rTargetTable) filterExp
    let orderByRelations = HashMap.fromList [(relationshipName, API.OrderByRelation targetTableWhereExp mempty)]
    pure (translatedOrderByElement, orderByRelations)

mergeOrderByRelations ::
  forall m f.
  (MonadError QErr m, Foldable f) =>
  f (HashMap API.RelationshipName API.OrderByRelation) ->
  m (HashMap API.RelationshipName API.OrderByRelation)
mergeOrderByRelations orderByRelationsList =
  foldM mergeMap mempty orderByRelationsList
  where
    mergeMap :: HashMap API.RelationshipName API.OrderByRelation -> HashMap API.RelationshipName API.OrderByRelation -> m (HashMap API.RelationshipName API.OrderByRelation)
    mergeMap left right = foldM (\targetMap (relName, orderByRel) -> HashMap.alterF (maybe (pure $ Just orderByRel) (fmap Just . mergeOrderByRelation orderByRel)) relName targetMap) left $ HashMap.toList right

    mergeOrderByRelation :: API.OrderByRelation -> API.OrderByRelation -> m API.OrderByRelation
    mergeOrderByRelation right left =
      if API._obrWhere left == API._obrWhere right
        then do
          mergedSubrelations <- mergeMap (API._obrSubrelations left) (API._obrSubrelations right)
          pure $ API.OrderByRelation (API._obrWhere left) mergedSubrelations
        else throw500 "mergeOrderByRelations: Differing filter expressions found for the same table"

translateAnnFieldsWithNoAggregates ::
  ( MonadState state m,
    Has TableRelationships state,
    Has RedactionExpressionState state,
    MonadError QErr m,
    MonadReader r m,
    Has API.ScalarTypesCapabilities r,
    Has SessionVariables r
  ) =>
  FieldPrefix ->
  API.TargetName ->
  AnnFieldsG 'DataConnector Void (UnpreparedValue 'DataConnector) ->
  m FieldsAndAggregates
translateAnnFieldsWithNoAggregates fieldNamePrefix sourceName fields =
  (\fields' -> FieldsAndAggregates (Just fields') Nothing) <$> translateAnnFields fieldNamePrefix sourceName fields

translateAnnFields ::
  ( MonadState state m,
    Has TableRelationships state,
    Has RedactionExpressionState state,
    MonadError QErr m,
    MonadReader r m,
    Has API.ScalarTypesCapabilities r,
    Has SessionVariables r
  ) =>
  FieldPrefix ->
  API.TargetName ->
  AnnFieldsG 'DataConnector Void (UnpreparedValue 'DataConnector) ->
  m (HashMap FieldName API.Field)
translateAnnFields fieldNamePrefix sourceName fields = do
  translatedFields <- traverse (traverse (translateAnnField sourceName)) fields
  pure $ HashMap.fromList (mapMaybe (\(fieldName, field) -> (applyPrefix fieldNamePrefix fieldName,) <$> field) translatedFields)

translateAnnField ::
  ( MonadState state m,
    Has TableRelationships state,
    Has RedactionExpressionState state,
    MonadError QErr m,
    MonadReader r m,
    Has API.ScalarTypesCapabilities r,
    Has SessionVariables r
  ) =>
  API.TargetName ->
  AnnFieldG 'DataConnector Void (UnpreparedValue 'DataConnector) ->
  m (Maybe API.Field)
translateAnnField sourceTableName = \case
  AFNestedObject nestedObj ->
    Just
      . API.NestedObjField (Witch.from $ _anosColumn nestedObj)
      <$> translateNestedObjectSelect sourceTableName nestedObj
  AFNestedArray _ (ANASSimple field) ->
    fmap mkArrayField <$> translateAnnField sourceTableName field
    where
      mkArrayField nestedField =
        API.NestedArrayField (API.ArrayField nestedField Nothing Nothing Nothing Nothing)
  -- TODO(dmoverton): support limit, offset, where and order_by in ArrayField
  AFNestedArray _ (ANASAggregate _) ->
    pure Nothing -- TODO(dmoverton): support nested array aggregates
  AFColumn AnnColumnField {..} -> do
    redactionExpName <- recordRedactionExpression sourceTableName _acfRedactionExpression
    pure . Just $ API.ColumnField (Witch.from _acfColumn) (Witch.from $ columnTypeToScalarType _acfType) redactionExpName
  AFObjectRelation objRel ->
    case _aosTarget (_aarAnnSelect objRel) of
      FromTable tableName -> do
        let targetTable = Witch.from tableName
        let relationshipName = mkRelationshipName $ _aarRelationshipName objRel
        fields <- translateAnnFields noPrefix (API.TNTable targetTable) (_aosFields (_aarAnnSelect objRel))
        whereClause <- translateBoolExpToExpression (API.TNTable targetTable) (_aosTargetFilter (_aarAnnSelect objRel))

        recordTableRelationship
          sourceTableName
          relationshipName
          API.Relationship
            { _rTargetTable = targetTable,
              _rRelationshipType = API.ObjectRelationship,
              _rColumnMapping = HashMap.fromList $ bimap Witch.from Witch.from <$> HashMap.toList (_aarColumnMapping objRel)
            }

        pure
          . Just
          . API.RelField
          $ API.RelationshipField
            relationshipName
            ( API.Query
                { _qFields = Just $ mapFieldNameHashMap fields,
                  _qAggregates = mempty,
                  _qWhere = whereClause,
                  _qAggregatesLimit = Nothing,
                  _qLimit = Nothing,
                  _qOffset = Nothing,
                  _qOrderBy = Nothing
                }
            )
      other -> error $ "translateAnnField: " <> show other
  AFArrayRelation (ASSimple arrayRelationSelect) -> do
    Just <$> translateArrayRelationSelect sourceTableName (translateAnnFieldsWithNoAggregates noPrefix) arrayRelationSelect
  AFArrayRelation (ASAggregate arrayRelationSelect) ->
    Just <$> translateArrayRelationSelect sourceTableName translateTableAggregateFields arrayRelationSelect
  AFExpression _literal ->
    -- We ignore literal text fields (we don't send them to the data connector agent)
    -- and add them back to the response JSON when we reshape what the agent returns
    -- to us
    pure Nothing

translateArrayRelationSelect ::
  ( MonadState state m,
    Has TableRelationships state,
    Has RedactionExpressionState state,
    MonadError QErr m,
    MonadReader r m,
    Has API.ScalarTypesCapabilities r,
    Has SessionVariables r
  ) =>
  API.TargetName ->
  (API.TargetName -> Fields (fieldType (UnpreparedValue 'DataConnector)) -> m FieldsAndAggregates) ->
  AnnRelationSelectG 'DataConnector (AnnSelectG 'DataConnector fieldType (UnpreparedValue 'DataConnector)) ->
  m API.Field
translateArrayRelationSelect sourceName translateFieldsAndAggregates arrRel = do
  case _asnFrom (_aarAnnSelect arrRel) of
    FromIdentifier _ -> throw400 NotSupported "AnnSelectG: FromIdentifier not supported"
    FromNativeQuery {} -> throw400 NotSupported "AnnSelectG: FromNativeQuery not supported"
    FromStoredProcedure {} -> throw400 NotSupported "AnnSelectG: FromStoredProcedure not supported"
    FromFunction {} -> throw400 NotSupported "translateArrayRelationSelect: FromFunction not currently supported"
    FromTable targetTable -> do
      query <- translateAnnSelect translateFieldsAndAggregates (API.TNTable (Witch.into targetTable)) (_aarAnnSelect arrRel)
      let relationshipName = mkRelationshipName $ _aarRelationshipName arrRel

      recordTableRelationship
        sourceName
        relationshipName
        API.Relationship
          { _rTargetTable = Witch.into targetTable,
            _rRelationshipType = API.ArrayRelationship,
            _rColumnMapping = HashMap.fromList $ bimap Witch.from Witch.from <$> HashMap.toList (_aarColumnMapping arrRel)
          }

      pure
        . API.RelField
        $ API.RelationshipField
          relationshipName
          query

translateTableAggregateFields ::
  ( MonadState state m,
    Has TableRelationships state,
    Has RedactionExpressionState state,
    MonadError QErr m,
    MonadReader r m,
    Has API.ScalarTypesCapabilities r,
    Has SessionVariables r
  ) =>
  API.TargetName ->
  TableAggregateFieldsG 'DataConnector Void (UnpreparedValue 'DataConnector) ->
  m FieldsAndAggregates
translateTableAggregateFields sourceName fields = do
  mconcat <$> traverse (uncurry (translateTableAggregateField sourceName)) fields

translateTableAggregateField ::
  ( MonadState state m,
    Has TableRelationships state,
    Has RedactionExpressionState state,
    MonadError QErr m,
    MonadReader r m,
    Has API.ScalarTypesCapabilities r,
    Has SessionVariables r
  ) =>
  API.TargetName ->
  FieldName ->
  TableAggregateFieldG 'DataConnector Void (UnpreparedValue 'DataConnector) ->
  m FieldsAndAggregates
translateTableAggregateField sourceName fieldName = \case
  TAFAgg aggregateFields -> do
    let fieldNamePrefix = prefixWith fieldName
    translatedAggregateFields <- mconcat <$> traverse (uncurry (translateAggregateField sourceName fieldNamePrefix)) aggregateFields
    pure
      $ FieldsAndAggregates
        Nothing
        (Just translatedAggregateFields)
  TAFNodes _ fields ->
    translateAnnFieldsWithNoAggregates (prefixWith fieldName) sourceName fields
  TAFExp _txt ->
    -- We ignore literal text fields (we don't send them to the data connector agent)
    -- and add them back to the response JSON when we reshape what the agent returns
    -- to us
    pure mempty

translateAggregateField ::
  ( MonadState state m,
    Has TableRelationships state,
    Has RedactionExpressionState state,
    MonadError QErr m,
    MonadReader r m,
    Has API.ScalarTypesCapabilities r,
    Has SessionVariables r
  ) =>
  API.TargetName ->
  FieldPrefix ->
  FieldName ->
  AggregateField 'DataConnector (UnpreparedValue 'DataConnector) ->
  m (HashMap FieldName API.Aggregate)
translateAggregateField sourceName fieldPrefix fieldName = \case
  AFCount countAggregate -> do
    aggregate <-
      case countAggregate of
        StarCount -> pure API.StarCount
        ColumnCount (column, redactionExp) -> do
          redactionExpName <- recordRedactionExpression sourceName redactionExp
          pure $ API.ColumnCount $ API.ColumnCountAggregate {_ccaColumn = Witch.from column, _ccaRedactionExpression = redactionExpName, _ccaDistinct = False}
        ColumnDistinctCount (column, redactionExp) -> do
          redactionExpName <- recordRedactionExpression sourceName redactionExp
          pure $ API.ColumnCount $ API.ColumnCountAggregate {_ccaColumn = Witch.from column, _ccaRedactionExpression = redactionExpName, _ccaDistinct = True}
    pure $ HashMap.singleton (applyPrefix fieldPrefix fieldName) aggregate
  AFOp AggregateOp {..} -> do
    let fieldPrefix' = fieldPrefix <> prefixWith fieldName
    aggFunction <- translateSingleColumnAggregateFunction _aoOp

    fmap (HashMap.fromList . catMaybes) . forM _aoFields $ \(columnFieldName, columnField) ->
      case columnField of
        SFCol column resultType redactionExp -> do
          redactionExpName <- recordRedactionExpression sourceName redactionExp
          let resultScalarType = Witch.from $ columnTypeToScalarType resultType
          pure $ Just (applyPrefix fieldPrefix' columnFieldName, API.SingleColumn $ API.SingleColumnAggregate aggFunction (Witch.from column) redactionExpName resultScalarType)
        SFExp _txt ->
          -- We ignore literal text fields (we don't send them to the data connector agent)
          -- and add them back to the response JSON when we reshape what the agent returns
          -- to us
          pure Nothing
        -- See Hasura.RQL.Types.Backend.supportsAggregateComputedFields
        SFComputedField _ _ -> error "Aggregate computed fields aren't currently supported for Data Connectors!"
  AFExp _txt ->
    -- We ignore literal text fields (we don't send them to the data connector agent)
    -- and add them back to the response JSON when we reshape what the agent returns
    -- to us
    pure mempty

translateSingleColumnAggregateFunction :: (MonadError QErr m) => Text -> m API.SingleColumnAggregateFunction
translateSingleColumnAggregateFunction functionName =
  fmap API.SingleColumnAggregateFunction (G.mkName functionName)
    `onNothing` throw500 ("translateSingleColumnAggregateFunction: Invalid aggregate function encountered: " <> functionName)

translateNestedObjectSelect ::
  ( MonadState state m,
    Has TableRelationships state,
    Has RedactionExpressionState state,
    MonadError QErr m,
    MonadReader r m,
    Has API.ScalarTypesCapabilities r,
    Has SessionVariables r
  ) =>
  API.TargetName ->
  AnnNestedObjectSelectG 'DataConnector Void (UnpreparedValue 'DataConnector) ->
  m API.Query
translateNestedObjectSelect relationshipKey selectG = do
  FieldsAndAggregates {..} <- translateAnnFieldsWithNoAggregates noPrefix relationshipKey $ _anosFields selectG
  pure
    API.Query
      { _qFields = mapFieldNameHashMap <$> _faaFields,
        _qAggregates = Nothing,
        _qAggregatesLimit = Nothing,
        _qLimit = Nothing,
        _qOffset = Nothing,
        _qWhere = Nothing,
        _qOrderBy = Nothing
      }

--------------------------------------------------------------------------------

reshapeResponseToQueryShape ::
  (MonadError QErr m) =>
  QueryDB 'DataConnector Void v ->
  API.QueryResponse ->
  m J.Encoding
reshapeResponseToQueryShape queryDb response =
  case queryDb of
    QDBMultipleRows simpleSelect -> reshapeSimpleSelectRows Many (_asnFields simpleSelect) response
    QDBSingleRow simpleSelect -> reshapeSimpleSelectRows Single (_asnFields simpleSelect) response
    QDBAggregation aggregateSelect -> reshapeTableAggregateFields (_asnFields aggregateSelect) response

reshapeSimpleSelectRows ::
  (MonadError QErr m) =>
  Cardinality ->
  AnnFieldsG 'DataConnector Void v ->
  API.QueryResponse ->
  m J.Encoding
reshapeSimpleSelectRows cardinality fields API.QueryResponse {..} =
  case cardinality of
    Single ->
      case rows of
        [] -> pure $ J.toEncoding J.Null
        [singleRow] -> reshapeAnnFields noPrefix fields singleRow
        _multipleRows ->
          throw500 "Data Connector agent returned multiple rows when only one was expected" -- TODO(dchambers): Add pathing information for error clarity
    Many -> do
      reshapedRows <- traverse (reshapeAnnFields noPrefix fields) rows
      pure $ JE.list id reshapedRows
  where
    rows = fromMaybe mempty _qrRows

reshapeTableAggregateFields ::
  (MonadError QErr m) =>
  TableAggregateFieldsG 'DataConnector Void v ->
  API.QueryResponse ->
  m J.Encoding
reshapeTableAggregateFields tableAggregateFields API.QueryResponse {..} = do
  reshapedFields <- forM tableAggregateFields $ \(fieldName@(FieldName fieldNameText), tableAggregateField) -> do
    case tableAggregateField of
      TAFAgg aggregateFields -> do
        reshapedAggregateFields <- reshapeAggregateFields (prefixWith fieldName) aggregateFields responseAggregates
        pure $ (fieldNameText, reshapedAggregateFields)
      TAFNodes _ annFields -> do
        reshapedRows <- traverse (reshapeAnnFields (prefixWith fieldName) annFields) responseRows
        pure $ (fieldNameText, JE.list id reshapedRows)
      TAFExp txt ->
        pure $ (fieldNameText, JE.text txt)
  pure $ encodeAssocListAsObject reshapedFields
  where
    responseRows = fromMaybe mempty _qrRows
    responseAggregates = fromMaybe mempty _qrAggregates

reshapeAggregateFields ::
  (MonadError QErr m) =>
  FieldPrefix ->
  AggregateFields 'DataConnector v ->
  HashMap API.FieldName J.Value ->
  m J.Encoding
reshapeAggregateFields fieldPrefix aggregateFields responseAggregates = do
  reshapedFields <- forM aggregateFields $ \(fieldName@(FieldName fieldNameText), aggregateField) ->
    case aggregateField of
      AFCount _countAggregate -> do
        let fieldNameKey = API.FieldName . getFieldNameTxt $ applyPrefix fieldPrefix fieldName
        responseAggregateValue <-
          HashMap.lookup fieldNameKey responseAggregates
            `onNothing` throw500 ("Unable to find expected aggregate " <> API.unFieldName fieldNameKey <> " in aggregates returned by Data Connector agent") -- TODO(dchambers): Add pathing information for error clarity
        pure (fieldNameText, J.toEncoding responseAggregateValue)
      AFOp AggregateOp {..} -> do
        reshapedColumnFields <- forM _aoFields $ \(columnFieldName@(FieldName columnFieldNameText), columnField) ->
          case columnField of
            SFCol _column _columnType _redactionExp -> do
              let fieldPrefix' = fieldPrefix <> prefixWith fieldName
              let columnFieldNameKey = API.FieldName . getFieldNameTxt $ applyPrefix fieldPrefix' columnFieldName
              responseAggregateValue <-
                HashMap.lookup columnFieldNameKey responseAggregates
                  `onNothing` throw500 ("Unable to find expected aggregate " <> API.unFieldName columnFieldNameKey <> " in aggregates returned by Data Connector agent") -- TODO(dchambers): Add pathing information for error clarity
              pure (columnFieldNameText, J.toEncoding responseAggregateValue)
            SFExp txt ->
              pure (columnFieldNameText, JE.text txt)
            -- See Hasura.RQL.Types.Backend.supportsAggregateComputedFields
            SFComputedField _ _ -> error "Aggregate computed fields aren't currently supported for Data Connectors!"

        pure (fieldNameText, encodeAssocListAsObject reshapedColumnFields)
      AFExp txt ->
        pure (fieldNameText, JE.text txt)
  pure $ encodeAssocListAsObject reshapedFields

reshapeAnnFields ::
  (MonadError QErr m) =>
  FieldPrefix ->
  AnnFieldsG 'DataConnector Void v ->
  HashMap API.FieldName API.FieldValue ->
  m J.Encoding
reshapeAnnFields fieldNamePrefix fields responseRow = do
  reshapedFields <- forM fields $ \(fieldName@(FieldName fieldNameText), field) -> do
    let fieldNameKey = API.FieldName . getFieldNameTxt $ applyPrefix fieldNamePrefix fieldName
    let responseField = fromMaybe API.nullFieldValue $ HashMap.lookup fieldNameKey responseRow
    reshapedField <- reshapeField field responseField
    pure (fieldNameText, reshapedField)

  pure $ encodeAssocListAsObject reshapedFields

reshapeField ::
  (MonadError QErr m) =>
  AnnFieldG 'DataConnector Void v ->
  API.FieldValue ->
  m J.Encoding
reshapeField field responseFieldValue =
  case field of
    AFNestedObject nestedObj ->
      handleNull responseFieldValue
        $ case API.deserializeAsNestedObjFieldValue responseFieldValue of
          Left err -> throw500 $ "Expected object in field returned by Data Connector agent: " <> err -- TODO(dmoverton): Add pathing information for error clarity
          Right nestedResponse ->
            reshapeAnnFields noPrefix (_anosFields nestedObj) nestedResponse
    AFNestedArray _ (ANASSimple arrayField) ->
      handleNull responseFieldValue
        $ case API.deserializeAsNestedArrayFieldValue responseFieldValue of
          Left err -> throw500 $ "Expected array in field returned by Data Connector agent: " <> err -- TODO(dmoverton): Add pathing information for error clarity
          Right arrayResponse ->
            JE.list id <$> traverse (reshapeField arrayField) arrayResponse
    AFNestedArray _ (ANASAggregate _) ->
      throw400 NotSupported "Nested array aggregate not supported"
    AFColumn _columnField -> do
      let columnFieldValue = API.deserializeAsColumnFieldValue responseFieldValue
      pure $ J.toEncoding columnFieldValue
    AFObjectRelation objectRelationField -> do
      case API.deserializeAsRelationshipFieldValue responseFieldValue of
        Left err -> throw500 $ "Found column field value where relationship field value was expected in field returned by Data Connector agent: " <> err -- TODO(dchambers): Add pathing information for error clarity
        Right subqueryResponse ->
          let fields = _aosFields $ _aarAnnSelect objectRelationField
           in reshapeSimpleSelectRows Single fields subqueryResponse
    AFArrayRelation (ASSimple simpleArrayRelationField) ->
      reshapeAnnRelationSelect (reshapeSimpleSelectRows Many) simpleArrayRelationField responseFieldValue
    AFArrayRelation (ASAggregate aggregateArrayRelationField) ->
      reshapeAnnRelationSelect reshapeTableAggregateFields aggregateArrayRelationField responseFieldValue
    AFExpression txt -> pure $ JE.text txt
  where
    handleNull v a =
      if API.isNullFieldValue v
        then pure JE.null_
        else a

reshapeAnnRelationSelect ::
  (MonadError QErr m) =>
  (Fields (fieldType v) -> API.QueryResponse -> m J.Encoding) ->
  AnnRelationSelectG 'DataConnector (AnnSelectG 'DataConnector fieldType v) ->
  API.FieldValue ->
  m J.Encoding
reshapeAnnRelationSelect reshapeFields annRelationSelect fieldValue =
  case API.deserializeAsRelationshipFieldValue fieldValue of
    Left err -> throw500 $ "Found column field value where relationship field value was expected in field returned by Data Connector agent: " <> err -- TODO(dchambers): Add pathing information for error clarity
    Right subqueryResponse ->
      let annSimpleSelect = _aarAnnSelect annRelationSelect
       in reshapeFields (_asnFields annSimpleSelect) subqueryResponse
