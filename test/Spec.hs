module Main (main) where

import Bot (commandResponse, messageUrl, recommendationWeight)
import Discord.Types (DiscordId (..), Snowflake (..))
import Test.Hspec (describe, hspec, it, shouldBe, shouldSatisfy)

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
  describe "recommendationWeight" $ do
    it "favors messages with more bread reactions" $
      recommendationWeight 30 9 0 `shouldSatisfy` (> recommendationWeight 30 1 0)
    it "favors older messages" $
      recommendationWeight 365 1 0 `shouldSatisfy` (> recommendationWeight 1 1 0)
    it "reduces the weight after each selection" $
      recommendationWeight 30 1 1 `shouldBe` recommendationWeight 30 1 0 / 4

discordId :: Word64 -> DiscordId a
discordId = DiscordId . Snowflake
