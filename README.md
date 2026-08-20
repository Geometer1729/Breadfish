# bread-bot

A small [discord-haskell](https://hackage.haskell.org/package/discord-haskell)
bot starter, built with Cabal and Nix.

The included bot registers `/ping` and `/bread` commands. A background worker
scans each server's readable text and news channel history for messages with a
standard bread reaction, adding results to an in-memory index page by page.
`/bread` chooses from whatever has been indexed so far. Messages with more
bread reactions and older messages receive more weight, with diminishing
returns, while each selection reduces that message's weight to discourage
repeats. Reaction and deletion events keep the index current until the bot
restarts, when selection history is reset.

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
2. Enable Message Content Intent on the application's **Bot** page. Discord
   gates historical attachment metadata behind this intent.
3. Install Breadfish using the
   [server authorization link](https://discord.com/oauth2/authorize?client_id=1539782184850952392&permissions=68608&scope=bot%20applications.commands).
   It requests the `bot` and `applications.commands` scopes with View Channels,
   Send Messages, and Read Message History permissions. An
   `applications.commands`-only installation can respond to slash commands but
   cannot read server channels.
4. Provide the bot token through `DISCORD_TOKEN`:

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
- Enable only the gateway intents required by event handlers in `app/Main.hs`.

The history scan intentionally excludes threads and channels the bot cannot
read. A persistent index is the next step if repeating the background scan on
each restart becomes too expensive.
