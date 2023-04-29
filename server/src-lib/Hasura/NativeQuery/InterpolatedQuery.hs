{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Parser and prettyprinter for native query code.
module Hasura.NativeQuery.InterpolatedQuery
  ( NativeQueryArgumentName (..),
    InterpolatedItem (..),
    InterpolatedQuery (..),
    parseInterpolatedQuery,
    module Hasura.LogicalModel.NullableScalarType,
  )
where

import Autodocodec
import Autodocodec qualified as AC
import Data.Aeson (FromJSON, FromJSONKey, ToJSON, ToJSONKey)
import Data.Bifunctor (first)
import Data.Text qualified as T
import Hasura.LogicalModel.NullableScalarType (NullableScalarType (..), nullableScalarTypeMapCodec)
import Hasura.Prelude hiding (first)
import Language.Haskell.TH.Syntax (Lift)

newtype RawQuery = RawQuery {getRawQuery :: Text}
  deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)

instance HasCodec RawQuery where
  codec = AC.dimapCodec RawQuery getRawQuery codec

---------------------------------------

-- | A component of an interpolated query
data InterpolatedItem variable
  = -- | normal text
    IIText Text
  | -- | a captured variable
    IIVariable variable
  deriving stock (Eq, Ord, Show, Functor, Foldable, Data, Generic, Lift, Traversable)

-- | Converting an interpolated query back to text.
--   Should roundtrip with the 'parseInterpolatedQuery'.
ppInterpolatedItem :: InterpolatedItem NativeQueryArgumentName -> Text
ppInterpolatedItem (IIText t) = t
ppInterpolatedItem (IIVariable v) = "{{" <> getNativeQueryArgumentName v <> "}}"

deriving instance (Hashable variable) => Hashable (InterpolatedItem variable)

deriving instance (NFData variable) => NFData (InterpolatedItem variable)

---------------------------------------

-- | A list of stored procedure components representing a single stored procedure,
--   separating the variables from the text.
newtype InterpolatedQuery variable = InterpolatedQuery
  { getInterpolatedQuery :: [InterpolatedItem variable]
  }
  deriving newtype (Eq, Ord, Show, Generic)
  deriving stock (Data, Functor, Foldable, Lift, Traversable)

deriving newtype instance (Hashable variable) => Hashable (InterpolatedQuery variable)

deriving newtype instance (NFData variable) => NFData (InterpolatedQuery variable)

ppInterpolatedQuery :: InterpolatedQuery NativeQueryArgumentName -> Text
ppInterpolatedQuery (InterpolatedQuery parts) = foldMap ppInterpolatedItem parts

-- | We store the interpolated query as the user text and parse it back
--   when converting back to Haskell code.
instance v ~ NativeQueryArgumentName => HasCodec (InterpolatedQuery v) where
  codec =
    CommentCodec
      ("An interpolated query expressed in native code (SQL)")
      $ bimapCodec
        (first T.unpack . parseInterpolatedQuery)
        ppInterpolatedQuery
        textCodec

deriving via
  (Autodocodec (InterpolatedQuery NativeQueryArgumentName))
  instance
    v ~ NativeQueryArgumentName =>
    ToJSON (InterpolatedQuery v)

---------------------------------------

newtype NativeQueryArgumentName = NativeQueryArgumentName
  { getNativeQueryArgumentName :: Text
  }
  deriving newtype (Eq, Ord, Show, Hashable)
  deriving stock (Generic)

instance HasCodec NativeQueryArgumentName where
  codec = dimapCodec NativeQueryArgumentName getNativeQueryArgumentName codec

deriving newtype instance ToJSON NativeQueryArgumentName

deriving newtype instance FromJSON NativeQueryArgumentName

deriving newtype instance ToJSONKey NativeQueryArgumentName

deriving newtype instance FromJSONKey NativeQueryArgumentName

instance NFData NativeQueryArgumentName

-- | extract all of the `{{ variable }}` inside our query string
parseInterpolatedQuery ::
  Text ->
  Either Text (InterpolatedQuery NativeQueryArgumentName)
parseInterpolatedQuery =
  fmap
    ( InterpolatedQuery
        . mergeAdjacent
        . trashEmpties
    )
    . consumeString
    . T.unpack
  where
    trashEmpties = filter (/= IIText "")

    mergeAdjacent = \case
      (IIText a : IIText b : rest) ->
        mergeAdjacent (IIText (a <> b) : rest)
      (a : rest) -> a : mergeAdjacent rest
      [] -> []

    consumeString :: String -> Either Text [InterpolatedItem NativeQueryArgumentName]
    consumeString str =
      let (beforeCurly, fromCurly) = break (== '{') str
       in case fromCurly of
            ('{' : '{' : rest) ->
              (IIText (T.pack beforeCurly) :) <$> consumeVar rest
            ('{' : other) ->
              (IIText (T.pack (beforeCurly <> "{")) :) <$> consumeString other
            _other -> pure [IIText (T.pack beforeCurly)]

    consumeVar :: String -> Either Text [InterpolatedItem NativeQueryArgumentName]
    consumeVar str =
      let (beforeCloseCurly, fromClosedCurly) = break (== '}') str
       in case fromClosedCurly of
            ('}' : '}' : rest) ->
              (IIVariable (NativeQueryArgumentName $ T.pack beforeCloseCurly) :) <$> consumeString rest
            _ -> Left "Found '{{' without a matching closing '}}'"
