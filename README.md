# Breadfish

Breadfish is a Discord bot for resurfacing memorable server posts. React to a
message with the standard Unicode 🍞 emoji, then use `/bread` to get a weighted
random classic from the server's history.

> **AI-generated code disclaimer:** All code in this repository was generated
> by AI. Treat it as unaudited software: review the implementation, permissions,
> dependencies, and token handling before running it in a server you care about.

## Add Breadfish To A Server

Use the
[Breadfish authorization link](https://discord.com/oauth2/authorize?client_id=1539782184850952392&permissions=68608&scope=bot%20applications.commands),
choose a server, and approve the requested permissions.

The link requests the `bot` and `applications.commands` scopes with these bot
permissions:

- View Channels
- Send Messages
- Read Message History

Installing only the `applications.commands` scope is not enough. The commands
will appear and `/ping` can respond, but Breadfish will not be a server member
and cannot scan channel history.

After Breadfish joins, it begins indexing readable text and announcement
channels in the background. `/bread` can use partial results while that scan is
still running.

### Privacy Warning

Breadfish indexes every channel it can read. It does not currently verify that
the person invoking `/bread` can access the selected source channel. Discord
will protect the message jump link, but direct attachment URLs included in the
response may expose files from private channels. Restrict the bot's channel
permissions accordingly.

## Commands

- `/ping` checks whether the bot is responding.
- `/bread` returns a message carrying at least one standard 🍞 reaction.

Custom server emojis named `bread` do not count. Threads are not scanned.

Recommendations are weighted by reaction count, message age, and how often a
message has already been selected:

```text
weight = sqrt(bread reactions)
       * (1 + log2(1 + age in days / 30))
       / (1 + selections)^2
```

The index and selection history are kept in memory. Restarting Breadfish clears
both and starts a new history scan.

## Self-Hosting

1. Create an application and bot in the
   [Discord Developer Portal](https://discord.com/developers/applications).
2. Enable **Message Content Intent** on the application's **Bot** page. Discord
   gates historical attachment metadata behind this intent.
3. Install the application with the `bot` and `applications.commands` scopes.
   Grant View Channels, Send Messages, and Read Message History only where the
   bot should operate.
4. Clone this repository and enter its Nix development shell:

```console
nix develop
```

5. Run the bot with its token:

```console
DISCORD_TOKEN='your-token' just run
```

You can instead put the token in a local `token.auth` file or pass it as the
executable's only argument. `.env*` and `token.auth` are ignored by Git. Do not
commit a bot token.

The flake also exposes the executable as its default app, so this works outside
the development shell:

```console
DISCORD_TOKEN='your-token' nix run
```

## Development

Run `direnv allow` if you want direnv to load the Nix shell automatically.
Common commands are available through `just`:

```console
just build  # Build every Cabal component
just test   # Run the Hspec suite
just fmt    # Format Haskell, Cabal, and Nix files
just check  # Run all flake checks
just run    # Start Breadfish
```

The main files are:

- `app/Main.hs`: token loading, gateway intents, and Discord startup.
- `src/Bot.hs`: command registration, event handling, history scanning, the
  in-memory index, and recommendation weighting.
- `test/Spec.hs`: pure command, URL, and recommendation-weight tests.
- `bread-bot.cabal`: components, compiler settings, and dependencies.
- `flake.nix` and `nix/`: reproducible development, build, and check setup.

### Adding A Feature

1. Add or modify application-command definitions in `commands` in `src/Bot.hs`.
2. Handle the corresponding interaction or gateway event in `eventHandler`.
3. Keep logic pure where practical and add focused tests in `test/Spec.hs`.
4. Add only the Discord gateway intents and bot permissions the feature needs.
5. Run `just fmt`, `just test`, and `just check` before committing.

Global application commands can take time to propagate. During command-schema
development, guild command registration provides faster updates than the global
registration used by `syncCommands`.

### Current Architecture And Limits

- A `GuildCreate` event starts one background scan per server.
- Channels are scanned sequentially in pages of 100 messages.
- The STM-backed index becomes usable as each page completes.
- Bread reaction and message deletion events update the live index.
- A restart loses the index and repeat penalties, then scans all history again.
- Inaccessible channels are skipped after Discord returns an error.
- Persistent storage is not implemented.
