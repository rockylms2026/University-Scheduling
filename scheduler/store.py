"""Save and load solved schedules as JSON (output/schedule_sem<N>.json)."""

from __future__ import annotations

import json
from pathlib import Path

from .model import University
from .solver import Schedule, Session

OUTPUT_DIR = Path(__file__).resolve().parent.parent / "output"


def save(schedule: Schedule, path: Path | None = None) -> Path:
    path = path or OUTPUT_DIR / f"schedule_sem{schedule.semester}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    data = {
        "semester": schedule.semester,
        "status": schedule.status,
        "stats": schedule.stats,
        "sessions": [
            {"meeting": s.meeting_id, "class": s.klass.id, "course": s.klass.course.code,
             "section": s.klass.section.name, "part": s.part, "day": s.day, "start": s.start,
             "end": s.end, "label": s.label, "room": s.room, "exception": s.exception}
            for s in schedule.sessions
        ],
    }
    path.write_text(json.dumps(data, indent=1))
    return path


def load(uni: University, semester: int, path: Path | None = None) -> Schedule:
    path = path or OUTPUT_DIR / f"schedule_sem{semester}.json"
    data = json.loads(path.read_text())
    classes = {k.id: k for k in uni.classes_for(semester)}
    sessions = []
    for s in data["sessions"]:
        k = classes.get(s["class"])
        if k is None or k.course.code != s["course"] or k.section.name != s["section"]:
            raise ValueError(f"{path.name} no longer matches the data files; solve again")
        sessions.append(Session(s["meeting"], k, s["part"], s["day"], s["start"], s["end"],
                                s["label"], s["room"], s.get("exception")))
    return Schedule(data["semester"], sessions, data["status"], data.get("stats", {}))
