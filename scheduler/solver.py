"""Timetable construction with the OR-Tools CP-SAT solver.

Phase 1 chooses, for every meeting, a time pattern from the University Class
Time Frame and a room pool (a college's classrooms, the shared Lingkod Hall
rooms, a laboratory type, or the PE venues). No student group, teacher, or
room pool is ever over-booked.
Phase 2 picks a specific room in the chosen pool for every session, keeping
each class and each section in as few rooms as possible.
"""

from __future__ import annotations

import time
from collections import defaultdict
from dataclasses import dataclass, field

from ortools.sat.python import cp_model

from .model import Klass, Period, University, parse_time

# Objective weights.
W_SHARED_ROOM = 6        # class placed in a Lingkod Hall overflow room
W_ALT_LAB = 3            # lab in its second-choice lab room type
W_LAB_LECTURE_IN_LAB = 1 # lecture part held in the laboratory
W_OFF_BLOCK = 8          # lab in a block the time frame does not assign to its room
W_LAB_DAY = 2            # CISC lab not on its year level's lab day
W_FAC_LONG_DAY = 3       # per half-hour a teacher teaches beyond the preferred daily hours
W_GAP = 2                # per extra block of classes in a student group's day (idle time)
W_OUTSIDE_HOME = 1       # session outside its department's building (phase 2)
W_ROOM_CHANGE = 1        # extra room used by a class or a section (phase 2)
# Exceptions to the time frame, used only when no compliant time exists.
# Each use is reported as needing approval.
W_EXCEPTION = 60


@dataclass
class Meeting:
    id: str
    klass: Klass
    part: str            # Lec | Lab | PE | NSTP | Supervision
    kind: str            # option generator key


@dataclass
class Option:
    label: str                                   # e.g. "M2 MWF", "LA Fri", "T3 TTh"
    intervals: tuple[tuple[str, int, int], ...]  # (day, start, end) in minutes
    penalty: int = 0
    block: str | None = None
    exception: str | None = None      # why this option breaks the time frame


@dataclass
class Choice:
    option: Option
    pool: str | None
    penalty: int


@dataclass
class Session:
    """One scheduled meeting on one day."""
    meeting_id: str
    klass: Klass
    part: str
    day: str
    start: int
    end: int
    label: str
    room: str | None
    exception: str | None = None


@dataclass
class Schedule:
    semester: int
    sessions: list[Session]
    status: str
    stats: dict = field(default_factory=dict)


def build_meetings(classes: list[Klass]) -> list[Meeting]:
    meetings = []
    for k in classes:
        kind = k.course.kind
        if kind == "field":
            if k.faculty:   # supervision period for the faculty member
                meetings.append(Meeting(f"{k.id}-S", k, "Supervision", "supervision"))
        elif kind == "lab":
            meetings.append(Meeting(f"{k.id}-L", k, "Lec", "lab_lecture"))
            meetings.append(Meeting(f"{k.id}-B", k, "Lab", "lab"))
        elif kind == "pe":
            meetings.append(Meeting(f"{k.id}-P", k, "PE", "pe"))
        elif kind == "nstp":
            meetings.append(Meeting(f"{k.id}-N", k, "NSTP", "nstp"))
        elif kind == "uni":
            meetings.append(Meeting(f"{k.id}-U", k, "Lec", "uni"))
        else:
            meetings.append(Meeting(f"{k.id}-L", k, "Lec", "lecture"))
    return meetings


def time_options(uni: University, kind: str) -> list[Option]:
    tf = uni.timeframe
    mwf, tth = tf.mwf_periods(), tf.tth_periods()
    opts: list[Option] = []

    def on(p: Period, days) -> tuple:
        return tuple((d, p.start, p.end) for d in days)

    if kind in ("lecture", "supervision"):
        opts += [Option(f"{p.name} MWF", on(p, p.days)) for p in mwf]
        opts += [Option(f"{p.name} TTh", on(p, p.days)) for p in tth]
        if kind == "lecture":
            # Exception: Saturday morning make-up slot, for sections whose
            # placement days leave too few periods for their lectures.
            n = tf.nstp
            opts.append(Option("Sat make-up", ((n.days[0], n.start, n.end),), W_EXCEPTION * 2,
                               exception="lecture on Saturday morning (make-up slot)"))
    elif kind == "lab_lecture":
        for a, b in (("Mon", "Wed"), ("Mon", "Fri"), ("Wed", "Fri")):
            opts += [Option(f"{p.name} {a[0]}{b[0]}", on(p, (a, b))) for p in mwf]
        # Exception: students on placement Mon, Wed, Fri take every class on
        # TTh (rule 5), so the lecture part may meet as one TTh period.
        opts += [Option(f"{p.name} TTh", on(p, p.days), W_EXCEPTION,
                        exception="lab lecture on TTh because the students are on placement MWF")
                 for p in tth]
    elif kind == "lab":
        for name, blk in tf.lab_blocks.items():
            for d in blk.days:
                opts.append(Option(f"{name} {d}", ((d, blk.start, blk.end),), block=name))
        # Exception: Saturday morning make-up slot.
        n = tf.nstp
        opts.append(Option("Sat lab", ((n.days[0], n.start, n.end),), W_EXCEPTION * 2, block="SAT",
                           exception="laboratory on Saturday morning (make-up slot)"))
    elif kind == "pe":
        for a, b in (("Mon", "Wed"), ("Mon", "Fri"), ("Wed", "Fri")):
            opts += [Option(f"{p.name} {a[0]}{b[0]}", on(p, (a, b))) for p in mwf]
        for p, q in zip(mwf, mwf[1:]):
            if p.end == q.start:    # two adjacent periods, not across lunch
                for d in p.days:
                    opts.append(Option(f"{p.name}-{q.name} {d}", ((d, p.start, q.end),)))
    elif kind == "uni":
        for p in mwf:
            for d in p.days:
                opts.append(Option(f"{p.name} {d}", ((d, p.start, p.end),)))
    elif kind == "nstp":
        n = tf.nstp
        opts.append(Option(f"{n.days[0]} CWTS", ((n.days[0], n.start, n.end),)))
    return opts


def room_pools(uni: University, m: Meeting) -> list[tuple[str | None, int]]:
    """Room pools a meeting may use, with a penalty for each."""
    sec, course = m.klass.section, m.klass.course
    classroom = [(f"classrooms:{sec.college}", 0), ("shared", W_SHARED_ROOM)]
    if sec.is_small and uni.campus.pool(f"seminar:{sec.college}"):
        classroom.append((f"seminar:{sec.college}", 0))
    if m.kind in ("supervision", "nstp"):   # CWTS meets on the grounds as one group
        return [(None, 0)]
    if m.kind == "pe":
        return [("pe", 0)]
    if m.kind == "lab":
        return [(f"lab:{t}", 0 if i == 0 else W_ALT_LAB) for i, t in enumerate(course.lab_rooms)]
    if m.kind == "lab_lecture":
        return classroom + [(f"lab:{t}", W_LAB_LECTURE_IN_LAB) for t in course.lab_rooms]
    return classroom


def _blocked_days(classes: list[Klass]) -> dict:
    """Placement days: student groups on practicum are off campus those days."""
    blocked = defaultdict(set)
    for k in classes:
        if k.course.placement:
            for sub in k.section.subcohorts:
                blocked[sub].update(k.course.placement)
    return blocked


def _choices(uni: University, m: Meeting, blocked: dict) -> list[Choice]:
    tf = uni.timeframe
    sec, course = m.klass.section, m.klass.course
    off_days = set()
    if m.kind != "supervision":
        for sub in sec.subcohorts:
            off_days |= blocked.get(sub, set())
    unavailable = []
    if m.klass.faculty:
        for u in tf.faculty_unavailable.get(m.klass.faculty.key, []):
            unavailable.append((u["day"], parse_time(u["from"]), parse_time(u["to"])))
    lab_pref = None
    if m.kind == "lab":
        for p in tf.lab_day_preferences:
            if p["college"] == sec.college and p["year"] == sec.year:
                lab_pref = p
    pin = uni.fixed.get(m.klass.semester, {}).get((course.code, sec.name, m.part))
    pinned_pool = None
    if pin and pin.get("room"):
        pinned_pool = next((r.pool for r in uni.campus.rooms if r.name == pin["room"]), None)
    choices = []
    for opt in time_options(uni, m.kind):
        if pin and opt.label != pin["pattern"]:
            continue
        if opt.exception and (course.code, sec.name, m.part) in uni.avoid.get(m.klass.semester, set()):
            continue
        if any(d in off_days for d, _, _ in opt.intervals):
            continue
        if any(d == ud and s < ue and us < e for d, s, e in opt.intervals for ud, us, ue in unavailable):
            continue
        base = opt.penalty
        if lab_pref and not (opt.block in lab_pref["blocks"] and opt.intervals[0][0] in lab_pref["days"]):
            base += W_LAB_DAY
        for pool, pen in room_pools(uni, m):
            if pool is not None and not uni.campus.pool(pool):
                continue
            if pinned_pool and pool != pinned_pool:
                continue
            extra = 0
            if m.kind == "lab" and pool:
                preferred = uni.campus.lab_blocks.get(pool.split(":", 1)[1], [])
                if preferred and opt.block not in preferred:
                    extra += W_OFF_BLOCK
            choices.append(Choice(opt, pool, base + pen + extra))
    return choices


def solve_semester(uni: University, semester: int, time_limit: float = 180.0,
                   workers: int = 8, log: bool = False) -> Schedule:
    tf = uni.timeframe
    classes = uni.classes_for(semester)
    meetings = build_meetings(classes)
    blocked = _blocked_days(classes)
    slot = tf.slot

    def cells(opt: Option):
        for d, s, e in opt.intervals:
            for t in range(s, e, slot):
                yield d, t

    model = cp_model.CpModel()
    choices: dict[str, list[Choice]] = {}
    xs: dict[str, list] = {}
    objective = []
    stu: dict = defaultdict(lambda: defaultdict(list))      # subcohort -> cell -> lits
    fac: dict = defaultdict(lambda: defaultdict(list))      # faculty -> cell -> lits
    fac_day: dict = defaultdict(lambda: defaultdict(list))  # faculty -> day -> (lit, slots)
    pool_use: dict = defaultdict(lambda: defaultdict(list))

    for m in meetings:
        cs = _choices(uni, m, blocked)
        if not cs:
            raise ValueError(f"No allowed time for {m.klass.course.code} {m.klass.section.name} ({m.part})")
        lits = [model.NewBoolVar("") for _ in cs]
        model.AddExactlyOne(lits)
        choices[m.id], xs[m.id] = cs, lits
        for lit, c in zip(lits, cs):
            if c.penalty:
                objective.append(c.penalty * lit)
            for cell in cells(c.option):
                if m.kind != "supervision":
                    for sub in m.klass.section.subcohorts:
                        stu[sub][cell].append(lit)
                if m.klass.faculty and m.kind != "nstp":
                    fac[m.klass.faculty.key][cell].append(lit)
                if c.pool:
                    pool_use[c.pool][cell].append(lit)
            if m.klass.faculty and m.kind != "nstp":
                for d, s, e in c.option.intervals:
                    fac_day[m.klass.faculty.key][d].append((lit, (e - s) // slot))

    # No student group or teacher in two places at once.
    for per_cell in list(stu.values()) + list(fac.values()):
        for lits in per_cell.values():
            if len(lits) > 1:
                model.AddAtMostOne(lits)

    # Room pools: never more classes at once than rooms in the pool.
    for pool, per_cell in pool_use.items():
        cap = sum(r.capacity for r in uni.campus.pool(pool))
        for lits in per_cell.values():
            if len(lits) > cap:
                model.Add(sum(lits) <= cap)

    # Faculty daily hours (rule 3).
    per_hour = 60 // slot
    hard, pref = int(tf.fac_max_hours * per_hour), int(tf.fac_pref_hours * per_hour)
    for per_day in fac_day.values():
        for items in per_day.values():
            total = sum(n * l for l, n in items)
            model.Add(total <= hard)
            over = model.NewIntVar(0, hard, "")
            model.Add(over >= total - pref)
            objective.append(W_FAC_LONG_DAY * over)

    # Compact student days: count blocks of consecutive classes per day.
    # Lunch slots are skipped, so a lunch break does not count as a gap.
    lunch = {"Mon": (690, 750), "Wed": (690, 750), "Fri": (690, 750), "Tue": (720, 810), "Thu": (720, 810)}
    compact = []
    for per_cell in stu.values():
        for d in tf.days:
            if d not in lunch:
                continue
            times = [t for t in range(tf.day_start, tf.day_end, slot)
                     if not (lunch[d][0] <= t < lunch[d][1])]
            occ = {t: per_cell[(d, t)] for t in times if per_cell.get((d, t))}
            if len(occ) < 2:
                continue
            prev = None
            for t in times:
                if t in occ:
                    start = model.NewBoolVar("")
                    here = sum(occ[t])
                    model.Add(start >= here - (sum(occ[prev]) if prev in occ else 0))
                    compact.append(W_GAP * start)
                prev = t

    solver = cp_model.CpSolver()
    solver.parameters.num_search_workers = workers
    solver.parameters.log_search_progress = log
    t0 = time.time()
    model.Minimize(sum(objective))
    solver.parameters.max_time_in_seconds = time_limit * 0.3
    status = solver.Solve(model)
    if status in (cp_model.OPTIMAL, cp_model.FEASIBLE) and compact:
        for m in meetings:
            for lit in xs[m.id]:
                model.AddHint(lit, solver.Value(lit))
        model.Minimize(sum(objective) + sum(compact))
        solver.parameters.max_time_in_seconds = max(10.0, time_limit - (time.time() - t0))
        status2 = solver.Solve(model)
        if status2 in (cp_model.OPTIMAL, cp_model.FEASIBLE):
            status = status2
    elapsed = time.time() - t0
    name = solver.StatusName(status)
    if status not in (cp_model.OPTIMAL, cp_model.FEASIBLE):
        return Schedule(semester, [], name, {"time_s": round(elapsed, 1), "meetings": len(meetings)})

    picked: dict[str, Choice] = {}
    for m in meetings:
        picked[m.id] = next(c for lit, c in zip(xs[m.id], choices[m.id]) if solver.Value(lit))

    rooms = assign_rooms(uni, meetings, picked, time_limit=min(90.0, time_limit / 2))
    sessions = []
    for m in meetings:
        c = picked[m.id]
        for d, s, e in c.option.intervals:
            sessions.append(Session(m.id, m.klass, m.part, d, s, e, c.option.label, rooms.get((m.id, d)),
                                    c.option.exception))
    order = {d: i for i, d in enumerate(tf.days)}
    sessions.sort(key=lambda s: (order[s.day], s.start, s.klass.section.name))
    stats = {"time_s": round(elapsed, 1), "meetings": len(meetings), "classes": len(classes),
             "objective": solver.ObjectiveValue(), "best_bound": solver.BestObjectiveBound()}
    return Schedule(semester, sessions, name, stats)


def assign_rooms(uni: University, meetings: list[Meeting], picked: dict[str, Choice],
                 time_limit: float = 60.0) -> dict[tuple[str, str], str]:
    """Pick a room for every session inside its meeting's room pool."""
    model = cp_model.CpModel()
    slot = uni.timeframe.slot
    use: dict = defaultdict(list)             # (room, day, time) -> lits
    y: dict = {}                              # (meeting, day) -> {room: lit}
    objective = []
    meeting_room: dict = {}
    section_room: dict = {}

    for m in meetings:
        c = picked[m.id]
        if not c.pool:
            continue
        rooms = uni.campus.pool(c.pool)
        pin = uni.fixed.get(m.klass.semester, {}).get((m.klass.course.code, m.klass.section.name, m.part))
        if pin and pin.get("room"):
            rooms = [r for r in rooms if r.name == pin["room"]] or rooms
        home = uni.campus.home_buildings(m.klass.section.department)
        for d, s, e in c.option.intervals:
            y[(m.id, d)] = {}
            for r in rooms:
                v = model.NewBoolVar("")
                y[(m.id, d)][r.name] = v
                for t in range(s, e, slot):
                    use[(r.name, d, t)].append(v)
                if c.pool.startswith(("classrooms", "seminar")):
                    if r.building not in home:
                        objective.append(W_OUTSIDE_HOME * v)
                    key = (m.klass.section.name, r.name)
                    if key not in section_room:
                        section_room[key] = model.NewBoolVar("")
                    model.AddImplication(v, section_room[key])
                key = (m.id, r.name)
                if key not in meeting_room:
                    meeting_room[key] = model.NewBoolVar("")
                model.AddImplication(v, meeting_room[key])
            model.AddExactlyOne(y[(m.id, d)].values())

    capacity = {r.name: r.capacity for r in uni.campus.rooms}
    for (room, _, _), lits in use.items():
        if len(lits) > capacity[room]:
            model.Add(sum(lits) <= capacity[room])
    objective += [W_ROOM_CHANGE * v for v in meeting_room.values()]
    objective += [W_ROOM_CHANGE * v for v in section_room.values()]
    model.Minimize(sum(objective))
    solver = cp_model.CpSolver()
    solver.parameters.max_time_in_seconds = time_limit
    solver.parameters.num_search_workers = 8
    status = solver.Solve(model)
    if status not in (cp_model.OPTIMAL, cp_model.FEASIBLE):
        return {}
    return {key: next(r for r, v in opts.items() if solver.Value(v)) for key, opts in y.items()}


def evaluate(uni: University, schedule: Schedule) -> dict:
    """Quality measures for a finished schedule."""
    tf = uni.timeframe
    stu: dict = defaultdict(lambda: defaultdict(list))
    fac: dict = defaultdict(lambda: defaultdict(list))
    no_room = shared = 0
    for s in schedule.sessions:
        if s.part != "Supervision":
            for sub in s.klass.section.subcohorts:
                stu[sub][s.day].append((s.start, s.end))
            if s.room is None and s.part != "NSTP":
                no_room += 1
            elif s.room.startswith("LIN"):
                shared += 1
        if s.klass.faculty and s.part != "NSTP":
            fac[s.klass.faculty.key][s.day].append((s.start, s.end))
    lunch = {"Mon": 60, "Wed": 60, "Fri": 60, "Tue": 90, "Thu": 90}

    def idle(spans, day):
        spans.sort()
        gap = sum(max(0, b[0] - a[1]) for a, b in zip(spans, spans[1:]))
        if spans[0][1] <= 720 <= spans[-1][0]:
            gap -= lunch.get(day, 0)
        return max(0, gap)

    stu_idle = sum(idle(sp, d) for days in stu.values() for d, sp in days.items()) / 60
    long_days = sum(1 for days in fac.values() for sp in days.values()
                    if sum(e - s for s, e in sp) > tf.fac_pref_hours * 60)
    return {
        "student_groups": len(stu),
        "avg_idle_hours_per_student_group_per_week": round(stu_idle / max(1, len(stu)), 2),
        "faculty_days_over_preferred_hours": long_days,
        "sessions_in_overflow_rooms": shared,
        "sessions_without_room": no_room,
    }


def diagnose(uni: University, semester: int, time_limit: float = 60.0, max_conflicts: int = 8) -> list[list[str]]:
    """Find a small set of resources whose hard limits cannot all hold.

    Every teacher, student group, room pool, and teacher daily limit gets
    its own switch; the solver reports a set of switches that together make
    the timetable impossible.
    """
    tf = uni.timeframe
    classes = uni.classes_for(semester)
    meetings = build_meetings(classes)
    blocked = _blocked_days(classes)
    slot = tf.slot
    model = cp_model.CpModel()
    stu: dict = defaultdict(lambda: defaultdict(list))
    fac: dict = defaultdict(lambda: defaultdict(list))
    fac_day: dict = defaultdict(lambda: defaultdict(list))
    pool_use: dict = defaultdict(lambda: defaultdict(list))
    for m in meetings:
        cs = _choices(uni, m, blocked)
        if not cs:
            return [[f"{m.klass.course.code} {m.klass.section.name} ({m.part}) has no allowed time at all"]]
        lits = [model.NewBoolVar("") for _ in cs]
        model.AddExactlyOne(lits)
        for lit, c in zip(lits, cs):
            for d, s, e in c.option.intervals:
                for t in range(s, e, slot):
                    if m.kind != "supervision":
                        for sub in m.klass.section.subcohorts:
                            stu[sub][(d, t)].append(lit)
                    if m.klass.faculty and m.kind != "nstp":
                        fac[m.klass.faculty.key][(d, t)].append(lit)
                    if c.pool:
                        pool_use[c.pool][(d, t)].append(lit)
                if m.klass.faculty and m.kind != "nstp":
                    fac_day[m.klass.faculty.key][d].append((lit, (e - s) // slot))
    switches = {}

    def switch(label):
        if label not in switches:
            switches[label] = model.NewBoolVar(label)
        return switches[label]

    for sub, per_cell in stu.items():
        sw = switch(f"student group {sub.label}")
        for lits in per_cell.values():
            if len(lits) > 1:
                model.Add(sum(lits) <= 1).OnlyEnforceIf(sw)
    for key, per_cell in fac.items():
        sw = switch(f"teacher {uni.faculty[key].name}")
        for lits in per_cell.values():
            if len(lits) > 1:
                model.Add(sum(lits) <= 1).OnlyEnforceIf(sw)
    for pool, per_cell in pool_use.items():
        cap = sum(r.capacity for r in uni.campus.pool(pool))
        sw = switch(f"room pool {pool} ({cap} at once)")
        for lits in per_cell.values():
            if len(lits) > cap:
                model.Add(sum(lits) <= cap).OnlyEnforceIf(sw)
    hard = int(tf.fac_max_hours * 60 // slot)
    for key, per_day in fac_day.items():
        sw = switch(f"daily maximum for {uni.faculty[key].name}")
        for items in per_day.values():
            model.Add(sum(n * l for l, n in items) <= hard).OnlyEnforceIf(sw)
    # Find one conflict, switch its members off, and look for the next.
    conflicts, active = [], dict(switches)
    by_index = {v.Index(): name for name, v in switches.items()}
    for _ in range(max_conflicts):
        model.ClearAssumptions()
        model.AddAssumptions(list(active.values()))
        solver = cp_model.CpSolver()
        solver.parameters.max_time_in_seconds = time_limit
        solver.parameters.num_search_workers = 1
        status = solver.Solve(model)
        if status != cp_model.INFEASIBLE:
            break
        core = [by_index[i] for i in solver.SufficientAssumptionsForInfeasibility()]
        if not core:
            break
        conflicts.append(core)
        for name in core:
            active.pop(name, None)
    return conflicts
