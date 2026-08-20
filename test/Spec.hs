module Main (main) where

import Bot (commandResponse)
import Test.Hspec (describe, hspec, it, shouldBe)

main :: IO ()
main =
  hspec $
    describe "commandResponse" $ do
      it "responds to ping" $
        commandResponse "ping" `shouldBe` Just "Pong!"
      it "ignores unknown commands" $
        commandResponse "unknown" `shouldBe` Nothing
