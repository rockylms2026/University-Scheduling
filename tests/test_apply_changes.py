"""Changes saved online become overrides the loader and solver honour."""

import shutil

from scheduler.apply_changes import apply_changes
from scheduler.model import DATA_DIR, load_university
from scheduler.solver import Meeting, _choices


def test_changes_become_overrides(tmp_path):
    data = tmp_path / "data"
    shutil.copytree(DATA_DIR, data)
    uni = load_university(data)
    items = [
        {"type": "assign", "sem": 1, "course": "FIL 207", "section": "BSA 1A", "newTeacher": "Ms. Ana Cruz"},
        {"type": "assign", "sem": 1, "course": "FIL 207", "section": "BSA 1B", "teacher": "COE-S8"},
        {"type": "move", "sem": 1, "course": "IT 210", "section": "BSIT 2A", "part": "Lec", "pattern": "M2 MW", "room": "SIN 202"},
        {"type": "approve", "sem": 2, "course": "BAN 403", "section": "BSBA 4-BAN", "part": "Lec", "decision": "another_time"},
    ]
    counts = apply_changes(items, uni, data)
    assert counts == {"move": 1, "assign": 2, "approve": 0, "another_time": 1}

    uni = load_university(data)
    classes = {(k.course.code, k.section.name): k for k in uni.classes_for(1)}
    assert classes[("FIL 207", "BSA 1A")].faculty.name == "Ms. Ana Cruz"
    assert classes[("FIL 207", "BSA 1B")].faculty.key == "COE-S8"
    k = classes[("IT 210", "BSIT 2A")]
    choices = _choices(uni, Meeting("x", k, "Lec", "lab_lecture"), {})
    assert {c.option.label for c in choices} == {"M2 MW"}
    assert {c.pool for c in choices} == {"classrooms:CILS"}
    ban = next(k for k in uni.classes_for(2) if k.course.code == "BAN 403")
    assert not any(c.option.exception for c in _choices(uni, Meeting("y", ban, "Lec", "lab_lecture"), {}))

    # Applying the same change twice does not duplicate it.
    apply_changes(items[:1], load_university(data), data)
    assert sum(1 for k in load_university(data).classes_for(1) if k.faculty and k.faculty.key.startswith("PT-")) == 1
