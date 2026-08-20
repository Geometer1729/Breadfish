module Main (main) where

import Bot (commandResponse, messageUrl)
import Discord.Types (DiscordId (..), Snowflake (..))
import Test.Hspec (describe, hspec, it, shouldBe)

main :: IO ()
main = hspec $ do
  describe "commandResponse" $ do
    it "responds to ping" $
      commandResponse "ping" `shouldBe` Just "Pong!"
    it "ignores unknown commands" $
      commandResponse "unknown" `shouldBe` Nothing
  describe "messageUrl" $
    it "creates a Discord message jump link" $
      messageUrl (discordId 1) (discordId 2) (discordId 3)
        `shouldBe` "https://discord.com/channels/1/2/3"

discordId :: Word64 -> DiscordId a
discordId = DiscordId . Snowflake
