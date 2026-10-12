"""Independent check of a finished timetable against the hard rules.

This does not trust the solver: it re-reads the sessions and reports every
double booking, lunch violation, placement-day clash, and over-full day.
"""

from __future__ import annotations

from collections import defaultdict

from .model import University
from .solver import Schedule

LUNCH = {"Mon": (690, 750), "Wed": (690, 750), "Fri": (690, 750), "Tue": (720, 810), "Thu": (720, 810)}


def _overlaps(items):
    items = sorted(items, key=lambda x: x[0])
    for (s1, e1, a), (s2, e2, b) in zip(items, items[1:]):
        if s2 < e1:
            yield a, b


def verify(uni: University, schedule: Schedule) -> list[str]:
    problems: list[str] = []
    sem = schedule.semester
    by_student = defaultdict(list)
    by_teacher = defaultdict(list)
    by_room = defaultdict(list)
    teacher_minutes = defaultdict(int)
    capacity = {r.name: r.capacity for r in uni.campus.rooms}

    placement = defaultdict(set)
    for k in uni.classes_for(sem):
        for sub in k.section.subcohorts:
            placement[sub].update(k.course.placement)

    for s in schedule.sessions:
        tag = f"{s.klass.course.code} {s.klass.section.name} {s.part} {s.day} {s.label}"
        if s.part != "Supervision":
            for sub in s.klass.section.subcohorts:
                by_student[(sub, s.day)].append((s.start, s.end, tag))
                if s.day in placement[sub]:
                    problems.append(f"{tag}: {sub.label} is at placement on {s.day}")
            if s.room is None and s.part != "NSTP":
                problems.append(f"{tag}: no room")
            elif s.room is not None:
                by_room[(s.room, s.day)].append((s.start, s.end, tag))
        if s.klass.faculty and s.part != "NSTP":
            by_teacher[(s.klass.faculty.key, s.day)].append((s.start, s.end, tag))
            teacher_minutes[(s.klass.faculty.key, s.day)] += s.end - s.start
        lunch = LUNCH.get(s.day)
        if lunch and s.start < lunch[1] and lunch[0] < s.end:
            problems.append(f"{tag}: runs through lunch")

    for (sub, day), items in by_student.items():
        for a, b in _overlaps(items):
            problems.append(f"Student group {sub.label} double-booked on {day}: {a} / {b}")
    for (key, day), items in by_teacher.items():
        for a, b in _overlaps(items):
            problems.append(f"{uni.faculty[key].name} double-booked on {day}: {a} / {b}")
    for (room, day), items in by_room.items():
        if capacity.get(room, 1) == 1:
            for a, b in _overlaps(items):
                problems.append(f"Room {room} double-booked on {day}: {a} / {b}")
        else:
            points = sorted({t for s, e, _ in items for t in (s, e)})
            for t in points:
                n = sum(1 for s, e, _ in items if s <= t < e)
                if n > capacity[room]:
                    problems.append(f"{room} holds {n} classes at {day} {t // 60}:{t % 60:02d} (limit {capacity[room]})")
    limit = uni.timeframe.fac_max_hours * 60
    for (key, day), minutes in teacher_minutes.items():
        if minutes > limit:
            problems.append(f"{uni.faculty[key].name} teaches {minutes / 60:.1f} h on {day} (limit {limit / 60:.0f})")

    # Every class that meets on campus is scheduled for its full weekly hours.
    minutes = defaultdict(int)
    for s in schedule.sessions:
        minutes[s.klass.id] += s.end - s.start
    for k in uni.classes_for(sem):
        need = (k.course.lec + k.course.lab) * 60
        if k.course.kind == "field" or k.course.kind == "uni":
            continue
        if minutes[k.id] < need:
            problems.append(f"{k.course.code} {k.section.name}: {minutes[k.id] / 60:.1f} h scheduled, needs {need / 60:.0f} h")
    return problems
