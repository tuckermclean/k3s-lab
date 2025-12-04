from __future__ import annotations

from typing import List, Tuple


def summarize_diff(diff_text: str, max_lines: int = 400) -> str:
    """Return a trimmed diff keeping headers and first/last chunks per file.
    Keeps overall size in check for prompt consumption.
    """
    lines = diff_text.splitlines()
    if len(lines) <= max_lines:
        return diff_text

    summary: List[str] = []
    current: List[str] = []

    def flush_file(block: List[str]) -> None:
        if not block:
            return
        # Keep file header + first 40 and last 40 lines if long
        if len(block) <= 120:
            summary.extend(block)
        else:
            summary.extend(block[:60])
            summary.append("... [snip: diff truncated for brevity] ...")
            summary.extend(block[-60:])

    for ln in lines:
        if ln.startswith("diff --git ") and current:
            flush_file(current)
            current = []
        current.append(ln)
    flush_file(current)

    out = "\n".join(summary)
    if len(out.splitlines()) > max_lines:
        out = "\n".join(out.splitlines()[:max_lines]) + "\n... [global truncation] ..."
    return out
