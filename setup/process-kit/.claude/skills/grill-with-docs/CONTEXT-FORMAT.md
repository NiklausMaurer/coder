# CONTEXT.md format

```md
# {Context name}

{One or two sentences on what this context is and why it exists.}

## Language

**Order**:
{One or two sentences defining the term.}
_Avoid_: Purchase, transaction

**Invoice**:
A request for payment sent to a customer after delivery.
_Avoid_: Bill, payment request
```

## Rules

- **Be opinionated.** When several words exist for one concept, pick the best and list the
  rest under `_Avoid_`.
- **Keep definitions tight.** One or two sentences. Define what the term IS, not what it
  does.
- **Only terms specific to this project's domain.** General programming concepts
  (timeouts, error types, utility patterns) don't belong, however much the project uses
  them. Ask: is this unique to this context, or is it just programming?
- **Group under subheadings** when natural clusters emerge; a flat list is fine otherwise.

## Multiple contexts

A repo with several contexts carries a root `CONTEXT-MAP.md` naming each one, where it
lives, and how they relate:

```md
# Context map

## Contexts

- [Ordering](./src/ordering/CONTEXT.md): receives and tracks customer orders
- [Billing](./src/billing/CONTEXT.md): generates invoices and processes payments

## Relationships

- **Ordering → Billing**: Ordering emits `OrderPlaced`; Billing consumes it to invoice
- **Ordering ↔ Billing**: shared types for `CustomerId` and `Money`
```

No `CONTEXT-MAP.md` means a single context: one `CONTEXT.md` at the repo root.
