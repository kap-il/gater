---
name: gater-delegate
description: Use when sending work to another Claude session.
---

# Gater delegation format

This skill only covers **how** to format a message once you've already decided to delegate. It says nothing about when or whether to delegate — that decision is yours.

## Addressing

Send with the `SendMessage` tool. Gater names each delegate session `delegate-<name>` (for example `delegate-auth`); use that as `to`.

If no session with that name exists yet, sending a `type: delegate` message to it opens one: Gater creates the worktree (branch `gater/<name>`), starts the session, and delivers your message once it's ready. Names use letters, digits, `.`, `_` or `-`.

Unless the user named them, name a new delegate after the work it's doing (`delegate-apples`, `delegate-session-expiry`), not generically (`delegate-a`, `delegate-2`). The name becomes its branch and worktree folder, so it should say what's in them.

## Message format

Every message you send as the orchestrator must lead with a `GATER/1` block:

```
GATER/1
type: delegate | rescope | cancel | merge | instruct | finish
id: <dish id, e.g. d-007>          # new for delegate, existing otherwise
feature: <feature name>             # e.g. "Auth"
directive: <one line: what is being asked>
scope: <comma-separated paths/globs or symbols the orchestrator expects to be touched>
merge_into: <dish id>               # only for type=merge
---
<free-form instructions to the delegate>
```

A hook validates this block and will block the message (and tell you what's wrong) if it's malformed or its id doesn't fit the plan. Just fix the block and resend — nothing about the message's content or your decision to delegate is being second-guessed, only its shape.

## Dish ids

- New work is always `type: delegate` with a **new** id (`d-001`, `d-002`, …). If you're unsure which ids exist, `.gater/plan.json` in the repo lists them; a blocked message also names the next free id.
- Every other type refers to an **existing** dish id.

## Message types

- `delegate` — creates a new dish and, if the feature is new, a new feature node. Requires `feature`, `directive`, and non-empty free-form instructions.
- `rescope` — changes an existing dish's scope or directive. Requires at least one of `directive` or `scope`.
- `cancel` — kills a dish. Only `id` is required.
- `merge` — combines two dishes or features. Requires `merge_into`.
- `instruct` — an adaptive correction to an existing dish, typically sent in response to a `[GATER] overlap` wake message. Requires `directive`.
- `finish` — marks a dish as taken to the pass for finishing. Only `id` is required.

## Closing note (include this in every delegation's instructions)

Tell the delegate to end each unit of work with this block, so it needs nothing preinstalled:

```
GATER-DONE d-007
did: <what was done>
assumed: <assumptions made — this is where context breaks surface>
touched: <optional; Gater verifies against actual edits anyway>
```
