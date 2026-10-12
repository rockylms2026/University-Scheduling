"""Checks the Supabase access rules against a local Postgres loaded with supabase/setup.sql.

Run: python tests/rls_check.py  (needs a local database "sched" loaded with tests/supabase_stub.sql, then supabase/setup.sql)
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
    return psql(sql)[1].splitlines()[-1] if psql(sql)[1] else ""


# Pick real classes from the seed.
psy_major = one("select id from classes where department='Psychology' and not is_ge limit 1")
eco_major = one("select id from classes where department='Economics' and not is_ge limit 1")
cisc_major = one("select id from classes where college='CISC' and not is_ge limit 1")
ge_css = one("select id from classes where is_ge and college='CSS' and id not in (select class_id from bookings) limit 1")
ge_cisc = one("select id from classes where is_ge and college='CISC' limit 1")
psy_teacher = one("select key from faculty where department='Psychology' limit 1")
eco_teacher = one("select key from faculty where department='Economics' limit 1")
t2_dept, t2_college = one("select department||'|'||college from faculty where key='CISC-T2'").split("|")

ADMIN = "agbayanispencer@gmail.com"
psql(f"""insert into staff (email, full_name, role, college, department) values
  ('chair.psy@u.edu','Chair Psychology','chair','CSS','Psychology'),
  ('chair.t2@u.edu','Chair of CISC-T2','chair','{t2_college}','{t2_dept}'),
  ('adean.css@u.edu','Assoc Dean CSS','associate_dean','CSS',null),
  ('adean.t2@u.edu','Assoc Dean of CISC-T2','associate_dean','{t2_college}',null),
  ('ge@u.edu','GE Coordinator','ge_coordinator',null,null),
  ('dean@u.edu','Dean','dean',null,null) on conflict do nothing;
  update settings set ge_open=false where id=1""")

bk = lambda cid, pat="M3 MWF": f"insert into bookings (class_id, part, sem, pattern, room) values ('{cid}', (select 'Lec'), 1, '{pat}', 'DIW 301') on conflict (class_id, part) do update set pattern=excluded.pattern"

expect("anon cannot read", False, "set role anon; select count(*) from bookings")
expect("unknown account sees nothing", True, "select count(*) from bookings", "stranger@x.com", contains="0")
expect("unknown account cannot book", False, bk(psy_major), "stranger@x.com")
expect("staff can read all bookings", True, "select count(*) from bookings", "chair.psy@u.edu", contains="49")

expect("chair books own department class", True, bk(psy_major), "chair.psy@u.edu")
expect("chair cannot book another department", False, bk(eco_major), "chair.psy@u.edu")
expect("chair cannot book GE", False, bk(ge_css), "chair.psy@u.edu")
expect("chair assigns own faculty", True, f"insert into teacher_changes (class_id, sem, teacher) values ('{psy_major}',1,'{psy_teacher}')", "chair.psy@u.edu")
expect("chair cannot assign other department's faculty", False,
       f"update teacher_changes set teacher='{eco_teacher}' where class_id='{psy_major}'", "chair.psy@u.edu")
expect("stamp records who booked", True, f"select updated_by from bookings where class_id='{psy_major}'", "chair.psy@u.edu", contains="chair.psy@u.edu")

expect("GE coordinator blocked while GE is closed", False, bk(ge_css), "ge@u.edu")
expect("chair cannot open GE", True, "update settings set ge_open=true where id=1; select ge_open from settings", "chair.psy@u.edu", contains="f")
expect("registrar opens GE", True, "update settings set ge_open=true where id=1", ADMIN)
expect("GE coordinator books GE once open", True, bk(ge_css), "ge@u.edu")
expect("GE coordinator cannot book majors", False, bk(psy_major, "M4 MWF"), "ge@u.edu")
expect("associate dean books own college major", True, bk(eco_major), "adean.css@u.edu")
expect("associate dean cannot book other college", False, bk(cisc_major), "adean.css@u.edu")
expect("associate dean books GE in own college sections", True, bk(ge_css, "M5 MWF"), "adean.css@u.edu")
expect("associate dean cannot book GE in other colleges", False, bk(ge_cisc), "adean.css@u.edu")
expect("dean books anything", True, bk(cisc_major), "dean@u.edu")

# S1-0637: STS 180 in BSP 1B, moved to CISC-T2 in the claude.ai version.
expect("cross-college GE needs approval", True, "select needs_approval('S1-0637')", "ge@u.edu", contains="t")
expect("GE Department teacher needs none", True,
       "select needs_approval((select c.id from classes c join faculty f on f.key=c.plan_teacher where c.is_ge and f.college='GE' limit 1))", "ge@u.edu", contains="f")
expect("other chair cannot approve", False, "select decide_ge('S1-0637','approve')", "chair.psy@u.edu")
expect("GE coordinator cannot approve", False, "select decide_ge('S1-0637','approve')", "ge@u.edu")
expect("teacher's chair approves", True, "select decide_ge('S1-0637','approve')", "chair.t2@u.edu")
expect("still pending without associate dean", True, "select adean_at is null from ge_approvals where class_id='S1-0637'", "chair.t2@u.edu", contains="t")
expect("teacher's associate dean approves", True, "select decide_ge('S1-0637','approve')", "adean.t2@u.edu")
expect("both approvals recorded", True, "select chair_by||' '||adean_by from ge_approvals where class_id='S1-0637'", ADMIN, contains="chair.t2@u.edu adean.t2@u.edu")
expect("approvals cannot be written directly", False, "update ge_approvals set chair_by='me'", "chair.t2@u.edu")
psql("update bookings set pattern='T2 TTh' where class_id='S1-0637'")
expect("a new time starts approval over", True, "select decide_ge('S1-0637','approve'); select coalesce(adean_by,'none') from ge_approvals where class_id='S1-0637'", "chair.t2@u.edu", contains="none")
expect("associate dean rejects", True, "select decide_ge('S1-0637','reject','Teaching a thesis class then')", "adean.t2@u.edu")
expect("rejection recorded", True, "select rejected_by from ge_approvals where class_id='S1-0637'", ADMIN, contains="adean.t2@u.edu")

expect("chair cannot publish", False, "select publish_schedule()", "chair.psy@u.edu")
expect("registrar publishes", True, "select publish_schedule()", ADMIN)
expect("chair cannot add staff", False, "insert into staff (email, role) values ('x@u.edu','dean')", "chair.psy@u.edu")
expect("chair cannot raise own role", True, "update staff set role='dean' where email='chair.psy@u.edu'; select role from staff where email='chair.psy@u.edu'", "chair.psy@u.edu", contains="chair")
expect("registrar adds staff", True, "insert into staff (email, full_name, role) values ('new@u.edu','New','dean')", ADMIN)
expect("cannot read reference data without a role", True, "select count(*) from faculty", "stranger@x.com", contains="0")

print(f"\n{len(failures)} failed" if failures else "\nAll access rules behave as intended.")
sys.exit(1 if failures else 0)
