# Problem Description

I want to build an autonomous loop that works with the development process
implemented in `../nikos` (check out the `/refine`, `/implement` skills and the
`slice-lander` agent over there for details).

## The goal

I want an autonomous loop that periodically:

1. Pulls the repository.
2. Checks for stories in `todo` or `refined`.
3. Works on them until either done or human input is needed.
4. Pulls again, and so forth.

## Requirements

- The loop should be easily applicable to any git repository/branch that adheres
  to the same development process.
- Ideally, I only have to configure the git repo (and, of course, make sure all
  permissions are there).
- The loop will run in isolation.
