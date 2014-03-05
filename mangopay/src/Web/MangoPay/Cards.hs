{-# LANGUAGE DeriveDataTypeable, ScopedTypeVariables, OverloadedStrings, FlexibleContexts, FlexibleInstances, PatternGuards #-}
-- | handle cards
module Web.MangoPay.Cards where

import Web.MangoPay.Documents
import Web.MangoPay.Monad
import Web.MangoPay.Types
import Web.MangoPay.Users

import Data.Conduit
import Data.Text
import Data.Typeable (Typeable)
import Data.Aeson
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import Control.Applicative
import qualified Network.HTTP.Types as HT

import qualified Network.HTTP.Conduit as H
import Control.Monad.IO.Class (liftIO)
import qualified Data.Conduit.List as EL (consume)
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString as BS

import qualified Data.HashMap.Lazy as HM
import Control.Exception.Base (throw)

type CardRegistrationID=Text

-- | perform the full registration of a card
fullRegistration :: (MonadBaseControl IO m, MonadResource m) => AnyUserID -> Currency -> CardInfo -> AccessToken -> MangoPayT m CardRegistration
fullRegistration uid currency cardInfo at=do
  -- create registration
  let cr1=mkCardRegistration uid currency
  cr2<-storeCardRegistration cr1 at
  -- register it
  cr3<-registerCard cardInfo cr2
  -- save registered version
  storeCardRegistration cr3 at
  

-- | create or edit a card registration
storeCardRegistration ::  (MonadBaseControl IO m, MonadResource m) => CardRegistration -> AccessToken -> MangoPayT m CardRegistration
storeCardRegistration cr at= 
        case crId cr of
                Nothing-> do
                        url<-getClientURL "/cardregistrations"
                        postExchange url (Just at) cr
                Just i-> do
                        url<-getClientURLMultiple ["/cardregistrations/",i]
                        let Object m=toJSON cr
                        putExchange url (Just at) $ Object $ HM.filterWithKey (\k _->k=="RegistrationData") m

-- | credit card information
data CardInfo = CardInfo {
  ciNumber :: Text
  ,ciExpire :: Text
  ,ciCSC :: Text
  } deriving (Show,Read,Eq,Ord,Typeable)

-- | register a card with the registration URL
registerCard :: (MonadBaseControl IO m, MonadResource m) => CardInfo -> CardRegistration -> MangoPayT m CardRegistration
registerCard ci cr |
  Just url <- crCardRegistrationURL cr,
  Just pre <- crPreregistrationData cr,
  Just ak <- crAccessKey cr=do
    req <-liftIO $ H.parseUrl $ unpack url  
    mgr<-getManager
    let b=HT.renderQuery False $ HT.toQuery [
            "accessKeyRef" ?+ ak
            ,"data" ?+ pre
            ,"cardNumber" ?+ ciNumber ci
            ,"cardExpirationDate" ?+ ciExpire ci
            ,"cardCvx" ?+ ciCSC ci]
    let req'=req {H.method=HT.methodPost
         , H.requestHeaders=[("content-type","application/x-www-form-urlencoded")]
         , H.requestBody=H.RequestBodyBS b}             
    res<- H.http req' mgr
    reg <- H.responseBody res $$+- EL.consume
    let t=TE.decodeUtf8 $ BS.concat reg
    if "data=" `isPrefixOf` t 
      then return cr{crRegistrationData=Just t}
      else do
        pt<-liftIO getPOSIXTime
        throw $ MpAppException $ MpError "" "RegistrationError" t $ Just pt            
registerCard _ _=do
  pt<-liftIO getPOSIXTime
  throw $ MpAppException $ MpError "" "IllegalState" "CardRegistration not ready" $ Just pt            
                
-- | helper function to create a new card registration
mkCardRegistration :: AnyUserID -> Currency -> CardRegistration
mkCardRegistration uid currency=CardRegistration Nothing Nothing Nothing uid currency Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing

-- | a card registration
data CardRegistration = CardRegistration {
  crId :: Maybe CardRegistrationID -- ^ The Id of the object
  ,crCreationDate  :: Maybe POSIXTime -- ^ The creation date of the object
  ,crTag :: Maybe Text -- ^  Custom data
  ,crUserId  :: AnyUserID -- ^  The ID of the author
  ,crCurrency  :: Currency -- ^ The currency of the card registrated
  ,crAccessKey :: Maybe Text -- ^ This key has to be sent with the card details and the PreregistrationData
  ,crPreregistrationData  :: Maybe Text -- ^  This passphrase has to be sent with the card details and the AccessKey
  ,crCardRegistrationURL  :: Maybe Text -- ^  The URL where to POST the card details, the AccessKey and PreregistrationData
  ,crRegistrationData   :: Maybe Text -- ^  You get the CardRegistrationData once you posted the card details, the AccessKey and PreregistrationData
  ,crCardType   :: Maybe Text -- ^  « CB_VISA_MASTERCARD » is the only value available yet
  ,crCardId   :: Maybe CardID -- ^  You get the CardId (to process payments) once you edited the CardRegistration Object with the RegistrationData
  ,crResultCode   :: Maybe Text -- ^  The result code of the object
  ,crResultMessage  :: Maybe Text -- ^  The message explaining the result code
  ,crStatus  :: Maybe DocumentStatus -- ^ The status of the object.
} deriving (Show,Eq,Ord,Typeable)


-- | to json as per MangoPay format        
instance ToJSON CardRegistration where
        toJSON cr=object ["Tag" .= crTag cr,"UserId" .= crUserId cr
          ,"Currency" .= crCurrency cr,"RegistrationData" .= crRegistrationData cr
          ,"CardRegistrationURL" .= crCardRegistrationURL cr]

-- | from json as per MangoPay format 
instance FromJSON CardRegistration where
        parseJSON (Object v) =CardRegistration <$>
                         v .: "Id" <*>
                         v .: "CreationDate" <*>
                         v .:? "Tag" <*>
                         v .: "UserId" <*>
                         v .: "Currency" <*>
                         v .:? "AccessKey"  <*>
                         v .:? "PreregistrationData"  <*>
                         v .:? "CardRegistrationURL"  <*>
                         v .:? "RegistrationData"  <*>
                         v .:? "CardType"  <*>
                         v .:? "CardId"  <*>
                         v .:? "ResultCode"  <*>
                         v .:? "ResultMessage"  <*>
                         v .:? "Status"  
        parseJSON _=fail "CardRegistration"  