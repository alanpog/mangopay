{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -F -pgmF htfpp #-}
-- | test documents
module Web.MangoPay.DocumentsTest where

import Web.MangoPay
import Web.MangoPay.TestUtils

import Test.Framework
import Test.HUnit (Assertion)
import Data.Maybe (isJust, fromJust)
import qualified Data.ByteString as BS

-- | test document API
test_Document :: Assertion
test_Document=do
  us<-testMP $ listUsers (Just $ Pagination 1 1)
  assertEqual 1 (length us)
  let uid=urId $ head us
  let d=Document Nothing Nothing Nothing IDENTITY_PROOF (Just CREATED) Nothing Nothing
  d2<-testMP $ storeDocument uid d
  assertBool (isJust $ dId d2)
  assertBool (isJust $ dCreationDate d2)
  assertEqual IDENTITY_PROOF (dType d2)
  tf<-BS.readFile "data/test.jpg"
  -- document has to be in CREATED status
  testMP $ storePage uid (fromJust $ dId d2) tf
  d3<-testMP $ storeDocument uid d2{dStatus=Just VALIDATION_ASKED}
  assertEqual (Just VALIDATION_ASKED) (dStatus d3)
  assertEqual (dId d2) (dId d3)
  d4<-testMP $ fetchDocument uid (fromJust $ dId d2)
  assertEqual (Just VALIDATION_ASKED) (dStatus d4)
  
  