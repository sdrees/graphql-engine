{-# LANGUAGE CPP #-}

module Hasura.Server.AppStateRef
  ( AppStateRef (..),
    AppState (..),
    initialiseAppStateRef,
    withSchemaCacheUpdate,
    readAppContextRef,
    readSchemaCacheRef,
    getAppContext,
    getSchemaCache,
    getSchemaCacheWithVersion,
    getSchemaCacheRef,

    -- * Utility
    logInconsistentMetadata,
  )
where

import Control.Concurrent.MVar.Lifted
import Control.Concurrent.STM qualified as STM
import Control.Monad.Trans.Control (MonadBaseControl)
import Data.IORef
import Hasura.App.State
import Hasura.Logging qualified as L
import Hasura.Prelude hiding (get, put)
import Hasura.RQL.DDL.Schema
import Hasura.RQL.Types.Metadata.Object
import Hasura.RQL.Types.SchemaCache
import Hasura.Server.Logging
import Hasura.Server.Metrics
  ( ServerMetrics (smSchemaCacheMetadataResourceVersion),
  )
import System.Metrics.Gauge (Gauge)
import System.Metrics.Gauge qualified as Gauge

-- | A mutable reference to a 'AppState', plus
--
-- * a write lock,
-- * update version tracking, and
-- * a gauge metric that tracks the metadata version of the 'SchemaCache'.
data AppStateRef impl = AppStateRef
  { -- | The idea behind explicit locking here is to
    --
    --   1. Allow maximum throughput for serving requests (/v1/graphql) (as each
    --      request reads the current schemacache)
    --   2. We don't want to process more than one request at any point of time
    --      which would modify the schema cache as such queries are expensive.
    --
    -- Another option is to consider removing this lock in place of `_scrCache ::
    -- MVar ...` if it's okay or in fact correct to block during schema update in
    -- e.g.  _wseGCtxMap. Vamshi says: It is theoretically possible to have a
    -- situation (in between building new schemacache and before writing it to
    -- the IORef) where we serve a request with a stale schemacache but I guess
    -- it is an okay trade-off to pay for a higher throughput (I remember doing a
    -- bunch of benchmarks to test this hypothesis).
    _scrLock :: MVar (),
    _scrCache :: AppState impl,
    -- | The gauge metric that tracks the current metadata version.
    --
    -- Invariant: This gauge must be updated via 'updateMetadataVersionGauge'
    -- whenever the _scrCache IORef is updated.
    _scrMetadataVersionGauge :: Gauge
  }

-- | A mutable reference to '(RebuildableSchemaCache, SchemaCacheVer)' and 'RebuildableAppContext'
data AppState impl = AppState
  { asSchemaCache :: IORef (RebuildableSchemaCache, SchemaCacheVer),
    asAppCtx :: IORef (RebuildableAppContext impl)
  }

-- | Build a new 'AppStateRef'
initialiseAppStateRef ::
  MonadIO m =>
  ServerMetrics ->
  RebuildableSchemaCache ->
  RebuildableAppContext impl ->
  m (AppStateRef impl)
initialiseAppStateRef serverMetrics rebuildableSchemaCache appCtx = liftIO $ do
  cacheLock <- newMVar ()
  !asSchemaCache <- newIORef (rebuildableSchemaCache, initSchemaCacheVer)
  !asAppCtx <- newIORef appCtx
  let cacheCell = AppState {..}
  let metadataVersionGauge = smSchemaCacheMetadataResourceVersion serverMetrics
  updateMetadataVersionGauge metadataVersionGauge rebuildableSchemaCache
  pure $ AppStateRef cacheLock cacheCell metadataVersionGauge

-- | Set the 'AppStateRef' to the 'RebuildableSchemaCache' produced by the
-- given action.
--
-- An internal lock ensures that at most one update to the 'AppStateRef' may
-- proceed at a time.
withSchemaCacheUpdate ::
  (MonadIO m, MonadBaseControl IO m) =>
  (AppStateRef impl) ->
  L.Logger L.Hasura ->
  Maybe (STM.TVar Bool) ->
  m (a, RebuildableSchemaCache) ->
  m a
withSchemaCacheUpdate (AppStateRef lock cacheRef metadataVersionGauge) logger mLogCheckerTVar action =
  withMVarMasked lock $ \() -> do
    (!res, !newSC) <- action
    liftIO $ do
      let AppState asSchemaCache _ = cacheRef
      -- update schemacache in IO reference
      modifyIORef' asSchemaCache $ \appStateSchemaCache ->
        let !newVer = incSchemaCacheVer (snd appStateSchemaCache)
         in (newSC, newVer)

      -- update metric with new metadata version
      updateMetadataVersionGauge metadataVersionGauge newSC

      let inconsistentObjectsList = scInconsistentObjs $ lastBuiltSchemaCache newSC
          logInconsistentMetadata' = logInconsistentMetadata logger inconsistentObjectsList
      -- log any inconsistent objects only once and not everytime this method is called
      case mLogCheckerTVar of
        Nothing -> do logInconsistentMetadata'
        Just logCheckerTVar -> do
          logCheck <- liftIO $ STM.readTVarIO logCheckerTVar
          if null inconsistentObjectsList && logCheck
            then do
              STM.atomically $ STM.writeTVar logCheckerTVar False
            else do
              unless (logCheck || null inconsistentObjectsList) $ do
                STM.atomically $ STM.writeTVar logCheckerTVar True
                logInconsistentMetadata'

    return res

-- | Read the contents of the 'AppStateRef' to get the latest 'RebuildableSchemaCache' and 'SchemaCacheVer'
readSchemaCacheRef :: AppStateRef impl -> IO (RebuildableSchemaCache, SchemaCacheVer)
readSchemaCacheRef scRef = readIORef <$> asSchemaCache $ _scrCache scRef

-- | Read the contents of the 'AppStateRef' to get the latest 'RebuildableAppContext'
readAppContextRef :: AppStateRef impl -> IO (RebuildableAppContext impl)
readAppContextRef scRef = readIORef <$> asAppCtx $ _scrCache scRef

-- | Utility function. Read the latest 'SchemaCache' from the 'AppStateRef'.
--
-- > getSchemaCache == fmap (lastBuiltSchemaCache . fst) . readAppStateRef
getSchemaCache :: AppStateRef impl -> IO SchemaCache
getSchemaCache asRef = lastBuiltSchemaCache . fst <$> readSchemaCacheRef asRef

getSchemaCacheWithVersion :: AppStateRef impl -> IO (SchemaCache, SchemaCacheVer)
getSchemaCacheWithVersion scRef = fmap (\(sc, ver) -> (lastBuiltSchemaCache sc, ver)) $ readSchemaCacheRef scRef

getSchemaCacheRef :: AppStateRef impl -> IORef (RebuildableSchemaCache, SchemaCacheVer)
getSchemaCacheRef = asSchemaCache . _scrCache

-- | Utility function. Read the latest 'AppContext' from the 'AppStateRef'.
getAppContext :: AppStateRef impl -> IO AppContext
getAppContext asRef = lastBuiltAppContext <$> readAppContextRef asRef

-- | Utility function
logInconsistentMetadata :: L.Logger L.Hasura -> [InconsistentMetadata] -> IO ()
logInconsistentMetadata logger objs =
  unless (null objs) $
    L.unLogger logger $
      mkInconsMetadataLog objs

-- Internal helper. Set the gauge metric to the metadata version of the schema
-- cache, if it exists.
updateMetadataVersionGauge :: MonadIO m => Gauge -> RebuildableSchemaCache -> m ()
updateMetadataVersionGauge metadataVersionGauge schemaCache = do
  let metadataVersion = scMetadataResourceVersion . lastBuiltSchemaCache $ schemaCache
  liftIO $ traverse_ (Gauge.set metadataVersionGauge . getMetadataResourceVersion) metadataVersion
