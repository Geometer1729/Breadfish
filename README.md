# bread-bot

A small [discord-haskell](https://hackage.haskell.org/package/discord-haskell)
bot starter, built with Cabal and Nix.

The included bot registers a global `/ping` command and responds with `Pong!`.
Its command response is kept pure and covered by a small Hspec test so that bot
logic can grow without requiring a Discord connection in tests.

## Development

Enter the development shell directly:

```console
nix develop
```

Or load it automatically with direnv:

```console
direnv allow
```

Useful commands are exposed through `just`:

```console
just build
just test
just fmt
just check
```

The flake exposes the same executable as its default package and app, so
`nix build` and `nix run` also work.

## Discord Setup

1. Create an application and bot in the
   [Discord Developer Portal](https://discord.com/developers/applications).
2. Install it in a server with the `bot` and `applications.commands` scopes.
3. Provide the bot token through `DISCORD_TOKEN`:

```console
DISCORD_TOKEN='your-token' just run
```

For compatibility with the sibling bots, you can instead put the token in a
local `token.auth` file or pass it as the executable's only argument. Both
`.env*` and `token.auth` are ignored by Git.

Global commands can take time to propagate in Discord. For rapid command-schema
iteration, replace the global registration requests in `src/Bot.hs` with guild
registration requests for a development server.

## Extending The Bot

- Add slash-command definitions to `commands` in `src/Bot.hs`.
- Add pure command behavior to `commandResponse` and test it in `test/Spec.hs`.
- Extend `eventHandler` for components, autocomplete, messages, or guild events.
- Enable only the gateway intents required by those new event handlers in
  `app/Main.hs`; the starter command needs no privileged intents.
