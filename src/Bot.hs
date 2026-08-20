module Bot (
  BreadState,
  commandResponse,
  commands,
  eventHandler,
  messageUrl,
  newBreadState,
  recommendationWeight,
) where

import Control.Concurrent (forkIO)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Discord (DiscordHandler, FromJSON, Request, restCall)
import Discord.Interactions
import Discord.Internal.Rest.ApplicationCommands (
  ApplicationCommandRequest (..),
 )
import Discord.Internal.Rest.Channel (
  ChannelRequest (..),
  MessageTiming (..),
 )
import Discord.Internal.Rest.Interactions (InteractionResponseRequest (..))
import Discord.Internal.Types.Events (
  Event (..),
  GuildCreateData (..),
  ReactionInfo (..),
  ReactionRemoveInfo (..),
 )
import Discord.Types (
  ApplicationId,
  Attachment (..),
  Channel (..),
  ChannelId,
  Emoji (..),
  GuildId,
  Message (..),
  MessageId,
  MessageReaction (..),
  PartialApplication (..),
 )
import Discord.Types qualified as DiscordTypes
import System.Random (randomRIO)

newtype BreadState = BreadState (TVar (Map GuildId GuildBreadIndex))

data GuildBreadIndex = GuildBreadIndex
  { indexedBreadMessages :: [BreadMessage]
  , breadScanStatus :: BreadScanStatus
  }

data BreadScanStatus
  = BreadScanning
  | BreadComplete
  | BreadFailed
  deriving stock (Eq, Show)

data BreadMessage = BreadMessage
  { breadGuildId :: GuildId
  , breadChannelId :: ChannelId
  , breadMessageId :: MessageId
  , breadReactionCount :: Int
  , breadPostedAt :: UTCTime
  , breadSelectionCount :: Int
  }
  deriving stock (Eq, Show)

newBreadState :: IO BreadState
newBreadState = BreadState <$> newTVarIO Map.empty

commands :: [CreateApplicationCommand]
commands =
  [ simpleCommand "ping" "Check whether the bot is running" Nothing
  , simpleCommand "bread" "Find a random message with a bread reaction" Nothing
  ]

commandResponse :: Text -> Maybe Text
commandResponse = \case
  "ping" -> Just "Pong!"
  _ -> Nothing

eventHandler :: BreadState -> Event -> DiscordHandler ()
eventHandler breadState = \case
  Ready _ _ _ _ _ _ (PartialApplication applicationId _) -> do
    putTextLn "Connected to Discord"
    syncCommands applicationId
    putTextLn "Application commands registered"
  GuildCreate guild guildData ->
    startBreadScan
      breadState
      (DiscordTypes.guildId guild)
      (guildCreateChannels guildData)
  InteractionCreate interaction ->
    case interaction of
      InteractionApplicationCommand
        { applicationCommandData =
          ApplicationCommandDataChatInput
            { applicationCommandDataName = commandName
            }
        } ->
          if commandName == "bread"
            then handleBread breadState interaction
            else whenJust (commandResponse commandName) $ respond interaction
      _ -> pass
  MessageReactionAdd reaction
    | isBreadEmoji (reactionEmoji reaction) ->
        whenJust (reactionGuildId reaction) $ \guildId ->
          refreshBreadMessage
            breadState
            guildId
            (reactionChannelId reaction)
            (reactionMessageId reaction)
  MessageReactionRemove reaction
    | isBreadEmoji (reactionEmoji reaction) ->
        whenJust (reactionGuildId reaction) $ \guildId ->
          refreshBreadMessage
            breadState
            guildId
            (reactionChannelId reaction)
            (reactionMessageId reaction)
  MessageReactionRemoveAll sourceChannelId sourceMessageId ->
    liftIO $ removeBreadMessageEverywhere breadState sourceChannelId sourceMessageId
  MessageReactionRemoveEmoji reaction
    | isBreadEmoji (reactionRemoveEmoji reaction) ->
        liftIO $
          removeBreadMessageEverywhere
            breadState
            (reactionRemoveChannelId reaction)
            (reactionRemoveMessageId reaction)
  MessageDelete sourceChannelId sourceMessageId ->
    liftIO $ removeBreadMessageEverywhere breadState sourceChannelId sourceMessageId
  MessageDeleteBulk sourceChannelId sourceMessageIds ->
    liftIO $
      forM_ sourceMessageIds $
        removeBreadMessageEverywhere breadState sourceChannelId
  _ -> pass

handleBread :: BreadState -> Interaction -> DiscordHandler ()
handleBread breadState interaction = do
  respondWith interaction InteractionResponseDeferChannelMessage
  case interactionGuildId interaction of
    Nothing -> finishInteraction interaction "`/bread` can only be used in a server."
    Just guildId -> do
      breadIndex <- liftIO $ readBreadIndex breadState guildId
      case breadIndex of
        Nothing -> finishInteraction interaction "Still gathering bread. Try again shortly."
        Just index -> do
          selected <- selectBreadMessage breadState $ indexedBreadMessages index
          case selected of
            Just message -> finishInteraction interaction $ breadResponse guildId message
            Nothing -> do
              currentStatus <- liftIO $ fmap breadScanStatus <$> readBreadIndex breadState guildId
              finishInteraction interaction $ emptyBreadResponse currentStatus

startBreadScan :: BreadState -> GuildId -> [Channel] -> DiscordHandler ()
startBreadScan breadState@(BreadState breadByGuild) guildId channels = do
  shouldStart <- liftIO $ atomically $ do
    indexes <- readTVar breadByGuild
    if Map.member guildId indexes
      then pure False
      else do
        writeTVar breadByGuild $
          Map.insert guildId (GuildBreadIndex [] BreadScanning) indexes
        pure True
  when shouldStart $ do
    putTextLn $ "Starting bread scan for guild " <> show guildId
    discordHandle <- ask
    void $ liftIO $ forkIO $ runReaderT (scanGuild breadState guildId channels) discordHandle

scanGuild :: BreadState -> GuildId -> [Channel] -> DiscordHandler ()
scanGuild breadState guildId channels = do
  let historyChannels = mapMaybe historyChannel channels
  putTextLn $ "Scanning " <> show (length historyChannels) <> " channels for bread"
  traverse_
    (uncurry $ scanChannel breadState guildId)
    historyChannels
  liftIO $ setBreadScanStatus breadState guildId BreadComplete
  breadIndex <- liftIO $ readBreadIndex breadState guildId
  let breadCount = maybe 0 (length . indexedBreadMessages) breadIndex
  putTextLn $ "Bread index contains " <> show breadCount <> " messages"

historyChannel :: Channel -> Maybe (ChannelId, Text)
historyChannel channel = case channel of
  ChannelText {} -> Just (channelId channel, channelName channel)
  ChannelNews {} -> Just (channelId channel, channelName channel)
  _ -> Nothing

scanChannel :: BreadState -> GuildId -> ChannelId -> Text -> DiscordHandler ()
scanChannel breadState guildId sourceChannelId sourceChannelName = do
  putTextLn $ "Starting channel #" <> sourceChannelName <> " (" <> show sourceChannelId <> ")"
  (messagesChecked, breadFound) <- go LatestMessages 0 0
  putTextLn $
    "Finished channel #"
      <> sourceChannelName
      <> " ("
      <> show sourceChannelId
      <> "): "
      <> show messagesChecked
      <> " messages checked, "
      <> show breadFound
      <> " bread found"
  where
    go timing messagesChecked breadFound =
      restCall (GetChannelMessages sourceChannelId (100, timing)) >>= \case
        Left err -> do
          putTextLn $ "Skipping channel " <> show sourceChannelId <> ": " <> show err
          pure (messagesChecked, breadFound)
        Right messages -> do
          let breadMessages = mapMaybe (toBreadMessage guildId) messages
              messagesChecked' = messagesChecked + length messages
              breadFound' = breadFound + length breadMessages
          liftIO $ addBreadMessages breadState guildId breadMessages
          if length messages < 100
            then pure (messagesChecked', breadFound')
            else case reverse messages of
              oldest : _ ->
                go (BeforeMessage $ messageId oldest) messagesChecked' breadFound'
              [] -> pure (messagesChecked', breadFound')

toBreadMessage :: GuildId -> Message -> Maybe BreadMessage
toBreadMessage guildId message =
  if reactionCount > 0
    then
      Just
        BreadMessage
          { breadGuildId = guildId
          , breadChannelId = messageChannelId message
          , breadMessageId = messageId message
          , breadReactionCount = reactionCount
          , breadPostedAt = messageTimestamp message
          , breadSelectionCount = 0
          }
    else Nothing
  where
    reactionCount = messageBreadCount message

messageBreadCount :: Message -> Int
messageBreadCount =
  sum
    . map messageReactionCount
    . filter (isBreadEmoji . messageReactionEmoji)
    . messageReactions

isBreadEmoji :: Emoji -> Bool
isBreadEmoji emoji = isNothing (emojiId emoji) && emojiName emoji == "🍞"

selectBreadMessage :: BreadState -> [BreadMessage] -> DiscordHandler (Maybe Message)
selectBreadMessage _ [] = pure Nothing
selectBreadMessage breadState candidates = do
  now <- liftIO getCurrentTime
  selected <- liftIO $ weightedRandom $ map (withWeight now) candidates
  restCall
    ( GetChannelMessage
        (breadChannelId selected, breadMessageId selected)
    )
    >>= \case
      Right message
        | Just refreshed <- toBreadMessage (breadGuildId selected) message -> do
            liftIO $ do
              addBreadMessage breadState refreshed
              markBreadSelected breadState selected
            pure $ Just message
      _ -> do
        liftIO $ removeBreadMessage breadState selected
        selectBreadMessage breadState $ filter (/= selected) candidates

withWeight :: UTCTime -> BreadMessage -> (BreadMessage, Double)
withWeight now message =
  ( message
  , recommendationWeight
      (realToFrac (diffUTCTime now $ breadPostedAt message) / 86_400)
      (breadReactionCount message)
      (breadSelectionCount message)
  )

recommendationWeight :: Double -> Int -> Int -> Double
recommendationWeight ageDays reactionCount selectionCount =
  popularity * ageBonus / selectionPenalty
  where
    popularity = sqrt $ fromIntegral $ max 1 reactionCount
    ageBonus = 1 + logBase 2 (1 + max 0 ageDays / 30)
    selectionPenalty = fromIntegral (1 + max 0 selectionCount) ^ (2 :: Int)

weightedRandom :: [(a, Double)] -> IO a
weightedRandom weighted = do
  target <- randomRIO (0, sum $ map snd weighted)
  pure $ pick target weighted
  where
    pick _ [(value, _)] = value
    pick remaining ((value, weight) : rest)
      | remaining <= weight = value
      | otherwise = pick (remaining - weight) rest
    pick _ [] = error "weightedRandom requires at least one candidate"

refreshBreadMessage :: BreadState -> GuildId -> ChannelId -> MessageId -> DiscordHandler ()
refreshBreadMessage breadState guildId sourceChannelId sourceMessageId =
  restCall (GetChannelMessage (sourceChannelId, sourceMessageId)) >>= \case
    Right message ->
      liftIO $ case toBreadMessage guildId message of
        Just breadMessage -> addBreadMessage breadState breadMessage
        Nothing -> removeBreadMessageEverywhere breadState sourceChannelId sourceMessageId
    Left err ->
      putTextLn $ "Failed to refresh bread message " <> show sourceMessageId <> ": " <> show err

addBreadMessage :: BreadState -> BreadMessage -> IO ()
addBreadMessage breadState message =
  addBreadMessages breadState (breadGuildId message) [message]

addBreadMessages :: BreadState -> GuildId -> [BreadMessage] -> IO ()
addBreadMessages (BreadState breadByGuild) guildId messages =
  atomically $
    modifyTVar' breadByGuild $
      Map.adjust
        (\index -> index {indexedBreadMessages = foldr upsertBreadMessage (indexedBreadMessages index) messages})
        guildId

upsertBreadMessage :: BreadMessage -> [BreadMessage] -> [BreadMessage]
upsertBreadMessage message = \case
  [] -> [message]
  existing : rest
    | sameBreadMessage message existing ->
        message {breadSelectionCount = breadSelectionCount existing} : rest
    | otherwise -> existing : upsertBreadMessage message rest

sameBreadMessage :: BreadMessage -> BreadMessage -> Bool
sameBreadMessage left right =
  breadChannelId left == breadChannelId right
    && breadMessageId left == breadMessageId right

markBreadSelected :: BreadState -> BreadMessage -> IO ()
markBreadSelected (BreadState breadByGuild) selected =
  atomically $
    modifyTVar' breadByGuild $
      Map.adjust
        ( \index ->
            index
              { indexedBreadMessages =
                  map
                    ( \message ->
                        if sameBreadMessage message selected
                          then message {breadSelectionCount = breadSelectionCount message + 1}
                          else message
                    )
                    (indexedBreadMessages index)
              }
        )
        (breadGuildId selected)

removeBreadMessage :: BreadState -> BreadMessage -> IO ()
removeBreadMessage (BreadState breadByGuild) message =
  atomically $
    modifyTVar' breadByGuild $
      Map.adjust
        (\index -> index {indexedBreadMessages = filter (not . sameBreadMessage message) $ indexedBreadMessages index})
        (breadGuildId message)

removeBreadMessageEverywhere :: BreadState -> ChannelId -> MessageId -> IO ()
removeBreadMessageEverywhere (BreadState breadByGuild) sourceChannelId sourceMessageId =
  atomically $
    modifyTVar' breadByGuild $
      Map.map $
        \index ->
          index
            { indexedBreadMessages =
                filter
                  ( \message ->
                      breadChannelId message /= sourceChannelId
                        || breadMessageId message /= sourceMessageId
                  )
                  (indexedBreadMessages index)
            }

readBreadIndex :: BreadState -> GuildId -> IO (Maybe GuildBreadIndex)
readBreadIndex (BreadState breadByGuild) guildId =
  Map.lookup guildId <$> readTVarIO breadByGuild

setBreadScanStatus :: BreadState -> GuildId -> BreadScanStatus -> IO ()
setBreadScanStatus (BreadState breadByGuild) guildId status =
  atomically $
    modifyTVar' breadByGuild $
      Map.adjust (\index -> index {breadScanStatus = status}) guildId

emptyBreadResponse :: Maybe BreadScanStatus -> Text
emptyBreadResponse = \case
  Just BreadScanning -> "Still gathering bread. Try again shortly."
  Just BreadFailed -> "The bread scan failed. Check the bot logs and channel permissions."
  _ ->
    "No bread-reacted messages found. Check the bot's View Channel and Read Message History permissions."

breadResponse :: GuildId -> Message -> Text
breadResponse guildId message =
  Text.intercalate "\n" $
    fitLines 2_000 $
      messageUrl guildId (messageChannelId message) (messageId message)
        : (attachmentUrl <$> messageAttachments message)

messageUrl :: GuildId -> ChannelId -> MessageId -> Text
messageUrl sourceGuildId sourceChannelId sourceMessageId =
  "https://discord.com/channels/"
    <> show sourceGuildId
    <> "/"
    <> show sourceChannelId
    <> "/"
    <> show sourceMessageId

fitLines :: Int -> [Text] -> [Text]
fitLines _ [] = []
fitLines remaining (line : rest)
  | Text.length line > remaining = []
  | otherwise = line : fitLines (remaining - Text.length line - 1) rest

syncCommands :: ApplicationId -> DiscordHandler ()
syncCommands applicationId =
  discordCall_ $ BulkOverWriteGlobalApplicationCommand applicationId commands

respond :: Interaction -> Text -> DiscordHandler ()
respond interaction content =
  respondWith interaction $ interactionResponseBasic content

respondWith :: Interaction -> InteractionResponse -> DiscordHandler ()
respondWith interaction response =
  discordCall_ $
    CreateInteractionResponse
      (interactionId interaction)
      (interactionToken interaction)
      response

finishInteraction :: Interaction -> Text -> DiscordHandler ()
finishInteraction interaction content =
  discordCall_ $
    EditOriginalInteractionResponse
      (interactionApplicationId interaction)
      (interactionToken interaction)
      (interactionResponseMessageBasic content)

discordCall_ :: (Request (request response), FromJSON response) => request response -> DiscordHandler ()
discordCall_ = void . discordCall

discordCall :: (Request (request response), FromJSON response) => request response -> DiscordHandler response
discordCall request =
  restCall request >>= \case
    Right response -> pure response
    Left err -> die $ show err

simpleCommand :: Text -> Text -> Maybe Options -> CreateApplicationCommand
simpleCommand name description options =
  CreateApplicationCommandChatInput
    { createName = name
    , createLocalizedName = Nothing
    , createDescription = description
    , createLocalizedDescription = Nothing
    , createOptions = options
    , createDefaultMemberPermissions = Nothing
    , createDMPermission = Nothing
    }
