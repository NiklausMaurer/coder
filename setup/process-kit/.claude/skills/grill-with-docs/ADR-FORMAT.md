# ADR format

ADRs live in `docs/adr/`, numbered sequentially — `0001-slug.md`, `0002-slug.md`. Scan the
directory for the highest number and increment. Create the directory lazily, with the
first ADR.

```md
# {Short title of the decision}

{1-3 sentences: the context, what was decided, and why.}
```

That's the whole template. An ADR can be one paragraph — the value is recording _that_ a
decision was made and _why_, not filling out sections. Add **Status** frontmatter
(`proposed | accepted | deprecated | superseded by ADR-NNNN`), **Considered options** or
**Consequences** only when they carry genuine value; most ADRs need none of them.

## What earns one

All three gates must hold: hard to reverse, surprising without context, the result of a
real trade-off. Typical qualifiers:

- **Architectural shape** — "the write model is event-sourced, the read model projected
  into Postgres".
- **Integration patterns between contexts** — "Ordering and Billing talk via domain
  events, not synchronous HTTP".
- **Technology choices carrying lock-in** — database, message bus, auth provider,
  deployment target. Not every library: the ones that would take a quarter to swap.
- **Boundary and scope decisions** — "Customer data is owned by the Customer context;
  others reference it by ID". The explicit no-s are as valuable as the yes-s.
- **Deliberate deviations from the obvious path** — "manual SQL instead of an ORM
  because X". These stop the next engineer from "fixing" something that was intentional.
- **Constraints invisible in the code** — compliance, a partner API's response-time
  contract.
- **Rejected alternatives whose rejection is non-obvious** — otherwise someone proposes
  GraphQL again in six months.
