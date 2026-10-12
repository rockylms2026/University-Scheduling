"""Turn changes saved in the online schedule into data/overrides.yaml.

The page stores each change as a document in its shared "changes"
collection. Export them as a JSON list (each item: the document fields plus
"id") and run:  python -m scheduler apply-changes changes.json
"""

from __future__ import annotations

import json
from pathlib import Path

import yaml

from .model import DATA_DIR
from .store import OUTPUT_DIR, load


def apply_changes(items: list[dict], uni, data_dir: Path = DATA_DIR) -> dict:
    path = data_dir / "overrides.yaml"
    raw = yaml.safe_load(path.read_text()) if path.exists() else {}
    raw = raw or {}
    extra = raw.setdefault("extra_faculty", []) or []
    raw["extra_faculty"] = extra
    assigns = raw.setdefault("teacher_assignments", {}) or {}
    raw["teacher_assignments"] = assigns
    fixed = raw.setdefault("fixed", {}) or {}
    raw["fixed"] = fixed
    avoid = raw.setdefault("avoid_exceptions", {}) or {}
    raw["avoid_exceptions"] = avoid
    counts = {"move": 0, "assign": 0, "approve": 0, "another_time": 0}

    def upsert(table: dict, sem: int, entry: dict, keys: tuple):
        rows = table.setdefault(sem, []) or []
        table[sem] = [r for r in rows if tuple(r.get(k) for k in keys) != tuple(entry.get(k) for k in keys)] + [entry]

    schedules = {}
    for c in items:
        sem = int(c["sem"])
        if c["type"] == "move":
            entry = {"course": c["course"], "section": c["section"], "part": c["part"], "pattern": c["pattern"]}
            if c.get("room"):
                entry["room"] = c["room"]
            upsert(fixed, sem, entry, ("course", "section", "part"))
            counts["move"] += 1
        elif c["type"] == "assign":
            teacher = c.get("teacher")
            if not teacher:
                name = c["newTeacher"].strip()
                existing = next((f for f in extra if f["name"] == name), None)
                if existing is None:
                    existing = {"key": f"PT-{len(extra) + 1}", "name": name, "department": "Part-time", "max_lu": 12}
                    extra.append(existing)
                teacher = existing["key"]
            upsert(assigns, sem, {"course": c["course"], "section": c["section"], "teacher": teacher}, ("course", "section"))
            counts["assign"] += 1
        elif c["type"] == "approve":
            if c.get("decision") == "approved":
                # Keep the approved exception exactly where it is.
                if sem not in schedules:
                    schedules[sem] = load(uni, sem)
                s = next((s for s in schedules[sem].sessions if s.klass.course.code == c["course"]
                          and s.klass.section.name == c["section"] and s.part == c["part"]), None)
                if s:
                    entry = {"course": c["course"], "section": c["section"], "part": c["part"], "pattern": s.label}
                    if s.room:
                        entry["room"] = s.room
                    upsert(fixed, sem, entry, ("course", "section", "part"))
                counts["approve"] += 1
            else:
                upsert(avoid, sem, {"course": c["course"], "section": c["section"], "part": c["part"]},
                       ("course", "section", "part"))
                counts["another_time"] += 1

    header = ""
    if path.exists():   # keep the explanatory comment block at the top
        for line in path.read_text().splitlines(keepends=True):
            if line.startswith("#") or not line.strip():
                header += line
            else:
                break
    path.write_text(header + yaml.safe_dump(raw, sort_keys=False, allow_unicode=True))
    return counts


def main(json_path: str, uni) -> dict:
    items = json.loads(Path(json_path).read_text())
    return apply_changes(items, uni)
