"""Self-contained HTML timetable viewer (output/schedule_viewer.html)."""

from __future__ import annotations

import json
from collections import defaultdict
from datetime import date
from pathlib import Path

from .model import University
from .solver import Schedule
from .store import OUTPUT_DIR
from .validate import faculty_load_summary
from .verify import verify

TEMPLATE_PATH = Path(__file__).with_name("viewer_template.html")


def viewer_data(uni: University, schedules: dict[int, Schedule]) -> dict:
    tf = uni.timeframe
    colleges = {"CSS": "Social Sciences", "CISC": "Information Sciences and Computing",
                "CBE": "Business and Entrepreneurship", "COE": "Education",
                "CCJPS": "Criminal Justice and Public Service", "GE": "General Education Department"}
    courses = {}
    teachers = {}
    sems = {}
    for key, f in uni.faculty.items():
        teachers[key] = {"name": f.name, "rank": f.rank, "dept": f.department, "college": f.college,
                         "max": f.max_lu, "role": f.designation, "lu": {}}
    groups = {}
    for sem, sched in schedules.items():
        load = faculty_load_summary(uni, sem)
        for key, row in load.items():
            teachers[key]["lu"][sem] = row["lu"]
        sessions = []
        for s in sched.sessions:
            k = s.klass
            courses[k.course.code] = [k.course.title, k.course.college]
            subs = [] if s.part == "Supervision" else sorted(x.label for x in k.section.subcohorts)
            for sub in k.section.subcohorts:
                prog = uni.programs[sub.program]
                groups[sub.label] = {"program": prog.name, "college": prog.college, "year": sub.year}
            sessions.append([k.course.code, s.part, k.section.name, subs,
                             k.faculty.key if k.faculty else None,
                             None if k.faculty else k.teacher_label,
                             s.room, s.day, s.start, s.end, s.label, s.exception])
        field = defaultdict(list)
        for k in uni.classes_for(sem):
            if k.course.placement:
                for sub in k.section.subcohorts:
                    field[sub.label].append([k.course.code, k.course.placement])
        problems = verify(uni, sched)
        sems[sem] = {"sessions": sessions, "placements": field, "problems": problems,
                     "quality": sched.stats.get("quality", {})}
    rooms = {r.name: {"pool": r.pool, "cap": r.capacity} for r in uni.campus.rooms}
    return {"days": tf.days, "start": tf.day_start, "end": tf.day_end, "slot": tf.slot,
            "generated": date.today().isoformat(), "colleges": colleges, "courses": courses,
            "teachers": teachers, "groups": groups, "rooms": rooms, "sems": sems}


def write_viewer(uni: University, schedules: dict[int, Schedule], path: Path | None = None) -> Path:
    path = path or OUTPUT_DIR / "schedule_viewer.html"
    data = json.dumps(viewer_data(uni, schedules), separators=(",", ":"))
    html = TEMPLATE_PATH.read_text().replace("/*__DATA__*/null", data.replace("</", "<\\/"))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(html)
    return path
