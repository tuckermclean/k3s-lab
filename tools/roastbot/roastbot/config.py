from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import List, Optional

import yaml


@dataclass
class Settings:
    github_token: str
    repos: List[str]
    poll_interval: int = 120
    review_commits: bool = False
    branch_filters: List[str] = field(default_factory=lambda: ["main", "master"])
    log_level: str = "INFO"
    state_file: str = ".roastbot_state.json"

    @staticmethod
    def from_env_or_file(path: Optional[str] = None) -> "Settings":
        cfg: dict = {}
        if path and os.path.exists(path):
            with open(path, "r", encoding="utf-8") as f:
                cfg = yaml.safe_load(f) or {}
        # Environment overrides
        token = os.getenv("GITHUB_TOKEN") or cfg.get("GITHUB_TOKEN") or cfg.get("github_token")
        if not token:
            raise ValueError("GITHUB_TOKEN not provided in env or config")
        repos = cfg.get("repos") or (os.getenv("ROASTBOT_REPOS", "").split(",") if os.getenv("ROASTBOT_REPOS") else [])
        if not repos:
            raise ValueError("No repositories configured. Provide 'repos' in config or ROASTBOT_REPOS env (comma-separated owner/repo)")
        return Settings(
            github_token=token.strip(),
            repos=[r.strip() for r in repos if r.strip()],
            poll_interval=int(os.getenv("ROASTBOT_POLL_INTERVAL", cfg.get("poll_interval", 120))),
            review_commits=bool(
                str(os.getenv("ROASTBOT_REVIEW_COMMITS", cfg.get("review_commits", False))).lower() in {"1", "true", "yes"}
            ),
            branch_filters=cfg.get("branch_filters", ["main", "master"]),
            log_level=os.getenv("ROASTBOT_LOG_LEVEL", cfg.get("log_level", "INFO")),
            state_file=os.getenv("ROASTBOT_STATE_FILE", cfg.get("state_file", ".roastbot_state.json")),
        )
