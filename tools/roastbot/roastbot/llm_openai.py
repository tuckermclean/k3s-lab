from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Optional

from tenacity import retry, stop_after_attempt, wait_exponential, retry_if_exception_type

try:
    from openai import OpenAI
except Exception:  # pragma: no cover
    OpenAI = None  # type: ignore

from .llm import LLMResponse, PROMPT_TEMPLATE


@dataclass
class OpenAIConfig:
    api_key: str
    model: str = "gpt-4o-mini"
    base_url: Optional[str] = None


class OpenAIEngine:
    def __init__(self, cfg: OpenAIConfig) -> None:
        if OpenAI is None:
            raise RuntimeError("openai package not installed; add 'openai' to dependencies")
        self.client = OpenAI(api_key=cfg.api_key, base_url=cfg.base_url) if cfg.base_url else OpenAI(api_key=cfg.api_key)
        self.model = cfg.model

    def build_prompt(self, *, repo: str, subject: str, author: str, base: str, ci: str, diff: str) -> str:
        return PROMPT_TEMPLATE.format(repo=repo, subject=subject, author=author, base=base, ci=ci, diff=diff)

    @retry(reraise=True, stop=stop_after_attempt(3), wait=wait_exponential(multiplier=1, min=1, max=10))
    def review(self, *, repo: str, subject: str, author: str, base: str, ci: str, diff: str) -> LLMResponse:
        prompt = self.build_prompt(repo=repo, subject=subject, author=author, base=base, ci=ci, diff=diff)
        resp = self.client.chat.completions.create(
            model=self.model,
            messages=[
                {"role": "system", "content": "You are a brutally honest senior engineer who roasts code mercilessly while being technically precise and professional."},
                {"role": "user", "content": prompt},
            ],
            temperature=0.4,
        )
        content = resp.choices[0].message.content or ""
        # naive parsing by sections; robust parsing can be added later
        sections = {"summary": "", "issues": "", "praise": "", "one_killer_roast_line": ""}
        current = None
        for line in content.splitlines():
            l = line.strip()
            key = l.lower().strip(":")
            if key in sections:
                current = key
                continue
            if current:
                sections[current] += (line + "\n")
        return LLMResponse(
            summary=sections["summary"].strip() or content.strip(),
            issues=sections["issues"].strip() or "",
            praise=sections["praise"].strip() or "",
            one_killer_roast_line=sections["one_killer_roast_line"].strip() or "This code trips over its own abstractions.",
        )
