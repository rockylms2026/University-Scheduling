"""Checks that the data files match the college loading plans."""

from scheduler.model import load_university
from scheduler.solver import build_meetings, time_options
from scheduler.validate import faculty_load_summary, validate

UNI = load_university()


def test_no_data_errors():
    errors = [i.message for i in validate(UNI) if i.level == "error"]
    assert errors == []


def test_counts():
    assert len(UNI.faculty) == 115            # CSS 21, CICS 18, CBE 21, COE 21, CCJPS 15, GE 19 (each college: its Associate Dean)
    ads = [f for f in UNI.faculty.values() if f.designation == "Associate Dean"]
    assert len(ads) == 5 and all(f.max_lu == 6 and f.class_cap == 2 and f.course_cap == 1 and f.prep_cap == 1 for f in ads)
    assert not any("GE Handler" in f.designation or "GE handler" in f.designation for f in UNI.faculty.values())
    assert len(UNI.programs) == 19
    assert len(UNI.campus.pool("classrooms:CSS")) == 15
    assert len(UNI.campus.pool("classrooms:CCJPS")) == 8


def test_loads_match_plan_summaries():
    # (faculty, semester) -> LU from the plans' load summary tables
    expected = {
        ("CSS-P5", 1): 24, ("CSS-L4", 1): 18, ("CICS-C3", 1): 24, ("CICS-B4", 2): 18,
        ("CBE-B4", 1): 17, ("CBE-H4", 2): 22, ("CCJPS-D2", 1): 7, ("CCJPS-W4", 2): 12,
        ("COE-S13", 1): 16,   # 18 in the plan, which counts SEF 405 as a 5-LU lab; here it is a 3-LU lecture
        ("GE-G13", 1): 22, ("GE-G19", 2): 18,
    }
    for (key, sem), lu in expected.items():
        assert faculty_load_summary(UNI, sem)[key]["lu"] == lu, key


def test_time_frame_patterns():
    assert len([o for o in time_options(UNI, "lecture") if not o.exception]) == 8 + 5   # M1-M8 MWF, T1-T5 TTh
    assert len([o for o in time_options(UNI, "lab") if not o.exception]) == 4 * 3 + 3 * 2
    for o in time_options(UNI, "lecture") + time_options(UNI, "pe"):
        for day, start, end in o.intervals:   # nothing runs through lunch
            lunch = (690, 750) if day in ("Mon", "Wed", "Fri") else (720, 810)
            assert end <= lunch[0] or start >= lunch[1], o.label


def test_bsba_major_groups_conflict_with_both_blocks():
    fm = UNI.sections["BSBA 3-FM"].subcohorts
    assert fm & UNI.sections["BSBA 3A"].subcohorts
    assert fm & UNI.sections["BSBA 3B"].subcohorts
    assert not fm & UNI.sections["BSBA 3-MKT"].subcohorts


def test_every_class_has_meetings():
    for sem in (1, 2):
        ids = {m.klass.id for m in build_meetings(UNI.classes_for(sem))}
        for k in UNI.classes_for(sem):
            if k.course.kind != "field" or k.faculty:
                assert k.id in ids, (k.course.code, k.section.name)


def test_organization_chart_matches_faculty():
    """data/organization.yaml points only at real faculty, every college has its Associate Dean, and every GE
    Department teacher sits in one area."""
    import yaml
    from scheduler.model import DATA_DIR
    org = yaml.safe_load((DATA_DIR / "organization.yaml").read_text())
    keys = set(UNI.faculty)
    for code, unit in org["colleges"].items():
        f = UNI.faculty[unit["associate_dean"]["faculty"]]
        assert f.college == code and f.designation == "Associate Dean"
    assert UNI.faculty[org["ge"]["coordinator"]["faculty"]].college == "GE"
    in_areas = [k for a in org["ge"]["areas"] for k in a["faculty"]]
    ge = {k for k, f in UNI.faculty.items() if f.college == "GE"} - {org["ge"]["coordinator"]["faculty"]}
    assert sorted(in_areas) == sorted(ge)
    referenced = [s["faculty"] for u in org["support_units"] for s in u["staff"] if "faculty" in s]
    assert set(referenced) <= keys and set(org["faculty_emails"]) == keys
    assert "123456" not in (DATA_DIR / "organization.yaml").read_text()   # no passwords in the chart


def test_faculty_degrees_and_specializations():
    """Every faculty member has a highest degree; everyone from the loading plans also has a specialization."""
    # The Religious Education plan lists no degrees or specializations.
    plans = [f for f in UNI.faculty.values() if f.department != "Religious Education"]
    assert all(f.degree for f in plans)
    missing = [f.name for f in plans if not f.specialization and f.designation != "Associate Dean"]
    assert not missing, missing
    assert UNI.faculty["CCJPS-R4"].specialization == "Criminalistics, photography, ballistics, questioned documents"


def test_religion_and_one_section_programs():
    """Every program takes the religion sequence; four programs run one section a year (2026-10 plans)."""
    rel = {"1-1": "REL 103A", "1-2": "REL 103B", "2-1": "REL 203A", "2-2": "REL 203B", "3-1": "REL 303A", "3-2": "REL 303B", "4-1": "REL 403"}
    for p in UNI.programs.values():
        for key, code in rel.items():
            y, s = map(int, key.split("-"))
            assert code in [c for c, _ in p.curriculum[(y, s)]], (p.code, code)
    assert UNI.courses["REL 403"].kind == "double" and UNI.courses["REL 103A"].kind == "uni"
    for code in ("ABC", "ABEcon", "BLIS", "BSEntrep"):
        assert all(b == [""] for b in UNI.programs[code].blocks.values()), code
    assert "ABC 2" in UNI.sections and "ABC 2A" not in UNI.sections
    for gone in ("CSS-L5", "CSS-M2", "CSS-E3", "CICS-B2", "CICS-B5", "CBE-N3"):
        assert gone not in UNI.faculty
    re = [f for f in UNI.faculty.values() if f.department == "Religious Education"]
    assert len(re) == 6 and UNI.faculty["RE-RE1"].max_lu == 15
    # class ids come from the semester, course and section, so they survive curriculum changes
    assert UNI.classes[1][0].id.startswith("S1-") and any(k.id == "S1-REL403-BSP4C" for k in UNI.classes[1])
