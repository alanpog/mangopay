{-# LANGUAGE RankNTypes,OverloadedStrings,DeriveDataTypeable #-}
{-# OPTIONS_GHC -F -pgmF htfpp #-}
module Web.MangoPay.TestUtils where

import Web.MangoPay

import Data.ByteString.Lazy as BS hiding (map)
import Network.HTTP.Conduit as H
import Data.Conduit
import Data.Maybe
import Test.Framework

import Network.Wai as W
import Network.Wai.Handler.Warp
import Network.HTTP.Types (status200)
import Blaze.ByteString.Builder (copyByteString)
import Data.Aeson as A
import Control.Concurrent (forkIO, ThreadId, threadDelay,killThread)
import Control.Concurrent.MVar (MVar, newMVar, putMVar, takeMVar)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)

import Data.Text (Text)
import Data.List
import Data.Typeable
import Control.Applicative
import Test.HUnit (Assertion)
import Control.Exception (bracket)

-- | file path to test client conf file
testConfFile :: FilePath
testConfFile="client.test.conf"

-- | a test card
testCardInfo1 :: CardInfo
testCardInfo1 = CardInfo "4970100000000154" "1220" "123"

-- | test MangoPay API call, logging in with the client credentials
-- expects a file called client.test.conf containing the JSON of client credentials
-- in the current directory 
testMP :: forall b.
            (AccessToken -> MangoPayT (ResourceT IO) b)
            -> IO b
testMP f= do
        js<-BS.readFile testConfFile
        let mcred=decode js
        assertBool (isJust mcred)
        let cred=fromJust mcred
        assertBool (isJust $ cClientSecret cred)
        let s=fromJust $ cClientSecret cred
        H.withManager (\mgr->
          runMangoPayT cred mgr Sandbox (do
                at<-oauthLogin (cClientID cred) s
                f at
                ))

-- | read end point information from hook.test.conf in current folder
getHookEndPoint :: IO HookEndPoint
getHookEndPoint = do
      js<-BS.readFile "hook.test.conf"
      let mhook=decode js  
      assertBool (isJust mhook)
      return $ fromJust mhook

-- | simple configuration to tell the tests what endpoint to use for notifications
data HookEndPoint = HookEndPoint{
        hepUrl :: Text
        ,hepPort :: Int
        } deriving (Show,Read,Eq,Ord,Typeable)

-- | to json        
instance ToJSON HookEndPoint where
        toJSON h=object ["Url"  .= hepUrl h,"Port" .= hepPort h]

-- | from json 
instance FromJSON HookEndPoint where
        parseJSON (Object v) =HookEndPoint <$>
                         v .: "Url" <*>
                         v .: "Port" 
        parseJSON _=fail "HookEndPoint"


-- | the events received via the notification hook
-- uses a MVar for storing events
data ReceivedEvents=ReceivedEvents{
        events::MVar [Either EventResult Event]
        }

-- | creates the new ReceivedEvents
newReceivedEvents :: IO ReceivedEvents
newReceivedEvents=do
        mv<-newMVar []          
        return $ ReceivedEvents mv

-- | test an event, checking the event type, and resource id
testEvent :: EventType -> Maybe Text -> Event -> Bool
testEvent et tid evt= tid == (Just $ eResourceId evt) 
        && et == eEventType evt

-- | run a test with the notification server running
checkEvents :: IO a -- ^ the test, returning a value
  -> [a -> Event -> Bool] -- ^ the test on the events, taking into account the returned value
  -> Assertion
checkEvents ops tests=do
    hook<-getHookEndPoint
    res<-newReceivedEvents
    er<-bracket 
          (startHTTPServer (hepPort hook) res)
          killThread
          (\_->do
            a<-ops
            waitForEvent res (map ($ a) tests) 30
          )
    assertEqual EventsOK er
            
-- | result of waiting for event
data EventResult = Timeout -- ^ didn't receive all expected events
  | EventsOK -- ^ OK: everything expected received, nothing unexpected
  | ExtraEvent Event -- ^ unexpected
  | UnhandledNotification String -- ^ notification we couldn't parse
  deriving (Show,Eq,Ord,Typeable)

-- | wait till we receive all the expected events, and none other, for a maximum number of seconds
waitForEvent :: ReceivedEvents 
  -> [Event -> Bool] -- ^ function on the expected event
  -> Integer -- ^ delay in seconds
  -> IO EventResult
waitForEvent _ _ del | del<=0=return Timeout
waitForEvent rc fs del=do
        mevt<-popReceivedEvent rc
        case (mevt,fs) of
          (Nothing,[])->return EventsOK -- nothing left to process
          (Just (Left er),_)->return er -- some notification we didn't understant
          (Just (Right evt),[])->return $ ExtraEvent evt -- an event that doesn't match
          (Nothing,_)->do -- no event yet
             threadDelay 1000000
             waitForEvent rc fs (del-1)
          (Just (Right evt),_)-> -- an event, does it match
                case Data.List.foldl' (match1 evt) ([],False) fs of
                  ([],True)->return EventsOK -- match, nothing else to do
                  (_,False)->return $ ExtraEvent evt -- doesn't match
                  (fs2,_)-> do -- matched, more to do
                        threadDelay 1000000
                        waitForEvent rc fs2 (del-1)
  where 
    -- | match the first event function and return all the non matching function, and a flag indicating if we matched
    match1 :: Event -> ([Event -> Bool],Bool) -> (Event -> Bool) -> ([Event -> Bool],Bool)
    match1 evt (nfs,False) f
      | f evt=(nfs,True)
      | otherwise=(f:nfs,False)
    match1 _ (nfs,True) f=(f:nfs,True)

-- | get one received event (and remove it from the underlying storage)        
popReceivedEvent :: ReceivedEvents -> IO (Maybe (Either EventResult Event))
popReceivedEvent (ReceivedEvents mv)=do
        evts<-takeMVar mv                
        case evts of
          []->do
                putMVar mv []
                return Nothing
          (e:es)->do
                putMVar mv es
                return $ Just e

-- | get all received events (and remove them from the underlying storage)        
popReceivedEvents :: ReceivedEvents -> IO [Either EventResult Event]
popReceivedEvents (ReceivedEvents mv)=do
        evts<-takeMVar mv                
        putMVar mv []
        return evts

-- | add a new event
pushReceivedEvent :: ReceivedEvents -> Either EventResult Event -> IO ()
pushReceivedEvent (ReceivedEvents mv) evt=do
        evts' <-takeMVar mv    
        putMVar mv (evt : evts')
        return ()

-- | start a HTTP server listening on the given port
-- if the path info is "mphook", then we'll push the received event                        
startHTTPServer :: Port -> ReceivedEvents -> IO ThreadId
startHTTPServer p revts= 
  forkIO $ run p app
  where
    app req = do
                when (pathInfo req == ["mphook"]) $ do
                        let mevt=eventFromQueryString $ W.queryString req
                        liftIO $ case mevt of
                            Just evt->do
                                pushReceivedEvent revts $ Right evt
                                print evt
                            Nothing->pushReceivedEvent revts $ Left $ UnhandledNotification $ show $ W.queryString req
                return $ ResponseBuilder status200 [("Content-Type", "text/plain")] $ copyByteString "noop"
                