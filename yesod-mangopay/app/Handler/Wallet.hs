module Handler.Wallet where

import Import
import Web.MangoPay
import Yesod.MangoPay
import Control.Monad (join, liftM)
import Control.Arrow ((&&&))

-- | get wallet list
getWalletsR :: AnyUserID -> Handler Html
getWalletsR uid=do
  -- no paging, should be reasonable
  wallets<-runYesodMPTToken $ getAll $ listWallets uid
  defaultLayout $ do
        aDomId <- newIdent
        setTitleI MsgTitleWallets
        $(widgetFile "wallets")

-- | get wallet creation/edition form
getWalletR :: AnyUserID -> Handler Html
getWalletR uid=do
    mwid<-lookupGetParam "id"
    mwallet<-case mwid of
          Just wid->liftM Just $ runYesodMPTToken $ fetchWallet wid
          _->return Nothing
    (widget, enctype) <- generateFormPost $ walletForm mwallet
    defaultLayout $ do
        aDomId <- newIdent
        setTitleI MsgTitleWallet
        $(widgetFile "wallet")

-- | edit/create wallet
postWalletR :: AnyUserID -> Handler Html
postWalletR uid=do
  ((result, widget), enctype) <- runFormPost $ walletForm Nothing
  mwallet<-case result of
    FormSuccess w->do
            -- set the owner to current user
            let wo= w{wOwners=[uid]}
            catchMP (do
              wallet<-runYesodMPTToken $ storeWallet wo
              setMessageI MsgWalletDone
              return (Just wallet)
              )
              (\e->do
                setMessage $ toHtml $ show e
                return (Just wo)
              )    
    _ -> do
            setMessageI MsgErrorData
            return Nothing
  defaultLayout $ do
        aDomId <- newIdent
        setTitleI MsgTitleWallet
        $(widgetFile "wallet")
        
-- | form for wallet  
walletForm ::  HtmlForm Wallet
walletForm mwallet= renderDivs $ Wallet
    <$> aopt hiddenField "" (wId <$> mwallet)
    <*> pure (join $ wCreationDate <$> mwallet)        
    <*> aopt textField (localizedFS MsgWalletCustomData) (wTag <$> mwallet)
    <*> pure []
    <*> areq textField (localizedFS MsgWalletDescription) (wDescription <$> mwallet)
    <*> areq (selectFieldList (map (id &&& id) supportedCurrencies)) (disabledIfJust mwallet $ localizedFS MsgWalletCurrency) (wCurrency <$> mwallet)
    -- we can't edit the amount anyway, so we show it as disabled and return a const 0 value
    <*> (fmap (const $ Amount "EUR" 0) <$> aopt intField (disabled $ localizedFS MsgWalletBalance) (fmap aAmount <$> wBalance <$> mwallet))