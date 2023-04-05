{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- | Postgres Instances Metadata
--
-- Defines a 'Hasura.RQL.Types.Metadata.Backend.BackendMetadata' type class instance for Postgres.
module Hasura.Backends.Postgres.Instances.Metadata () where

import Data.HashMap.Strict qualified as Map
import Data.HashMap.Strict.InsOrd qualified as InsOrd
import Data.Text.Extended
import Database.PG.Query.PTI qualified as PTI
import Database.PostgreSQL.LibPQ qualified as PQ
import Hasura.Backends.Postgres.DDL qualified as Postgres
import Hasura.Backends.Postgres.Instances.LogicalModels as Postgres (validateLogicalModel)
import Hasura.Backends.Postgres.SQL.Types (QualifiedTable)
import Hasura.Backends.Postgres.SQL.Types qualified as Postgres
import Hasura.Backends.Postgres.Types.CitusExtraTableMetadata
import Hasura.Base.Error
import Hasura.Prelude
import Hasura.RQL.Types.Backend (Backend)
import Hasura.RQL.Types.Metadata.Backend
import Hasura.RQL.Types.Relationships.Local
import Hasura.RQL.Types.Table
import Hasura.SQL.Backend

--------------------------------------------------------------------------------
-- PostgresMetadata

-- | We differentiate the handling of metadata between Citus and Vanilla
-- Postgres because Citus imposes limitations on the types of joins that it
-- permits, which then limits the types of relations that we can track.
class PostgresMetadata (pgKind :: PostgresKind) where
  -- TODO: find a better name
  validateRel ::
    MonadError QErr m =>
    TableCache ('Postgres pgKind) ->
    QualifiedTable ->
    Either (ObjRelDef ('Postgres pgKind)) (ArrRelDef ('Postgres pgKind)) ->
    m ()

  -- | A mapping from pg scalar types with clear oid equivalent to oid.
  --
  -- This is a insert order hash map so that when we invert it
  -- duplicate oids will point to a more "general" type.
  pgTypeOidMapping :: InsOrd.InsOrdHashMap Postgres.PGScalarType PQ.Oid
  pgTypeOidMapping =
    InsOrd.fromList $
      [ (Postgres.PGSmallInt, PTI.int2),
        (Postgres.PGSerial, PTI.int4),
        (Postgres.PGInteger, PTI.int4),
        (Postgres.PGBigSerial, PTI.int8),
        (Postgres.PGBigInt, PTI.int8),
        (Postgres.PGFloat, PTI.float4),
        (Postgres.PGDouble, PTI.float8),
        (Postgres.PGMoney, PTI.numeric),
        (Postgres.PGNumeric, PTI.numeric),
        (Postgres.PGBoolean, PTI.bool),
        (Postgres.PGChar, PTI.bpchar),
        (Postgres.PGVarchar, PTI.varchar),
        (Postgres.PGText, PTI.text),
        (Postgres.PGDate, PTI.date),
        (Postgres.PGTimeStamp, PTI.timestamp),
        (Postgres.PGTimeStampTZ, PTI.timestamptz),
        (Postgres.PGTimeTZ, PTI.timetz),
        (Postgres.PGJSON, PTI.json),
        (Postgres.PGJSONB, PTI.jsonb),
        (Postgres.PGUUID, PTI.uuid),
        (Postgres.PGArray Postgres.PGSmallInt, PTI.int2_array),
        (Postgres.PGArray Postgres.PGSerial, PTI.int4_array),
        (Postgres.PGArray Postgres.PGInteger, PTI.int4_array),
        (Postgres.PGArray Postgres.PGBigSerial, PTI.int8_array),
        (Postgres.PGArray Postgres.PGBigInt, PTI.int8_array),
        (Postgres.PGArray Postgres.PGFloat, PTI.float4_array),
        (Postgres.PGArray Postgres.PGDouble, PTI.float8_array),
        (Postgres.PGArray Postgres.PGMoney, PTI.numeric_array),
        (Postgres.PGArray Postgres.PGNumeric, PTI.numeric_array),
        (Postgres.PGArray Postgres.PGBoolean, PTI.bool_array),
        (Postgres.PGArray Postgres.PGChar, PTI.char_array),
        (Postgres.PGArray Postgres.PGVarchar, PTI.varchar_array),
        (Postgres.PGArray Postgres.PGText, PTI.text_array),
        (Postgres.PGArray Postgres.PGDate, PTI.date_array),
        (Postgres.PGArray Postgres.PGTimeStamp, PTI.timestamp_array),
        (Postgres.PGArray Postgres.PGTimeStampTZ, PTI.timestamptz_array),
        (Postgres.PGArray Postgres.PGTimeTZ, PTI.timetz_array),
        (Postgres.PGArray Postgres.PGJSON, PTI.json_array),
        (Postgres.PGArray Postgres.PGJSON, PTI.jsonb_array),
        (Postgres.PGArray Postgres.PGUUID, PTI.uuid_array)
      ]

instance PostgresMetadata 'Vanilla where
  validateRel _ _ _ = pure ()

instance PostgresMetadata 'Citus where
  validateRel ::
    forall m.
    MonadError QErr m =>
    TableCache ('Postgres 'Citus) ->
    QualifiedTable ->
    Either (ObjRelDef ('Postgres 'Citus)) (ArrRelDef ('Postgres 'Citus)) ->
    m ()
  validateRel tableCache sourceTable relInfo = do
    sourceTableInfo <- lookupTableInfo sourceTable
    case relInfo of
      Left (RelDef _ obj _) ->
        case obj of
          RUFKeyOn (SameTable _) -> pure ()
          RUFKeyOn (RemoteTable targetTable _) -> checkObjectRelationship sourceTableInfo targetTable
          RUManual RelManualConfig {} -> pure ()
      Right (RelDef _ obj _) ->
        case obj of
          RUFKeyOn (ArrRelUsingFKeyOn targetTable _col) -> checkArrayRelationship sourceTableInfo targetTable
          RUManual RelManualConfig {} -> pure ()
    where
      lookupTableInfo tableName =
        Map.lookup tableName tableCache
          `onNothing` throw400 NotFound ("no such table " <>> tableName)

      checkObjectRelationship sourceTableInfo targetTable = do
        targetTableInfo <- lookupTableInfo targetTable
        let notSupported = throwNotSupportedError sourceTableInfo targetTableInfo "object"
        case ( _tciExtraTableMetadata $ _tiCoreInfo sourceTableInfo,
               _tciExtraTableMetadata $ _tiCoreInfo targetTableInfo
             ) of
          (Distributed {}, Local) -> notSupported
          (Distributed {}, Reference) -> pure ()
          (Distributed {}, Distributed {}) -> pure ()
          (_, Distributed {}) -> notSupported
          (_, _) -> pure ()

      checkArrayRelationship sourceTableInfo targetTable = do
        targetTableInfo <- lookupTableInfo targetTable
        let notSupported = throwNotSupportedError sourceTableInfo targetTableInfo "array"
        case ( _tciExtraTableMetadata $ _tiCoreInfo sourceTableInfo,
               _tciExtraTableMetadata $ _tiCoreInfo targetTableInfo
             ) of
          (Distributed {}, Distributed {}) -> pure ()
          (Distributed {}, _) -> notSupported
          (_, Distributed {}) -> notSupported
          (_, _) -> pure ()

      showDistributionType :: ExtraTableMetadata -> Text
      showDistributionType = \case
        Local -> "local"
        Distributed _ -> "distributed"
        Reference -> "reference"

      throwNotSupportedError :: TableInfo ('Postgres 'Citus) -> TableInfo ('Postgres 'Citus) -> Text -> m ()
      throwNotSupportedError sourceTableInfo targetTableInfo t =
        let tciSrc = _tiCoreInfo sourceTableInfo
            tciTgt = _tiCoreInfo targetTableInfo
         in throw400
              NotSupported
              ( showDistributionType (_tciExtraTableMetadata tciSrc)
                  <> " tables ("
                  <> toTxt (_tciName tciSrc)
                  <> ") cannot have an "
                  <> t
                  <> " relationship against a "
                  <> showDistributionType (_tciExtraTableMetadata $ _tiCoreInfo targetTableInfo)
                  <> " table ("
                  <> toTxt (_tciName tciTgt)
                  <> ")"
              )

instance PostgresMetadata 'Cockroach where
  validateRel _ _ _ = pure ()
  pgTypeOidMapping =
    InsOrd.fromList
      [ (Postgres.PGInteger, PTI.int8),
        (Postgres.PGSerial, PTI.int8),
        (Postgres.PGJSON, PTI.jsonb)
      ]
      `InsOrd.union` pgTypeOidMapping @'Vanilla

----------------------------------------------------------------
-- BackendMetadata instance

instance
  ( Backend ('Postgres pgKind),
    PostgresMetadata pgKind,
    Postgres.FetchTableMetadata pgKind,
    Postgres.FetchFunctionMetadata pgKind,
    Postgres.ToMetadataFetchQuery pgKind
  ) =>
  BackendMetadata ('Postgres pgKind)
  where
  prepareCatalog = Postgres.prepareCatalog
  buildComputedFieldInfo = Postgres.buildComputedFieldInfo
  fetchAndValidateEnumValues = Postgres.fetchAndValidateEnumValues
  resolveSourceConfig = Postgres.resolveSourceConfig
  resolveDatabaseMetadata = Postgres.resolveDatabaseMetadata
  parseBoolExpOperations = Postgres.parseBoolExpOperations
  buildFunctionInfo = Postgres.buildFunctionInfo
  updateColumnInEventTrigger = Postgres.updateColumnInEventTrigger
  parseCollectableType = Postgres.parseCollectableType
  postDropSourceHook = Postgres.postDropSourceHook
  validateRelationship = validateRel @pgKind
  buildComputedFieldBooleanExp = Postgres.buildComputedFieldBooleanExp
  validateLogicalModel = Postgres.validateLogicalModel (pgTypeOidMapping @pgKind)
  supportsBeingRemoteRelationshipTarget _ = True
