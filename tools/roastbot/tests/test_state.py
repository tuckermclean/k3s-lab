import json
import os
from roastbot.state import State


def test_state_roundtrip(tmp_path):
    path = tmp_path / "state.json"
    s = State(str(path))
    s.load()
    assert not s.has_reviewed("o/r", "abc")
    s.mark_reviewed("o/r", "abc")
    s.save()

    s2 = State(str(path))
    s2.load()
    assert s2.has_reviewed("o/r", "abc")
