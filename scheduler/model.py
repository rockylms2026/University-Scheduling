"""Data model and loader for curricula, faculty, loads, time frame, and campus."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import yaml

DATA_DIR = Path(__file__).resolve().parent.parent / "data"

# Year 1 introductory courses: excluded from the 4-preparation cap. Colleges
# can add to this list with "intro_courses" in their data file.
INTRO_COURSES = {
    "CRIM 101", "PAD 101", "SW 101",
    "ACC 101", "ENT 101", "BUS 101", "THM 101",
    "CCS 101", "LIS 101",
    "PSYC 101", "POLS 101", "COMM 101", "ECON 101",
}

DAY_GROUPS = {"MWF": ("Mon", "Wed", "Fri"), "TTh": ("Tue", "Thu")}


@dataclass
class Course:
    code: str
    title: str
    credits: int = 3
    lec: int = 3            # lecture contact hours per week
    lab: int = 0            # laboratory contact hours per week
    lab_rooms: tuple[str, ...] = ()   # lab room types, most preferred first
    kind: str = "lecture"   # lecture | lab | pe | nstp | uni | field
    college: str = "CORE"
    housed_by: str | None = None
    placement: tuple[str, ...] = ()   # field courses: days at the placement

    @property
    def is_core(self) -> bool:
        return self.college == "CORE"

    @property
    def is_field(self) -> bool:
        return self.kind == "field"

    @property
    def load_units(self) -> int:
        """Teaching load units (LU) per section, per the college plans."""
        if self.kind == "field":
            return 3
        return self.lec + self.lab


@dataclass
class Program:
    code: str
    name: str
    department: str
    college: str
    blocks: dict[int, list[str]]
    tracks: dict[int, list[str]]
    curriculum: dict[tuple[int, int], list[tuple[str, str | None]]]


@dataclass
class Faculty:
    key: str           # college-qualified ID, e.g. "CISC-C1"
    id: str
    name: str
    rank: str
    department: str
    college: str
    designation: str = ""
    max_lu: int = 24
    prep_cap: int | None = 4

    @property
    def short(self) -> str:
        parts = self.name.split()
        return f"{parts[0]} {parts[-1]}" if len(parts) > 1 else self.name


@dataclass(frozen=True)
class Subcohort:
    """The smallest group of students who share a whole timetable."""
    program: str
    year: int
    block: str
    track: str | None

    @property
    def label(self) -> str:
        base = f"{self.program} {self.year}{self.block}"
        return f"{base} ({self.track})" if self.track else base


@dataclass
class Section:
    """A student group that attends a class together."""
    name: str
    program: str
    college: str
    department: str
    year: int
    block: str | None = None
    track: str | None = None
    subcohorts: frozenset[Subcohort] = frozenset()

    @property
    def is_small(self) -> bool:
        return self.track is not None


@dataclass
class Klass:
    """One course offered to one section in one semester."""
    id: str
    course: Course
    section: Section
    semester: int
    faculty: Faculty | None = None

    @property
    def teacher_label(self) -> str:
        if self.faculty:
            return self.faculty.name
        return f"TBA ({self.course.housed_by or 'GE Department'})"


@dataclass
class Period:
    name: str
    days: tuple[str, ...]
    start: int     # minutes after midnight
    end: int


@dataclass
class TimeFrame:
    days: list[str]
    periods: dict[str, Period]
    lab_blocks: dict[str, Period]
    nstp: Period
    fac_pref_hours: float
    fac_max_hours: float
    lab_day_preferences: list[dict]
    faculty_unavailable: dict[str, list[dict]]
    slot: int = 30
    day_start: int = 7 * 60 + 30
    day_end: int = 16 * 60 + 30

    @property
    def n_slots(self) -> int:
        return (self.day_end - self.day_start) // self.slot

    def slot_of(self, minutes: int) -> int:
        return (minutes - self.day_start) // self.slot

    def slots(self, start: int, end: int) -> range:
        return range(self.slot_of(start), self.slot_of(end))

    def mwf_periods(self) -> list[Period]:
        return [p for p in self.periods.values() if p.days == DAY_GROUPS["MWF"]]

    def tth_periods(self) -> list[Period]:
        return [p for p in self.periods.values() if p.days == DAY_GROUPS["TTh"]]


@dataclass
class Room:
    name: str
    building: str
    pool: str           # classrooms:<college> | shared | seminar:<college> | lab:<type> | pe
    capacity: int = 1   # classes it can hold at once (PE venues)


@dataclass
class Campus:
    rooms: list[Room]
    buildings: dict[str, dict]
    lab_blocks: dict[str, list[str]]     # lab type -> preferred blocks ([] = any)

    def pool(self, name: str) -> list[Room]:
        return [r for r in self.rooms if r.pool == name]

    def home_buildings(self, department: str) -> set[str]:
        return {code for code, b in self.buildings.items() if department in b["departments"]}


@dataclass
class Issue:
    level: str        # error | warning | info
    category: str
    message: str


@dataclass
class University:
    courses: dict[str, Course]
    programs: dict[str, Program]
    faculty: dict[str, Faculty]
    sections: dict[str, Section]
    classes: dict[int, list[Klass]]          # semester -> classes
    timeframe: TimeFrame
    campus: Campus
    intro_courses: set[str]
    issues: list[Issue] = field(default_factory=list)

    def classes_for(self, semester: int) -> list[Klass]:
        return self.classes[semester]


def parse_time(text: str) -> int:
    h, m = str(text).split(":")
    return int(h) * 60 + int(m)


def fmt_time(minutes: int) -> str:
    h, m = divmod(minutes, 60)
    return f"{h % 12 or 12}:{m:02d}"


def _course_from_entry(code: str, entry, college: str) -> Course:
    if isinstance(entry, str):
        return Course(code=code, title=entry, college=college)
    entry = dict(entry)
    title = entry.pop("title")
    kind = entry.pop("kind", None)
    credits = entry.pop("credits", 3)
    lab = entry.pop("lab", None)
    lec = entry.pop("lec", None)
    housed_by = entry.pop("housed_by", None)
    placement = tuple(entry.pop("placement", ()))
    if entry:
        raise ValueError(f"{code}: unknown fields {sorted(entry)}")
    if kind == "field":
        return Course(code, title, credits, 0, 0, (), "field", college, housed_by, placement)
    if lab:
        rooms = tuple(lab) if isinstance(lab, list) else (lab,)
        return Course(code, title, credits, 2, 3, rooms, "lab", college, housed_by)
    if kind is None:
        kind = "uni" if lec == 1 else "lecture"
    return Course(code, title, credits, lec if lec is not None else 3, 0, (), kind, college, housed_by)


def _parse_curriculum_item(item: str) -> tuple[str, str | None]:
    if "@" in item:
        code, tag = item.split("@")
        return code.strip(), tag.strip()
    return item.strip(), None


def section_name(program: str, year: int, block: str | None = None, track: str | None = None) -> str:
    if track:
        return f"{program} {year}-{track}"
    return f"{program} {year}{block or ''}"


def _load_timeframe(path: Path) -> TimeFrame:
    raw = yaml.safe_load(path.read_text())
    periods = {}
    for group, items in raw["periods"].items():
        for name, (a, b) in items.items():
            periods[name] = Period(name, DAY_GROUPS[group], parse_time(a), parse_time(b))
    blocks = {name: Period(name, DAY_GROUPS[b["days"]], parse_time(b["time"][0]), parse_time(b["time"][1]))
              for name, b in raw["lab_blocks"].items()}
    n = raw["nstp"]
    nstp = Period("NSTP", (n["day"],), parse_time(n["time"][0]), parse_time(n["time"][1]))
    return TimeFrame(
        days=raw["days"],
        periods=periods,
        lab_blocks=blocks,
        nstp=nstp,
        fac_pref_hours=raw["faculty_preferred_max_hours_per_day"],
        fac_max_hours=raw["faculty_max_hours_per_day"],
        lab_day_preferences=raw.get("lab_day_preferences") or [],
        faculty_unavailable=raw.get("faculty_unavailable") or {},
    )


def _load_campus(path: Path) -> Campus:
    raw = yaml.safe_load(path.read_text())
    rooms: list[Room] = []

    def add(name: str, pool: str, capacity: int = 1):
        rooms.append(Room(name, name.split()[0], pool, capacity))

    for college, names in raw["classrooms"].items():
        for n in names:
            add(n, f"classrooms:{college}")
    for n in raw.get("shared_classrooms") or []:
        add(n, "shared")
    for college, names in (raw.get("seminar_rooms") or {}).items():
        for n in names:
            add(n, f"seminar:{college}")
    lab_blocks = {}
    for lab_type, spec in raw["labs"].items():
        for n in spec["rooms"]:
            add(n, f"lab:{lab_type}")
        lab_blocks[lab_type] = list(spec.get("blocks") or [])
    for v in raw["pe_venues"]:
        rooms.append(Room(v["name"], "PE", "pe", v.get("classes_at_once", 1)))
    return Campus(rooms, raw["buildings"], lab_blocks)


def load_university(data_dir: Path = DATA_DIR) -> University:
    issues: list[Issue] = []
    courses: dict[str, Course] = {}
    core = yaml.safe_load((data_dir / "institutional_core.yaml").read_text())
    for code, entry in core["courses"].items():
        courses[code] = _course_from_entry(code, entry, "CORE")

    programs: dict[str, Program] = {}
    faculty: dict[str, Faculty] = {}
    intro = set(INTRO_COURSES)
    raw_loads: list[tuple[str, int, str, str, str]] = []  # college, sem, fac_id, course, section

    for path in sorted((data_dir / "colleges").glob("*.yaml")):
        raw = yaml.safe_load(path.read_text())
        college = raw["college"]
        intro.update(raw.get("intro_courses") or [])
        prep_cap = raw.get("prep_cap", 4)
        for code, entry in (raw.get("courses") or {}).items():
            if code in courses:
                issues.append(Issue("error", "data", f"{path.name}: course {code} is defined twice"))
            courses[code] = _course_from_entry(code, entry, college)
        for pcode, p in (raw.get("programs") or {}).items():
            blocks_raw = p["blocks"]
            blocks = blocks_raw if isinstance(blocks_raw, dict) else {y: list(blocks_raw) for y in range(1, 5)}
            blocks = {int(y): [str(b) for b in v] for y, v in blocks.items()}
            tracks = {int(y): list(v) for y, v in (p.get("tracks") or {}).items()}
            curriculum = {}
            for key, items in p["curriculum"].items():
                y, s = (int(x) for x in key.split("-"))
                curriculum[(y, s)] = [_parse_curriculum_item(i) for i in items]
            programs[pcode] = Program(pcode, p["name"], p["department"], college, blocks, tracks, curriculum)
        for fid, f in raw["faculty"].items():
            key = f"{college}-{fid}"
            faculty[key] = Faculty(key, fid, f["name"], f["rank"], f["department"], college,
                                   f.get("designation", ""), f.get("max_lu", 24), prep_cap)
        for sem, per_fac in (raw.get("loads") or {}).items():
            for fid, entries in per_fac.items():
                for entry in entries:
                    for course_code, sections in entry.items():
                        for sec in str(sections).split(","):
                            raw_loads.append((college, int(sem), fid, course_code.strip(), sec.strip()))

    timeframe = _load_timeframe(data_dir / "time_frame.yaml")
    campus = _load_campus(data_dir / "campus.yaml")
    lab_types = set(campus.lab_blocks)
    for c in courses.values():
        for t in c.lab_rooms:
            if t not in lab_types:
                issues.append(Issue("error", "data", f"{c.code}: lab room type '{t}' is not in campus.yaml"))

    # Build sections and classes from the curricula.
    sections: dict[str, Section] = {}
    classes: dict[int, list[Klass]] = {1: [], 2: []}
    index: dict[tuple[int, str, str], Klass] = {}

    for prog in programs.values():
        for year in range(1, 5):
            blocks = prog.blocks.get(year, [""])
            tracks = prog.tracks.get(year, [])
            if tracks:
                subs = [Subcohort(prog.code, year, b, t) for b in blocks for t in tracks]
            else:
                subs = [Subcohort(prog.code, year, b, None) for b in blocks]
            for b in blocks:
                name = section_name(prog.code, year, block=b)
                sections[name] = Section(name, prog.code, prog.college, prog.department, year, block=b,
                                         subcohorts=frozenset(s for s in subs if s.block == b))
            for t in tracks:
                name = section_name(prog.code, year, track=t)
                sections[name] = Section(name, prog.code, prog.college, prog.department, year, track=t,
                                         subcohorts=frozenset(s for s in subs if s.track == t))
            for sem in (1, 2):
                for code, tag in prog.curriculum.get((year, sem), []):
                    course = courses.get(code)
                    if course is None:
                        issues.append(Issue("error", "data", f"{prog.code} {year}-{sem}: unknown course {code}"))
                        continue
                    if tag and tag in tracks:
                        targets = [section_name(prog.code, year, track=tag)]
                    elif tag:
                        if tag not in blocks:
                            issues.append(Issue("error", "data", f"{prog.code} {year}-{sem}: {code} @{tag} matches no block or track"))
                            continue
                        targets = [section_name(prog.code, year, block=tag)]
                    else:
                        targets = [section_name(prog.code, year, block=b) for b in blocks]
                    for sname in targets:
                        kid = f"S{sem}-{len(classes[sem]) + 1:04d}"
                        k = Klass(kid, course, sections[sname], sem)
                        classes[sem].append(k)
                        index[(sem, code, sname)] = k

    # Attach faculty from the loading plans.
    for college, sem, fid, code, sname in raw_loads:
        key = f"{college}-{fid}"
        fac = faculty.get(key)
        if fac is None:
            issues.append(Issue("error", "loads", f"{college} semester {sem}: unknown faculty ID {fid}"))
            continue
        k = index.get((sem, code, sname))
        if k is None:
            issues.append(Issue("error", "loads",
                                f"Semester {sem}: {fac.name} is loaded with {code} for {sname}, "
                                f"but {sname} does not take {code} that semester"))
            continue
        if k.faculty is not None and k.faculty is not fac:
            issues.append(Issue("error", "loads",
                                f"Semester {sem}: {code} {sname} is loaded to both {k.faculty.name} and {fac.name}"))
            continue
        k.faculty = fac

    return University(courses, programs, faculty, sections, classes, timeframe, campus, intro, issues)
