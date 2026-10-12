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
own_ge = cls(f"{BSP} and course = 'PSYC 160'")                       # Psychology may teach it
gedept = cls(f"{BSP} and course = 'PE 101'")                         # GE Department
sw_own = cls("department = 'Social Work' and course = 'PSYC 160'")   # Social Work may teach it too
crim_psyc = cls("department = 'Criminology' and course = 'PSYC 160'")
entrep_gad = cls("department = 'Entrepreneurship' and course = 'GAD 171'")
sw_teacher = one("select key from faculty where department = 'Social Work' order by key limit 1")
psy_teacher = one("select key from faculty where department = 'Psychology' order by key limit 1")
eco_teacher = one("select key from faculty where department = 'Economics' order by key limit 1")

ADMIN = "agbayanispencer@gmail.com"
psql("""insert into staff (email, full_name, role, college, department) values
  ('chair.psy@u.edu','Chair Psychology','chair','CSS','Psychology'),
  ('chair.eco@u.edu','Chair Economics','chair','CSS','Economics'),
  ('chair.sw@u.edu','Chair Social Work','chair','CCJPS','Social Work'),
  ('chair.crim@u.edu','Chair Criminology','chair','CCJPS','Criminology'),
  ('chair.entrep@u.edu','Chair Entrepreneurship','chair','CBE','Entrepreneurship'),
  ('adean.ccjps@u.edu','Assoc Dean CCJPS','associate_dean','CCJPS',null),
  ('adean.css@u.edu','Assoc Dean CSS','associate_dean','CSS',null),
  ('adean.cisc@u.edu','Assoc Dean CISC','associate_dean','CISC',null),
  ('ge@u.edu','GE Coordinator','ge_coordinator',null,null),
  ('dean@u.edu','Dean','dean',null,null) on conflict do nothing;
  update settings set ge_open=false where id=1;
  delete from bookings where class_id in (select id from classes where department in ('Psychology','Social Work','Criminology','Entrepreneurship'));
  delete from teacher_changes where class_id in (select id from classes where department in ('Psychology','Social Work','Criminology','Entrepreneurship'));
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

# Asking: Criminology cannot teach PSYC 160, so it asks
expect("Criminology must book its own GE classes first", False, bk(crim_psyc, "T1 TTh"), "chair.crim@u.edu")
expect("Criminology books its own GE classes", True, book_own_ge("Criminology") + "; select own_ge_left('Criminology')", "chair.crim@u.edu", contains="0")
expect("then books the PSYC 160 time", True, bk(crim_psyc, "T1 TTh"), "chair.crim@u.edu")
expect("cannot ask a department that does not teach it", False, f"select request_ge('{crim_psyc}','Accountancy')", "chair.crim@u.edu")
expect("cannot ask Social Work before it submits", False, f"select request_ge('{crim_psyc}','Social Work','{sw_teacher}')", "chair.crim@u.edu", contains="not submitted")
expect("Social Work books its own GE classes", True, book_own_ge("Social Work") + "; select own_ge_left('Social Work')", "chair.sw@u.edu", contains="0")
psql("insert into submissions (department, college, complete) values ('Social Work','CCJPS',true), ('Psychology','CSS',true) on conflict do nothing")
expect("cannot name an instructor of another department", False, f"select request_ge('{crim_psyc}','Social Work','{psy_teacher}')", "chair.crim@u.edu")
expect("Criminology asks a Social Work instructor", True,
       f"select request_ge('{crim_psyc}','Social Work','{sw_teacher}'); select class_teacher('{crim_psyc}')", "chair.crim@u.edu", contains=sw_teacher)
expect("asked class needs approval", True, f"select needs_approval('{crim_psyc}')", ADMIN, contains="t")
expect("Criminology cannot pick its teacher", False, tc(crim_psyc, sw_teacher), "chair.crim@u.edu")
expect("Psychology chair cannot answer for Social Work", False, f"select decide_ge('{crim_psyc}','approve')", "chair.psy@u.edu")
expect("CCJPS associate dean is not the one to answer (same college)", False, f"select decide_ge('{crim_psyc}','approve')", "adean.ccjps@u.edu")
expect("Social Work cannot give it to a Psychology teacher", False, f"select decide_ge('{crim_psyc}','approve',null,'{psy_teacher}')", "chair.sw@u.edu")
expect("Social Work chair approves with its teacher", True,
       f"select decide_ge('{crim_psyc}','approve',null,'{sw_teacher}'); select class_teacher('{crim_psyc}')||' '||approved_by from ge_decisions where class_id='{crim_psyc}'",
       "chair.sw@u.edu", contains=f"{sw_teacher} chair.sw@u.edu")
expect("Criminology changes the time", True, bk(crim_psyc, "T2 TTh"), "chair.crim@u.edu")
expect("Social Work rejects the new time", True, f"select decide_ge('{crim_psyc}','reject','No instructor free then')", "chair.sw@u.edu", contains="rejected")
expect("Psychology has its own GE classes left", True, "select own_ge_left('Psychology') > 0", ADMIN, contains="t")
psql(book_own_ge("Psychology"))
expect("Criminology asks Psychology instead", True,
       f"select request_ge('{crim_psyc}','Psychology','{psy_teacher}'); select count(*) from ge_decisions where class_id='{crim_psyc}'", "chair.crim@u.edu", contains="0")
expect("the CSS associate dean answers (another college)", True, f"select can_decide('{crim_psyc}')", "adean.css@u.edu", contains="t")
expect("the Psychology chair does not (another college)", True, f"select can_decide('{crim_psyc}')", "chair.psy@u.edu", contains="f")

# Another college: Entrepreneurship (CBE) asks Social Work (CCJPS) for GAD 171
psql(book_own_ge("Entrepreneurship"))
expect("Entrepreneurship asks Social Work", True, bk(entrep_gad, "T3 TTh") + f"; select request_ge('{entrep_gad}','Social Work','{sw_teacher}')", "chair.entrep@u.edu", contains="asked")
expect("the CCJPS associate dean answers", True, f"select can_decide('{entrep_gad}')", "adean.ccjps@u.edu", contains="t")
expect("the Social Work chair does not", True, f"select can_decide('{entrep_gad}')", "chair.sw@u.edu", contains="f")
expect("requests cannot be written directly", False, f"insert into ge_requests (class_id, department, college) values ('{entrep_gad}','Psychology','CSS')", "chair.entrep@u.edu")
expect("answers cannot be written directly", False, "update ge_decisions set approved_by='me'", "chair.sw@u.edu")

# The registrar edits the teaching lists
expect("registrar removes a department from a list", True,
       "update ge_teachers set allowed = false where course = 'GAD 171' and department = 'Social Work'; select may_teach('GAD 171','Social Work')", ADMIN, contains="f")
psql("update ge_teachers set allowed = true")

# Submitting a department schedule
expect("Psychology still has incomplete classes", True, "select dept_missing('Psychology') > 0", ADMIN, contains="t")
expect("an incomplete schedule cannot be submitted", False, "select submit_schedule('Psychology')", "chair.psy@u.edu", contains="unscheduled")
expect("another chair cannot submit Psychology", False, "select submit_schedule('Psychology')", "chair.eco@u.edu")
expect("submissions cannot be written directly", False, "insert into submissions (department, college, complete) values ('Psychology','CSS',true)", "chair.psy@u.edu")

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
