from roastbot.diff_utils import summarize_diff


def test_summarize_small_diff():
    diff = """diff --git a/a b/a
index 1..2 100644
--- a/a
+++ b/a
@@
+line1
+line2
"""
    assert summarize_diff(diff) == diff


def test_summarize_large_diff_truncates():
    header = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@\n"
    body = "\n".join([f"+x{i}" for i in range(1000)])
    out = summarize_diff(header + body, max_lines=100)
    assert "[global truncation]" in out or "[snip: diff truncated" in out
