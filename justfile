default:
    @just --list

# Build every Cabal component
build:
    cabal build all

# Run the test suite
test:
    cabal test all

# Format Haskell, Cabal, and Nix sources
fmt:
    nix fmt

# Run all Nix-provided checks
check:
    nix flake check --print-build-logs

# Start a Cabal REPL for the bot library
repl:
    cabal repl lib:bread-bot

# Run the Discord bot
run:
    cabal run bread-bot
