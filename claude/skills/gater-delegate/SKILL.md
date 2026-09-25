---
name: gater-delegate
description: Use when sending work to another Claude session.
---

# Gater delegation format

This skill only covers **how** to format a message once you've already decided to delegate. It says nothing about when or whether to delegate — that decision is yours.

## Message format

Every cross-session message you send as the orchestrator must lead with a `GATER/1` block:

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

A hook validates this format and will block the message (and tell you what's wrong) if it's malformed. Just fix the block and resend — nothing about the message's content or your decision to delegate is being second-guessed, only its shape.

## Message types

- `delegate` — creates a new dish and, if the feature is new, a new feature node. Requires `feature`, `directive`, and non-empty free-form instructions.
- `rescope` — changes an existing dish's scope or directive. Requires at least one of `directive` or `scope`.
- `cancel` — kills a dish. Only `id` is required.
- `merge` — combines two dishes or features. Requires `merge_into`.
- `instruct` — an adaptive correction, typically sent in response to a `[GATER] overlap` wake message. Requires `directive`.
- `finish` — marks a dish as taken to the pass for finishing. Only `id` is required.

## Closing note (include this in every delegation's instructions)

Tell the delegate to end each unit of work with this block, so it needs nothing preinstalled:

```
GATER-DONE d-007
did: <what was done>
assumed: <assumptions made — this is where context breaks surface>
touched: <optional; Gater verifies against actual edits anyway>
```
