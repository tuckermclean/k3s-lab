from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from typing import Dict, Set


@dataclass
class State:
    path: str
    reviewed_shas: Dict[str, Set[str]] = field(default_factory=dict)  # repo -> set(shas)

    def load(self) -> None:
        if not os.path.exists(self.path):
            self.reviewed_shas = {}
            return
        with open(self.path, "r", encoding="utf-8") as f:
            raw = json.load(f)
        self.reviewed_shas = {k: set(v) for k, v in raw.get("reviewed_shas", {}).items()}

    def save(self, *, max_entries: int | None = None) -> None:
        os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        data = {k: sorted(list(v))[-(max_entries or len(v)) :] for k, v in self.reviewed_shas.items()}
        with open(self.path, "w", encoding="utf-8") as f:
            json.dump({"reviewed_shas": data}, f, indent=2)

    def has_reviewed(self, repo: str, sha: str) -> bool:
        return sha in self.reviewed_shas.get(repo, set())

    def mark_reviewed(self, repo: str, sha: str) -> None:
        self.reviewed_shas.setdefault(repo, set()).add(sha)
        # optional pruning on add can be applied by caller on save
