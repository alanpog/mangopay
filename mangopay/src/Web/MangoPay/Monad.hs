{-# LANGUAGE DeriveDataTypeable, OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables, GeneralizedNewtypeDeriving, FlexibleInstances,
  MultiParamTypeClasses, UndecidableInstances, TypeFamilies,
  FlexibleContexts, RankNTypes,CPP #-}
-- | the utility monad and related functions, taking care of the HTTP, JSON, etc.
module Web.MangoPay.Monad where

import Web.MangoPay.Types

import Control.Applicative 
import Control.Monad (MonadPlus, liftM, void)
import Control.Monad.Base (MonadBase(..))
import Control.Monad.Fix (MonadFix)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Trans.Class (MonadTrans(lift))
import Control.Monad.Trans.Control ( MonadTransControl(..), MonadBaseControl(..)
                                   , ComposeSt, defaultLiftBaseWith
                                   , defaultRestoreM )
import Control.Monad.Trans.Reader (ReaderT(..), ask, mapReaderT)
import Data.Typeable (Typeable)
import Data.Default
import qualified Control.Monad.Trans.Resource as R
import qualified Control.Exception.Lifted as L

import qualified Data.Conduit as C
import qualified Network.HTTP.Conduit as H
import qualified Network.HTTP.Types as HT
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy.Char8 as BSLC
import Data.Aeson (json,fromJSON,Result(..),FromJSON, ToJSON,encode)
import Data.Conduit.Attoparsec (sinkParser, ParseError)
import Control.Exception.Base (throw)
import qualified Data.Text.Encoding as TE
import qualified Data.Text as T (Text)

#if DEBUG
import Data.Conduit.Binary (sinkHandle)
import System.IO (stdout)
import Data.Conduit.Util (zipSinks)
#endif


-- | the mangopay monad transformer
-- this encapsulates the data necessary to pass the app credentials, etc
newtype MangoPayT m a = Mp { unIs :: ReaderT MpData m a }
    deriving ( Functor, Applicative, Alternative, Monad
             , MonadFix, MonadPlus, MonadIO, MonadTrans
             , R.MonadThrow, R.MonadActive, R.MonadResource )
             
instance MonadBase b m => MonadBase b (MangoPayT m) where
    liftBase = lift . liftBase

instance MonadTransControl MangoPayT where
    newtype StT MangoPayT a = MpStT { unMpStT :: StT (ReaderT MpData) a }
    liftWith f = Mp $ liftWith (\run -> f (liftM MpStT . run . unIs))
    restoreT = Mp . restoreT . liftM unMpStT

instance MonadBaseControl b m => MonadBaseControl b (MangoPayT m) where
    newtype StM (MangoPayT m) a = StMT {unStMT :: ComposeSt MangoPayT m a}
    liftBaseWith = defaultLiftBaseWith StMT
    restoreM = defaultRestoreM unStMT
    
-- | Run a computation in the 'MangoPayT' monad transformer with
-- your credentials.
runMangoPayT :: Credentials -- ^ Your app's credentials.
             -> H.Manager -- ^ Connection manager (see 'H.withManager').
             -> AccessPoint
             -> MangoPayT m a -- ^ the action to run
             -> m a -- ^ the result
runMangoPayT creds manager ap (Mp act) =
    runReaderT act (MpData creds manager ap) 
    
-- | Get the user's credentials.
getCreds :: Monad m => MangoPayT m Credentials
getCreds = mpCreds `liftM` Mp ask

-- | Get the MangoPay host
getHost :: Monad m => MangoPayT m ByteString
getHost = (getAccessPointURL . mpAccessPoint) `liftM` Mp ask

-- | build a post request to MangoPay
getPostRequest :: (Monad m,MonadIO m,HT.QueryLike q) => ByteString -- ^ the url path
  -> Maybe AccessToken
  -> q -- ^ the query parameters
  -> MangoPayT m H.Request -- ^ the properly configured request
getPostRequest path mat query=do
  host<-getHost
  let b=HT.renderQuery False $ HT.toQuery query      
#if DEBUG
  liftIO $ BSC.putStrLn path
  liftIO $ BSC.putStrLn b
#endif  
  return $ def {
                     H.secure=True
                     , H.host = host
                     , H.port = 443
                     , H.path = path
                     , H.method=HT.methodPost
                     , H.requestHeaders=[("content-type","application/x-www-form-urlencoded")] ++
                        case mat of 
                                Just (AccessToken at)->[("Authorization",at)]
                                _->[]   
                     , H.requestBody=H.RequestBodyBS b
                }

-- | build a get request to MangoPay
getGetRequest :: (Monad m,MonadIO m,HT.QueryLike q) => ByteString -- ^ the url path
  -> Maybe AccessToken
  -> q -- ^ the query parameters
  -> MangoPayT m H.Request -- ^ the properly configured request
getGetRequest path mat query=do
  host<-getHost
  let qs=HT.renderQuery True $ HT.toQuery query
#if DEBUG
  liftIO $ BSC.putStrLn $ BS.append path qs
#endif  
  return $ def {
                     H.secure=True
                     , H.host = host
                     , H.port = 443
                     , H.path = path
                     , H.method=HT.methodGet
                     , H.queryString=qs
                     , H.requestHeaders=getJSONHeaders mat
                }
   
-- | build a delete request  to MangoPay
getDeleteRequest :: (Monad m,MonadIO m,HT.QueryLike q) => ByteString -- ^ the url path
  -> Maybe AccessToken
  -> q -- ^ the query parameters
  -> MangoPayT m H.Request -- ^ the properly configured request
getDeleteRequest path mat query=do
  get<-getGetRequest path mat query
  return $ get {H.method=HT.methodDelete}

-- | get the url to use for our clientId
getClientURL :: (Monad m)=> ByteString -- ^ the url path
        -> MangoPayT m ByteString  -- ^ the URL
getClientURL path=do
        cid<- liftM clientIDBS getCreds
        return $ BS.concat ["/v2/",cid,path]

-- | get the url to use for our clientId
getClientURLMultiple :: (Monad m)=> [T.Text] -- ^ the url components
        -> MangoPayT m ByteString  -- ^ the URL
getClientURLMultiple path=do
        cid<- liftM clientIDBS getCreds
        return $ BS.concat $ ["/v2/",cid] ++ map TE.encodeUtf8 path

-- | build a URL for a get operation with a single query
getQueryURL :: (Monad m,HT.QueryLike q) => ByteString -- ^ the url path
  -> q -- ^ the query parameters 
  -> MangoPayT m ByteString  -- ^ the URL
getQueryURL path query=do
  host<-getHost
  return $ BS.concat ["https://",host,path,HT.renderQuery True  $ HT.toQuery query]

-- | perform a HTTP request and deal with the JSON result
mpReq :: forall b (m :: * -> *) wrappedErr .
                    (MonadBaseControl IO m, C.MonadResource m,FromJSON b,FromJSON wrappedErr) =>
                    H.Request
                    -> (wrappedErr -> MpError) -- ^ extract the error from the JSON
                    -> MangoPayT m b
mpReq req extractError=do
   -- we check the status ourselves
  let req' = req { H.checkStatus = \_ _ _ -> Nothing }
  mgr<-getManager
  res<-H.http req' mgr
  let status = H.responseStatus res
      headers = H.responseHeaders res
      cookies = H.responseCookieJar res
      ok=isOkay status
      err=H.StatusCodeException status headers cookies
  L.catch (do    
#if DEBUG
    (value,_)<-H.responseBody res C.$$+- zipSinks (sinkParser json) (sinkHandle stdout)
    liftIO $ BSC.putStrLn ""
#else  
    value<-H.responseBody res C.$$+- sinkParser json
#endif
    if ok
      then 
          -- parse response as the expected value
          case fromJSON value of
            Success ot->return ot
            Error jerr->throw $ JSONException jerr -- got an ok response we couldn't parse
      else
          -- parse response as an error
          case fromJSON value of
            Success ise-> throw $ MpAppException $ extractError ise
            _ -> throw err -- we can't even parse the error, throw the HTTP error
    ) (\(_::ParseError)->throw err) -- the error body wasn't even json   
 
-- | get a JSON response from a request to MangoPay
-- MangoPay returns either a result, or an error
getJSONResponse :: forall (m :: * -> *) v.
                                 (MonadBaseControl IO m, C.MonadResource m,FromJSON v) =>
                                 H.Request
                                 -> MangoPayT
                                      m v
getJSONResponse req=mpReq req id 
 
-- | get the headers necessary for a JSON call              
getJSONHeaders ::  Maybe AccessToken -> HT.RequestHeaders
getJSONHeaders mat=  [("content-type","application/json")] ++
                        case mat of 
                                Just (AccessToken at)->[("Authorization",at)]
                                _->[]           


-- | send JSON via post, get JSON back                
postExchange :: forall (m :: * -> *) v p.
                 (MonadBaseControl IO m, C.MonadResource m,FromJSON v,ToJSON p) =>
                 ByteString
                 -> Maybe AccessToken
                 -> p
                 -> MangoPayT
                      m v        
postExchange=jsonExchange HT.methodPost

-- | send JSON via post, get JSON back                
putExchange :: forall (m :: * -> *) v p.
                 (MonadBaseControl IO m, C.MonadResource m,FromJSON v,ToJSON p) =>
                 ByteString
                 -> Maybe AccessToken
                 -> p
                 -> MangoPayT
                      m v        
putExchange=jsonExchange HT.methodPut
   
-- | send JSON, get JSON back                
jsonExchange :: forall (m :: * -> *) v p.
                 (MonadBaseControl IO m, C.MonadResource m,FromJSON v,ToJSON p) =>
                 HT.Method
                 -> ByteString
                 -> Maybe AccessToken
                 -> p
                 -> MangoPayT
                      m v        
jsonExchange meth path mat p= getJSONRequest meth path mat p >>= getJSONResponse
  
-- | get JSON request                
getJSONRequest :: forall (m :: * -> *) p.
                 (MonadBaseControl IO m, C.MonadResource m,ToJSON p) =>
                 HT.Method
                 -> ByteString
                 -> Maybe AccessToken
                 -> p
                 ->  MangoPayT m H.Request -- ^ the properly configured request            
getJSONRequest meth path mat p=    do
  host<-getHost
#if DEBUG
  liftIO $ BSC.putStrLn path
  liftIO $ BSLC.putStrLn $ encode p
#endif  
  return def {
                     H.secure=True
                     , H.host = host
                     , H.port = 443
                     , H.path = path
                     , H.method=meth
                     , H.requestHeaders=getJSONHeaders mat
                     , H.requestBody=H.RequestBodyLBS $ encode p
                }      
                         
-- | post JSON content and ignore the reply                
postNoReply :: forall (m :: * -> *) p.
                 (MonadBaseControl IO m, C.MonadResource m,ToJSON p) =>
                  ByteString
                 -> Maybe AccessToken
                 -> p
                 -> MangoPayT
                      m ()                        
postNoReply path mat p= do
  req<- getJSONRequest HT.methodPost path mat p
  mgr<-getManager
  void $ H.http req mgr        
                
-- | Get the 'H.Manager'.
getManager :: Monad m => MangoPayT m H.Manager
getManager = mpManager `liftM` Mp ask

-- | Run a 'ResourceT' inside a 'MangoPayT'.
runResourceInMp :: (C.MonadResource m, MonadBaseControl IO m) =>
                   MangoPayT (C.ResourceT m) a
                -> MangoPayT m a
runResourceInMp (Mp inner) = Mp $ ask >>= lift . C.runResourceT . runReaderT inner    
    
-- | Transform the computation inside a 'MangoPayT'.
mapMangoPayT :: (m a -> n b) -> MangoPayT m a -> MangoPayT n b
mapMangoPayT f = Mp . mapReaderT f . unIs    
    
-- | the data kept through the computations
data MpData = MpData {
        mpCreds::Credentials -- ^ app credentials
        ,mpManager::H.Manager -- ^ HTTP connection manager
        ,mpAccessPoint:: AccessPoint -- ^ access point
        } 
        deriving (Typeable)

-- | @True@ if the the 'Status' is ok (i.e. @2XX@).
isOkay :: HT.Status -> Bool
isOkay status =
  let sc = HT.statusCode status
  in 200 <= sc && sc < 300

