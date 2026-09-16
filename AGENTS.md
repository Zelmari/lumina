# Agent rules

Follow this file for how you work in this repo. Product behavior lives in `plans/SPEC_LUMINA.md` and `plans/DESIGN_DOC_LUMINA.md`. Implementation order lives in `plans/Breakpoints.md`.

## Git and GitHub

These rules apply to every `git` and `gh` command. Read this section before the first one in a session. Do not invent a different branching, commit, or PR policy.

### Branch

- Work on `main` by default. Do not create, rename, or switch branches unless the user tells you to.
- When you **are** told to use a branch, name it `<type>/<short-kebab-description>`:
  - `type` is one of: `feat`, `fix`, `docs`, `test`, `chore`, `refactor`, `ci`, `perf`
  - description is lowercase kebab-case, no spaces, no issue-number-only names
  - examples: `feat/spiral-insert`, `fix/ax-generation-ignore`, `docs/install-bundle-script`
- Do not use `update`, `wip`, `temp`, `foo`, or a breakpoint number alone as the branch name. A breakpoint may appear in the description (`feat/bp-02-spiral-tree`) but type + meaning are required.

### Commits

- Use [Conventional Commits](https://www.conventionalcommits.org/):
  - `feat: add spiral insert and collapse`
  - `fix: clamp sibling before floating overflow tile`
  - `docs: document 1px stash remnant`
  - `test: cover spatial focus strip rule`
  - `chore: add TOMLDecoder dependency`
  - `refactor: extract MutationQueue`
  - `ci: run layout tests on arm64`
- Subject: imperative, lowercase after the type, no trailing period, ≤72 characters. Match the existing history (`chore: cleanup`, `chore: initial file structure`).
- Body (when needed): explain **why**, not a file list. Wrap at 72 characters.
- One logical change per commit. Do not mix unrelated breakpoints in one commit unless the user asked for a single catch-up commit.
- Never commit secrets, signing identities, or `.env`.
- Only commit when the user asked, or when the current plan step explicitly requires a commit.

### Pull requests

- PR title uses the same Conventional Commit form as a subject line (`feat: …`, `fix: …`).
- PR description must explain the change well enough to review without the chat log. Include:
  - **Summary** — what landed and why (1–3 bullets)
  - **Test plan** — commands run, and what a reviewer should check
  - notable follow-ups or known gaps, if any
- Do not open a PR with an empty or one-line description.
- **Never merge a pull request** (`gh pr merge`, GitHub merge button, merge commit into `main` from a PR) unless the user explicitly tells you to merge it.

### Push and CI

- If this repo has CI/CD, **push when you need those checks**. Do not wait until the very end of a long branch of work if intermediate pushes are what make CI run on your commits.
- Before the **final commit** of a piece of work, and **before you open or request review on a PR**, existing CI/CD checks must be green. Wait for them. If they fail, fix the failure and push again. Do not submit or leave a PR that you know has red checks.
- If there is no CI yet, do not invent a workflow unless asked. Still run the tests the plan names locally.
