{-# LANGUAGE TemplateHaskell #-}

module Bot (
  BreadState,
  commandResponse,
  eventHandler,
  messageUrl,
  newBreadState,
  recommendationWeight,
) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM.TVar (stateTVar)
import Control.Lens (
  assign,
  at,
  ix,
  makeLenses,
  modifying,
  traversed,
  use,
  (^.),
 )
import Control.Monad.Trans.Except (except, throwE)
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
  { _indexedBreadMessages :: [BreadMessage]
  , _breadScanStatus :: BreadScanStatus
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

makeLenses ''GuildBreadIndex

newBreadState :: IO BreadState
newBreadState = BreadState <$> newTVarIO Map.empty

atomicBreadState ::
  BreadState -> State (Map GuildId GuildBreadIndex) a -> IO a
atomicBreadState (BreadState breadByGuild) action =
  atomically $ stateTVar breadByGuild $ runState action

readBreadState ::
  BreadState -> (Map GuildId GuildBreadIndex -> a) -> IO a
readBreadState (BreadState breadByGuild) query =
  query <$> readTVarIO breadByGuild

commands :: [CreateApplicationCommand]
commands =
  [ simpleCommand "ping" "Check whether the bot is running"
  , simpleCommand "bread" "Find a random message with a bread reaction"
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
  InteractionCreate
    interaction@InteractionApplicationCommand
      { applicationCommandData =
        ApplicationCommandDataChatInput
          { applicationCommandDataName = commandName
          }
      }
      | commandName == "bread" -> handleBread breadState interaction
      | Just content <- commandResponse commandName ->
          respondWith interaction $ interactionResponseBasic content
  MessageReactionAdd reaction ->
    refreshBreadReaction
      breadState
      (reactionEmoji reaction)
      (reactionGuildId reaction)
      (reactionChannelId reaction)
      (reactionMessageId reaction)
  MessageReactionRemove reaction ->
    refreshBreadReaction
      breadState
      (reactionEmoji reaction)
      (reactionGuildId reaction)
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
  result <- runExceptT $ do
    guildId <-
      except $
        maybeToRight
          "`/bread` can only be used in a server."
          (interactionGuildId interaction)
    breadIndex <-
      liftIO (readBreadIndex breadState guildId)
        >>= maybe (throwE $ emptyBreadResponse Nothing) pure
    message <-
      lift (selectBreadMessage breadState $ breadIndex ^. indexedBreadMessages)
        >>= \case
          Just message -> pure message
          Nothing -> do
            currentStatus <-
              liftIO $
                fmap (^. breadScanStatus) <$> readBreadIndex breadState guildId
            throwE $ emptyBreadResponse currentStatus
    pure (guildId, message)
  finishInteraction interaction $ either id (uncurry breadResponse) result

startBreadScan :: BreadState -> GuildId -> [Channel] -> DiscordHandler ()
startBreadScan breadState guildId channels = do
  shouldStart <- liftIO $ beginBreadScan breadState guildId
  when shouldStart $ do
    putTextLn $ "Starting bread scan for guild " <> show guildId
    discordHandle <- ask
    void $
      liftIO $
        forkIO $
          runReaderT (scanGuild breadState guildId channels) discordHandle

scanGuild :: BreadState -> GuildId -> [Channel] -> DiscordHandler ()
scanGuild breadState guildId channels = do
  let historyChannels = mapMaybe historyChannel channels
  putTextLn $
    "Scanning " <> show (length historyChannels) <> " channels for bread"
  traverse_
    (uncurry $ scanChannel breadState guildId)
    historyChannels
  liftIO $ setBreadScanStatus breadState guildId BreadComplete
  breadCount <-
    liftIO $
      maybe 0 (length . (^. indexedBreadMessages))
        <$> readBreadIndex breadState guildId
  putTextLn $ "Bread index contains " <> show breadCount <> " messages"

historyChannel :: Channel -> Maybe (ChannelId, Text)
historyChannel = \case
  channel@ChannelText {} -> Just (channelId channel, channelName channel)
  channel@ChannelNews {} -> Just (channelId channel, channelName channel)
  _ -> Nothing

scanChannel :: BreadState -> GuildId -> ChannelId -> Text -> DiscordHandler ()
scanChannel breadState guildId sourceChannelId sourceChannelName = do
  putTextLn $
    "Starting channel #" <> sourceChannelName <> " (" <> show sourceChannelId <> ")"
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
          if
            | length messages < 100 -> pure (messagesChecked', breadFound')
            | oldest : _ <- reverse messages ->
                go (BeforeMessage $ messageId oldest) messagesChecked' breadFound'
            | otherwise -> pure (messagesChecked', breadFound')

toBreadMessage :: GuildId -> Message -> Maybe BreadMessage
toBreadMessage guildId message = do
  let reactionCount = messageBreadCount message
  guard $ reactionCount > 0
  pure
    BreadMessage
      { breadGuildId = guildId
      , breadChannelId = messageChannelId message
      , breadMessageId = messageId message
      , breadReactionCount = reactionCount
      , breadPostedAt = messageTimestamp message
      , breadSelectionCount = 0
      }

messageBreadCount :: Message -> Int
messageBreadCount =
  sum
    . map messageReactionCount
    . filter (isBreadEmoji . messageReactionEmoji)
    . messageReactions

isBreadEmoji :: Emoji -> Bool
isBreadEmoji emoji = isNothing (emojiId emoji) && emojiName emoji == "🍞"

selectBreadMessage ::
  BreadState -> [BreadMessage] -> DiscordHandler (Maybe Message)
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

refreshBreadReaction ::
  BreadState ->
  Emoji ->
  Maybe GuildId ->
  ChannelId ->
  MessageId ->
  DiscordHandler ()
refreshBreadReaction breadState emoji guildId sourceChannelId sourceMessageId =
  when (isBreadEmoji emoji) $
    whenJust guildId $ \sourceGuildId ->
      refreshBreadMessage
        breadState
        sourceGuildId
        sourceChannelId
        sourceMessageId

refreshBreadMessage ::
  BreadState ->
  GuildId ->
  ChannelId ->
  MessageId ->
  DiscordHandler ()
refreshBreadMessage breadState guildId sourceChannelId sourceMessageId =
  restCall (GetChannelMessage (sourceChannelId, sourceMessageId)) >>= \case
    Right message ->
      liftIO $ case toBreadMessage guildId message of
        Just breadMessage -> addBreadMessage breadState breadMessage
        Nothing -> removeBreadMessageEverywhere breadState sourceChannelId sourceMessageId
    Left err ->
      putTextLn $
        "Failed to refresh bread message " <> show sourceMessageId <> ": " <> show err

addBreadMessage :: BreadState -> BreadMessage -> IO ()
addBreadMessage breadState message =
  addBreadMessages breadState (breadGuildId message) [message]

addBreadMessages :: BreadState -> GuildId -> [BreadMessage] -> IO ()
addBreadMessages breadState guildId messages =
  modifyBreadMessages breadState guildId $ \existing ->
    foldr upsertBreadMessage existing messages

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
markBreadSelected breadState selected =
  modifyBreadMessages breadState (breadGuildId selected) $
    map $ \message ->
      if sameBreadMessage message selected
        then message {breadSelectionCount = breadSelectionCount message + 1}
        else message

removeBreadMessage :: BreadState -> BreadMessage -> IO ()
removeBreadMessage breadState message =
  modifyBreadMessages breadState (breadGuildId message) $
    filter $
      not . sameBreadMessage message

removeBreadMessageEverywhere :: BreadState -> ChannelId -> MessageId -> IO ()
removeBreadMessageEverywhere
  breadState
  sourceChannelId
  sourceMessageId =
    atomicBreadState breadState $
      modifying (traversed . indexedBreadMessages) $
        filter $ \message ->
          breadChannelId message /= sourceChannelId
            || breadMessageId message /= sourceMessageId

beginBreadScan :: BreadState -> GuildId -> IO Bool
beginBreadScan breadState guildId =
  atomicBreadState breadState $ do
    existing <- use $ at guildId
    case existing of
      Just _ -> pure False
      Nothing -> do
        assign (at guildId) $ Just $ GuildBreadIndex [] BreadScanning
        pure True

readBreadIndex :: BreadState -> GuildId -> IO (Maybe GuildBreadIndex)
readBreadIndex breadState guildId =
  readBreadState breadState (^. at guildId)

setBreadScanStatus :: BreadState -> GuildId -> BreadScanStatus -> IO ()
setBreadScanStatus breadState guildId status =
  atomicBreadState breadState $
    assign (ix guildId . breadScanStatus) status

modifyBreadMessages ::
  BreadState -> GuildId -> ([BreadMessage] -> [BreadMessage]) -> IO ()
modifyBreadMessages breadState guildId update =
  atomicBreadState breadState $
    modifying (ix guildId . indexedBreadMessages) update

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

discordCall_ ::
  (Request (request response), FromJSON response) =>
  request response -> DiscordHandler ()
discordCall_ = void . discordCall

discordCall ::
  (Request (request response), FromJSON response) =>
  request response -> DiscordHandler response
discordCall request =
  restCall request >>= \case
    Right response -> pure response
    Left err -> die $ show err

simpleCommand :: Text -> Text -> CreateApplicationCommand
simpleCommand name description =
  CreateApplicationCommandChatInput
    { createName = name
    , createLocalizedName = Nothing
    , createDescription = description
    , createLocalizedDescription = Nothing
    , createOptions = Nothing
    , createDefaultMemberPermissions = Nothing
    , createDMPermission = Nothing
    }
