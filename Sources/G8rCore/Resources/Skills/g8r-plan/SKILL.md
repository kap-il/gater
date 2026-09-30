---
name: g8r-plan
description: Use when writing or editing a plan doc (PLAN.md, plans/*.md, docs/plans/*.md) in a repo opened in g8r, so every component lands on g8r's map exactly as written.
---

# Writing a g8r plan

g8r draws the codebase as a map of the components a plan describes. It reads
the plan with plain code, no model, so it only understands one shape. Write
in that shape and the map is exact; drift from it and components go missing.

## The shape

```markdown
# <Project>: <what the plan is for>

Prose for people: goals, context, decisions. g8r ignores it.

## auth: Sign-in

Email and password sign-in, with sessions kept in a cookie. (The first
sentence here becomes the node's summary.)

- Needs: db
- Code: `src/auth/`, `src/middleware.ts`
- Done when: a user can sign up, sign in and sign out, and the auth tests pass.

## db: Database

Postgres through Drizzle, with migrations checked in.

- Code: `src/db/`, `drizzle/`
- Done when: `bun run migrate` works on a fresh database.
```

## Rules

- **A component is a heading at level 2, 3 or 4 written `<id>: <Name>`.**
  The id is lowercase letters, digits and hyphens, starting with a letter
  (`auth`, `api-health`, `ui2`). One id per component, unique across all
  plan docs.
- **Open each section with one plain sentence** saying what the component
  is. Not a bullet, not a table: g8r takes the first sentence of the first
  paragraph as the summary.
- **Bullets g8r reads**, exactly these keys, comma-separated values:
  - `- Needs:` ids it can't be built without. This sets the build order.
  - `- Changes:` ids of existing components it modifies.
  - `- Code:` where its code lives: files, folders ending in `/`, or globs
    (`src/**/*.test.ts`). Every component needs one, or its files end up
    under "no plan".
  - `- Done when:` a checkable finish line. The build session is told to
    stop when it holds, so make it testable.
  A long value can continue on the next line if that line is indented.
- **Components, not tasks.** A component is code that exists and stays
  (a module, a service, a page). "Set up CI" is a component (`ci`, code in
  `.github/workflows/`); "Phase 2" or "Refactor stuff" is not.
- **No status fields.** Don't write "done", "in progress" or checkboxes.
  g8r measures status from the code and the tests.
- **Needs must point at ids in the plan, and never in a circle.** A need
  that names nothing, or two components that need each other, shows up as
  a problem on the map.
- **Retiring a component:** put it under a heading named `Retired`, as a
  sub-heading with a line on why. Don't just delete it.
- **Headings inside code fences don't count**, so examples in fences are
  safe.

## Before you finish

- Every component heading matches `## id: Name`.
- Every component has a first sentence, a `Code:` line and a `Done when:`.
- Every id in `Needs:` and `Changes:` is defined somewhere in the plan.
- Nothing needs itself, directly or through others.
