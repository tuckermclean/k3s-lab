from roastbot.llm import RoastEngine, PROMPT_TEMPLATE


def test_prompt_includes_context():
    eng = RoastEngine()
    p = eng.build_prompt(repo="o/r", subject="Fix stuff", author="alice", base="main", ci="SUCCESS", diff="+a\n-b")
    assert "Repo: o/r" in p
    assert "Fix stuff" in p
    assert "Author: alice" in p
    assert "Base: main" in p
    assert "CI Status: SUCCESS" in p
    assert "Diff (trimmed):" in p


def test_mock_review_structure():
    eng = RoastEngine()
    r = eng.review(repo="o/r", subject="Fix", author="bob", base="main", ci="PENDING", diff="+a")
    assert r.summary and r.issues and r.praise and r.one_killer_roast_line
