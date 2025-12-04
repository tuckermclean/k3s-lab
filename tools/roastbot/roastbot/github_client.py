from __future__ import annotations

import hashlib
import logging
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional

import httpx

logger = logging.getLogger(__name__)


@dataclass
class PR:
    owner: str
    repo: str
    number: int
    title: str
    head_sha: str
    base_ref: str
    author: str


class GitHubClient:
    def __init__(self, token: str, base_url: str = "https://api.github.com") -> None:
        self.base_url = base_url.rstrip("/")
        self._client = httpx.Client(
            base_url=self.base_url,
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "roastbot/0.1",
            },
            timeout=30.0,
        )

    def list_open_prs(self, full_repo: str) -> List[PR]:
        owner, repo = full_repo.split("/")
        prs: List[PR] = []
        page = 1
        while True:
            r = self._client.get(f"/repos/{owner}/{repo}/pulls", params={"state": "open", "per_page": 50, "page": page})
            r.raise_for_status()
            data = r.json()
            for pr in data:
                prs.append(
                    PR(
                        owner=owner,
                        repo=repo,
                        number=pr["number"],
                        title=pr["title"],
                        head_sha=pr["head"]["sha"],
                        base_ref=pr["base"]["ref"],
                        author=pr["user"]["login"],
                    )
                )
            if len(data) < 50:
                break
            page += 1
        return prs

    def get_pr_diff(self, owner: str, repo: str, number: int) -> str:
        r = self._client.get(f"/repos/{owner}/{repo}/pulls/{number}", headers={"Accept": "application/vnd.github.v3.diff"})
        r.raise_for_status()
        return r.text

    def get_pr_files(self, owner: str, repo: str, number: int) -> List[Dict]:
        files: List[Dict] = []
        page = 1
        while True:
            r = self._client.get(f"/repos/{owner}/{repo}/pulls/{number}/files", params={"per_page": 100, "page": page})
            r.raise_for_status()
            data = r.json()
            files.extend(data)
            if len(data) < 100:
                break
            page += 1
        return files

    def post_pr_review(self, owner: str, repo: str, number: int, body: str, event: str = "COMMENT") -> None:
        payload = {"body": body, "event": event}
        r = self._client.post(f"/repos/{owner}/{repo}/pulls/{number}/reviews", json=payload)
        if r.status_code == 422:
            # Possibly already reviewed as a pending review; fallback to plain comment
            logger.debug("Review submission unprocessable; posting issue comment instead")
            self.post_issue_comment(owner, repo, number, body)
            return
        r.raise_for_status()

    def post_issue_comment(self, owner: str, repo: str, issue_number: int, body: str) -> None:
        r = self._client.post(f"/repos/{owner}/{repo}/issues/{issue_number}/comments", json={"body": body})
        r.raise_for_status()

    def commit_status(self, owner: str, repo: str, sha: str) -> Dict:
        r = self._client.get(f"/repos/{owner}/{repo}/commits/{sha}/status")
        r.raise_for_status()
        return r.json()

    def list_commits(self, full_repo: str, branch: str, per_page: int = 30) -> List[Dict]:
        owner, repo = full_repo.split("/")
        r = self._client.get(f"/repos/{owner}/{repo}/commits", params={"sha": branch, "per_page": per_page})
        r.raise_for_status()
        return r.json()

    @staticmethod
    def review_marker(repo: str, sha: str) -> str:
        short = sha[:7]
        digest = hashlib.sha256(f"{repo}:{sha}".encode()).hexdigest()[:8]
        return f"<!-- roastbot: reviewed {repo}@{short} {digest} -->"
