module Main (main) where

import Bot (eventHandler, newBreadState)
import Data.Text qualified as Text
import Discord (RunDiscordOpts (..), def, runDiscord)
import Discord.Types (GatewayIntent (..))

main :: IO ()
main = do
  token <- loadToken
  breadState <- newBreadState
  runDiscord
    def
      { discordToken = token
      , discordOnStart = liftIO $ putTextLn "Starting bread-bot"
      , discordOnEvent = eventHandler breadState
      , discordGatewayIntent = def {gatewayIntentMessageContent = True}
      }
    >>= print

loadToken :: IO Text
loadToken = do
  rawToken <-
    getArgs >>= \case
      [] ->
        lookupEnv "DISCORD_TOKEN" >>= \case
          Just token -> pure $ fromString token
          Nothing -> decodeUtf8 <$> readFileBS "token.auth"
      [token] -> pure $ fromString token
      _ -> die "Usage: bread-bot [TOKEN]"
  let token = Text.strip rawToken
  when (Text.null token) $ die "The Discord token must not be empty"
  pure token
