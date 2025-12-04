RoastBot - Brutal, Useful Code Roast Reviews for GitHub
=======================================================

Purpose
-------
RoastBot hunts your GitHub repos for fresh PRs (and optionally commits) and delivers a savage, technically accurate roast. It mocks bad naming, janky architecture, and fragile code while still giving real, actionable fixes. No personal attacks — only surgical takedowns of questionable engineering decisions.

Features
--------
- Watches configured repos for new/updated PRs (and optionally protected branch commits)
- Fetches diffs, metadata, and basic CI status
- Sends a structured review request to a pluggable LLM engine
- Posts a summary PR review comment (inline comments optional for future)
- Tracks reviewed commit SHAs to avoid re-roasting the same changes
- CLI for one-shot runs or a daemon-style polling loop

Safety and Tone
---------------
- Aggressively roasts the code, never the person
- Strictly avoids protected-class harassment
- Hard-hitting, sarcastic tone with genuinely useful advice

Quickstart
----------
1. Copy config.example.yaml to config.yaml and set values
2. Export GITHUB_TOKEN or set it in the config file
3. Run once: `python -m roastbot run --config config.yaml`
4. Poll forever: `python -m roastbot poll --interval 120`

Docker
------
- Build: `docker build -t roastbot:dev tools/roastbot`
- Run: `docker run -e GITHUB_TOKEN=... -e OPENAI_API_KEY=sk-... -v $PWD/tools/roastbot/config.example.yaml:/app/config.yaml roastbot:dev run --config /app/config.yaml`

Tests
-----
`pytest -q`

Future Work
-----------
- Webhook receiver for instant reviews
- Inline review comments with path/line references
- Per-user/persona modes and roast intensity knobs
- Repo-specific rules and checklists
- GraphQL for richer metadata and CI surfaces
