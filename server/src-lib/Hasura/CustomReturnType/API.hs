{-# LANGUAGE UndecidableInstances #-}

-- | Define and handle v1/metadata API operations to track, untrack, and get custom return types.
module Hasura.CustomReturnType.API
  ( GetCustomReturnType (..),
    TrackCustomReturnType (..),
    UntrackCustomReturnType (..),
    runGetCustomReturnType,
    runTrackCustomReturnType,
    runUntrackCustomReturnType,
    dropCustomReturnTypeInMetadata,
    module Hasura.CustomReturnType.Types,
  )
where

import Autodocodec (HasCodec)
import Autodocodec qualified as AC
import Control.Lens (Traversal', has, preview, (^?))
import Data.Aeson
import Data.HashMap.Strict.InsOrd qualified as InsOrd
import Data.HashMap.Strict.InsOrd.Extended qualified as OMap
import Data.Text.Extended (toTxt, (<<>))
import Hasura.Base.Error
import Hasura.CustomReturnType.Metadata (CustomReturnTypeMetadata (..))
import Hasura.CustomReturnType.Types (CustomReturnTypeName)
import Hasura.EncJSON
import Hasura.LogicalModel.Types (NullableScalarType, nullableScalarTypeMapCodec)
import Hasura.Metadata.DTO.Utils (codecNamePrefix)
import Hasura.Prelude
import Hasura.RQL.Types.Backend (Backend (..))
import Hasura.RQL.Types.Common (SourceName, sourceNameToText, successMsg)
import Hasura.RQL.Types.Metadata
import Hasura.RQL.Types.Metadata.Backend
import Hasura.RQL.Types.Metadata.Object
import Hasura.RQL.Types.SchemaCache.Build
import Hasura.SQL.AnyBackend qualified as AB
import Hasura.SQL.Backend
import Hasura.Server.Init.FeatureFlag as FF
import Hasura.Server.Types (HasServerConfigCtx (..), ServerConfigCtx (..))

-- | Default implementation of the 'track_custom_return_type' request payload.
data TrackCustomReturnType (b :: BackendType) = TrackCustomReturnType
  { tctSource :: SourceName,
    tctName :: CustomReturnTypeName,
    tctDescription :: Maybe Text,
    tctFields :: InsOrd.InsOrdHashMap (Column b) (NullableScalarType b)
  }

instance (Backend b) => HasCodec (TrackCustomReturnType b) where
  codec =
    AC.CommentCodec
      ("A request to track a custom return type")
      $ AC.object (codecNamePrefix @b <> "TrackCustomReturnType")
      $ TrackCustomReturnType
        <$> AC.requiredField "source" sourceDoc
          AC..= tctSource
        <*> AC.requiredField "name" rootFieldDoc
          AC..= tctName
        <*> AC.optionalField "description" descriptionDoc
          AC..= tctDescription
        <*> AC.requiredFieldWith "fields" nullableScalarTypeMapCodec fieldsDoc
          AC..= tctFields
    where
      sourceDoc = "The source in which this custom return type should be tracked"
      rootFieldDoc = "Root field name for the custom return type"
      fieldsDoc = "Return type of the expression"
      descriptionDoc = "A description of the query which appears in the graphql schema"

deriving via
  (AC.Autodocodec (TrackCustomReturnType b))
  instance
    (Backend b) => FromJSON (TrackCustomReturnType b)

deriving via
  (AC.Autodocodec (TrackCustomReturnType b))
  instance
    (Backend b) => ToJSON (TrackCustomReturnType b)

-- | Validate a custom return type and extract the custom return type info from the request.
customTypeTrackToMetadata ::
  forall b.
  TrackCustomReturnType b ->
  CustomReturnTypeMetadata b
customTypeTrackToMetadata TrackCustomReturnType {..} =
  CustomReturnTypeMetadata
    { _ctmName = tctName,
      _ctmFields = tctFields,
      _ctmSelectPermissions = mempty,
      _ctmDescription = tctDescription
    }

-- | API payload for the 'get_custom_return_type' endpoint.
data GetCustomReturnType (b :: BackendType) = GetCustomReturnType
  { glmSource :: SourceName
  }

deriving instance Backend b => Show (GetCustomReturnType b)

deriving instance Backend b => Eq (GetCustomReturnType b)

instance Backend b => FromJSON (GetCustomReturnType b) where
  parseJSON = withObject "GetCustomReturnType" $ \o -> do
    glmSource <- o .: "source"
    pure GetCustomReturnType {..}

instance Backend b => ToJSON (GetCustomReturnType b) where
  toJSON GetCustomReturnType {..} =
    object
      [ "source" .= glmSource
      ]

-- | Handler for the 'get_custom_return_type' endpoint.
runGetCustomReturnType ::
  forall b m.
  ( BackendMetadata b,
    MetadataM m,
    HasServerConfigCtx m,
    MonadIO m,
    MonadError QErr m
  ) =>
  GetCustomReturnType b ->
  m EncJSON
runGetCustomReturnType q = do
  throwIfFeatureDisabled

  metadata <- getMetadata

  let customTypes :: Maybe (CustomReturnTypes b)
      customTypes = metadata ^? metaSources . ix (glmSource q) . toSourceMetadata . smCustomReturnTypes @b

  pure (encJFromJValue (OMap.elems <$> customTypes))

-- | Handler for the 'track_custom_return_type' endpoint. The type 'TrackCustomReturnType b'
-- (appearing here in wrapped as 'BackendTrackCustomReturnType b' for 'AnyBackend'
-- compatibility) is defined in 'class CustomReturnTypeMetadata'.
runTrackCustomReturnType ::
  forall b m.
  ( BackendMetadata b,
    CacheRWM m,
    MetadataM m,
    MonadError QErr m,
    HasServerConfigCtx m,
    MonadIO m
  ) =>
  TrackCustomReturnType b ->
  m EncJSON
runTrackCustomReturnType trackCustomReturnTypeRequest = do
  throwIfFeatureDisabled

  sourceMetadata <-
    maybe (throw400 NotFound $ "Source " <> sourceNameToText source <> " not found.") pure
      . preview (metaSources . ix source . toSourceMetadata @b)
      =<< getMetadata

  let (metadata :: CustomReturnTypeMetadata b) = customTypeTrackToMetadata trackCustomReturnTypeRequest

  let fieldName = _ctmName metadata
      metadataObj =
        MOSourceObjId source $
          AB.mkAnyBackend $
            SMOCustomReturnType @b fieldName
      existingCustomReturnTypes = OMap.keys (_smCustomReturnTypes sourceMetadata)

  when (fieldName `elem` existingCustomReturnTypes) do
    throw400 AlreadyTracked $ "Logical model '" <> toTxt fieldName <> "' is already tracked."

  buildSchemaCacheFor metadataObj $
    MetadataModifier $
      (metaSources . ix source . toSourceMetadata @b . smCustomReturnTypes)
        %~ OMap.insert fieldName metadata

  pure successMsg
  where
    source = tctSource trackCustomReturnTypeRequest

-- | API payload for the 'untrack_custom_return_type' endpoint.
data UntrackCustomReturnType (b :: BackendType) = UntrackCustomReturnType
  { utctSource :: SourceName,
    utctName :: CustomReturnTypeName
  }

deriving instance Show (UntrackCustomReturnType b)

deriving instance Eq (UntrackCustomReturnType b)

instance FromJSON (UntrackCustomReturnType b) where
  parseJSON = withObject "UntrackCustomReturnType" $ \o -> do
    utctSource <- o .: "source"
    utctName <- o .: "name"
    pure UntrackCustomReturnType {..}

instance ToJSON (UntrackCustomReturnType b) where
  toJSON UntrackCustomReturnType {..} =
    object
      [ "source" .= utctSource,
        "name" .= utctName
      ]

-- | Handler for the 'untrack_custom_return_type' endpoint.
runUntrackCustomReturnType ::
  forall b m.
  ( BackendMetadata b,
    MonadError QErr m,
    CacheRWM m,
    MetadataM m
  ) =>
  UntrackCustomReturnType b ->
  m EncJSON
runUntrackCustomReturnType q = do
  -- we do not check for feature flag here as we always want users to be able
  -- to remove custom return types if they'd like
  assertCustomReturnTypeExists @b source fieldName

  let metadataObj =
        MOSourceObjId source $
          AB.mkAnyBackend $
            SMOCustomReturnType @b fieldName

  buildSchemaCacheFor metadataObj $
    dropCustomReturnTypeInMetadata @b source fieldName

  pure successMsg
  where
    source = utctSource q
    fieldName = utctName q

dropCustomReturnTypeInMetadata :: forall b. BackendMetadata b => SourceName -> CustomReturnTypeName -> MetadataModifier
dropCustomReturnTypeInMetadata source rootFieldName = do
  MetadataModifier $
    metaSources . ix source . toSourceMetadata @b . smCustomReturnTypes
      %~ OMap.delete rootFieldName

-- | check feature flag is enabled before carrying out any actions
throwIfFeatureDisabled :: (HasServerConfigCtx m, MonadIO m, MonadError QErr m) => m ()
throwIfFeatureDisabled = do
  configCtx <- askServerConfigCtx
  let CheckFeatureFlag runCheckFeatureFlag = _sccCheckFeatureFlag configCtx

  enableCustomReturnTypes <- liftIO (runCheckFeatureFlag FF.logicalModelInterface)

  unless enableCustomReturnTypes (throw500 "CustomReturnTypes is disabled!")

-- | Check whether a custom return type with the given root field name exists for
-- the given source.
assertCustomReturnTypeExists :: forall b m. (Backend b, MetadataM m, MonadError QErr m) => SourceName -> CustomReturnTypeName -> m ()
assertCustomReturnTypeExists sourceName rootFieldName = do
  metadata <- getMetadata

  let sourceMetadataTraversal :: Traversal' Metadata (SourceMetadata b)
      sourceMetadataTraversal = metaSources . ix sourceName . toSourceMetadata @b

  sourceMetadata <-
    preview sourceMetadataTraversal metadata
      `onNothing` throw400 NotFound ("Source " <> sourceName <<> " not found.")

  let desiredCustomReturnType :: Traversal' (SourceMetadata b) (CustomReturnTypeMetadata b)
      desiredCustomReturnType = smCustomReturnTypes . ix rootFieldName

  unless (has desiredCustomReturnType sourceMetadata) do
    throw400 NotFound ("Logical model " <> rootFieldName <<> " not found in source " <> sourceName <<> ".")
