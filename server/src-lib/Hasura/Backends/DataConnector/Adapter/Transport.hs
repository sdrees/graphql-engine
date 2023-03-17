{-# OPTIONS_GHC -fno-warn-orphans #-}

module Hasura.Backends.DataConnector.Adapter.Transport () where

--------------------------------------------------------------------------------

import Control.Exception.Safe (throwIO)
import Control.Monad.Trans.Control
import Data.Aeson qualified as J
import Data.Text.Extended ((<>>))
import Hasura.Backends.DataConnector.Adapter.Execute (DataConnectorPreparedQuery (..), encodePreparedQueryToJsonText)
import Hasura.Backends.DataConnector.Adapter.Types (SourceConfig (..))
import Hasura.Backends.DataConnector.Agent.Client (AgentClientContext (..), AgentClientT, runAgentClientT)
import Hasura.Base.Error (QErr)
import Hasura.EncJSON (EncJSON)
import Hasura.GraphQL.Execute.Backend (DBStepInfo (..), OnBaseMonad (..), arResult)
import Hasura.GraphQL.Logging qualified as HGL
import Hasura.GraphQL.Namespace (RootFieldAlias)
import Hasura.GraphQL.Transport.Backend (BackendTransport (..))
import Hasura.GraphQL.Transport.HTTP.Protocol (GQLReqUnparsed)
import Hasura.Logging (Hasura, Logger, nullLogger)
import Hasura.Prelude
import Hasura.RQL.Types.Backend (ResolvedConnectionTemplate)
import Hasura.SQL.AnyBackend (AnyBackend)
import Hasura.SQL.Backend (BackendType (DataConnector))
import Hasura.Server.Types (RequestId)
import Hasura.Session (UserInfo)
import Hasura.Tracing qualified as Tracing

--------------------------------------------------------------------------------

instance BackendTransport 'DataConnector where
  runDBQuery = runDBQuery'
  runDBQueryExplain = runDBQueryExplain'
  runDBMutation = runDBMutation'
  runDBStreamingSubscription _ _ _ _ =
    liftIO . throwIO $ userError "runDBStreamingSubscription: not implemented for the Data Connector backend."
  runDBSubscription _ _ _ _ =
    liftIO . throwIO $ userError "runDBSubscription: not implemented for the Data Connector backend."

runDBQuery' ::
  ( MonadIO m,
    MonadBaseControl IO m,
    MonadError QErr m,
    Tracing.MonadTrace m,
    HGL.MonadQueryLog m
  ) =>
  RequestId ->
  GQLReqUnparsed ->
  RootFieldAlias ->
  UserInfo ->
  Logger Hasura ->
  SourceConfig ->
  OnBaseMonad AgentClientT (Maybe (AnyBackend HGL.ExecutionStats), a) ->
  Maybe DataConnectorPreparedQuery ->
  ResolvedConnectionTemplate 'DataConnector ->
  m (DiffTime, a)
runDBQuery' requestId query fieldName _userInfo logger SourceConfig {..} action queryRequest _ = do
  void $ HGL.logQueryLog logger $ mkQueryLog query fieldName queryRequest requestId
  withElapsedTime
    . Tracing.newSpan ("Data Connector backend query for root field " <>> fieldName)
    . flip runAgentClientT (AgentClientContext logger _scEndpoint _scManager _scTimeoutMicroseconds)
    . fmap snd
    . runOnBaseMonad
    $ action

mkQueryLog ::
  GQLReqUnparsed ->
  RootFieldAlias ->
  Maybe DataConnectorPreparedQuery ->
  RequestId ->
  HGL.QueryLog
mkQueryLog gqlQuery fieldName maybeQuery requestId =
  HGL.QueryLog
    gqlQuery
    ((\query -> (fieldName, HGL.GeneratedQuery (encodePreparedQueryToJsonText query) J.Null)) <$> maybeQuery)
    requestId
    -- @QueryLogKindDatabase Nothing@ means that the backend doesn't support connection templates
    (HGL.QueryLogKindDatabase Nothing)

runDBQueryExplain' ::
  ( MonadIO m,
    MonadBaseControl IO m,
    MonadError QErr m,
    Tracing.MonadTrace m
  ) =>
  DBStepInfo 'DataConnector ->
  m EncJSON
runDBQueryExplain' (DBStepInfo _ SourceConfig {..} _ action _) =
  flip runAgentClientT (AgentClientContext nullLogger _scEndpoint _scManager _scTimeoutMicroseconds) $
    fmap arResult (runOnBaseMonad action)

runDBMutation' ::
  ( MonadIO m,
    MonadBaseControl IO m,
    MonadError QErr m,
    Tracing.MonadTrace m,
    HGL.MonadQueryLog m
  ) =>
  RequestId ->
  GQLReqUnparsed ->
  RootFieldAlias ->
  UserInfo ->
  Logger Hasura ->
  SourceConfig ->
  OnBaseMonad AgentClientT a ->
  Maybe DataConnectorPreparedQuery ->
  ResolvedConnectionTemplate 'DataConnector ->
  m (DiffTime, a)
runDBMutation' requestId query fieldName _userInfo logger SourceConfig {..} action queryRequest _ = do
  void $ HGL.logQueryLog logger $ mkQueryLog query fieldName queryRequest requestId
  withElapsedTime
    . Tracing.newSpan ("Data Connector backend mutation for root field " <>> fieldName)
    . flip runAgentClientT (AgentClientContext logger _scEndpoint _scManager _scTimeoutMicroseconds)
    . runOnBaseMonad
    $ action
