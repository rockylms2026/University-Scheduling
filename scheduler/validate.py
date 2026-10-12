"""Consistency checks on the curricula and loading plans, before scheduling."""

from __future__ import annotations

from collections import Counter, defaultdict

from .model import Issue, University


def faculty_load_summary(uni: University, semester: int) -> dict[str, dict]:
    """LU and preparation counts per faculty member for one semester."""
    summary: dict[str, dict] = {
        key: {"lu": 0, "major_lu": 0, "ge_lu": 0, "courses": set(), "classes": 0}
        for key in uni.faculty
    }
    for k in uni.classes_for(semester):
        if k.faculty is None:
            continue
        row = summary[k.faculty.key]
        lu = k.course.load_units
        row["lu"] += lu
        row["ge_lu" if k.course.is_core else "major_lu"] += lu
        row["courses"].add(k.course.code)
        row["classes"] += 1
    for row in summary.values():
        courses = row["courses"]
        row["preps_capped"] = len([c for c in courses if c not in uni.intro_courses and not uni.courses[c].is_core])
        row["preps_total"] = len(courses)
    return summary


def validate(uni: University) -> list[Issue]:
    issues = list(uni.issues)

    for sem in (1, 2):
        unassigned_core: dict[str, list[str]] = defaultdict(list)
        for k in uni.classes_for(sem):
            if k.faculty is not None:
                continue
            if k.course.is_core:
                unassigned_core[k.course.code].append(k.section.name)
            else:
                issues.append(Issue("warning", "unassigned",
                                    f"Semester {sem}: major class {k.course.code} {k.section.name} has no teacher in the loading plan"))
        for code, secs in sorted(unassigned_core.items()):
            course = uni.courses[code]
            issues.append(Issue("info", "ge-tba",
                                f"Semester {sem}: {len(secs)} section(s) of {code} {course.title} have no named teacher "
                                f"and are scheduled as TBA ({course.housed_by}): {', '.join(secs)}"))

        for key, row in faculty_load_summary(uni, sem).items():
            fac = uni.faculty[key]
            if row["lu"] > fac.max_lu:
                issues.append(Issue("error", "load",
                                    f"Semester {sem}: {fac.name} carries {row['lu']} LU, above the {fac.max_lu} LU limit"))
            if fac.prep_cap is not None and row["preps_capped"] > fac.prep_cap:
                issues.append(Issue("error", "preps",
                                    f"Semester {sem}: {fac.name} has {row['preps_capped']} preparations (cap {fac.prep_cap})"))
            if row["preps_total"] > 5:
                issues.append(Issue("error", "preps",
                                    f"Semester {sem}: {fac.name} has {row['preps_total']} different courses (cap 5)"))

    return issues


def print_issues(issues: list[Issue]) -> None:
    order = {"error": 0, "warning": 1, "info": 2}
    counts = Counter(i.level for i in issues)
    for issue in sorted(issues, key=lambda i: (order[i.level], i.category)):
        print(f"[{issue.level.upper():7}] {issue.category:10} {issue.message}")
    print(f"\n{counts['error']} error(s), {counts['warning']} warning(s), {counts['info']} note(s)")
