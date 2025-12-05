from __future__ import annotations

import logging
from typing import Optional

from .config import Settings
from .diff_utils import summarize_diff
from .github_client import GitHubClient
from .llm import RoastEngine
from .llm_openai import OpenAIEngine, OpenAIConfig
from .state import State

logger = logging.getLogger(__name__)


class Controller:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.gh = GitHubClient(settings.github_token)
        # Select LLM engine
        if settings.llm_provider == "openai":
            try:
                if not settings.openai_api_key:
                    raise ValueError("OPENAI_API_KEY is required when llm_provider=openai")
                self.engine = OpenAIEngine(
                    OpenAIConfig(api_key=settings.openai_api_key, model=settings.openai_model, base_url=settings.openai_base_url)
                )
            except Exception as e:
                logger.warning("OpenAI engine unavailable (%s); falling back to mock engine.", e)
                self.engine = RoastEngine()
        else:
            self.engine = RoastEngine()
        self.state = State(settings.state_file)
        self.state.load()

    def run_once(self) -> None:
        for full_repo in self.settings.repos:
            self._process_repo(full_repo)
        self.state.save()

    def _process_repo(self, full_repo: str) -> None:
        prs = self.gh.list_open_prs(full_repo)
        logger.info("Repo %s: found %d open PRs", full_repo, len(prs))
        for pr in prs:
            if self.state.has_reviewed(full_repo, pr.head_sha):
                logger.debug("Already reviewed %s@%s", full_repo, pr.head_sha[:7])
                continue
            if self.settings.branch_filters and pr.base_ref not in self.settings.branch_filters:
                logger.debug("Skipping PR #%s base %s not in filters", pr.number, pr.base_ref)
                continue
            self._review_pr(pr)
            self.state.mark_reviewed(full_repo, pr.head_sha)

    def _review_pr(self, pr) -> None:
        diff = self.gh.get_pr_diff(pr.owner, pr.repo, pr.number)
        files = self.gh.get_pr_files(pr.owner, pr.repo, pr.number)
        ci = self.gh.commit_status(pr.owner, pr.repo, pr.head_sha)
        ci_summary = ci.get("state", "unknown").upper()
        trimmed = summarize_diff(diff)
        prompt = self.engine.build_prompt(
            repo=f"{pr.owner}/{pr.repo}", subject=pr.title, author=pr.author, base=pr.base_ref, ci=ci_summary, diff=trimmed
        )
        resp = self.engine.review(repo=f"{pr.owner}/{pr.repo}", subject=pr.title, author=pr.author, base=pr.base_ref, ci=ci_summary, diff=trimmed)
        body = self._format_review_body(pr, resp, prompt)
        self.gh.post_pr_review(pr.owner, pr.repo, pr.number, body)
        logger.info("Posted review on %s PR #%d (%s)", f"{pr.owner}/{pr.repo}", pr.number, pr.head_sha[:7])

    @staticmethod
    def _format_review_body(pr, resp, prompt: str) -> str:
        marker = GitHubClient.review_marker(f"{pr.owner}/{pr.repo}", pr.head_sha)
        return (
            f"{marker}\n"
            f"RoastBot review for {pr.owner}/{pr.repo} PR #{pr.number}: {pr.title}\n\n"
            f"summary\n-------\n{resp.summary}\n\n"
            f"issues\n------\n{resp.issues}\n\n"
            f"praise\n------\n{resp.praise}\n\n"
            f"one_killer_roast_line\n----------------------\n{resp.one_killer_roast_line}\n\n"
            f"Debug: prompt excerpt (first 60 lines)\n---------------------------------------\n" + "\n".join(prompt.splitlines()[:60])
        )
