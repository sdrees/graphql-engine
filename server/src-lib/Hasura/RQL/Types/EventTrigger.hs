module Hasura.RQL.Types.EventTrigger
  ( CreateEventTriggerQuery(..)
  , SubscribeOpSpec(..)
  , SubscribeColumns(..)
  , TriggerName(..)
  , triggerNameToTxt
  , Ops(..)
  , EventId(..)
  , TriggerOpsDef(..)
  , EventTriggerConf(..)
  , RetryConf(..)
  , DeleteEventTriggerQuery(..)
  , RedeliverEventQuery(..)
  , InvokeEventTriggerQuery(..)
  -- , HeaderConf(..)
  -- , HeaderValue(..)
  -- , HeaderName
  , EventHeaderInfo(..)
  , WebhookConf(..)
  , WebhookConfInfo(..)
  , HeaderConf(..)

  , defaultRetryConf
  , defaultTimeoutSeconds
  ) where

import           Hasura.Prelude

import qualified Data.ByteString.Lazy               as LBS
import qualified Data.Text                          as T
import qualified Database.PG.Query                  as Q
import qualified Text.Regex.TDFA                    as TDFA

import           Data.Aeson
import           Data.Aeson.TH
import           Data.Text.Extended
import           Data.Text.NonEmpty

import qualified Hasura.Backends.Postgres.SQL.Types as PG

import           Hasura.Incremental                 (Cacheable)
import           Hasura.RQL.DDL.Headers
import           Hasura.RQL.Types.Backend
import           Hasura.RQL.Types.Common            (InputWebhook, SourceName, defaultSource)
import           Hasura.SQL.Backend


-- This change helps us create functions for the event triggers
-- without the function name being truncated by PG, since PG allows
-- for only 63 chars for identifiers.
-- Reasoning for the 42 characters:
-- 63 - (notify_hasura_) - (_INSERT | _UPDATE | _DELETE)
maxTriggerNameLength :: Int
maxTriggerNameLength = 42

-- | Unique name for event trigger.
newtype TriggerName = TriggerName { unTriggerName :: NonEmptyText }
  deriving (Show, Eq, Ord, Hashable, ToTxt, FromJSON, ToJSON, ToJSONKey
           , Q.ToPrepArg, Generic, NFData, Cacheable, Arbitrary, Q.FromCol)

triggerNameToTxt :: TriggerName -> Text
triggerNameToTxt = unNonEmptyText . unTriggerName

newtype EventId = EventId {unEventId :: Text}
  deriving (Show, Eq, Ord, Hashable, ToTxt, FromJSON, ToJSON, ToJSONKey, Q.FromCol, Q.ToPrepArg, Generic, Arbitrary, NFData, Cacheable)

data Ops = INSERT | UPDATE | DELETE | MANUAL deriving (Show)

data SubscribeColumns = SubCStar | SubCArray [PG.PGCol]
  deriving (Show, Eq, Generic)
instance NFData SubscribeColumns
instance Cacheable SubscribeColumns

instance FromJSON SubscribeColumns where
  parseJSON (String s) = case s of
                          "*" -> return SubCStar
                          _   -> fail "only * or [] allowed"
  parseJSON v@(Array _) = SubCArray <$> parseJSON v
  parseJSON _ = fail "unexpected columns"

instance ToJSON SubscribeColumns where
  toJSON SubCStar         = "*"
  toJSON (SubCArray cols) = toJSON cols

data SubscribeOpSpec
  = SubscribeOpSpec
  { sosColumns :: !SubscribeColumns
  , sosPayload :: !(Maybe SubscribeColumns)
  } deriving (Show, Eq, Generic)
instance NFData SubscribeOpSpec
instance Cacheable SubscribeOpSpec
$(deriveJSON hasuraJSON{omitNothingFields=True} ''SubscribeOpSpec)

defaultNumRetries :: Int
defaultNumRetries = 0

defaultRetryInterval :: Int
defaultRetryInterval = 10

defaultTimeoutSeconds:: Int
defaultTimeoutSeconds = 60

defaultRetryConf :: RetryConf
defaultRetryConf = RetryConf defaultNumRetries defaultRetryInterval (Just defaultTimeoutSeconds)

data RetryConf
  = RetryConf
  { rcNumRetries  :: !Int
  , rcIntervalSec :: !Int
  , rcTimeoutSec  :: !(Maybe Int)
  } deriving (Show, Eq, Generic)
instance NFData RetryConf
instance Cacheable RetryConf
$(deriveJSON hasuraJSON{omitNothingFields=True} ''RetryConf)

data EventHeaderInfo
  = EventHeaderInfo
  { ehiHeaderConf  :: !HeaderConf
  , ehiCachedValue :: !Text
  } deriving (Show, Eq, Generic)
instance NFData EventHeaderInfo
$(deriveToJSON hasuraJSON{omitNothingFields=True} ''EventHeaderInfo)

data WebhookConf = WCValue InputWebhook | WCEnv Text
  deriving (Show, Eq, Generic)
instance NFData WebhookConf
instance Cacheable WebhookConf

instance ToJSON WebhookConf where
  toJSON (WCValue w)  = toJSON w
  toJSON (WCEnv wEnv) = object ["from_env" .= wEnv ]

instance FromJSON WebhookConf where
  parseJSON (Object o) = WCEnv <$> o .: "from_env"
  parseJSON t@(String _) =
    case fromJSON t of
      Error s   -> fail s
      Success a -> pure $ WCValue a
  parseJSON _          = fail "one of string or object must be provided for webhook"

data WebhookConfInfo
  = WebhookConfInfo
  { wciWebhookConf :: !WebhookConf
  , wciCachedValue :: !Text
  } deriving (Show, Eq, Generic)
instance NFData WebhookConfInfo
$(deriveToJSON hasuraJSON{omitNothingFields=True} ''WebhookConfInfo)

data CreateEventTriggerQuery (b :: BackendType)
  = CreateEventTriggerQuery
  { cetqSource         :: !SourceName
  , cetqName           :: !TriggerName
  , cetqTable          :: !(TableName b)
  , cetqInsert         :: !(Maybe SubscribeOpSpec)
  , cetqUpdate         :: !(Maybe SubscribeOpSpec)
  , cetqDelete         :: !(Maybe SubscribeOpSpec)
  , cetqEnableManual   :: !(Maybe Bool)
  , cetqRetryConf      :: !(Maybe RetryConf)
  , cetqWebhook        :: !(Maybe InputWebhook)
  , cetqWebhookFromEnv :: !(Maybe Text)
  , cetqHeaders        :: !(Maybe [HeaderConf])
  , cetqReplace        :: !Bool
  } deriving (Generic)
deriving instance (Backend b) => Show (CreateEventTriggerQuery b)
deriving instance (Backend b) => Eq   (CreateEventTriggerQuery b)

instance Backend b => FromJSON (CreateEventTriggerQuery b) where
  parseJSON (Object o) = do
    sourceName      <- o .:? "source" .!= defaultSource
    name            <- o .:  "name"
    table           <- o .:  "table"
    insert          <- o .:? "insert"
    update          <- o .:? "update"
    delete          <- o .:? "delete"
    enableManual    <- o .:? "enable_manual" .!= False
    retryConf       <- o .:? "retry_conf"
    webhook         <- o .:? "webhook"
    webhookFromEnv  <- o .:? "webhook_from_env"
    headers         <- o .:? "headers"
    replace         <- o .:? "replace" .!= False
    let regex = "^[A-Za-z]+[A-Za-z0-9_\\-]*$" :: LBS.ByteString
        compiledRegex = TDFA.makeRegex regex :: TDFA.Regex
        isMatch = TDFA.match compiledRegex . T.unpack $ triggerNameToTxt name
    unless isMatch $
      fail "only alphanumeric and underscore and hyphens allowed for name"
    unless (T.length (triggerNameToTxt name) <= maxTriggerNameLength) $
      fail "event trigger name can be at most 42 characters"
    unless (any isJust [insert, update, delete] || enableManual) $
      fail "atleast one amongst insert/update/delete/enable_manual spec must be provided"
    case (webhook, webhookFromEnv) of
      (Just _, Nothing) -> return ()
      (Nothing, Just _) -> return ()
      (Just _, Just _)  -> fail "only one of webhook or webhook_from_env should be given"
      _                 ->   fail "must provide webhook or webhook_from_env"
    mapM_ checkEmptyCols [insert, update, delete]
    return $ CreateEventTriggerQuery sourceName name table insert update delete (Just enableManual) retryConf webhook webhookFromEnv headers replace
    where
      checkEmptyCols spec
        = case spec of
        Just (SubscribeOpSpec (SubCArray cols) _) -> when (null cols) (fail "found empty column specification")
        Just (SubscribeOpSpec _ (Just (SubCArray cols)) ) -> when (null cols) (fail "found empty payload specification")
        _ -> return ()
  parseJSON _ = fail "expecting an object"

instance Backend b => ToJSON (CreateEventTriggerQuery b) where
  toJSON = genericToJSON hasuraJSON{omitNothingFields=True}


-- | The table operations on which the event trigger will be invoked.
data TriggerOpsDef
  = TriggerOpsDef
  { tdInsert       :: !(Maybe SubscribeOpSpec)
  , tdUpdate       :: !(Maybe SubscribeOpSpec)
  , tdDelete       :: !(Maybe SubscribeOpSpec)
  , tdEnableManual :: !(Maybe Bool)
  } deriving (Show, Eq, Generic)
instance NFData TriggerOpsDef
instance Cacheable TriggerOpsDef
$(deriveJSON hasuraJSON{omitNothingFields=True} ''TriggerOpsDef)

data DeleteEventTriggerQuery (b :: BackendType)
  = DeleteEventTriggerQuery
  { detqSource :: !SourceName
  , detqName   :: !TriggerName
  } deriving (Generic)
deriving instance (Backend b) => Show (DeleteEventTriggerQuery b)
deriving instance (Backend b) => Eq   (DeleteEventTriggerQuery b)

instance Backend b => FromJSON (DeleteEventTriggerQuery b) where
  parseJSON = withObject "Object" $ \o ->
    DeleteEventTriggerQuery
      <$> o .:? "source" .!= defaultSource
      <*> o .: "name"

instance Backend b => ToJSON (DeleteEventTriggerQuery b) where
  toJSON = genericToJSON hasuraJSON{omitNothingFields=True}


data EventTriggerConf
  = EventTriggerConf
  { etcName           :: !TriggerName
  , etcDefinition     :: !TriggerOpsDef
  , etcWebhook        :: !(Maybe InputWebhook)
  , etcWebhookFromEnv :: !(Maybe Text)
  , etcRetryConf      :: !RetryConf
  , etcHeaders        :: !(Maybe [HeaderConf])
  } deriving (Show, Eq, Generic)
instance Cacheable EventTriggerConf

$(deriveJSON hasuraJSON{omitNothingFields=True} ''EventTriggerConf)


data RedeliverEventQuery (b :: BackendType)
  = RedeliverEventQuery
  { rdeqEventId :: !EventId
  , rdeqSource  :: !SourceName
  } deriving (Generic)
deriving instance (Backend b) => Show (RedeliverEventQuery b)
deriving instance (Backend b) => Eq   (RedeliverEventQuery b)

instance Backend b => FromJSON (RedeliverEventQuery b) where
  parseJSON = withObject "Object" $ \o ->
    RedeliverEventQuery
      <$> o .: "event_id"
      <*> o .:? "source" .!= defaultSource

instance Backend b => ToJSON (RedeliverEventQuery b) where
  toJSON = genericToJSON hasuraJSON{omitNothingFields=True}


data InvokeEventTriggerQuery (b :: BackendType)
  = InvokeEventTriggerQuery
  { ietqName    :: !TriggerName
  , ietqSource  :: !SourceName
  , ietqPayload :: !Value
  } deriving (Generic)
deriving instance (Backend b) => Show (InvokeEventTriggerQuery b)
deriving instance (Backend b) => Eq   (InvokeEventTriggerQuery b)

instance Backend b => FromJSON (InvokeEventTriggerQuery b) where
  parseJSON = withObject "Object" $ \o ->
    InvokeEventTriggerQuery
      <$> o .: "name"
      <*> o .:? "source" .!= defaultSource
      <*> o .: "payload"

instance Backend b => ToJSON (InvokeEventTriggerQuery b) where
  toJSON = genericToJSON hasuraJSON{omitNothingFields=True}
