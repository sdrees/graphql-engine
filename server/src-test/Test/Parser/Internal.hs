-- | Internal helper module. Some things re-exported by
-- 'Test.Parser.Expectation'.
module Test.Parser.Internal
  ( mkTable,
    ColumnInfoBuilder (..),
    mkColumnInfo,
    mkParser,
    Parser,
    TableInfoBuilder (..),
    tableInfoBuilder,
    buildTableInfo,
  )
where

import Data.HashMap.Strict qualified as HM
import Data.HashSet qualified as HS
import Data.Sequence.NonEmpty qualified as NESeq
import Data.Text.Casing qualified as C
import Hasura.Backends.Postgres.Instances.Schema ()
import Hasura.Backends.Postgres.SQL.Types (ConstraintName (..), QualifiedObject (..), QualifiedTable, TableName (..), unsafePGCol)
import Hasura.GraphQL.Schema.Backend
import Hasura.GraphQL.Schema.Common (Scenario (Frontend))
import Hasura.GraphQL.Schema.Parser (FieldParser)
import Hasura.Prelude
import Hasura.RQL.IR.BoolExp (AnnBoolExpFld (..), GBoolExp (..), PartialSQLExp (..))
import Hasura.RQL.IR.Root (RemoteRelationshipField)
import Hasura.RQL.IR.Update (AnnotatedUpdateG (..))
import Hasura.RQL.IR.Value (UnpreparedValue (..))
import Hasura.RQL.Types.Column (ColumnInfo (..), ColumnMutability (..), ColumnType (..))
import Hasura.RQL.Types.Common (Comment (..), FieldName (..), OID (..))
import Hasura.RQL.Types.Instances ()
import Hasura.RQL.Types.Permission (AllowedRootFields (..))
import Hasura.RQL.Types.Relationships.Local (RelInfo (..), fromRel)
import Hasura.RQL.Types.Source (SourceInfo)
import Hasura.RQL.Types.Table (Constraint (..), CustomRootField (..), FieldInfo (..), PrimaryKey (..), RolePermInfo (..), SelPermInfo (..), TableConfig (..), TableCoreInfoG (..), TableCustomRootFields (..), TableInfo (..), UpdPermInfo (..))
import Hasura.SQL.Backend (BackendType (Postgres), PostgresKind (Vanilla))
import Language.GraphQL.Draft.Syntax (unsafeMkName)
import Test.Parser.Monad

{-# ANN module ("HLint: ignore Use mkName" :: String) #-}

type PG = 'Postgres 'Vanilla

type Parser = FieldParser ParserTest (AnnotatedUpdateG PG (RemoteRelationshipField UnpreparedValue) (UnpreparedValue PG))

-- | Create a table by its name, using the public schema.
mkTable :: Text -> QualifiedTable
mkTable name =
  QualifiedObject
    { qSchema = "public",
      qName = TableName name
    }

-- | Build a column, see 'mkColumnInfo'.
data ColumnInfoBuilder = ColumnInfoBuilder
  { -- | name of the column
    cibName :: Text,
    -- | Column type, e.g.
    --
    -- > ColumnScalar PGText
    cibType :: ColumnType PG,
    -- | whether the column is nullable or not
    cibNullable :: Bool,
    -- | is it a primary key?
    cibIsPrimaryKey :: Bool
  }

-- | Create a column using the provided 'ColumnInfoBuilder' and defaults.
--
-- Note that all permissions are enabled by default.
mkColumnInfo :: ColumnInfoBuilder -> ColumnInfo PG
mkColumnInfo ColumnInfoBuilder {..} =
  ColumnInfo
    { ciColumn = unsafePGCol cibName,
      ciName = unsafeMkName cibName,
      ciPosition = 0,
      ciType = cibType,
      ciIsNullable = cibNullable,
      ciDescription = Nothing,
      ciMutability = columnMutability
    }
  where
    columnMutability :: ColumnMutability
    columnMutability =
      ColumnMutability
        { _cmIsInsertable = True,
          _cmIsUpdatable = True
        }

-- | Create a parser for the provided table and columns.
--
-- No special permissions, required headers, filters, etc., are set.
--
-- This will not work for inserts and deletes (see @rolePermInfo@ below).
mkParser :: TableInfoBuilder -> SchemaTest [Parser]
mkParser tib =
  buildTableUpdateMutationFields
    mempty
    Frontend
    sourceInfo
    (table tib)
    (buildTableInfo tib)
    name
  where
    sourceInfo :: SourceInfo PG
    sourceInfo = notImplementedYet "sourceInfo"

    name :: C.GQLNameIdentifier
    name = C.fromAutogeneratedName (unsafeMkName $ getTableTxt $ qName (table tib))

-- | Inputs for building 'TableInfo's.
-- The expectation is that this will be extended freely as new tests need more
-- elaborate setup.
data TableInfoBuilder = TableInfoBuilder
  { table :: QualifiedTable,
    columns :: [ColumnInfoBuilder],
    relations :: [RelInfo PG]
  }

-- | A smart constructor for an empty 'TableInfoBuilder'.
-- This should make it easier to maintain existing test code when new fields are
-- added.
tableInfoBuilder :: QualifiedTable -> TableInfoBuilder
tableInfoBuilder table = TableInfoBuilder {columns = [], relations = [], ..}

-- | Build a 'TableInfo' from a 'TableInfoBuilder.
-- The expectation is that this will be extended freely as new tests need more
-- elaborate setup.
buildTableInfo :: TableInfoBuilder -> TableInfo PG
buildTableInfo TableInfoBuilder {..} = tableInfo
  where
    tableInfo :: TableInfo PG
    tableInfo =
      TableInfo
        { _tiCoreInfo = tableCoreInfo,
          _tiRolePermInfoMap = mempty,
          _tiEventTriggerInfoMap = mempty,
          _tiAdminRolePermInfo = rolePermInfo
        }

    tableCoreInfo :: TableCoreInfoG PG (FieldInfo PG) (ColumnInfo PG)
    tableCoreInfo =
      TableCoreInfo
        { _tciName = table,
          _tciDescription = Nothing,
          _tciFieldInfoMap = fieldInfoMap,
          _tciPrimaryKey = pk,
          _tciUniqueConstraints = mempty,
          _tciForeignKeys = mempty,
          _tciViewInfo = Nothing,
          _tciEnumValues = Nothing,
          _tciCustomConfig = tableConfig,
          _tciExtraTableMetadata = (),
          _tciApolloFederationConfig = Nothing
        }

    pk :: Maybe (PrimaryKey PG (ColumnInfo PG))
    pk = case pks of
      Nothing -> Nothing
      Just primaryColumns ->
        Just
          PrimaryKey
            { _pkConstraint =
                Constraint
                  { _cName = ConstraintName "",
                    _cOid = OID 0
                  },
              _pkColumns = primaryColumns
            }

    rolePermInfo :: RolePermInfo PG
    rolePermInfo =
      RolePermInfo
        { _permIns = Nothing,
          _permSel = Just selPermInfo,
          _permUpd = Just updPermInfo,
          _permDel = Nothing
        }

    fieldInfoMap :: HM.HashMap FieldName (FieldInfo PG)
    fieldInfoMap = HM.unions [columnFields, relationFields]

    columnFields :: HM.HashMap FieldName (FieldInfo PG)
    columnFields =
      HM.fromList
        . fmap toCIHashPair
        $ columns

    toCIHashPair :: ColumnInfoBuilder -> (FieldName, FieldInfo PG)
    toCIHashPair cib = (coerce $ cibName cib, FIColumn $ mkColumnInfo cib)

    toRelHashPair :: RelInfo PG -> (FieldName, FieldInfo PG)
    toRelHashPair ri = (fromRel $ riName ri, FIRelationship ri)

    relationFields :: HM.HashMap FieldName (FieldInfo PG)
    relationFields = HM.fromList . fmap toRelHashPair $ relations

    tableConfig :: TableConfig PG
    tableConfig =
      TableConfig
        { _tcCustomRootFields = tableCustomRootFields,
          _tcColumnConfig = mempty,
          _tcCustomName = Nothing,
          _tcComment = Automatic
        }

    selPermInfo :: SelPermInfo PG
    selPermInfo =
      SelPermInfo
        { spiCols = HM.fromList . fmap ((,Nothing) . unsafePGCol . cibName) $ columns,
          spiComputedFields = mempty,
          spiFilter = upiFilter,
          spiLimit = Nothing,
          spiAllowAgg = True,
          spiRequiredHeaders = mempty,
          spiAllowedQueryRootFields = ARFAllowAllRootFields,
          spiAllowedSubscriptionRootFields = ARFAllowAllRootFields
        }

    tableCustomRootFields :: TableCustomRootFields
    tableCustomRootFields =
      TableCustomRootFields
        { _tcrfSelect = customRootField,
          _tcrfSelectByPk = customRootField,
          _tcrfSelectAggregate = customRootField,
          _tcrfSelectStream = customRootField,
          _tcrfInsert = customRootField,
          _tcrfInsertOne = customRootField,
          _tcrfUpdate = customRootField,
          _tcrfUpdateByPk = customRootField,
          _tcrfUpdateMany = customRootField,
          _tcrfDelete = customRootField,
          _tcrfDeleteByPk = customRootField
        }

    customRootField :: CustomRootField
    customRootField =
      CustomRootField
        { _crfName = Nothing,
          _crfComment = Automatic
        }

    updPermInfo :: UpdPermInfo PG
    updPermInfo =
      UpdPermInfo
        { upiCols = HS.fromList . fmap (unsafePGCol . cibName) $ columns,
          upiTable = table,
          upiFilter = upiFilter,
          upiCheck = Nothing,
          upiSet = mempty,
          upiBackendOnly = False,
          upiRequiredHeaders = mempty
        }

    columnInfos :: [ColumnInfo PG]
    columnInfos = mkColumnInfo <$> columns

    pks :: Maybe (NESeq.NESeq (ColumnInfo PG))
    pks = case mkColumnInfo <$> filter cibIsPrimaryKey columns of
      [] -> Nothing
      (x : xs) -> Just $ foldl (<>) (NESeq.singleton x) $ fmap NESeq.singleton xs

    upiFilter :: GBoolExp PG (AnnBoolExpFld PG (PartialSQLExp PG))
    upiFilter = BoolAnd $ fmap (\ci -> BoolField $ AVColumn ci []) columnInfos
