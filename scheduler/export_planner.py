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
SEAL_PATH = Path(__file__).with_name("assets") / "laucv_seal.png"


def seal_data_url() -> str:
    """The university seal as a data URL, for the top bar, the sign-in page and printed schedules."""
    import base64
    return "data:image/png;base64," + base64.b64encode(SEAL_PATH.read_bytes()).decode() if SEAL_PATH.exists() else ""
KINDS = ["lecture", "lab_lecture", "lab", "pe", "uni", "double", "nstp", "supervision"]
COLLEGES = {"CSBS": "College of Social and Behavioral Sciences", "CILS": "College of Information and Library Science",
            "CBAPA": "College of Business, Accountancy and Public Administration", "COE": "College of Education",
            "GE": "General Education Department",
            "RE": "Religious Education Department"}


def holder_department(housed_by: str | None, program_dept: str) -> str | None:
    """The department that holds a GE course: "Dept. of Psychology (CSBS)" -> "Psychology"."""
    if not housed_by:
        return None
    if housed_by.startswith("Program"):
        return program_dept
    if housed_by.startswith("GE Department"):
        return "General Education"
    if housed_by.startswith("Religious Education"):
        return "Religious Education"
    m = re.match(r"Dept\. of (.+?) \(", housed_by)
    return m.group(1) if m else None


def ge_house(k, uni: University, dept_college: dict) -> dict:
    """The house department of a GE class: the department in housed_by (None for non-GE classes)."""
    if not k.course.is_core:
        return {"house": None, "houseCollege": None}
    house = holder_department(k.course.housed_by, uni.programs[k.section.program].department)
    return {"house": house, "houseCollege": dept_college.get(house)}


def ge_teaching_lists(uni: University, semester: int, dept_college: dict) -> dict:
    """Departments that may teach each GE course (not GE Department courses): the house department
    and every department the loading plans give the course to. Social Work, say, for PSYC 160."""
    lists: dict[str, set] = {}
    for k in uni.classes_for(semester):
        if not k.course.is_core:
            continue
        house = holder_department(k.course.housed_by, uni.programs[k.section.program].department)
        if house in ("General Education", "Religious Education"):
            for d in k.course.also_taught_by:      # a department that may also teach a GE Department course
                lists.setdefault(k.course.code, set()).add(d)
            continue
        lists.setdefault(k.course.code, set()).add(house)
        if k.faculty and k.faculty.department != "General Education":
            lists[k.course.code].add(k.faculty.department)
    return {code: sorted(depts) for code, depts in sorted(lists.items())}


def specialization_courses(uni: University, code: str) -> list[str]:
    """Courses of a program's tracks or majors: tagged with a track in its curriculum (e.g. "PSYC 351 @C"), or,
    for majors kept as sibling programs (BSEd-E, BSEd-M, ...), courses that not every sibling takes."""
    prog = uni.programs[code]
    items = [it for lst in prog.curriculum.values() for it in lst]
    spec = {c for c, tag in items if tag}
    if "-" in code:
        base = code.split("-")[0]
        sibs = [p for k, p in uni.programs.items() if k.split("-")[0] == base and "-" in k]
        if len(sibs) > 1:
            shared = set.intersection(*({c for lst in p.curriculum.values() for c, _ in lst} for p in sibs))
            spec |= {c for c, _ in items if c not in shared}
    return sorted(c for c in spec if not uni.courses[c].is_core)


def planner_data(uni: University, semester: int) -> dict:
    campus_raw = yaml.safe_load((DATA_DIR / "campus.yaml").read_text())
    offices = campus_raw.get("faculty_offices") or {}
    building_college = {code: b["college"] for code, b in uni.campus.buildings.items()}

    programs = {}
    for p in uni.programs.values():
        programs[p.code] = {"name": p.name, "college": p.college, "dept": p.department, "sections": [],
                            "home": sorted(uni.campus.home_buildings(p.department)),
                            "specialization": specialization_courses(uni, p.code)}
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
    dept_college = {f.department: f.college for f in uni.faculty.values()}
    for k in uni.classes_for(semester):
        c = k.course
        courses[c.code] = {"title": c.title, "credits": c.credits, "lec": c.lec, "lab": c.lab,
                           "kind": c.kind, "college": c.college, "usual": c.housed_by,
                           "labRooms": list(c.lab_rooms), "placement": list(c.placement)}
        classes.append({"id": k.id, "course": c.code, "section": k.section.name,
                        # Every class starts with no teacher: the Registrar and the chairs assign them.
                        "teacher": None,
                        **ge_house(k, uni, dept_college),
                        "lu": c.load_units, "meetings": by_class.get(k.id, [])})

    load = faculty_load_summary(uni, semester)
    teachers = {key: {"name": f.name, "rank": f.rank, "dept": f.department, "college": f.college,
                      "role": f.designation, "max": f.max_lu, "prepCap": f.prep_cap,
                      "courseCap": f.course_cap, "classCap": f.class_cap, "degree": f.degree, "spec": f.specialization,
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
            "geTeachers": ge_teaching_lists(uni, semester, dept_college), "deptCollege": dept_college,
            "facPref": uni.timeframe.fac_pref_hours, "facMax": uni.timeframe.fac_max_hours,
            "org": organization(teachers)}


def organization(teachers: dict) -> dict | None:
    """The VPAA organizational chart: offices, staff and units around the faculty (data/organization.yaml)."""
    path = DATA_DIR / "organization.yaml"
    if not path.exists():
        return None
    org = yaml.safe_load(path.read_text())
    for key in [k for k in org.get("faculty_emails", {}) if k not in teachers]:
        del org["faculty_emails"][key]          # people no longer on the faculty list
    return org


def write_planner(uni: University, semester: int = 1, path: Path | None = None) -> Path:
    path = path or OUTPUT_DIR / "scheduling_system.html"
    data = json.dumps(planner_data(uni, semester), separators=(",", ":"))
    html = TEMPLATE_PATH.read_text().replace("/*__DATA__*/null", data.replace("</", "<\\/")).replace('/*__SEAL__*/""', json.dumps(seal_data_url()))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(html)
    return path
