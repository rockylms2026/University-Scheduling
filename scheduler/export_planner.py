"""The scheduling system page (output/scheduling_system.html).

The registrar schedules every class by hand in this page. It carries the
curricula, teaching loads, rooms, and the University Class Time Frame, and
checks every booking against students, teachers, and rooms as it is made.
Bookings are kept in the page's shared database, not in this file.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import yaml

from .model import DATA_DIR, University
from .solver import Meeting, build_meetings, room_pools, time_options
from .store import OUTPUT_DIR
from .validate import faculty_load_summary

TEMPLATE_PATH = Path(__file__).with_name("planner_template.html")
KINDS = ["lecture", "lab_lecture", "lab", "pe", "uni", "nstp", "supervision"]
COLLEGES = {"CSS": "College of Social Sciences", "CISC": "College of Information Sciences and Computing",
            "CBE": "College of Business and Entrepreneurship", "COE": "College of Education",
            "CCJPS": "College of Criminal Justice and Public Service", "GE": "General Education Department"}


def holder_department(housed_by: str | None, program_dept: str) -> str | None:
    """The department that holds a GE course: "Dept. of Psychology (CSS)" -> "Psychology"."""
    if not housed_by:
        return None
    if housed_by.startswith("Program"):
        return program_dept
    if housed_by.startswith("GE Department"):
        return "General Education"
    m = re.match(r"Dept\. of (.+?) \(", housed_by)
    return m.group(1) if m else None


def planner_data(uni: University, semester: int) -> dict:
    campus_raw = yaml.safe_load((DATA_DIR / "campus.yaml").read_text())
    offices = campus_raw.get("faculty_offices") or {}
    building_college = {code: b["college"] for code, b in uni.campus.buildings.items()}

    programs = {}
    for p in uni.programs.values():
        programs[p.code] = {"name": p.name, "college": p.college, "dept": p.department, "sections": [],
                            "home": sorted(uni.campus.home_buildings(p.department))}
    sections = {}
    for s in uni.sections.values():
        placement = sorted({d for k in uni.classes_for(semester) if k.section.subcohorts & s.subcohorts
                            for d in k.course.placement})
        sections[s.name] = {"program": s.program, "year": s.year, "track": s.track,
                            "groups": sorted(x.label for x in s.subcohorts), "placement": placement}
    for name, s in sorted(sections.items(), key=lambda kv: (kv[1]["year"], kv[1]["track"] or "", kv[0])):
        programs[s["program"]]["sections"].append(name)

    courses, classes = {}, []
    meetings = build_meetings(uni.classes_for(semester))
    by_class: dict[str, list] = {}
    for m in meetings:
        pools = [p for p, _ in room_pools(uni, m) if p is None or uni.campus.pool(p)]
        by_class.setdefault(m.klass.id, []).append({"part": m.part, "kind": m.kind, "pools": pools})
    for k in uni.classes_for(semester):
        c = k.course
        courses[c.code] = {"title": c.title, "credits": c.credits, "lec": c.lec, "lab": c.lab,
                           "kind": c.kind, "college": c.college, "usual": c.housed_by,
                           "labRooms": list(c.lab_rooms), "placement": list(c.placement)}
        classes.append({"id": k.id, "course": c.code, "section": k.section.name,
                        "teacher": k.faculty.key if k.faculty else None,
                        "holder": holder_department(c.housed_by, uni.programs[k.section.program].department) if c.is_core else None,
                        "lu": c.load_units, "meetings": by_class.get(k.id, [])})

    load = faculty_load_summary(uni, semester)
    teachers = {key: {"name": f.name, "rank": f.rank, "dept": f.department, "college": f.college,
                      "role": f.designation, "max": f.max_lu, "prepCap": f.prep_cap, "lu": load[key]["lu"],
                      "office": offices.get(key, "")}
                for key, f in uni.faculty.items()}

    rooms = {}
    for r in uni.campus.rooms:
        if r.pool.startswith("classrooms:") or r.pool.startswith("seminar:"):
            college = r.pool.split(":")[1]
        elif r.pool == "pe" or r.pool == "shared":
            college = "SHARED"
        else:
            college = building_college.get(r.building, "SHARED")
        lab_type = r.pool[4:] if r.pool.startswith("lab:") else None
        rooms[r.name] = {"pool": r.pool, "cap": r.capacity, "college": college, "building": r.building,
                         "lab": lab_type, "blocks": uni.campus.lab_blocks.get(lab_type, []) if lab_type else []}

    options = {kind: [{"label": o.label, "iv": [list(i) for i in o.intervals], "ex": o.exception, "block": o.block}
                      for o in time_options(uni, kind)] for kind in KINDS}
    lab_days = [p for p in uni.timeframe.lab_day_preferences]
    return {"semester": semester, "days": uni.timeframe.days, "start": uni.timeframe.day_start,
            "end": uni.timeframe.day_end, "slot": uni.timeframe.slot, "colleges": COLLEGES,
            "buildings": {c: b["name"] for c, b in uni.campus.buildings.items()},
            "intro": sorted(uni.intro_courses), "programs": programs, "sections": sections, "courses": courses, "classes": classes,
            "teachers": teachers, "rooms": rooms, "options": options, "labDays": lab_days,
            "facPref": uni.timeframe.fac_pref_hours, "facMax": uni.timeframe.fac_max_hours}


def write_planner(uni: University, semester: int = 1, path: Path | None = None) -> Path:
    path = path or OUTPUT_DIR / "scheduling_system.html"
    data = json.dumps(planner_data(uni, semester), separators=(",", ":"))
    html = TEMPLATE_PATH.read_text().replace("/*__DATA__*/null", data.replace("</", "<\\/"))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(html)
    return path
