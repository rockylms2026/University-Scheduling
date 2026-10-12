"""Command line: python -m scheduler <command>

  validate                 check the curricula and loading plans
  solve [--semester N]     build timetables (both semesters by default)
  diagnose --semester N    explain why a semester cannot be scheduled
  export                   write the Excel workbook and the HTML viewer
  apply-changes FILE       add changes saved in the online schedule (JSON) to data/overrides.yaml
"""

from __future__ import annotations

import argparse
import sys

from .model import load_university
from .validate import print_issues, validate


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="python -m scheduler", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("validate")
    p = sub.add_parser("solve")
    p.add_argument("--semester", type=int, choices=[1, 2])
    p.add_argument("--time-limit", type=float, default=240, help="seconds per semester (default 240)")
    p.add_argument("--log", action="store_true", help="show solver progress")
    p = sub.add_parser("diagnose")
    p.add_argument("--semester", type=int, choices=[1, 2], required=True)
    sub.add_parser("export")
    p = sub.add_parser("apply-changes")
    p.add_argument("file")
    args = parser.parse_args(argv)

    uni = load_university()
    if args.command == "validate":
        issues = validate(uni)
        print_issues(issues)
        return 1 if any(i.level == "error" for i in issues) else 0

    if args.command == "diagnose":
        from .solver import diagnose
        conflicts = diagnose(uni, args.semester)
        if not conflicts:
            print("No conflicts: the hard rules can all be met.")
        for i, c in enumerate(conflicts, 1):
            print(f"Conflict {i}: these cannot all be satisfied together:")
            for item in c:
                print(f"  - {item}")
        return 0

    if args.command == "solve":
        from . import store
        from .solver import evaluate, solve_semester
        from .verify import verify
        errors = [i for i in validate(uni) if i.level == "error"]
        if errors:
            print_issues(errors)
            print("Fix the data errors above before solving.")
            return 1
        failed = False
        for sem in [args.semester] if args.semester else [1, 2]:
            print(f"Semester {sem}: solving (up to {args.time_limit:.0f} s)...", flush=True)
            sched = solve_semester(uni, sem, time_limit=args.time_limit, log=args.log)
            if not sched.sessions:
                print(f"  No timetable found ({sched.status}). Run: python -m scheduler diagnose --semester {sem}")
                failed = True
                continue
            problems = verify(uni, sched)
            sched.stats["quality"] = evaluate(uni, sched)
            sched.stats["verification_problems"] = len(problems)
            path = store.save(sched)
            print(f"  {sched.status}: {len(sched.sessions)} sessions -> {path}")
            for k, v in sched.stats["quality"].items():
                print(f"  {k}: {v}")
            exceptions = sorted({(s.klass.course.code, s.klass.section.name, s.exception)
                                 for s in sched.sessions if s.exception})
            for code, sec, why in exceptions:
                print(f"  NEEDS APPROVAL: {code} {sec}: {why}")
            for prob in problems:
                print(f"  PROBLEM: {prob}")
            failed |= bool(problems)
        return 1 if failed else 0

    if args.command == "apply-changes":
        from .apply_changes import main as apply_main
        counts = apply_main(args.file, uni)
        print("Added to data/overrides.yaml:", ", ".join(f"{v} {k.replace('_', ' ')}" for k, v in counts.items()))
        print("Now run: python -m scheduler solve && python -m scheduler export")
        return 0

    if args.command == "export":
        from . import store
        from .export_excel import write_workbook
        from .export_html import write_viewer
        schedules = {}
        for sem in (1, 2):
            try:
                schedules[sem] = store.load(uni, sem)
            except FileNotFoundError:
                print(f"Semester {sem}: no saved schedule (run solve first)")
        if not schedules:
            return 1
        print("Workbook:", write_workbook(uni, schedules))
        print("Viewer:  ", write_viewer(uni, schedules))
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
