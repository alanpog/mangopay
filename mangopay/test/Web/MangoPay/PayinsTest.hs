{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -F -pgmF htfpp #-}
-- | test payins
module Web.MangoPay.PayinsTest where

import Web.MangoPay
import Web.MangoPay.TestUtils

import Data.Maybe (isJust, fromJust)
import Test.Framework
import Test.HUnit (Assertion)

-- | test bankwire
test_BankWire :: Assertion
test_BankWire=do
  us<-testMP $ listUsers (Just $ Pagination 1 1)
  assertEqual 1 (length us)
  let uid=urId $ head us
  let w=Wallet Nothing Nothing (Just "custom") [uid] "my wallet" "EUR" Nothing 
  w2<-testMP $ storeWallet w
  assertBool (isJust $ wId w2)
  let bw1=mkBankWire uid uid (fromJust $ wId w2) (Amount "EUR" 100) (Amount "EUR" 1)
  bw2<-testMP $ storeBankWire bw1
  assertBool (isJust $ bwId bw2)
  assertBool (isJust $ bwBankAccount bw2)
  bw3<-testMP $ fetchBankWire (fromJust $ bwId bw2)
  assertEqual (bwId bw2) (bwId bw3)
  
-- | test a successful card pay in
test_CardOK :: Assertion
test_CardOK = do
  us<-testMP $ listUsers (Just $ Pagination 1 1)
  assertEqual 1 (length us)
  let uid=urId $ head us
  let ci=CardInfo "4970100000000154" "1220" "123"
  cr<-testMP $ fullRegistration uid "EUR" ci
  assertBool (isJust $ crCardId cr)
  let cid=fromJust $ crCardId cr
  let w=Wallet Nothing Nothing (Just "custom") [uid] "my wallet" "EUR" Nothing 
  w2<-testMP $ storeWallet w
  assertBool (isJust $ wId w2)
  let wid=fromJust $ wId w2
  let cp=mkCardPayin uid uid wid (Amount "EUR" 333) (Amount "EUR" 1) "http://dummy" cid
  cp2<-testMP $ storeCardPayin cp
  assertBool (isJust $ cpId cp2)
  assertEqual (Just Succeeded) (cpStatus cp2)
  w3<-testMP $ fetchWallet wid
  assertEqual (Just $ Amount "EUR" 332) (wBalance w3)
  
-- | test a failed card pay in
-- according to <http://docs.mangopay.com/api-references/test-payment/>
-- test disabled because the transaction succeeds even for amounts it shouldn't...
disabled_test_CardKO :: Assertion
disabled_test_CardKO = do
  us<-testMP $ listUsers (Just $ Pagination 1 1)
  assertEqual 1 (length us)
  let uid=urId $ head us
  let ci=CardInfo "4970100000000154" "1220" "123"
  cr<-testMP $ fullRegistration uid "EUR" ci
  assertBool (isJust $ crCardId cr)
  let cid=fromJust $ crCardId cr
  let w=Wallet Nothing Nothing (Just "custom") [uid] "my wallet" "EUR" Nothing 
  w2<-testMP $ storeWallet w
  assertBool (isJust $ wId w2)
  let wid=fromJust $ wId w2
  let cp=mkCardPayin uid uid wid (Amount "EUR" 333.05) (Amount "EUR" 0) "http://dummy" cid
  cp2<-testMP $ storeCardPayin cp
  assertBool (isJust $ cpId cp2)
  assertEqual (Just Failed) (cpStatus cp2)
  assertEqual (Just "101101") (cpResultCode cp2)
  assertEqual (Just "Transaction refused by the bank (Do not honor)") (cpResultMessage cp2)
  w3<-testMP $ fetchWallet wid
  assertEqual (Just $ Amount "EUR" 0) (wBalance w3)
    