# Breadfish Style Guide

Read this before editing Breadfish.

## The Spirit

The code should be direct-style `do` blocks that read like the domain rules:
boring, concrete, pure wherever possible, with IO pushed to the edges.

Treat complexity as a sacrifice grudgingly made when it can't be avoided, and
make the sacrifice once rather than a little bit everywhere.

## General

- Prefer the smallest change that makes similar code identical.
- If two branches differ only by wording, wrapper shape, or incidental plumbing,
  unify them unless there is a concrete behavioral reason not to.
- Treat extra names, branches, and helper functions as costs unless they explain
  domain intent.
- Prefer fewer lines when the shorter version is still obvious to a Haskell
  reader.
- Run `just fmt` after making Haskell changes; it includes Fourmolu and HLint.
- Favor pure code whenever possible.
- Keep the build warning-clean; opt out of a specific warning with a stated
  reason rather than tolerating noise.
- Modules should be modular; minimize exports
  try to have a clear comprehensible interface
  don't just use them as buckets for where to drop functions

## Haskell

- Enable broadly safe extensions in the Cabal `default-extensions` rather than
  per-module pragmas. Extensions that change desugaring or evaluation go
  package-wide only when the whole package wants those semantics.
- Prefer `x <- fst <$> f` over `(x, _) <- f`.
- Prefer `Maybe` `do` over nested `case ... of Just/Nothing` plumbing for
  step-by-step parsers.
- In `Maybe` `do` blocks, prefer `guard cond; pure x` over
  `if cond then Just x else Nothing`.
- In list `do` blocks, prefer `guard cond; xs` over
  `if cond then xs else []`.
- Pull local `let`/`where` helpers into the `do` when they only sequence or name
  intermediate steps.
- Recursively apply these rules inside local `let`/`where` helpers. Do not stop
  after simplifying only the outer function.
- Lean on `LambdaCase` (`eventHandler breadState = \case`) instead of naming an
  argument only to inspect it with `case`.
- Lean on `MultiWayIf` instead of if/else staircases.
- List comprehensions are encouraged, including pattern-match guards
  (`channel@ChannelText {} <- channels`) and boolean singletons
  (`[message | messageBreadCount message > 0]`).
- When the same big constraint list repeats across a module, make a constraint
  alias and just extend it when GHC asks.

## Point-Free And Inlining

Point-free style is not always best, but it is often useful here.

- Plumbing does not earn names. Inline aggressively when a local name adds no
  meaning, especially one-use `let`/`where` helpers and pipeline temporaries.
- In every `let`/`where`, check whether a binding is used exactly once by the
  next binding. If so, strongly consider deleting the name and composing the
  right-hand sides.
- Names like `items`, `segments`, `parts`, `rebuilt`, `result`, `cleaned`,
  `stripped`, and `sanitized*` are usually not documentation. Inline them unless
  the surrounding domain meaning gets clearer with the name.
- Prefer point-free/combinator style when it removes throwaway names without
  hurting readability.
- Collapse linear `let` pipelines into composition. For example,
  `c = h b; b = g a; a = f x` should usually become `h . g . f` or
  `h (g (f x))`.
- When the same simple function or test is repeated across several values,
  consider a static list plus `any`, `all`, `map`, `or`, `and`, or `on`.
- Useful combinators to consider: `($)`, `(.)`, `(&)`, `on`, `first`, `second`,
  `(***)`, `(&&&)`, `<$>`, and `<&>`.

## Errors And Partiality

- `error` is for broken invariants and programmer mistakes only — never for
  states the program can legitimately reach. Make the message specific, and
  funny if you can manage it.
- Where crashing is worse than degrading (rendering, cosmetics), log the
  failure to the app log and carry on instead of throwing.
- Debug output goes through the app's debug channel, not stdout.

## Comments

- Comments explain domain rules, invariants, and TODOs — not what the next line
  does.
- First person, informal, and jokes are house style. Don't sand the personality
  off existing comments.
- A superseded implementation may sit in a comment block while its replacement
  is fresh; delete it once it stops earning its keep.

## Smells

When a function has one of these smells, look harder for a simpler shape:

- Large indentation blocks, especially `if ... then ... else do` staircases.
- Long lines, especially over 80 columns.
- Function bodies longer than 60 lines, except for genuinely linear pipeline
  flows.
- Nested calls like `f (g (h x))` where `$`, `.`, or a clearer pipeline would be
  easier to read.
- Trivial wrapper functions are almost always bad.
- Avoidable IO.
