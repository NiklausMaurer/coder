---
name: grill-with-docs
description: Interview the user relentlessly about a plan or design until every branch of the decision tree is settled, sharpening the project's vocabulary and writing resolved terms into CONTEXT.md and hard decisions into docs/adr/ as they crystallise. Use when the user wants to stress-test a plan or design, get grilled on it, or mentions "grill me".
---

# Grill With Docs

Interview the user relentlessly until you reach a shared understanding. Map this as a
**design tree**: every decision branches into the decisions that hang off it. The session
leaves files behind — the vocabulary you settle and the decisions you make land in the
repo as you go, not in the user's head.

## The interview

Work the tree in **rounds**. The **frontier** is every decision whose prerequisites are
already settled: the questions you can ask _now_ without guessing at answers you haven't
heard yet. Ask the whole frontier in one round, then wait for the user's answers before
the next round.

```
❓ **Q1** - **<question title>**: <question body, may be several paragraphs, may offer choices>

➡️ <your recommended answer>

---

❓ **Q2** - **<question title>**: <question body>

➡️ <your recommended answer>
```

Each round's answers reshape the tree: settled decisions push the frontier outward and
unblock the questions that depended on them. Recompute the frontier and ask the next
round. A question whose answer depends on another question still open in this round
belongs to a _later_ round, not this one.

Finding **facts** is your job, never the user's. When a frontier question needs a fact
from the environment, dispatch a subagent to find it rather than asking. Don't block on
it: a running exploration is an unsettled prerequisite, so only the questions downstream
of it wait — ask the rest of the frontier now. The **decisions** are the user's: put each
to them and wait.

The session is done when the frontier is empty: every branch visited, nothing left
silently assumed. Do not act on the plan until the user confirms you have reached a
shared understanding.

## Domain awareness

While exploring the codebase, read the documentation it already carries. A root
`CONTEXT.md` is the project's glossary; a root `CONTEXT-MAP.md` instead means the repo has
several contexts and points at where each one's `CONTEXT.md` and `docs/adr/` live. Decide
which context the topic belongs to, and ask if it's unclear.

Create these files **lazily** — only when you have something to write. No `CONTEXT.md`
yet? Create one when the first term resolves. No `docs/adr/`? Create it when the first ADR
is needed.

### Challenge against the glossary

When a term the user uses conflicts with the language in `CONTEXT.md`, call it out
immediately: "your glossary defines 'cancellation' as X, but you seem to mean Y — which is
it?"

### Sharpen fuzzy language

When the user reaches for a vague or overloaded term, propose a precise canonical one:
"you're saying 'account' — do you mean the Customer or the User? Those are different
things."

### Stress-test with concrete scenarios

When domain relationships come up, invent specific scenarios that probe the edges and
force the user to be precise about where one concept ends and the next begins.

### Cross-reference with code

When the user states how something works, check whether the code agrees. Surface any
contradiction: "your code cancels entire Orders, but you just said partial cancellation is
possible — which is right?"

### Write it down as it resolves

The moment a term is settled, update `CONTEXT.md` — inline, never batched at the end. Use
the format in [CONTEXT-FORMAT.md](./CONTEXT-FORMAT.md). `CONTEXT.md` is a glossary and
nothing else: keep implementation details, specs and scratch notes out of it.

Offer an ADR only when all three hold — **hard to reverse**, **surprising without
context**, and **the result of a real trade-off**. If any is missing, skip it. Use the
format in [ADR-FORMAT.md](./ADR-FORMAT.md).

<!--
Attribution: adapted from `skills/productivity/grilling` and
`skills/engineering/domain-modeling` in Matt Pocock's "Skills For Real Engineers"
(https://github.com/mattpocock/skills). Used under the MIT License —
Copyright (c) 2026 Matt Pocock.
-->
