{-# LANGUAGE DeriveDataTypeable, ScopedTypeVariables, OverloadedStrings, FlexibleContexts, FlexibleInstances #-}
-- | handle payins
module Web.MangoPay.Payins where

import Web.MangoPay.Monad
import Web.MangoPay.Types
import Web.MangoPay.Users
import Web.MangoPay.Wallets

import Data.Conduit
import Data.Text
import Data.Typeable (Typeable)
import Data.Aeson
import Data.Time.Clock.POSIX (POSIXTime)
import Control.Applicative
import qualified Network.HTTP.Types as HT

-- | create or edit a bankwire
storeBankWire ::  (MonadBaseControl IO m, MonadResource m) => BankWire -> AccessToken -> MangoPayT m BankWire
storeBankWire bw at= do
  url<-getClientURL "/payins/bankwire/direct" 
  postExchange url (Just at) bw
   
-- | fetch a bank wire from its ID
fetchBankWire :: (MonadBaseControl IO m, MonadResource m) => BankWireID -> AccessToken -> MangoPayT m BankWire
fetchBankWire bwid at=do
        url<-getClientURLMultiple ["/payins/",bwid]
        req<-getGetRequest url (Just at) ([]::HT.Query)
        getJSONResponse req    

-- | create or edit a direct card pay in
storeCardPayin ::  (MonadBaseControl IO m, MonadResource m) => CardPayin -> AccessToken -> MangoPayT m CardPayin
storeCardPayin cp at= do
  url<-getClientURL "/payins/card/direct" 
  postExchange url (Just at) cp
   
-- | fetch a direct pay in from its ID
fetchCardPayin :: (MonadBaseControl IO m, MonadResource m) => CardPayinID -> AccessToken -> MangoPayT m CardPayin
fetchCardPayin cpid at=do
        url<-getClientURLMultiple ["/payins/",cpid]
        req<-getGetRequest url (Just at) ([]::HT.Query)
        getJSONResponse req   
     
-- | bank account details
data BankAccount = BankAccount {
  baType :: Text
  ,baOwnerName :: Text
  ,baOwnerAddress :: Maybe Text
  ,baIBAN :: Text
  ,baBIC :: Text
} deriving (Show,Read,Eq,Ord,Typeable)

-- | to json as per MangoPay format        
instance ToJSON BankAccount where
        toJSON ba=object ["Type" .= baType ba,"OwnerName" .= baOwnerName ba
          ,"OwnerAddress" .= baOwnerAddress ba,"IBAN" .= baIBAN ba,"BIC" .= baBIC ba]

-- | from json as per MangoPay format 
instance FromJSON BankAccount where
        parseJSON (Object v) =BankAccount <$>
                         v .: "Type" <*>
                         v .: "OwnerName" <*>
                         v .:? "OwnerAddress" <*>
                         v .: "IBAN" <*>
                         v .: "BIC" 
        parseJSON _=fail "BankAccount"
   
-- | type of transaction
data TransactionType = PAY_IN 
  | PAY_OUT
  | TRANSFER 
  deriving (Show,Read,Eq,Ord,Bounded,Enum,Typeable)

-- | to json as per MangoPay format
instance ToJSON TransactionType where
        toJSON =toJSON . show

-- | from json as per MangoPay format
instance FromJSON TransactionType where
        parseJSON (String s)=pure $ read $ unpack s
        parseJSON _ =fail "TransactionType"

data TransactionNature =  REGULAR -- ^ just as you created the object
 | REFUND -- ^ the transaction has been refunded
 | REPUDIATION -- ^ the transaction has been repudiated
  deriving (Show,Read,Eq,Ord,Bounded,Enum,Typeable)

-- | to json as per MangoPay format
instance ToJSON TransactionNature where
        toJSON =toJSON . show

-- | from json as per MangoPay format
instance FromJSON TransactionNature where
        parseJSON (String s)=pure $ read $ unpack s
        parseJSON _ =fail "TransactionNature"

data PaymentExecution = WEB  -- ^ through a web interface
 | DIRECT -- ^ with a tokenized card
  deriving (Show,Read,Eq,Ord,Bounded,Enum,Typeable)

-- | to json as per MangoPay format
instance ToJSON PaymentExecution where
        toJSON =toJSON . show

-- | from json as per MangoPay format
instance FromJSON PaymentExecution where
        parseJSON (String s)=pure $ read $ unpack s
        parseJSON _ =fail "PaymentExecution"

-- | helper function to create a new bank wire with the needed information
mkBankWire :: AnyUserID -> AnyUserID -> WalletID -> Amount -> Amount -> BankWire
mkBankWire aid uid wid amount fees= BankWire Nothing Nothing Nothing aid uid Nothing
  wid Nothing Nothing Nothing amount fees Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing

-- | id of a bankwire
type BankWireID=Text

-- | a bank wire
-- there are a lot of common fields between all kinds of payments
-- so this could probably become a "Payment" type
data BankWire=BankWire {
  bwId :: Maybe BankWireID
  ,bwCreationDate :: Maybe POSIXTime
  ,bwTag :: Maybe Text -- ^  custom data
  ,bwAuthorId  :: AnyUserID -- ^   The user ID of the author
  ,bwCreditedUserId  :: AnyUserID -- ^  It represents the amount credited on the targeted e-wallet.
  ,bwFees :: Maybe Amount -- ^  It represents your fees taken on the DebitedFundsDebitedFunds – Fees = CreditedFunds (amount received on wallet)
  ,bwCreditedWalletId :: WalletID -- ^ The ID of the credited wallet
  ,bwDebitedWalletId :: Maybe WalletID -- ^  The ID of the debited wallet
  ,bwDebitedFunds  :: Maybe Amount -- ^  It represents the amount debited from the bank account.
  ,bwCreditedFunds :: Maybe Amount -- ^   It represents the amount credited on the targeted e-wallet.
  ,bwDeclaredDebitedFunds  :: Amount -- ^   It represents the expected amount by the platform before that the user makes the payment.
  ,bwDeclaredFees  :: Amount -- ^   It represents the expected fees amount by the platform before that the user makes the payment.
  ,bwWireReference :: Maybe Text -- ^ It is a reference generated by MANGOPAY and displayed to the user by the platform. The user have to indicate it into the bank wire.
  ,bwBankAccount :: Maybe BankAccount -- ^ The bank account is generated by MANGOPAY and displayed to the user.
  ,bwStatus  :: Maybe TransferStatus -- ^  The status of the payment
  ,bwResultCode  :: Maybe Text -- ^  The transaction result code
  ,bwResultMessage :: Maybe Text -- ^  The transaction result Message
  ,bwExecutionDate :: Maybe POSIXTime --   The date when the payment is processed
  ,bwType  :: Maybe TransactionType -- ^  The type of the transaction
  ,bwNature  :: Maybe TransactionNature -- ^  The nature of the transaction:
  ,bwPaymentType :: Maybe Text -- ^  The type of the payment (which type of mean of payment is used).
  ,bwExecutionType :: Maybe PaymentExecution -- ^  How the payment has been executed:
  } deriving (Show,Eq,Ord,Typeable)

-- | to json as per MangoPay format        
instance ToJSON BankWire where
        toJSON bw=object ["Tag" .= bwTag bw,"AuthorId" .= bwAuthorId  bw
          ,"CreditedUserId" .= bwCreditedUserId bw,"CreditedWalletId" .= bwCreditedWalletId bw
          ,"DeclaredDebitedFunds" .= bwDeclaredDebitedFunds bw,"DeclaredFees" .= bwDeclaredFees bw]

-- | from json as per MangoPay format 
instance FromJSON BankWire where
        parseJSON (Object v) =BankWire <$>
                         v .: "Id" <*>
                         v .: "CreationDate" <*>
                         v .:? "Tag" <*>
                         v .: "AuthorId" <*>
                         v .: "CreditedUserId" <*>
                         v .:? "Fees"  <*>
                         v .: "CreditedWalletId"  <*>
                         v .:? "DebitedWalletId"  <*>
                         v .:? "DebitedFunds"  <*>
                         v .:? "CreditedFunds"  <*>
                         v .: "DeclaredDebitedFunds"  <*>
                         v .: "DeclaredFees"  <*>
                         v .:? "WireReference"  <*>
                         v .:? "BankAccount"  <*>
                         v .:? "Status" <*>
                         v .:? "ResultCode" <*>
                         v .:? "ResultMessage" <*>
                         v .:? "ExecutionDate" <*>
                         v .:? "Type" <*>
                         v .:? "Nature" <*>
                         v .:? "PaymentType" <*>
                         v .:? "ExecutionType" 
        parseJSON _=fail "BankWire"  
 
-- | ID of a direct pay in
type CardPayinID=Text 
  
-- | helper function to create a new direct payin with the needed information
mkCardPayin :: AnyUserID -> AnyUserID -> WalletID -> Amount -> Amount -> Text -> CardID -> CardPayin
mkCardPayin aid uid wid amount fees url cid= CardPayin Nothing Nothing Nothing aid uid fees
  wid Nothing amount Nothing (Just url) Nothing Nothing cid Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing
  
  
-- | direct pay in via registered card
data CardPayin=CardPayin {
  cpId :: Maybe CardPayinID
  ,cpCreationDate :: Maybe POSIXTime
  ,cpTag :: Maybe Text -- ^  custom data
  ,cpAuthorId  :: AnyUserID -- ^   The user ID of the author
  ,cpCreditedUserId  :: AnyUserID -- ^  It represents the amount credited on the targeted e-wallet.
  ,cpFees :: Amount -- ^  It represents your fees taken on the DebitedFundsDebitedFunds – Fees = CreditedFunds (amount received on wallet)
  ,cpCreditedWalletId :: WalletID -- ^ The ID of the credited wallet
  ,cpDebitedWalletId :: Maybe WalletID -- ^  The ID of the debited wallet
  ,cpDebitedFunds  :: Amount -- ^  It represents the amount debited from the bank account.
  ,cpCreditedFunds :: Maybe Amount -- ^   It represents the amount credited on the targeted e-wallet.
  ,cpSecureModeReturnURL :: Maybe Text -- ^ This URL will be used in case the SecureMode is activated.
  ,cpSecureMode :: Maybe Text -- ^ The SecureMode correspond to « 3D secure » for CB Visa and MasterCard or « Amex Safe Key » for American Express. This field lets you activate it manually.
  ,cpSecureModeRedirectURL :: Maybe Text -- ^ This URL will be used in case the SecureMode is activated.
  ,cpCardId :: CardID -- ^ The ID of the registered card (Got through CardRegistration object)
  ,cpStatus  :: Maybe TransferStatus -- ^  The status of the payment
  ,cpResultCode  :: Maybe Text -- ^  The transaction result code
  ,cpResultMessage :: Maybe Text -- ^  The transaction result Message
  ,cpExecutionDate :: Maybe POSIXTime --   The date when the payment is processed
  ,cpType  :: Maybe TransactionType -- ^  The type of the transaction
  ,cpNature  :: Maybe TransactionNature -- ^  The nature of the transaction:
  ,cpPaymentType :: Maybe Text -- ^  The type of the payment (which type of mean of payment is used).
  ,cpExecutionType :: Maybe PaymentExecution -- ^  How the payment has been executed:
  } deriving (Show,Eq,Ord,Typeable)
  
-- | to json as per MangoPay format        
instance ToJSON CardPayin where
        toJSON cp=object ["Tag" .= cpTag cp,"AuthorId" .= cpAuthorId  cp
          ,"CreditedUserId" .= cpCreditedUserId cp,"CreditedWalletId" .= cpCreditedWalletId cp
          ,"DebitedFunds" .= cpDebitedFunds cp,"Fees" .= cpFees cp,"CardID" .= cpCardId cp
          ,"SecureModeReturnURL" .= cpSecureModeReturnURL cp
          ,"SecureMode" .= cpSecureMode cp]

-- | from json as per MangoPay format 
instance FromJSON CardPayin where
        parseJSON (Object v) =CardPayin <$>
                         v .: "Id" <*>
                         v .: "CreationDate" <*>
                         v .:? "Tag" <*>
                         v .: "AuthorId" <*>
                         v .: "CreditedUserId" <*>
                         v .: "Fees"  <*>
                         v .: "CreditedWalletId"  <*>
                         v .:? "DebitedWalletId"  <*>
                         v .: "DebitedFunds"  <*>
                         v .:? "CreditedFunds"  <*>
                         v .:? "SecureModeReturnURL" <*>
                         v .:? "SecureModeRedirectURL" <*>
                         v .:? "SecureMode" <*>
                         v .: "CardId" <*>
                         v .:? "Status" <*>
                         v .:? "ResultCode" <*>
                         v .:? "ResultMessage" <*>
                         v .:? "ExecutionDate" <*>
                         v .:? "Type" <*>
                         v .:? "Nature" <*>
                         v .:? "PaymentType" <*>
                         v .:? "ExecutionType" 
        parseJSON _=fail "CardPayin"   
   