{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE EmptyDataDecls             #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}

module Main (main, app) where

import Debug.Trace
import Data.Text.Encoding (decodeUtf8)


import System.IO
import Control.Monad
import Web.Spock                    as WS hiding ( head )
import Web.Spock.Config
import Data.Aeson                   hiding ( json ) -- Because we use Web.Spock.json
import Data.Monoid                  ( (<>) )                    
import Network.HTTP.Types           ( Status, ok200, created201, accepted202
                                    , badRequest400, notFound404 )

import Control.Monad.Logger         ( LoggingT, runStdoutLoggingT )
import Database.Persist             hiding ( get ) -- To avoid clash with Web.Spock.get
import Database.Persist.Sqlite      as PSQL hiding ( get )
-- import Database.Persist.PostgreSQL      as PSQL hiding ( get )
import Database.Persist.TH          
import Network.Wai                          ( Middleware )
import Network.Wai.Middleware.RequestLogger ( logStdoutDev )
import Network.Wai.Parse                    ( fileContent )

import Data.Int
import Data.HashMap.Strict          ( (!), keys, toList)
import Data.Text                    as T ( Text, length )
import NoteParser                   ( makeNotes )
import Models                       as M


runSQL :: (HasSpock m, SpockConn m ~ SqlBackend) => SqlPersistT (LoggingT IO) a -> m a
runSQL action = runQuery $ \conn -> runStdoutLoggingT $ runSqlConn action conn


-- API  error handlers
errorHandler ::  Status ->  ActionCtxT () IO ()
errorHandler s 
    | s == notFound404 = json $ object
            [ "result" .= String "failure", "msg" .= String "Page not found."]
    | otherwise = json $ object
            [ "result" .= String "failure", "msg" .= String "Something very bad happened!"]


makeResponse :: Status -> Text -> ActionCtxT b (WebStateM SqlBackend () ()) b
makeResponse status msg = 
    setStatus status >> json (object ["msg" .= String msg])


-- SERVER
main :: IO ()
main = runSpock 3000 $ fmap (logStdoutDev.) app


app :: IO Middleware
app = do
    -- Create db connection
    pool <- runStdoutLoggingT $ createSqlitePool "api.db" 5

    -- Add custom error handling
    spockCfg <- (defaultSpockCfg () (PCPool pool) ()) >>= \cfg -> 
        return $ cfg {spc_errorHandler = errorHandler}
    
    -- Migrate
    runStdoutLoggingT $ runSqlPool (do runMigration migrateAll) pool

    spock spockCfg routes


-- API
type Api = SpockM SqlBackend () () ()
type ApiAction a = SpockAction SqlBackend () () a


corsHeader :: ActionCtxT b (WebStateM SqlBackend () ()) b
corsHeader =
    do ctx <- WS.getContext
       WS.setHeader "Access-Control-Allow-Origin" "*"
       WS.setHeader "Access-Control-Allow-Methods" "GET,POST,PUT,DELETE,OPTIONS"
       WS.setHeader "Access-Control-Allow-Headers" "Content-Type, Authorization, Content-Length, X-Requested-With"
       pure ctx


routes :: Api
routes = prehook corsHeader $ do
    WS.hookAny OPTIONS (\path -> corsHeader)

    WS.get "books" $ do
        allBooks <- runSQL $ selectList [] [Asc BookId]
        json $ allBooks

    WS.get "notes" $ do
        allNotes <- runSQL $ selectList [] [Asc NoteId]
        json $ allNotes

    WS.post "notes" $ do
        bst <- body 
        let content = decodeUtf8 bst
        case makeNotes content of
            Left errmsg -> makeResponse badRequest400 errmsg
            Right notes -> do 
                mapM (runSQL.insertBy) notes
                allNotes <- runSQL $ selectList [] [Asc NoteId]
                json $ allNotes
    
    WS.delete ("notes" <//> var) $ \noteId -> do
        rmvId <- runSQL $ PSQL.delete (makeNoteKey noteId)
        makeResponse accepted202 "success"

    WS.put "books" $ do
        maybeBooks <- jsonBody :: ApiAction (Maybe (Book, Book))
        case maybeBooks of
            Nothing -> makeResponse badRequest400 "JSON body corrupted."
            Just (bkOld, bkNew) -> do
                smth <- runSQL $ updateWhere [NoteBook ==. bkOld] [NoteBook =. bkNew]
                makeResponse ok200 "success"
    
