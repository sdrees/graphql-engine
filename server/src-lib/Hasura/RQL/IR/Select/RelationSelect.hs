{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

-- | More leaves cut from RQL.IR.Select for sake of breaking up the big
-- blocking Template Haskell lense-creation party
module Hasura.RQL.IR.Select.RelationSelect
  ( AnnRelationSelectG (..),
    aarRelationshipName,
    aarColumnMapping,
    aarAnnSelect,
  )
where

import Control.Lens.TH (makeLenses)
import Hasura.Prelude
import Hasura.RQL.Types.Backend
import Hasura.RQL.Types.BackendType
import Hasura.RQL.Types.Common

-- Local relationship

data AnnRelationSelectG (b :: BackendType) a = AnnRelationSelectG
  { _aarRelationshipName :: RelName, -- Relationship name
    _aarColumnMapping :: HashMap (Column b) (Column b), -- Column of left table to join with
    _aarAnnSelect :: a -- Current table. Almost ~ to SQL Select
  }
  deriving stock (Functor, Foldable, Traversable)

deriving stock instance (Backend b, Eq v) => Eq (AnnRelationSelectG b v)

deriving stock instance (Backend b, Show v) => Show (AnnRelationSelectG b v)

$(makeLenses ''AnnRelationSelectG)
