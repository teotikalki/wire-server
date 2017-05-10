{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators     #-}

module Galley.API where

import Cassandra (runClient, shutdown)
import Cassandra.Schema (versionCheck)
import Control.Exception (finally)
import Control.Lens hiding (enum)
import Control.Monad
import Data.Aeson (encode)
import Data.ByteString (ByteString)
import Data.ByteString.Conversion (fromByteString, fromList)
import Data.Id (UserId, ConvId)
import Data.Metrics.Middleware
import Data.Misc
import Data.Range
import Data.Set (Set)
import Data.Swagger.Build.Api hiding (def, min, Response)
import Data.Text.Encoding (decodeLatin1)
import Galley.App
import Galley.API.Clients
import Galley.API.Create
import Galley.API.Update
import Galley.API.Teams
import Galley.API.Query
import Galley.Options
import Galley.Types (OtrFilterMissing (..))
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Predicate
import Network.Wai.Predicate.Request (HasQuery)
import Network.Wai.Routing hiding (route)
import Network.Wai.Utilities
import Network.Wai.Utilities.ZAuth
import Network.Wai.Utilities.Swagger
import Network.Wai.Utilities.Server hiding (serverPort)
import Prelude hiding (head)

import qualified Data.Predicate                as P
import qualified Data.Set                      as Set
import qualified Galley.API.Error              as Error
import qualified Galley.API.Internal           as Internal
import qualified Galley.Data                   as Data
import qualified Galley.Types.Swagger          as Model
import qualified Network.Wai.Predicate         as P
import qualified Network.Wai.Middleware.Gzip   as GZip
import qualified Network.Wai.Middleware.Gunzip as GZip
import qualified System.Logger                 as Log

run :: Opts -> IO ()
run o = do
    m <- metrics
    e <- createEnv m o
    let l = e^.applog
    s <- newSettings $ defaultServer (o^.hostname) (portNumber $ o^.serverPort) l m
    runClient (e^.cstate) $
        versionCheck Data.schemaVersion
    let rtree    = compile sitemap
        measured = measureRequests m rtree
        app r k  = runGalley e r (route rtree r k)
        start    = measured . catchErrors l m . GZip.gunzip . GZip.gzip GZip.def $ app
    runSettingsWithShutdown s start 5 `finally` do
        shutdown (e^.cstate)
        Log.flush l
        Log.close l

sitemap :: Routes ApiBuilder Galley ()
sitemap = do
    post "/teams" (continue createTeam) $
        zauthUserId
        .&. request
        .&. contentType "application" "json"

    get "/teams" (continue getManyTeams) $
        zauthUserId
        .&. opt (query "ids" ||| query "start")
        .&. def (unsafeRange 100) (query "size")
        .&. accept "application" "json"

    get "/teams/:tid" (continue getTeam) $
        zauthUserId
        .&. capture "tid"
        .&. accept "application" "json"

--    delete "/teams/:tid" (continue deleteTeam) $
--        zauthUserId
--        .&. capture "tid"
--        .&. accept "application" "json"

    get "/teams/:tid/members" (continue getTeamMembers) $
        zauthUserId
        .&. capture "tid"
        .&. accept "application" "json"

    post "/teams/:tid/members" (continue addTeamMember) $
        zauthUserId
        .&. capture "tid"
        .&. request
        .&. accept "application" "json"

    delete "/teams/:tid/members/:uid" (continue deleteTeamMember) $
        zauthUserId
        .&. capture "tid"
        .&. capture "uid"
        .&. accept "application" "json"

    get "/teams/:tid/conversations" (continue getTeamConversations) $
        zauthUserId
        .&. capture "tid"
        .&. accept "application" "json"

   --

    get "/bot/conversation" (continue getBotConversation) $
        zauth ZAuthBot
        .&> zauthBotId
        .&. zauthConvId
        .&. accept "application" "json"

    post "/bot/messages" (continue postBotMessage) $
        zauth ZAuthBot
        .&> zauthBotId
        .&. zauthConvId
        .&. def OtrReportAllMissing filterMissing
        .&. request
        .&. contentType "application" "json"
        .&. accept "application" "json"

    --

    get "/conversations/:cnv" (continue getConversation) $
        zauthUserId
        .&. capture "cnv"
        .&. accept "application" "json"

    document "GET" "conversation" $ do
        summary "Get a conversation by ID"
        returns (ref Model.conversation)
        parameter Path "cnv" bytes' $
            description "Conversation ID"
        errorResponse Error.convNotFound

    ---

    get "/conversations/ids" (continue getConversationIds) $
        zauthUserId
        .&. opt (query "start")
        .&. def (unsafeRange 1000) (query "size")
        .&. accept "application" "json"

    document "GET" "conversationIds" $ do
        summary "Get all conversation IDs"
        notes "At most 1000 IDs are returned per request"
        parameter Query "start" string' $ do
            optional
            description "Conversation ID to start from (exclusive)"
        parameter Query "size" string' $ do
            optional
            description "Max. number of IDs to return"
        returns (ref Model.conversationIds)

    ---

    get "/conversations" (continue getConversations) $
        zauthUserId
        .&. opt (query "ids" ||| query "start")
        .&. def (unsafeRange 100) (query "size")
        .&. accept "application" "json"

    document "GET" "conversations" $ do
        summary "Get all conversations"
        notes "At most 500 conversations are returned per request"
        returns (ref Model.conversations)
        parameter Query "ids" (array string') $ do
            optional
            description "Mutually exclusive with 'start'. At most 32 IDs per request."
        parameter Query "start" string' $ do
            optional
            description "Conversation ID to start from (exclusive). \
                        \Mutually exclusive with 'ids'."
        parameter Query "size" int32' $ do
            optional
            description "Max. number of conversations to return"

    ---

    post "/conversations" (continue createGroupConversation) $
        zauthUserId
        .&. zauthConnId
        .&. request
        .&. contentType "application" "json"

    document "POST" "createGroupConversation" $ do
        summary "Create a new conversation"
        notes "On 201, the conversation ID is the `Location` header"
        body (ref Model.newConversation) $
            description "JSON body"

    ---

    post "/conversations/self" (continue createSelfConversation)
        zauthUserId

    document "POST" "createSelfConversation" $ do
        summary "Create a self-conversation"
        notes "On 201, the conversation ID is the `Location` header"

    ---

    post "/conversations/one2one" (continue createOne2OneConversation) $
        zauthUserId
        .&. zauthConnId
        .&. request
        .&. contentType "application" "json"

    document "POST" "createOne2OneConversation" $ do
        summary "Create a 1:1-conversation"
        notes "On 201, the conversation ID is the `Location` header"
        body (ref Model.newConversation) $
            description "JSON body"

    ---

    put "/conversations/:cnv" (continue updateConversation) $
        zauthUserId
        .&. zauthConnId
        .&. capture "cnv"
        .&. request
        .&. contentType "application" "json"

    document "PUT" "updateConversation" $ do
        summary "Update conversation properties"
        parameter Path "cnv" bytes' $
            description "Conversation ID"
        body (ref Model.conversationUpdate) $
            description "JSON body"
        returns (ref Model.event)
        errorResponse Error.convNotFound

    ---

    post "/conversations/:cnv/join" (continue joinConversation) $
        zauthUserId
        .&. zauthConnId
        .&. capture "cnv"
        .&. accept "application" "json"

    document "POST" "joinConversation" $ do
        summary "Join a conversation"
        parameter Path "cnv" bytes' $
            description "Conversation ID"
        returns (ref Model.event)
        response 200 "Conversation joined." end
        errorResponse Error.convNotFound

    ---

    post "/conversations/:cnv/members" (continue addMembers) $
        zauthUserId
        .&. zauthConnId
        .&. capture "cnv"
        .&. request
        .&. contentType "application" "json"

    document "POST" "addMembers" $ do
        summary "Add users to an existing conversation"
        parameter Path "cnv" bytes' $
            description "Conversation ID"
        body (ref Model.invite) $
            description "JSON body"
        returns (ref Model.event)
        response 200 "Members added" end
        response 204 "No change" end
        errorResponse Error.convNotFound
        errorResponse (Error.invalidOp "Conversation type does not allow adding members")
        errorResponse Error.notConnected
        errorResponse Error.accessDenied

    ---

    get "/conversations/:cnv/self" (continue getMember) $
        zauthUserId
        .&. capture "cnv"

    document "GET" "getSelf" $ do
        summary "Get self membership properties"
        parameter Path "cnv" bytes' $
            description "Conversation ID"
        returns (ref Model.member)
        errorResponse Error.convNotFound

    ---

    put "/conversations/:cnv/self" (continue updateMember) $
        zauthUserId
        .&. zauthConnId
        .&. capture "cnv"
        .&. request
        .&. contentType "application" "json"

    document "PUT" "updateSelf" $ do
        summary "Update self membership properties"
        notes "Even though all fields are optional, at least one needs to be given."
        parameter Path "cnv" bytes' $
            description "Conversation ID"
        body (ref Model.memberUpdate) $
            description "JSON body"
        errorResponse Error.convNotFound

    ---

    post "/conversations/:cnv/typing" (continue isTyping) $
        zauthUserId
        .&. zauthConnId
        .&. capture "cnv"
        .&. request
        .&. contentType "application" "json"

    document "POST" "isTyping" $ do
        summary "Sending typing notifications"
        parameter Path "cnv" bytes' $
            description "Conversation ID"
        body (ref Model.typing) $
            description "JSON body"
        errorResponse Error.convNotFound

    ---

    delete "/conversations/:cnv/members/:usr" (continue removeMember) $
        zauthUserId
        .&. zauthConnId
        .&. capture "cnv"
        .&. capture "usr"

    document "DELETE" "removeMember" $ do
        summary "Remove member from conversation"
        parameter Path "cnv" bytes' $
            description "Conversation ID"
        parameter Path "usr" bytes' $
            description "User ID"
        returns (ref Model.event)
        response 200 "Member removed" end
        response 204 "No change" end
        errorResponse Error.convNotFound
        errorResponse $ Error.invalidOp "Conversation type does not allow removing members"

    ---

    post "/conversations/:cnv/otr/messages" (continue postOtrMessage) $
        zauthUserId
        .&. zauthConnId
        .&. capture "cnv"
        .&. def OtrReportAllMissing filterMissing
        .&. request
        .&. contentType "application" "json"

    document "POST" "postOtrMessage" $ do
        summary "Post an encrypted message to a conversation"
        parameter Path "cnv" bytes' $
            description "Conversation ID"
        parameter Query "ignore_missing" bool' $ do
            description "Force message delivery even when clients are missing."
            optional
        body (ref Model.newOtrMessage) $
            description "JSON body"
        returns (ref Model.clientMismatch)
        response 201 "Message posted" end
        response 412 "Missing clients" end
        errorResponse Error.convNotFound

    ---

    post "/conversations/:cnv/otr/messages" (continue postProtoOtrMessage) $
        zauthUserId
        .&. zauthConnId
        .&. capture "cnv"
        .&. def OtrReportAllMissing filterMissing
        .&. request
        .&. contentType "application" "x-protobuf"

    document "POST" "postProtoOtrMessage" $ do
        summary "Post an encrypted message to a conversation"
        parameter Path "cnv" bytes' $
            description "Conversation ID"
        parameter Query "ignore_missing" bool' $ do
            description "Force message delivery even when clients are missing."
            optional
        body (ref Model.newOtrMessage) $
            description "Protobuf body"
        returns (ref Model.clientMismatch)
        response 201 "Message posted" end
        response 403 "Unknown sending client" end
        response 412 "Missing clients" end
        errorResponse Error.convNotFound

    ---

    get "/conversations/api-docs" (continue docs) $
        accept "application" "json"
        .&. query "base_url"

    -- internal

    put "/i/conversations/:cnv/channel" (continue $ const (return empty)) $
       zauthUserId
       .&. (capture "cnv" :: HasCaptures r => Predicate r P.Error ConvId)
       .&. request

    head "/i/status" (continue $ const (return empty)) true

    get "/i/status" (continue $ const (return empty)) true

    get "/i/monitoring" (continue monitoring) $
        accept "application" "json"

    get "/i/conversations/:cnv/members/:usr" (continue internalGetMember) $
        capture "cnv"
        .&. capture "usr"

    post "/i/conversations/connect" (continue createConnectConversation) $
        zauthUserId
        .&. opt zauthConnId
        .&. request
        .&. contentType "application" "json"

    put "/i/conversations/:cnv/accept/v2" (continue acceptConv) $
        zauthUserId
        .&. opt zauthConnId
        .&. capture "cnv"

    put "/i/conversations/:cnv/block" (continue blockConv) $
        zauthUserId
        .&. capture "cnv"

    put "/i/conversations/:cnv/unblock" (continue unblockConv) $
        zauthUserId
        .&. opt zauthConnId
        .&. capture "cnv"

    get "/i/conversations/:cnv/meta" (continue getConversationMeta) $
        capture "cnv"

    get "/i/test/clients" (continue getClients)
        zauthUserId

    post "/i/clients/:client" (continue addClient) $
        zauthUserId
        .&. capture "client"

    delete "/i/clients/:client" (continue rmClient) $
        zauthUserId
        .&. capture "client"

    delete "/i/user" (continue Internal.rmUser) $
        zauthUserId .&. opt zauthConnId

    post "/i/services" (continue addService) $
        request
        .&. contentType "application" "json"

    delete "/i/services" (continue rmService) $
        request
        .&. contentType "application" "json"

    post "/i/bots" (continue addBot) $
        zauthUserId
        .&. zauthConnId
        .&. request
        .&. contentType "application" "json"

    delete "/i/bots" (continue rmBot) $
        zauthUserId
        .&. opt zauthConnId
        .&. request
        .&. contentType "application" "json"

type JSON = Media "application" "json"

docs :: JSON ::: ByteString -> Galley Response
docs (_ ::: url) =
    let doc = encode $ mkSwaggerApi (decodeLatin1 url) Model.galleyModels sitemap
    in return $ responseLBS status200 [jsonContent] doc

monitoring :: JSON -> Galley Response
monitoring = const $ json <$> (render =<< view monitor)

filterMissing :: HasQuery r => Predicate r P.Error OtrFilterMissing
filterMissing = (>>= go) <$> (query "ignore_missing" ||| query "report_missing")
  where
    go (Left ign) = case fromByteString ign of
        Just True  -> return OtrIgnoreAllMissing
        Just False -> return OtrReportAllMissing
        Nothing    -> OtrIgnoreMissing <$> users "ignore_missing" ign

    go (Right rep) = case fromByteString rep of
        Just True  -> return OtrReportAllMissing
        Just False -> return OtrIgnoreAllMissing
        Nothing    -> OtrReportMissing <$> users "report_missing" rep

    users :: ByteString -> ByteString -> P.Result P.Error (Set UserId)
    users src bs = case fromByteString bs of
        Nothing -> P.Fail $ P.setMessage "Boolean or list of user IDs expected."
                          $ P.setReason P.TypeError
                          $ P.setSource src
                          $ P.err status400
        Just  l -> P.Okay 0 (Set.fromList (fromList l))

