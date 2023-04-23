{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

-- | The representation of native queries as derived from the schema cache.
module Hasura.NativeQuery.Cache
  ( NativeQueryInfo (..),
    NativeQueryCache,
    nqiRootFieldName,
    nqiArrayRelationships,
    nqiCode,
    nqiReturns,
    nqiArguments,
    nqiDescription,
  )
where

import Control.Lens (makeLenses)
import Data.Aeson (ToJSON (toJSON), genericToJSON)
import Hasura.LogicalModel.Cache (LogicalModelInfo)
import Hasura.NativeQuery.Metadata (InterpolatedQuery, NativeQueryArgumentName, NativeQueryName)
import Hasura.NativeQuery.Types (NullableScalarType)
import Hasura.Prelude
import Hasura.RQL.Types.Backend (Backend)
import Hasura.RQL.Types.Common (RelName)
import Hasura.RQL.Types.Relationships.Local (RelInfo)
import Hasura.RQL.Types.Table (RolePermInfoMap)
import Hasura.SQL.Backend (BackendType)

type NativeQueryCache b = HashMap NativeQueryName (NativeQueryInfo b)

-- | The type into which 'NativeQueryMetadata' is resolved in
-- 'Hasura/RQL/DDL/Schema/Cache.buildSchemaCacheRule'.
data NativeQueryInfo (b :: BackendType) = NativeQueryInfo
  { _nqiRootFieldName :: NativeQueryName,
    _nqiCode :: InterpolatedQuery NativeQueryArgumentName,
    _nqiReturns :: LogicalModelInfo b,
    _nqiArguments :: HashMap NativeQueryArgumentName (NullableScalarType b),
    _nqiArrayRelationships :: InsOrdHashMap RelName (RelInfo b),
    _nqiDescription :: Maybe Text
  }
  deriving stock (Generic)

instance
  (Backend b, ToJSON (RolePermInfoMap b)) =>
  ToJSON (NativeQueryInfo b)
  where
  toJSON = genericToJSON hasuraJSON

makeLenses ''NativeQueryInfo
