{-# LANGUAGE DeriveDataTypeable, TypeFamilies, TemplateHaskell #-}
module Registry.DB.LibraryVersions (open, register, versions, latestUntagged, LibVer) where

import           Control.Applicative
import           Control.Monad.Error
import qualified Control.Monad.State  as State
import qualified Control.Monad.Reader as Reader
import           Data.Acid
import qualified Data.Binary          as Binary
import           Data.ByteString.Lazy (ByteString)
import qualified Data.SafeCopy        as SC
import           Data.Typeable
import qualified Data.Map             as Map
import qualified Data.List            as List
import           Model.Version

-- Data representation

type Library = String

data LibraryVersions = LibraryVersions !(Map.Map Library [Version])
    deriving (Typeable)

$(SC.deriveSafeCopy 0 'SC.base ''LibraryVersions)


-- Open

type LibVer = AcidState LibraryVersions

open :: IO LibVer
open = openLocalState (LibraryVersions Map.empty)


-- Transactions

acidRegister :: Library -> Version -> Update LibraryVersions ()
acidRegister library version =
    do LibraryVersions m <- State.get
       let m' = Map.insertWith (\[v] -> List.insertBy reverseOrder v) library [version] m
       State.put (LibraryVersions m')

acidVersions :: Library -> Query LibraryVersions (Maybe [Version])
acidVersions library =
    do LibraryVersions m <- Reader.ask
       return (Map.lookup library m)

$(makeAcidic ''LibraryVersions ['acidRegister, 'acidVersions])

register :: LibVer -> Library -> String -> ErrorT String IO ()
register db library rawVersion =
    case fromString rawVersion of
      Just version -> do
        liftIO $ update db (AcidRegister library version)
        return ()
      Nothing -> throwError $ unlines
                 [ "Could not register: " ++ rawVersion ++ " is not a valid version."
                 , "Versions must have one of the following formats: 0.1.2 or 0.1.2-tag"
                 ]

rawVersions :: LibVer -> Library -> ErrorT String IO (Maybe [Version])
rawVersions db library =
    liftIO $ query db (AcidVersions library)

versions :: LibVer -> Library -> ErrorT String IO ByteString
versions db library =
    do vers <- liftIO $ query db (AcidVersions library)
       return $ Binary.encode vers

latestUntagged :: LibVer -> Library -> ErrorT String IO Version
latestUntagged db library =
    do maybe <- rawVersions db library
       case maybe of
         Nothing -> throwError $ "Could not find a library named " ++ library ++ "!"
         Just vs ->
             case filter tagless vs of
               v:_ -> return v
               []  -> throwError $ unlines
                      [ "There is no untagged release of " ++ library
                      , "Try using one of the tagged releases: " ++ 
                        List.intercalate ", " (map show vs)
                      ]