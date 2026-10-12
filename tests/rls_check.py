"""Checks the Supabase access rules against a local Postgres loaded with supabase/setup.sql.

Run: python tests/rls_check.py  (needs a local database "sched" loaded with tests/supabase_stub.sql,
then supabase/setup.sql)
"""
import json
import subprocess
import sys

DB = sys.argv[1] if len(sys.argv) > 1 else "sched"
failures = []


def psql(sql, as_email=None):
    pre = ""
    if as_email is not None:
        pre = (f"set role authenticated; set request.jwt.claims = '{json.dumps({'email': as_email, 'sub': '00000000-0000-0000-0000-000000000001'})}';")
    r = subprocess.run(["su", "postgres", "-c", f"psql -X -q -At -v ON_ERROR_STOP=1 -d {DB}"], input=f"begin; {pre} {sql}; commit;",
                       capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr).strip()


def expect(label, ok_wanted, sql, who=None, contains=None):
    ok, out = psql(sql, who)
    good = ok == ok_wanted and (contains is None or contains in out)
    print(("PASS " if good else "FAIL ") + label + ("" if good else f"\n     -> {out[:300]}"))
    if not good:
        failures.append(label)
    return out


def one(sql):
    out = psql(sql)[1]
    return out.splitlines()[-1] if out else ""


def cls(where):
    return one(f"select id from classes where {where} order by id limit 1")


BSP = "program = 'BSP'"
psy_major = cls(f"{BSP} and not is_ge")
eco_major = cls("department = 'Economics' and not is_ge")
cisc_major = cls("college = 'CISC' and not is_ge")
own_ge = cls(f"{BSP} and course = 'PSYC 160'")                       # Psychology holds it
same_college = cls(f"{BSP} and course = 'SOCS 195'")                 # Economics (CSS) holds it
other_college = cls(f"{BSP} and course = 'STS 180'")                 # Information Technology (CISC) holds it
gedept = cls(f"{BSP} and course = 'PE 101'")                         # GE Department
ge_elsewhere = cls("department = 'Communication' and course = 'PSYC 160'")
# Social Work teaches PSYC 160 and GAD 171 (housed by Psychology) in the loading plan.
sw_own = cls("department = 'Social Work' and course = 'PSYC 160'")
sw_lends_same = cls("department = 'Criminology' and course = 'PSYC 160' and holder_dept = 'Social Work'")
sw_lends_other = cls("department = 'Entrepreneurship' and course = 'GAD 171' and holder_dept = 'Social Work'")
sw_teacher = one("select key from faculty where department = 'Social Work' order by key limit 1")
psy_teacher = one("select key from faculty where department = 'Psychology' order by key limit 1")
eco_teacher = one("select key from faculty where department = 'Economics' order by key limit 1")
it_teacher = one("select key from faculty where department = 'Information Technology' order by key limit 1")

ADMIN = "agbayanispencer@gmail.com"
psql("""insert into staff (email, full_name, role, college, department) values
  ('chair.psy@u.edu','Chair Psychology','chair','CSS','Psychology'),
  ('chair.eco@u.edu','Chair Economics','chair','CSS','Economics'),
  ('chair.it@u.edu','Chair IT','chair','CISC','Information Technology'),
  ('chair.sw@u.edu','Chair Social Work','chair','CCJPS','Social Work'),
  ('chair.crim@u.edu','Chair Criminology','chair','CCJPS','Criminology'),
  ('chair.entrep@u.edu','Chair Entrepreneurship','chair','CBE','Entrepreneurship'),
  ('adean.ccjps@u.edu','Assoc Dean CCJPS','associate_dean','CCJPS',null),
  ('adean.css@u.edu','Assoc Dean CSS','associate_dean','CSS',null),
  ('adean.cisc@u.edu','Assoc Dean CISC','associate_dean','CISC',null),
  ('ge@u.edu','GE Coordinator','ge_coordinator',null,null),
  ('dean@u.edu','Dean','dean',null,null) on conflict do nothing;
  update settings set ge_open=false where id=1;
  delete from bookings where class_id in (select id from classes where program = 'BSP');
  delete from teacher_changes where class_id in (select id from classes where program = 'BSP');""")


def bk(cid, pat="M3 MWF"):
    return (f"insert into bookings (class_id, part, sem, pattern, room) values ('{cid}', 'Lec', 1, '{pat}', 'DIW 301') "
            "on conflict (class_id, part) do update set pattern = excluded.pattern")


def tc(cid, t):
    return (f"insert into teacher_changes (class_id, sem, teacher) values ('{cid}', 1, '{t}') "
            "on conflict (class_id) do update set teacher = excluded.teacher")


expect("anon cannot read", False, "set role anon; select count(*) from bookings")
expect("unknown account sees nothing", True, "select count(*) from bookings", "stranger@x.com", contains="0")
expect("unknown account cannot book", False, bk(psy_major), "stranger@x.com")
expect("cannot read reference data without a role", True, "select count(*) from faculty", "stranger@x.com", contains="0")

# Kinds of classes
expect("kinds are right", True,
       f"select class_kind('{psy_major}')||' '||class_kind('{own_ge}')||' '||class_kind('{same_college}')||' '||class_kind('{other_college}')||' '||class_kind('{gedept}')",
       ADMIN, contains="major own borrowed borrowed gedept")

# Chairs: majors
expect("chair books own department major", True, bk(psy_major), "chair.psy@u.edu")
expect("chair cannot book another department", False, bk(eco_major), "chair.psy@u.edu")
expect("chair assigns own faculty to a major", True, tc(psy_major, psy_teacher), "chair.psy@u.edu")
expect("chair cannot assign other department faculty", False, tc(psy_major, eco_teacher), "chair.psy@u.edu")
expect("stamp records who booked", True, f"select updated_by from bookings where class_id='{psy_major}'", "chair.psy@u.edu", contains="chair.psy@u.edu")

# Chairs: their own GE
expect("chair books the GE their department holds", True, bk(own_ge, "M2 MWF"), "chair.psy@u.edu")
expect("own GE needs no approval", True, f"select needs_approval('{own_ge}')", "chair.psy@u.edu", contains="f")
expect("chair assigns own faculty to own GE", True, tc(own_ge, psy_teacher), "chair.psy@u.edu")
expect("chair cannot book GE for another department sections", False, bk(ge_elsewhere), "chair.psy@u.edu")

# Chairs: borrowed GE, same college (SOCS 195 from Economics)
expect("chair books a borrowed GE time", True, bk(same_college, "M5 MWF"), "chair.psy@u.edu")
expect("borrowed GE needs approval", True, f"select needs_approval('{same_college}')", "chair.psy@u.edu", contains="t")
expect("requesting chair cannot pick its teacher", False, tc(same_college, psy_teacher), "chair.psy@u.edu")
expect("requesting chair cannot approve", False, f"select decide_ge('{same_college}','approve')", "chair.psy@u.edu")
expect("same-college associate dean is not the approver", False, f"select decide_ge('{same_college}','approve')", "adean.css@u.edu")
expect("holding chair must pick a teacher of the holding department", False,
       f"select decide_ge('{same_college}','approve',null,'{psy_teacher}')", "chair.eco@u.edu")
expect("holding chair approves with a teacher", True,
       f"select decide_ge('{same_college}','approve',null,'{eco_teacher}'); select teacher||' '||approved_by from ge_decisions where class_id='{same_college}'",
       "chair.eco@u.edu", contains=f"{eco_teacher} chair.eco@u.edu")
expect("approval set the teacher", True, f"select class_teacher('{same_college}')", ADMIN, contains=eco_teacher)
expect("holding chair cannot book the time", False, bk(same_college, "M6 MWF"), "chair.eco@u.edu")
expect("approvals cannot be written directly", False, "update ge_decisions set approved_by='me'", "chair.eco@u.edu")

# Chairs: borrowed GE, another college (STS 180 from IT, CISC)
expect("chair books a GE from another college", True, bk(other_college, "M4 MWF"), "chair.psy@u.edu")
expect("holding chair of another college is not the approver", False, f"select decide_ge('{other_college}','approve')", "chair.it@u.edu")
expect("holding chair may still pick the teacher", True, tc(other_college, it_teacher), "chair.it@u.edu")
expect("associate dean of the holding college approves", True, f"select decide_ge('{other_college}','approve')", "adean.cisc@u.edu", contains="approved")
expect("associate dean rejects with a reason", True,
       f"select decide_ge('{other_college}','reject','Teacher has a thesis class then'); select rejected_by from ge_decisions where class_id='{other_college}'",
       "adean.cisc@u.edu", contains="adean.cisc@u.edu")
expect("requesting chair can ask again", True, f"select decide_ge('{other_college}','reopen')", "chair.psy@u.edu", contains="reopened")

# A department teaching a GE course it does not house (Social Work, PSYC 160 and GAD 171)
expect("Social Work's own PSYC 160 is its own GE", True, f"select class_kind('{sw_own}')", ADMIN, contains="own")
expect("Social Work chair books it with own faculty", True, bk(sw_own, "M1 MWF") + "; " + tc(sw_own, sw_teacher), "chair.sw@u.edu")
expect("Psychology chair cannot book it", False, bk(sw_own, "M2 MWF"), "chair.psy@u.edu")
expect("Criminology PSYC 160 is held by Social Work", True,
       f"select class_kind('{sw_lends_same}')||' '||holder_dept_of('{sw_lends_same}')", ADMIN, contains="borrowed Social Work")
expect("Criminology chair books its time", True, bk(sw_lends_same, "T1 TTh"), "chair.crim@u.edu")
expect("Psychology chair does not decide a Social Work class", False, f"select decide_ge('{sw_lends_same}','approve')", "chair.psy@u.edu")
expect("CSS associate dean does not decide it", False, f"select decide_ge('{sw_lends_same}','approve')", "adean.css@u.edu")
expect("Social Work chair cannot give it to a Psychology teacher", False,
       f"select decide_ge('{sw_lends_same}','approve',null,'{psy_teacher}')", "chair.sw@u.edu")
expect("Social Work chair approves it (same college)", True, f"select decide_ge('{sw_lends_same}','approve',null,'{sw_teacher}')", "chair.sw@u.edu", contains="approved")
expect("Entrepreneurship GAD 171 goes to the CCJPS associate dean", True, bk(sw_lends_other, "T2 TTh") + f"; select can_decide('{sw_lends_other}')",
       "chair.entrep@u.edu", contains="f")
expect("CCJPS associate dean decides it", True, f"select can_decide('{sw_lends_other}')", "adean.ccjps@u.edu", contains="t")

# Lacking an instructor: Social Work hands the Criminology class to the house (Psychology)
expect("Psychology chair cannot hand it over", False, f"select hand_to_house('{sw_lends_same}')", "chair.psy@u.edu")
expect("Social Work chair hands it to Psychology", True, f"select hand_to_house('{sw_lends_same}')", "chair.sw@u.edu", contains="handed over")
expect("now held by Psychology, no teacher, no decision", True,
       f"select holder_dept_of('{sw_lends_same}')||' '||coalesce(class_teacher('{sw_lends_same}'),'none')||' '||(select count(*) from ge_decisions where class_id='{sw_lends_same}')",
       ADMIN, contains="Psychology none 0")
expect("CSS associate dean now decides (another college)", True, f"select can_decide('{sw_lends_same}')", "adean.css@u.edu", contains="t")
expect("Psychology chair picks a Psychology teacher", True, tc(sw_lends_same, psy_teacher), "chair.psy@u.edu")
expect("Social Work takes it back", True, f"select hand_to_house('{sw_lends_same}', true); select holder_dept_of('{sw_lends_same}')", "chair.sw@u.edu", contains="Social Work")
expect("hand-overs cannot be written directly", False, f"insert into ge_holders (class_id, holder_dept, holder_college) values ('{sw_lends_same}','Psychology','CSS')", "chair.sw@u.edu")

# Associate deans book their own college
expect("associate dean books own college major", True, bk(eco_major), "adean.css@u.edu")
expect("associate dean cannot book other college", False, bk(cisc_major), "adean.css@u.edu")

# GE Coordinator: GE Department courses, last
expect("GE Coordinator blocked until opened", False, bk(gedept), "ge@u.edu")
expect("chair cannot open GE", True, "update settings set ge_open=true where id=1; select ge_open from settings", "chair.psy@u.edu", contains="f")
expect("chair cannot book a GE Department course", False, bk(gedept), "chair.psy@u.edu")
expect("registrar opens GE Department scheduling", True, "update settings set ge_open=true where id=1", ADMIN)
expect("GE Coordinator books GE Department course", True, bk(gedept, "M7 MWF"), "ge@u.edu")
expect("GE Department course needs no approval", True, f"select needs_approval('{gedept}')", "ge@u.edu", contains="f")
expect("GE Coordinator cannot book department-held GE", False, bk(own_ge), "ge@u.edu")
expect("GE Coordinator cannot book majors", False, bk(psy_major, "M4 MWF"), "ge@u.edu")
expect("dean books anything", True, bk(cisc_major), "dean@u.edu")

# Admin
expect("chair cannot publish", False, "select publish_schedule()", "chair.psy@u.edu")
expect("registrar publishes", True, "select publish_schedule()", ADMIN)
expect("chair cannot add staff", False, "insert into staff (email, role) values ('x@u.edu','dean')", "chair.psy@u.edu")
expect("chair cannot raise own role", True, "update staff set role='dean' where email='chair.psy@u.edu'; select role from staff where email='chair.psy@u.edu'",
       "chair.psy@u.edu", contains="chair")
expect("registrar adds staff", True, "insert into staff (email, full_name, role) values ('new@u.edu','New','dean') on conflict do nothing", ADMIN)

print(f"\n{len(failures)} failed" if failures else "\nAll access rules behave as intended.")
sys.exit(1 if failures else 0)
