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
eco_major = cls("department = 'Communication' and not is_ge")
cisc_major = cls("college = 'CILS' and not is_ge")
own_ge = cls(f"{BSP} and course = 'PSYC 160'")                       # Psychology may teach it
gedept = cls(f"{BSP} and course = 'PE 101'")                         # GE Department
sw_own = cls("department = 'Social Work' and course = 'PSYC 160'")   # Social Work may teach it too
crim_psyc = cls("department = 'Criminology' and course = 'PSYC 160'")
entrep_gad = cls("department = 'Accountancy' and course = 'GAD 171'")
sw_teacher = one("select key from faculty where department = 'Social Work' order by key limit 1")
psy_teacher = one("select key from faculty where department = 'Psychology' order by key limit 1")
eco_teacher = one("select key from faculty where department = 'Communication' order by key limit 1")

ADMIN = "agbayanispencer@gmail.com"
psql("""insert into staff (email, full_name, role, college, department) values
  ('chair.psy@u.edu','Chair Psychology','chair','CSBS','Psychology'),
  ('chair.eco@u.edu','Chair Communication','chair','CSBS','Communication'),
  ('chair.sw@u.edu','Chair Social Work','chair','CSBS','Social Work'),
  ('chair.crim@u.edu','Chair Criminology','chair','CSBS','Criminology'),
  ('chair.entrep@u.edu','Chair Accountancy','chair','CBAPA','Accountancy'),
  ('adean.cbapa@u.edu','Assoc Dean CBAPA','associate_dean','CBAPA',null),
  ('adean.css@u.edu','Assoc Dean CSBS','associate_dean','CSBS',null),
  ('adean.cisc@u.edu','Assoc Dean CILS','associate_dean','CILS',null),
  ('ge@u.edu','GE Coordinator','ge_coordinator',null,null),
  ('re@u.edu','Religious Education Coordinator','re_coordinator',null,null),
  ('dean@u.edu','Dean','dean',null,null) on conflict do nothing;
  update settings set ge_open=false where id=1;
  delete from bookings where class_id in (select id from classes where department in ('Psychology','Social Work','Criminology','Accountancy'));
  delete from teacher_changes where class_id in (select id from classes where department in ('Psychology','Social Work','Criminology','Accountancy'));
  delete from bookings where class_id in (select id from classes where house_dept = 'Religious Education');
  delete from teacher_changes where class_id in (select id from classes where house_dept = 'Religious Education');
  delete from ge_requests; delete from ge_decisions; delete from submissions;""")


def bk(cid, pat="M3 MWF"):
    return (f"insert into bookings (class_id, part, sem, pattern, room) values ('{cid}', 'Lec', 1, '{pat}', 'DIW 301') "
            "on conflict (class_id, part) do update set pattern = excluded.pattern")


def tc(cid, t):
    return (f"insert into teacher_changes (class_id, sem, teacher) values ('{cid}', 1, '{t}') "
            "on conflict (class_id) do update set teacher = excluded.teacher")


def book_own_ge(dept):
    return (f"insert into bookings (class_id, part, sem, pattern) select id, 'Lec', 1, 'M1 MWF' from classes "
            f"where department = '{dept}' and class_kind(id) = 'own' on conflict do nothing")


expect("anon cannot read", False, "set role anon; select count(*) from bookings")
expect("unknown account sees nothing", True, "select count(*) from bookings", "stranger@x.com", contains="0")
expect("unknown account cannot book", False, bk(psy_major), "stranger@x.com")
expect("cannot read reference data without a role", True, "select count(*) from faculty", "stranger@x.com", contains="0")

# Teaching lists and kinds
expect("Social Work may teach PSYC 160 and GAD 171", True, "select may_teach('PSYC 160','Social Work') and may_teach('GAD 171','Social Work')", ADMIN, contains="t")
expect("kinds are right", True,
       f"select class_kind('{psy_major}')||' '||class_kind('{own_ge}')||' '||class_kind('{sw_own}')||' '||class_kind('{crim_psyc}')||' '||class_kind('{gedept}')",
       ADMIN, contains="major own own borrowed gedept")
expect("chair cannot change the teaching lists", True,
       "update ge_teachers set allowed = false where course = 'PSYC 160'; select count(*) from ge_teachers where not allowed", "chair.psy@u.edu", contains="0")

# Chairs: majors
expect("chair books own department major", True, bk(psy_major), "chair.psy@u.edu")
expect("chair cannot book another department", False, bk(eco_major), "chair.psy@u.edu")
expect("chair assigns own faculty to a major", True, tc(psy_major, psy_teacher), "chair.psy@u.edu")
expect("chair cannot assign other department faculty", False, tc(psy_major, eco_teacher), "chair.psy@u.edu")
expect("stamp records who booked", True, f"select updated_by from bookings where class_id='{psy_major}'", "chair.psy@u.edu", contains="chair.psy@u.edu")

# Own GE: a department that may teach the course, for its own sections
expect("Psychology books its own PSYC 160", True, bk(own_ge, "M2 MWF") + "; " + tc(own_ge, psy_teacher), "chair.psy@u.edu")
expect("Social Work books PSYC 160 for its own sections", True, bk(sw_own, "M1 MWF") + "; " + tc(sw_own, sw_teacher), "chair.sw@u.edu")
expect("own GE needs no approval", True, f"select needs_approval('{sw_own}')", ADMIN, contains="f")
expect("Psychology chair cannot book Social Work sections", False, bk(sw_own, "M2 MWF"), "chair.psy@u.edu")

# Borrowing: Criminology cannot teach PSYC 160, so it books it with an instructor of a submitted department
def bb(cid, d, t, pat="T1 TTh"):
    return f"select book_borrowed('{cid}', 'Lec', '{pat}', 'KAT 301', '{d}', {('null' if t is None else repr(t))})"


expect("a borrowed class cannot be booked without an instructor", False, bk(crim_psyc, "T1 TTh"), "chair.crim@u.edu")
expect("Criminology must book its own GE classes first", False, bb(crim_psyc, "Social Work", sw_teacher), "chair.crim@u.edu")
expect("Criminology books its own GE classes", True, book_own_ge("Criminology") + "; select own_ge_left('Criminology')", "chair.crim@u.edu", contains="0")
expect("cannot book from a department that does not teach it", False, bb(crim_psyc, "Accountancy", sw_teacher), "chair.crim@u.edu")
expect("cannot book from Social Work before it submits", False, bb(crim_psyc, "Social Work", sw_teacher), "chair.crim@u.edu", contains="not submitted")
expect("Social Work books its own GE classes", True, book_own_ge("Social Work") + "; select own_ge_left('Social Work')", "chair.sw@u.edu", contains="0")
psql("insert into submissions (department, college, complete) values ('Social Work','CSBS',true), ('Psychology','CSBS',true) on conflict do nothing")
expect("cannot book without naming an instructor", False, bb(crim_psyc, "Social Work", None), "chair.crim@u.edu")
expect("cannot name an instructor of another department", False, bb(crim_psyc, "Social Work", psy_teacher), "chair.crim@u.edu")
expect("Criminology books PSYC 160 with a Social Work instructor", True,
       bb(crim_psyc, "Social Work", sw_teacher) + f"; select class_teacher('{crim_psyc}')||' '||class_schedule('{crim_psyc}')", "chair.crim@u.edu", contains=f"{sw_teacher} Lec:T1 TTh")
expect("the instructor is held while it waits", True, f"select needs_approval('{crim_psyc}') and class_teacher('{crim_psyc}') is not null", ADMIN, contains="t")
expect("Criminology cannot change its teacher directly", False, tc(crim_psyc, sw_teacher), "chair.crim@u.edu")
expect("Psychology chair cannot answer for Social Work", False, f"select decide_ge('{crim_psyc}','approve')", "chair.psy@u.edu")
expect("CSBS associate dean is not the one to answer (same college)", False, f"select decide_ge('{crim_psyc}','approve')", "adean.css@u.edu")
expect("Social Work cannot swap in a Psychology teacher", False, f"select decide_ge('{crim_psyc}','approve',null,'{psy_teacher}')", "chair.sw@u.edu")
expect("Social Work chair approves", True,
       f"select decide_ge('{crim_psyc}','approve'); select class_teacher('{crim_psyc}')||' '||approved_by from ge_decisions where class_id='{crim_psyc}'",
       "chair.sw@u.edu", contains=f"{sw_teacher} chair.sw@u.edu")
expect("Criminology books a new time", True, bb(crim_psyc, "Social Work", sw_teacher, "T2 TTh"), "chair.crim@u.edu")
expect("Social Work rejects it with a reason", True, f"select decide_ge('{crim_psyc}','reject','Thesis defense then')", "chair.sw@u.edu", contains="rejected")
expect("the rejection released the booking and the instructor", True,
       f"select (select count(*) from bookings where class_id='{crim_psyc}')||' '||coalesce(class_teacher('{crim_psyc}'),'none')||' '||(select note from ge_decisions where class_id='{crim_psyc}')",
       ADMIN, contains="0 none Thesis defense then")
psql(book_own_ge("Psychology"))
expect("Criminology books a Psychology instructor instead", True, bb(crim_psyc, "Psychology", psy_teacher), "chair.crim@u.edu", contains="booked")
expect("the Psychology chair answers (same college)", True, f"select can_decide('{crim_psyc}')", "chair.psy@u.edu", contains="t")
expect("the CSBS associate dean does not (same college)", True, f"select can_decide('{crim_psyc}')", "adean.css@u.edu", contains="f")
expect("Criminology releases it", True, f"select unbook_borrowed('{crim_psyc}'); select count(*) from bookings where class_id='{crim_psyc}'", "chair.crim@u.edu", contains="0")
expect("Criminology asks for an instructor without booking", True,
       f"select ask_instructor('{crim_psyc}','Psychology','Nobody free at our times'); select department from instructor_requests where class_id='{crim_psyc}'", "chair.crim@u.edu", contains="Psychology")
expect("the Psychology chair closes it", True, f"select close_instructor_request('{crim_psyc}')", "chair.psy@u.edu", contains="closed")
expect("another chair cannot close requests", False, f"select ask_instructor('{crim_psyc}','Psychology'); select close_instructor_request('{crim_psyc}')", "chair.eco@u.edu")

# Another college: Accountancy (CBAPA) books a Social Work (CSBS) instructor for GAD 171
psql(book_own_ge("Accountancy"))
expect("Accountancy books a Social Work instructor", True, bb(entrep_gad, "Social Work", sw_teacher, "T3 TTh"), "chair.entrep@u.edu", contains="booked")
expect("the CSBS associate dean answers", True, f"select can_decide('{entrep_gad}')", "adean.css@u.edu", contains="t")
expect("the Social Work chair does not", True, f"select can_decide('{entrep_gad}')", "chair.sw@u.edu", contains="f")
expect("requests cannot be written directly", False, f"insert into ge_requests (class_id, department, college) values ('{entrep_gad}','Psychology','CSBS')", "chair.entrep@u.edu")
expect("answers cannot be written directly", False, "update ge_decisions set approved_by='me'", "chair.sw@u.edu")

# The registrar edits the teaching lists
expect("registrar removes a department from a list", True,
       "update ge_teachers set allowed = false where course = 'GAD 171' and department = 'Social Work'; select may_teach('GAD 171','Social Work')", ADMIN, contains="f")
psql("update ge_teachers set allowed = true")

# Submitting a department schedule
expect("Psychology still has incomplete classes", True, "select dept_missing('Psychology') > 0", ADMIN, contains="t")
expect("an incomplete schedule cannot be submitted", False, "select submit_schedule('Psychology')", "chair.psy@u.edu", contains="unscheduled")
expect("another chair cannot submit Psychology", False, "select submit_schedule('Psychology')", "chair.eco@u.edu")
expect("submissions cannot be written directly", False, "insert into submissions (department, college, complete) values ('Psychology','CSBS',true)", "chair.psy@u.edu")

# Associate deans book their own college
expect("associate dean books own college major", True, bk(eco_major), "adean.css@u.edu")
expect("associate dean cannot book other college", False, bk(cisc_major), "adean.css@u.edu")

# GE Coordinator: GE Department courses, last
# PHIL 190 is a GE Department course that Political Science may also teach to its own sections.
pols_phil = cls("course = 'PHIL 190' and department = 'Political Science'")
psy_phil = cls("course = 'PHIL 190' and department = 'Psychology'")
expect("PHIL 190 of AB Political Science is its own class", True, f"select class_kind('{pols_phil}')", ADMIN, contains="own")
expect("PHIL 190 of BS Psychology stays with the GE Department", True, f"select class_kind('{psy_phil}')", ADMIN, contains="gedept")
psql("insert into staff (email, full_name, role, college, department) values ('chair.pols@u.edu','Chair Political Science','chair','CSBS','Political Science') on conflict do nothing")
expect("Political Science chair books its PHIL 190 before GE opens", True, bk(pols_phil, "M5 MWF"), "chair.pols@u.edu")
expect("GE Coordinator cannot book the Political Science PHIL 190", False, bk(pols_phil, "M6 MWF"), "ge@u.edu")
expect("Political Science chair cannot book PHIL 190 of BS Psychology", False, bk(psy_phil, "M5 MWF"), "chair.pols@u.edu")
psql(f"delete from bookings where class_id = '{pols_phil}'")
rel = cls("course = 'REL 103A' and section = 'BSP 1A'")
expect("REL 103A is a Religious Education class", True, f"select class_kind('{rel}')", ADMIN, contains="reldept")
expect("Religious Education Coordinator blocked until opened", False, bk(rel), "re@u.edu")
expect("GE Coordinator blocked until opened", False, bk(gedept), "ge@u.edu")
expect("chair cannot open GE", True, "update settings set ge_open=true where id=1; select ge_open from settings", "chair.psy@u.edu", contains="f")
expect("chair cannot book a GE Department course", False, bk(gedept), "chair.psy@u.edu")
expect("registrar opens GE Department scheduling", True, "update settings set ge_open=true where id=1", ADMIN)
expect("GE Coordinator books GE Department course", True, bk(gedept, "M7 MWF"), "ge@u.edu")
expect("GE Department course needs no approval", True, f"select needs_approval('{gedept}')", "ge@u.edu", contains="f")
expect("GE Coordinator cannot book department-held GE", False, bk(own_ge), "ge@u.edu")
expect("GE Coordinator cannot book majors", False, bk(psy_major, "M4 MWF"), "ge@u.edu")
expect("Religious Education Coordinator books a religion class", True, bk(rel, "M8 MWF"), "re@u.edu")
expect("religion class needs no approval", True, f"select needs_approval('{rel}')", "re@u.edu", contains="f")
expect("Religious Education Coordinator picks a religion teacher", True, tc(rel, "RE-RE2"), "re@u.edu")
expect("Religious Education Coordinator cannot pick another department's teacher", False, tc(rel, "CSBS-P1"), "re@u.edu")
expect("Religious Education Coordinator cannot book GE Department courses", False, bk(gedept, "M2 MWF"), "re@u.edu")
expect("Religious Education Coordinator cannot book majors", False, bk(psy_major, "M5 MWF"), "re@u.edu")
expect("GE Coordinator cannot book religion classes", False, bk(rel, "M6 MWF"), "ge@u.edu")
expect("chair cannot book religion classes", False, bk(rel, "M6 MWF"), "chair.psy@u.edu")
expect("dean books anything", True, bk(cisc_major), "dean@u.edu")

# Admin
expect("chair cannot publish", False, "select publish_schedule()", "chair.psy@u.edu")
expect("registrar publishes", True, "select publish_schedule()", ADMIN)
expect("chair cannot add staff", False, "insert into staff (email, role) values ('x@u.edu','dean')", "chair.psy@u.edu")
expect("chair cannot raise own role", True, "update staff set role='dean' where email='chair.psy@u.edu'; select role from staff where email='chair.psy@u.edu'",
       "chair.psy@u.edu", contains="chair")
# Associate Deans teach too: their department chair may assign them, and so may they themselves.
expect("Psychology chair assigns the CSBS Associate Dean", True, tc(psy_major, "CSBS-AD"), "chair.psy@u.edu")
expect("CSBS Associate Dean assigns their own class", True, tc(psy_major, "CSBS-AD"), "adean.css@u.edu")
expect("Communication chair cannot assign the CSBS Associate Dean", False, tc(eco_major, "CSBS-AD"), "chair.eco@u.edu")
psql(f"delete from teacher_changes where class_id = '{psy_major}'")

# Specializations: typed by the Registrar or the Dean only, and nothing else of a faculty row.
fac = one("select key from faculty where department = 'Psychology' order by key limit 1")
expect("registrar types a specialization", True, f"update faculty set specialization = 'Clinical Psychology' where key = '{fac}' returning key", ADMIN, contains=fac)
expect("chair cannot type a specialization", True, f"update faculty set specialization = 'X' where key = '{fac}' returning key", "chair.psy@u.edu")
expect("the chair's change did not apply", True, f"select specialization from faculty where key = '{fac}'", contains="Clinical Psychology")
expect("nobody renames faculty from the page", False, f"update faculty set name = 'X' where key = '{fac}'", ADMIN)
expect("registrar adds staff", True, "insert into staff (email, full_name, role) values ('new@u.edu','New','dean') on conflict do nothing", ADMIN)

print(f"\n{len(failures)} failed" if failures else "\nAll access rules behave as intended.")
sys.exit(1 if failures else 0)
