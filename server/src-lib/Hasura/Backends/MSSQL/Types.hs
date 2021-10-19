-- | Types for Transact-SQL aka T-SQL; the language of SQL Server.
module Hasura.Backends.MSSQL.Types
  ( module Hasura.Backends.MSSQL.Types.Internal,
    MSSQLExtraInsertData (..),
  )
where

import Hasura.Backends.MSSQL.Types.Instances ()
import Hasura.Backends.MSSQL.Types.Internal

data MSSQLExtraInsertData = MSSQLExtraInsertData
  { _mssqlPrimaryKeyColumns :: ![ColumnName],
    _mssqlIdentityColumns :: ![ColumnName]
  }
