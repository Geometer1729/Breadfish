module Bot (
  commandResponse,
  commands,
  eventHandler,
) where

import Discord (DiscordHandler, FromJSON, Request, restCall)
import Discord.Interactions (
  ApplicationCommandData (..),
  CreateApplicationCommand (..),
  Interaction (..),
  Options,
  interactionResponseBasic,
 )
import Discord.Internal.Rest.ApplicationCommands (
  ApplicationCommandRequest (..),
 )
import Discord.Internal.Rest.Interactions (InteractionResponseRequest (..))
import Discord.Internal.Types.Events (Event (..))
import Discord.Types (
  ApplicationId,
  PartialApplication (..),
 )

commands :: [CreateApplicationCommand]
commands = [simpleCommand "ping" "Check whether the bot is running" Nothing]

commandResponse :: Text -> Maybe Text
commandResponse = \case
  "ping" -> Just "Pong!"
  _ -> Nothing

eventHandler :: Event -> DiscordHandler ()
eventHandler = \case
  Ready _ _ _ _ _ _ (PartialApplication applicationId _) -> do
    putTextLn "Connected to Discord"
    syncCommands applicationId
    putTextLn "Application commands registered"
  InteractionCreate interaction ->
    case interaction of
      InteractionApplicationCommand
        { applicationCommandData =
          ApplicationCommandDataChatInput
            { applicationCommandDataName = commandName
            }
        } ->
          whenJust (commandResponse commandName) $ respond interaction
      _ -> pass
  _ -> pass

syncCommands :: ApplicationId -> DiscordHandler ()
syncCommands applicationId =
  discordCall_ $ BulkOverWriteGlobalApplicationCommand applicationId commands

respond :: Interaction -> Text -> DiscordHandler ()
respond interaction content =
  discordCall_ $
    CreateInteractionResponse
      (interactionId interaction)
      (interactionToken interaction)
      (interactionResponseBasic content)

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
