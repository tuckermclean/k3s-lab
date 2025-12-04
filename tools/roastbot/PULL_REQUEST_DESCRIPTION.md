Title: RoastBot: Savage PR Reviewer that’s actually useful

Summary
-------
This PR adds RoastBot, a minimal service that watches configured GitHub repositories for new/updated pull requests and posts brutally honest, technically accurate reviews. It mocks bad code decisions without touching protected traits, while providing actionable fixes.

How it works
------------
- Configuration via config.yaml (or env vars) for:
  - GITHUB_TOKEN
  - repos: list of owner/repo
  - optional: poll_interval, branch_filters, review_commits, log_level, state_file
- Controller loop:
  - Lists open PRs for each repo
  - Skips PRs we’ve already reviewed by commit SHA
  - Fetches diff, files, and CI status
  - Builds a structured prompt with strict roasting rules
  - Sends to a pluggable LLM engine (mock implementation included)
  - Posts a PR review comment containing:
    - summary, issues, praise, one_killer_roast_line
    - an embedded marker to prevent duplicate reviews
- State tracked in a small JSON file to avoid re-review spam

How to run
----------
1) Set GITHUB_TOKEN env or in config.yaml
2) Create config.yaml from config.example.yaml and list repos
3) Run one-shot: `python -m roastbot run --config tools/roastbot/config.yaml`
4) Polling mode: `python -m roastbot poll --config tools/roastbot/config.yaml`

Docker
------
- Build: `docker build -t roastbot:dev tools/roastbot`
- Run: `docker run -e GITHUB_TOKEN=... -v $PWD/tools/roastbot/config.example.yaml:/app/config.yaml roastbot:dev run --config /app/config.yaml`

Tests
-----
- Added pytest tests for diff summarization, prompt construction, and state persistence.

Future work
-----------
- Webhook-based triggers for instant reviews
- Inline review comments per file/line
- Per-user/personality modes with roast intensity
- Repo-specific rules and policies
- GraphQL integration for richer metadata and checks
