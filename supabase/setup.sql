-- Class Scheduling: run this once in the Supabase SQL Editor (it is safe to run again).
-- Class Scheduling: database schema, roles, and access rules for Supabase.
--
-- Who can do what (enforced here, in the database, not only in the page):
--   registrar, dean    everything, manage staff and GE teaching lists, publish, open GE Department scheduling
--   chair              major classes of their own department, with their own faculty.
--                      GE classes of their own sections that their department may teach, with their own faculty.
--                      Other GE classes of their own sections: they book the time together with a free instructor
--                      of a department that may teach the course and has submitted (book_borrowed), and the
--                      lending department approves, swaps the instructor, or rejects (which removes the booking).
--   associate_dean     the classes of the sections of their own college (as a chair would),
--                      and approves requests to departments of their college from other colleges
--   ge_coordinator     courses of the GE Department, once the Registrar or Dean opens them, with no approval
--   re_coordinator     religion courses of the Religious Education Department, opened together with the GE
--                      Department, with its own faculty and no approval
-- Everyone with a role can read the whole timetable, because conflict checks need it.
--
-- GE teaching lists (ge_teachers): the departments that may teach each GE course. A department
-- teaches a GE course for its own sections when it is on the list for that course. Otherwise the
-- section asks one of the departments on the list (a request). The asked department answers
-- through its chair when both are in the same college, or through the associate dean of its college
-- otherwise, and picks the teacher from its own faculty. A department may ask, or answer requests,
-- only after every GE class of its own sections that it may teach is booked.

-- ---------- reference data (loaded by seed.sql, read-only to users) ----------
create table if not exists public.faculty (
  key        text primary key,
  name       text not null,
  college    text not null,          -- CSS, CICS, CBE, COE, CCJPS, GE, RE
  department text not null,
  rank       text,
  designation text,
  max_lu     int not null default 24
);
-- What each instructor specializes in, typed on the Faculty Profiles page by the Registrar or the Dean.
alter table public.faculty add column if not exists specialization text;
-- Highest degree and licenses, from the loading plans.
alter table public.faculty add column if not exists degree text;

create table if not exists public.classes (
  id           text primary key,     -- e.g. S1-PSYC101-BSP1A (semester, course, section)
  sem          int  not null,
  course       text not null,
  section      text not null,
  program      text not null,
  college      text not null,        -- college of the section
  department   text not null,        -- department of the section program
  is_ge        boolean not null,
  plan_teacher text references public.faculty(key),
  house_dept   text,                 -- GE only: the department in housed_by
  house_college text
);
alter table public.classes add column if not exists house_dept text;
alter table public.classes add column if not exists house_college text;

-- The departments that may teach each GE course. allowed false keeps a removal when setup runs again.
create table if not exists public.ge_teachers (
  course     text not null,
  department text not null,
  college    text not null,
  allowed    boolean not null default true,
  primary key (course, department)
);

-- ---------- people ----------
create table if not exists public.staff (
  email      text primary key check (email = lower(email)),
  full_name  text not null default '',
  role       text not null,
  college    text,                   -- associate deans and chairs
  department text,                   -- chairs
  updated_at timestamptz not null default now(),
  check (role <> 'associate_dean' or college is not null),
  check (role <> 'chair' or (college is not null and department is not null))
);
alter table public.staff drop constraint if exists staff_role_check;
alter table public.staff add constraint staff_role_check
  check (role in ('registrar', 'dean', 'associate_dean', 'chair', 'ge_coordinator', 're_coordinator'));

-- ---------- the schedule ----------
create table if not exists public.bookings (
  class_id   text not null references public.classes(id) on delete cascade,
  part       text not null,          -- Lec, Lab, PE, NSTP, Supervision
  sem        int  not null,
  pattern    text not null,          -- a time option label, e.g. "M1 MWF", "LC Wed"
  room       text,
  updated_by text default (auth.jwt() ->> 'email'),
  updated_at timestamptz not null default now(),
  primary key (class_id, part)
);

-- A teacher different from the loading plan (teacher null = no teacher yet).
create table if not exists public.teacher_changes (
  class_id   text primary key references public.classes(id) on delete cascade,
  sem        int  not null,
  teacher    text references public.faculty(key),
  updated_by text default (auth.jwt() ->> 'email'),
  updated_at timestamptz not null default now()
);

-- Earlier designs, replaced by ge_requests.
drop table if exists public.ge_approvals cascade;
drop table if exists public.ge_holders cascade;
drop function if exists public.hand_to_house(text, boolean);
drop function if exists public.holder_dept_of(text);
drop function if exists public.holder_college_of(text);
drop function if exists public.decide_ge(text, text, text);
drop function if exists public.needs_adean(text);
alter table public.classes drop column if exists holder_dept;
alter table public.classes drop column if exists holder_college;

-- The department a section asked to teach one of its GE classes.
create table if not exists public.ge_requests (
  class_id     text primary key references public.classes(id) on delete cascade,
  department   text not null,
  college      text not null,
  requested_by text,
  requested_at timestamptz not null default now()
);

-- The answer of the asked department, for one department, schedule, and teacher.
create table if not exists public.ge_decisions (
  class_id    text primary key references public.classes(id) on delete cascade,
  schedule    text not null default '',  -- the bookings decided on, e.g. "Lec:M1 MWF"
  teacher     text references public.faculty(key),
  approved_by text,
  approved_at timestamptz,
  rejected_by text,
  rejected_at timestamptz,
  note        text
);
alter table public.ge_decisions add column if not exists department text;

-- A department telling everyone that it has finished scheduling its sections.
create table if not exists public.submissions (
  department   text primary key,
  college      text not null,
  submitted_by text,
  submitted_at timestamptz not null default now(),
  complete     boolean not null,
  missing      int not null default 0,      -- classes still incomplete when submitted
  missing_list jsonb not null default '[]',  -- what the page listed, for others to see
  reason       text                          -- why it was submitted incomplete
);

create table if not exists public.settings (
  id             int primary key default 1 check (id = 1),
  ge_open        boolean not null default false,   -- departments schedule first, then the GE Department
  published_at   timestamptz,
  published_by   text,
  updated_at     timestamptz not null default now()
);
insert into public.settings (id) values (1) on conflict do nothing;

-- ---------- helpers ----------
create or replace function public.my_staff() returns public.staff
language sql stable security definer set search_path = public as $$
  select * from public.staff where email = lower(coalesce(auth.jwt() ->> 'email', ''))
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((public.my_staff()).role in ('registrar', 'dean'), false)
$$;

create or replace function public.has_role() returns boolean
language sql stable security definer set search_path = public as $$
  select (public.my_staff()).email is not null
$$;

create or replace function public.class_teacher(cid text) returns text
language sql stable security definer set search_path = public as $$
  select case when tc.class_id is not null then tc.teacher else c.plan_teacher end
  from public.classes c left join public.teacher_changes tc on tc.class_id = c.id
  where c.id = cid
$$;

create or replace function public.class_schedule(cid text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(string_agg(part || ':' || pattern, ' ' order by part), '') from public.bookings where class_id = cid
$$;

-- May department d teach GE course code?
create or replace function public.may_teach(code text, d text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.ge_teachers g where g.course = code and g.department = d and g.allowed)
$$;

-- What kind of class: major, gedept (a GE Department course), own (a GE course the department of the
-- section may teach), or borrowed (a GE course the section must ask another department for).
create or replace function public.class_kind(cid text) returns text
language sql stable security definer set search_path = public as $$
  select case when not c.is_ge then 'major'
              when c.house_dept = 'Religious Education' then 'reldept'
              when c.house_dept is null or c.house_dept = 'General Education' then 'gedept'
              when public.may_teach(c.course, c.department) then 'own'
              else 'borrowed' end
  from public.classes c where c.id = cid
$$;

-- How many GE classes of the sections of department d, that d may teach, are not booked yet?
create or replace function public.own_ge_left(d text) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.classes c
  where c.department = d and c.is_ge and c.house_dept is distinct from 'General Education'
    and c.house_dept is distinct from 'Religious Education'
    and public.may_teach(c.course, d)
    and not exists (select 1 from public.bookings b where b.class_id = c.id)
$$;

-- The department asked to teach a class, and its college.
create or replace function public.request_dept(cid text) returns text
language sql stable security definer set search_path = public as $$
  select department from public.ge_requests where class_id = cid
$$;
create or replace function public.request_college(cid text) returns text
language sql stable security definer set search_path = public as $$
  select college from public.ge_requests where class_id = cid
$$;

-- May the signed-in person book the time and room of this class?
create or replace function public.can_edit_class(cid text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  me public.staff := public.my_staff();
  c  public.classes;
  kind text := public.class_kind(cid);
  ge_is_open boolean;
  mine boolean;
begin
  if me.email is null or kind is null then return false; end if;
  if me.role in ('registrar', 'dean') then return true; end if;
  select * into c from public.classes where id = cid;
  if kind = 'gedept' then
    select ge_open into ge_is_open from public.settings where id = 1;
    return me.role = 'ge_coordinator' and coalesce(ge_is_open, false);
  end if;
  if kind = 'reldept' then
    select ge_open into ge_is_open from public.settings where id = 1;
    return me.role = 're_coordinator' and coalesce(ge_is_open, false);
  end if;
  if kind = 'borrowed' then return false; end if;      -- booked only with an instructor, through book_borrowed()
  return (me.role = 'associate_dean' and c.college = me.college) or (me.role = 'chair' and c.department = me.department);
end $$;

-- May the signed-in person book (or release) this borrowed GE class for its section? The section
-- department must have booked every GE class it teaches for its own sections first.
create or replace function public.can_request(cid text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  me public.staff := public.my_staff();
  c  public.classes;
begin
  if me.email is null or public.class_kind(cid) is distinct from 'borrowed' then return false; end if;
  if me.role in ('registrar', 'dean') then return true; end if;
  select * into c from public.classes where id = cid;
  return ((me.role = 'associate_dean' and c.college = me.college) or (me.role = 'chair' and c.department = me.department))
     and public.own_ge_left(c.department) = 0;
end $$;

-- May the signed-in person answer the request for this class (approve, reject, pick the teacher)?
create or replace function public.can_decide(cid text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  me public.staff := public.my_staff();
  c  public.classes;
  d  text := public.request_dept(cid);
  dc text := public.request_college(cid);
begin
  if me.email is null or d is null or public.class_kind(cid) <> 'borrowed' then return false; end if;
  if me.role in ('registrar', 'dean') then return true; end if;
  if public.own_ge_left(d) > 0 then return false; end if;
  select * into c from public.classes where id = cid;
  if dc = c.college then return me.role = 'chair' and me.department = d; end if;
  return me.role = 'associate_dean' and me.college = dc;
end $$;

-- May the signed-in person give this class to teacher t (t null means no teacher yet)?
-- A borrowed class gets its teacher from the asked department.
create or replace function public.can_assign(cid text, t text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  me public.staff := public.my_staff();
  c  public.classes;
  kind text := public.class_kind(cid);
  f  public.faculty;
begin
  if me.email is null or kind is null then return false; end if;
  if me.role in ('registrar', 'dean') then return true; end if;
  select * into f from public.faculty where key = t;
  if kind = 'borrowed' then
    if t is not null and f.department is distinct from public.request_dept(cid) then return false; end if;
    return public.can_decide(cid);
  end if;
  if not public.can_edit_class(cid) then return false; end if;
  if t is null then return true; end if;
  if me.role = 're_coordinator' then return f.department = 'Religious Education'; end if;
  if me.role <> 'chair' then return true; end if;
  return f.department = me.department;
end $$;

-- Does this class wait for an answer? Only borrowed GE classes do.
create or replace function public.needs_approval(cid text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.class_kind(cid) = 'borrowed', false)
$$;

-- Book a borrowed GE class: its time and room together with instructor t of department d, which may
-- teach the course and has submitted its schedule. The booking holds the instructor at once and
-- waits for the lending department to approve. Any earlier answer is cleared.
drop function if exists public.request_ge(text, text);
drop function if exists public.request_ge(text, text, text);
create or replace function public.book_borrowed(cid text, meeting text, slot text, place text, d text, t text) returns text
language plpgsql volatile security definer set search_path = public as $$
declare
  c  public.classes;
  dc text;
begin
  if (public.my_staff()).email is null then raise exception 'Your account has no role yet'; end if;
  if not public.can_request(cid) then
    raise exception 'Book every GE class your department teaches for its own sections first, or this class is not yours';
  end if;
  select * into c from public.classes where id = cid;
  if not public.may_teach(c.course, d) then raise exception 'The % department does not teach %', d, c.course; end if;
  if not exists (select 1 from public.submissions s where s.department = d) then
    raise exception 'The % department has not submitted its schedule yet', d;
  end if;
  if t is null or not exists (select 1 from public.faculty f where f.key = t and f.department = d) then
    raise exception 'Choose an instructor of the % department', d;
  end if;
  select college into dc from public.ge_teachers where course = c.course and department = d;
  insert into public.bookings (class_id, part, sem, pattern, room) values (cid, meeting, c.sem, slot, place)
    on conflict (class_id, part) do update set pattern = excluded.pattern, room = excluded.room;
  insert into public.ge_requests (class_id, department, college, requested_by) values (cid, d, dc, (public.my_staff()).email)
    on conflict (class_id) do update set department = excluded.department, college = excluded.college,
      requested_by = excluded.requested_by, requested_at = now();
  delete from public.ge_decisions where class_id = cid;
  insert into public.teacher_changes (class_id, sem, teacher) values (cid, c.sem, t)
    on conflict (class_id) do update set teacher = excluded.teacher;
  delete from public.instructor_requests where class_id = cid;
  return 'booked';
end $$;

-- Release a borrowed GE class: its booking, request, answer, and instructor.
create or replace function public.unbook_borrowed(cid text) returns text
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.can_request(cid) then raise exception 'This class is not yours to release'; end if;
  delete from public.bookings where class_id = cid;
  delete from public.ge_requests where class_id = cid;
  delete from public.ge_decisions where class_id = cid;
  delete from public.teacher_changes where class_id = cid;
  return 'released';
end $$;

-- When no instructor is available: ask department d (and the Registrar) for one, without booking.
create table if not exists public.instructor_requests (
  class_id     text primary key references public.classes(id) on delete cascade,
  department   text not null,
  college      text not null,
  note         text,
  requested_by text,
  requested_at timestamptz not null default now()
);
create or replace function public.ask_instructor(cid text, d text, note text default null) returns text
language plpgsql volatile security definer set search_path = public as $$
declare
  c  public.classes;
  dc text;
begin
  if not public.can_request(cid) then raise exception 'This class is not yours to ask for'; end if;
  select * into c from public.classes where id = cid;
  if not public.may_teach(c.course, d) then raise exception 'The % department does not teach %', d, c.course; end if;
  select college into dc from public.ge_teachers where course = c.course and department = d;
  insert into public.instructor_requests (class_id, department, college, note, requested_by)
    values (cid, d, dc, ask_instructor.note, (public.my_staff()).email)
    on conflict (class_id) do update set department = excluded.department, college = excluded.college,
      note = excluded.note, requested_by = excluded.requested_by, requested_at = now();
  return 'asked';
end $$;
-- Close an instructor request: the asking section, the asked department, or the Registrar.
create or replace function public.close_instructor_request(cid text) returns text
language plpgsql volatile security definer set search_path = public as $$
declare
  me public.staff := public.my_staff();
  r  public.instructor_requests;
begin
  select * into r from public.instructor_requests where class_id = cid;
  if not found then return 'none'; end if;
  if not (public.is_admin() or public.can_request(cid) or (me.role = 'chair' and me.department = r.department)
          or (me.role = 'associate_dean' and me.college = r.college)) then
    raise exception 'Not allowed';
  end if;
  delete from public.instructor_requests where class_id = cid;
  return 'closed';
end $$;

-- Answer a request: approve (naming the teacher), reject (with a reason), or reopen (ask again).
create or replace function public.decide_ge(cid text, decision text, note text default null, teacher text default null)
returns text
language plpgsql volatile security definer set search_path = public as $$
declare
  me public.staff := public.my_staff();
  c  public.classes;
  d  text := public.request_dept(cid);
  sched text := public.class_schedule(cid);
  t text;
begin
  if me.email is null then raise exception 'Your account has no role yet'; end if;
  if not public.needs_approval(cid) then raise exception 'This class does not need approval'; end if;
  if d is null then raise exception 'No department has been asked yet'; end if;
  select * into c from public.classes where id = cid;
  if decision = 'reopen' then
    if not (public.can_request(cid) or public.can_decide(cid)) then raise exception 'Not allowed'; end if;
    delete from public.ge_decisions where class_id = cid;
    return 'reopened';
  end if;
  if not public.can_decide(cid) then
    if public.own_ge_left(d) > 0 then raise exception 'The % department must book its own GE classes first', d; end if;
    if public.request_college(cid) = c.college then raise exception 'Only the % chair can answer this', d; end if;
    raise exception 'Only the % associate dean can answer this', public.request_college(cid);
  end if;
  if sched = '' then raise exception 'The class has no booked time yet'; end if;
  if decision = 'approve' then
    if decide_ge.teacher is not null then
      if not exists (select 1 from public.faculty f where f.key = decide_ge.teacher and f.department = d) and not public.is_admin() then
        raise exception 'Choose a teacher from the % department', d;
      end if;
      if decide_ge.teacher is distinct from c.plan_teacher then
        insert into public.teacher_changes (class_id, sem, teacher) values (cid, c.sem, decide_ge.teacher)
          on conflict (class_id) do update set teacher = excluded.teacher;
      else
        delete from public.teacher_changes where class_id = cid;
      end if;
    end if;
    t := public.class_teacher(cid);
    if t is null then raise exception 'Choose the teacher before approving'; end if;
    insert into public.ge_decisions (class_id, department, schedule, teacher, approved_by, approved_at, note)
      values (cid, d, sched, t, me.email, now(), decide_ge.note)
      on conflict (class_id) do update set department = excluded.department, schedule = excluded.schedule, teacher = excluded.teacher,
        approved_by = excluded.approved_by, approved_at = excluded.approved_at,
        rejected_by = null, rejected_at = null, note = excluded.note;
    return 'approved';
  elsif decision = 'reject' then
    insert into public.ge_decisions (class_id, department, schedule, teacher, rejected_by, rejected_at, note)
      values (cid, d, sched, public.class_teacher(cid), me.email, now(), decide_ge.note)
      on conflict (class_id) do update set department = excluded.department, schedule = excluded.schedule, teacher = excluded.teacher,
        rejected_by = excluded.rejected_by, rejected_at = excluded.rejected_at,
        approved_by = null, approved_at = null, note = excluded.note;
    -- A rejection releases the booking and the held instructor. The answer stays, so the section sees why.
    delete from public.bookings where class_id = cid;
    delete from public.ge_requests where class_id = cid;
    delete from public.teacher_changes where class_id = cid;
    return 'rejected';
  end if;
  raise exception 'Unknown decision %', decision;
end $$;

-- The part of department d that it does itself, still incomplete: its major classes and the GE classes
-- it teaches, with no time or no teacher. Borrowed GE classes are booked after the lending departments
-- submit, so they do not count, and neither do GE Department courses.
create or replace function public.dept_missing(d text) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.classes c
  where c.department = d and public.class_kind(c.id) in ('major', 'own')
    and (not exists (select 1 from public.bookings b where b.class_id = c.id) or public.class_teacher(c.id) is null)
$$;

-- Submit the schedule of department d. Every class must be complete first.
create or replace function public.submit_schedule(d text, reason text default null, missing_list jsonb default '[]')
returns text
language plpgsql volatile security definer set search_path = public as $$
declare
  me public.staff := public.my_staff();
  dc text;
  left_n int := public.dept_missing(d);
  listed int := coalesce(jsonb_array_length(missing_list), 0);
begin
  if me.email is null then raise exception 'Your account has no role yet'; end if;
  select distinct college into dc from public.classes where department = d;
  if dc is null then raise exception 'Unknown department %', d; end if;
  if not (public.is_admin() or (me.role = 'chair' and me.department = d) or (me.role = 'associate_dean' and me.college = dc)) then
    raise exception 'Only the % chair can submit this schedule', d;
  end if;
  if left_n > 0 or listed > 0 then
    raise exception 'You have % unscheduled or incomplete classes. Finish them before submitting', greatest(left_n, listed);
  end if;
  insert into public.submissions (department, college, submitted_by, submitted_at, complete, missing, missing_list, reason)
    values (d, dc, me.email, now(), left_n = 0 and listed = 0, greatest(left_n, listed), coalesce(missing_list, '[]'),
            nullif(btrim(submit_schedule.reason), ''))
    on conflict (department) do update set college = excluded.college, submitted_by = excluded.submitted_by,
      submitted_at = excluded.submitted_at, complete = excluded.complete, missing = excluded.missing,
      missing_list = excluded.missing_list, reason = excluded.reason;
  return case when left_n = 0 and listed = 0 then 'complete' else 'incomplete' end;
end $$;

-- Publish the schedule (registrar and dean only).
create or replace function public.publish_schedule() returns timestamptz
language plpgsql volatile security definer set search_path = public as $$
declare stamp timestamptz := now();
begin
  if not public.is_admin() then raise exception 'Only the Dean or the Registrar can publish'; end if;
  update public.settings set published_at = stamp, published_by = (public.my_staff()).email, updated_at = stamp where id = 1;
  return stamp;
end $$;

-- Keep updated_by / updated_at honest.
create or replace function public.stamp_row() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  if tg_table_name in ('bookings', 'teacher_changes') then new.updated_by := lower(auth.jwt() ->> 'email'); end if;
  return new;
end $$;
drop trigger if exists stamp_bookings on public.bookings;
create trigger stamp_bookings before insert or update on public.bookings for each row execute function public.stamp_row();
drop trigger if exists stamp_teacher_changes on public.teacher_changes;
create trigger stamp_teacher_changes before insert or update on public.teacher_changes for each row execute function public.stamp_row();

-- ---------- row level security ----------
alter table public.faculty         enable row level security;
alter table public.classes         enable row level security;
alter table public.ge_teachers     enable row level security;
alter table public.staff           enable row level security;
alter table public.bookings        enable row level security;
alter table public.teacher_changes enable row level security;
alter table public.ge_requests     enable row level security;
alter table public.ge_decisions    enable row level security;
alter table public.settings        enable row level security;
alter table public.submissions     enable row level security;
alter table public.instructor_requests enable row level security;

drop policy if exists read_faculty on public.faculty;
create policy read_faculty on public.faculty for select to authenticated using (public.has_role());
drop policy if exists edit_faculty on public.faculty;
create policy edit_faculty on public.faculty for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists read_classes on public.classes;
create policy read_classes on public.classes for select to authenticated using (public.has_role());

drop policy if exists read_ge_teachers on public.ge_teachers;
create policy read_ge_teachers on public.ge_teachers for select to authenticated using (public.has_role());
drop policy if exists admin_ge_teachers on public.ge_teachers;
create policy admin_ge_teachers on public.ge_teachers for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists read_staff on public.staff;
create policy read_staff on public.staff for select to authenticated
  using (public.is_admin() or email = lower(auth.jwt() ->> 'email') or public.has_role());
drop policy if exists admin_staff on public.staff;
create policy admin_staff on public.staff for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists read_bookings on public.bookings;
create policy read_bookings on public.bookings for select to authenticated using (public.has_role());
drop policy if exists add_bookings on public.bookings;
create policy add_bookings on public.bookings for insert to authenticated with check (public.can_edit_class(class_id));
drop policy if exists change_bookings on public.bookings;
create policy change_bookings on public.bookings for update to authenticated
  using (public.can_edit_class(class_id)) with check (public.can_edit_class(class_id));
drop policy if exists remove_bookings on public.bookings;
create policy remove_bookings on public.bookings for delete to authenticated using (public.can_edit_class(class_id));

drop policy if exists read_teacher_changes on public.teacher_changes;
create policy read_teacher_changes on public.teacher_changes for select to authenticated using (public.has_role());
drop policy if exists add_teacher_changes on public.teacher_changes;
create policy add_teacher_changes on public.teacher_changes for insert to authenticated with check (public.can_assign(class_id, teacher));
drop policy if exists change_teacher_changes on public.teacher_changes;
create policy change_teacher_changes on public.teacher_changes for update to authenticated
  using (public.can_assign(class_id, null)) with check (public.can_assign(class_id, teacher));
drop policy if exists remove_teacher_changes on public.teacher_changes;
create policy remove_teacher_changes on public.teacher_changes for delete to authenticated using (public.can_assign(class_id, null));

-- Requests and answers are written only through request_ge() and decide_ge().
drop policy if exists read_ge_requests on public.ge_requests;
create policy read_ge_requests on public.ge_requests for select to authenticated using (public.has_role());
drop policy if exists read_ge_decisions on public.ge_decisions;
create policy read_ge_decisions on public.ge_decisions for select to authenticated using (public.has_role());

-- Instructor requests are written only through ask_instructor() and close_instructor_request().
drop policy if exists read_instructor_requests on public.instructor_requests;
create policy read_instructor_requests on public.instructor_requests for select to authenticated using (public.has_role());

-- Submissions are written only through submit_schedule().
drop policy if exists read_submissions on public.submissions;
create policy read_submissions on public.submissions for select to authenticated using (public.has_role());

drop policy if exists read_settings on public.settings;
create policy read_settings on public.settings for select to authenticated using (public.has_role());
drop policy if exists admin_settings on public.settings;
create policy admin_settings on public.settings for update to authenticated using (public.is_admin()) with check (public.is_admin());

grant usage on schema public to authenticated;
revoke update on public.faculty from authenticated;
grant update (specialization) on public.faculty to authenticated;
grant select on public.faculty, public.classes, public.ge_requests, public.ge_decisions, public.submissions, public.instructor_requests to authenticated;
grant select, insert, update, delete on public.staff, public.bookings, public.teacher_changes, public.ge_teachers to authenticated;
grant select, update on public.settings to authenticated;
-- Every helper the access rules call must be runnable by signed-in users (some projects do not grant this by default).
grant execute on function public.my_staff(), public.is_admin(), public.has_role(), public.class_teacher(text),
  public.class_schedule(text), public.may_teach(text, text), public.class_kind(text), public.own_ge_left(text),
  public.request_dept(text), public.request_college(text), public.can_edit_class(text), public.can_decide(text),
  public.can_assign(text, text), public.needs_approval(text), public.can_request(text),
  public.book_borrowed(text, text, text, text, text, text), public.unbook_borrowed(text),
  public.ask_instructor(text, text, text), public.close_instructor_request(text),
  public.decide_ge(text, text, text, text), public.dept_missing(text), public.submit_schedule(text, text, jsonb),
  public.publish_schedule(), public.stamp_row() to authenticated;
revoke all on all tables in schema public from anon;

-- ---------- live updates ----------
alter table public.bookings replica identity full;
alter table public.teacher_changes replica identity full;
alter table public.ge_requests replica identity full;
alter table public.ge_decisions replica identity full;
alter table public.ge_teachers replica identity full;
alter table public.submissions replica identity full;
alter table public.instructor_requests replica identity full;
do $$ begin
  begin alter publication supabase_realtime add table public.bookings; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.teacher_changes; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.ge_requests; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.ge_decisions; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.ge_teachers; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.settings; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.submissions; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.instructor_requests; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.staff; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.faculty; exception when duplicate_object then null; end;
end $$;

-- Faculty and classes, generated by: python -m scheduler web
-- Specializations come from the loading plans, and one typed on the Faculty Profiles page is kept.
insert into public.faculty (key, name, college, department, rank, designation, max_lu, degree, specialization) values
  ('CBE-A1', 'Dr. Leonora B. Velasco', 'CBE', 'Accountancy', 'Associate Professor I', 'Department Chair', 15, 'Doctor of Business Administration; CPA', 'Accounting standards, research, governance'),
  ('CBE-A2', 'Atty. Ronaldo P. Marquez', 'CBE', 'Accountancy', 'Assistant Professor II', 'Faculty', 24, 'JD; CPA; member of the Philippine Bar', 'Business law, regulation, taxation'),
  ('CBE-A3', 'Ms. Charmaine D. Uy', 'CBE', 'Accountancy', 'Assistant Professor I', 'Review Coordinator', 24, 'MS Accountancy; CPA', 'Financial accounting and reporting'),
  ('CBE-A4', 'Mr. Jerico M. Valencia', 'CBE', 'Accountancy', 'Assistant Professor I', 'Internship Coordinator', 24, 'MS Accountancy; CPA, CIA', 'Auditing, assurance, information systems'),
  ('CBE-A5', 'Ms. Abigail T. Flores', 'CBE', 'Accountancy', 'Instructor III', 'Faculty', 24, 'Master of Business Administration; CPA', 'Cost and management accounting, finance, management science'),
  ('CBE-AD', 'Dr. Fernando E. Ferrer', 'CBE', 'Accountancy', 'Professor I', 'Associate Dean', 6, 'Doctor of Business Administration; CPA', null),
  ('CBE-B1', 'Dr. Estela M. Torres', 'CBE', 'Business Administration', 'Associate Professor I', 'Department Chair', 15, 'Doctor of Business Administration', 'Strategic and operations management, research'),
  ('CBE-B2', 'Mr. Rodel P. Morales', 'CBE', 'Business Administration', 'Assistant Professor I', 'Financial Management Coordinator', 24, 'MBA (Financial Management); CPA', 'Finance, accounting, taxation, business law'),
  ('CBE-B3', 'Ms. Liezl G. Castro', 'CBE', 'Business Administration', 'Assistant Professor I', 'Marketing Coordinator', 24, 'MBA (Marketing)', 'Marketing, consumer behavior, sales'),
  ('CBE-B4', 'Mr. Adrian V. Ramirez', 'CBE', 'Business Administration', 'Instructor III', 'Business Analytics Coordinator', 24, 'MS Business Analytics', 'Analytics, data management, information systems'),
  ('CBE-B5', 'Ms. Josephine L. Delos Reyes', 'CBE', 'Business Administration', 'Instructor III', 'Internship Coordinator', 24, 'MBA (Human Resource Management); SHRM-CP', 'HRM, governance, international business, careers'),
  ('CBE-B6', 'Mr. Francis Noel D. Galang', 'CBE', 'Business Administration', 'Instructor III', 'Faculty', 24, 'MBA (Operations Management); MS Marketing Analytics', 'Operations, marketing analytics, quantitative methods'),
  ('CBE-H1', 'Dr. Marilou C. Padilla', 'CBE', 'Tourism and Hospitality Management', 'Associate Professor I', 'Department Chair', 15, 'PhD Hospitality Management', 'Tourism and hospitality management, research'),
  ('CBE-H2', 'Mr. Paolo R. Gutierrez', 'CBE', 'Tourism and Hospitality Management', 'Instructor III', 'Kitchen Laboratory Coordinator', 24, 'MS Hospitality Management; NC II Cookery and Bread and Pastry', 'Culinary, food and beverage, bar operations'),
  ('CBE-H3', 'Ms. Trisha M. Samonte', 'CBE', 'Tourism and Hospitality Management', 'Assistant Professor I', 'Faculty', 24, 'MS Tourism', 'Tourism geography, tour operations, ecotourism'),
  ('CBE-H4', 'Mr. Lorenzo D. Buenaventura', 'CBE', 'Tourism and Hospitality Management', 'Assistant Professor I', 'Practicum Coordinator', 24, 'MBA (Hospitality Management)', 'Lodging, front office, hospitality marketing and law'),
  ('CBE-H5', 'Ms. Jasmin L. Sarmiento', 'CBE', 'Tourism and Hospitality Management', 'Instructor II', 'Faculty', 24, 'MA Korean Studies; BS Tourism', 'Korean language, events, multicultural workplaces'),
  ('CBE-N1', 'Dr. Ramil S. Gonzales', 'CBE', 'Entrepreneurship', 'Associate Professor I', 'Department Chair', 15, 'Doctor of Business Administration', 'Business planning, strategy, operations'),
  ('CBE-N2', 'Ms. Kristel A. Rivera', 'CBE', 'Entrepreneurship', 'Assistant Professor I', 'Faculty', 24, 'Master of Business Administration (Marketing)', 'Market research, digital marketing, ideation'),
  ('CBE-N4', 'Ms. Aileen R. Javier', 'CBE', 'Entrepreneurship', 'Instructor III', 'Incubation Coordinator', 24, 'MS Entrepreneurship', 'Innovation, social enterprise, SMEs'),
  ('CCJPS-AD', 'Dr. Ian P. Bonilla', 'CCJPS', 'Criminology', 'Associate Professor IV', 'Associate Dean', 6, 'PhD Criminal Justice; RCrim', null),
  ('CCJPS-D1', 'Dr. Reynaldo C. Villamor', 'CCJPS', 'Public Administration', 'Associate Professor I', 'Department Chair', 15, 'Doctor of Public Administration', 'Public policy, governance, research'),
  ('CCJPS-D2', 'Ms. Lorna G. Fabian', 'CCJPS', 'Public Administration', 'Assistant Professor I', 'Faculty', 24, 'Master in Public Administration; CPA', 'Fiscal administration, government accounting, procurement'),
  ('CCJPS-D3', 'Mr. Joel R. Macapagal', 'CCJPS', 'Public Administration', 'Instructor III', 'Internship Coordinator', 24, 'Master in Public Administration', 'Local governance, disaster management, civil society'),
  ('CCJPS-D4', 'Atty. Kristine D. Ramos', 'CCJPS', 'Public Administration', 'Instructor III', 'Faculty', 24, 'JD; Master in Public Administration; member of the Philippine Bar', 'Administrative law, personnel administration, ethics, gender'),
  ('CCJPS-R1', 'Dr. Nestor B. Alcaraz', 'CCJPS', 'Criminology', 'Associate Professor I', 'Department Chair', 15, 'PhD Criminal Justice; RCrim', 'Criminological theory, research, juvenile justice'),
  ('CCJPS-R2', 'Atty. Celeste M. Rivera', 'CCJPS', 'Criminology', 'Assistant Professor II', 'Faculty', 24, 'JD; RCrim; member of the Philippine Bar', 'Criminal law, procedure, evidence, human rights'),
  ('CCJPS-R3', 'Mr. Herminio D. Bagasbas', 'CCJPS', 'Criminology', 'Assistant Professor I', 'Internship Coordinator', 24, 'MS Criminology; RCrim; retired Police Lieutenant Colonel', 'Police administration, patrol, intelligence, security'),
  ('CCJPS-R4', 'Ms. Janine F. Corpuz', 'CCJPS', 'Criminology', 'Instructor III', 'Crime Laboratory Coordinator', 24, 'MS Forensic Science; RCrim', 'Criminalistics, photography, ballistics, questioned documents'),
  ('CCJPS-R5', 'Mr. Rodrigo P. Salvador', 'CCJPS', 'Criminology', 'Instructor III', 'Faculty', 24, 'MS Criminal Justice (Investigation); RCrim', 'Criminal investigation, traffic, fire and arson, drugs'),
  ('CCJPS-R6', 'Ms. Marjorie L. Pascual', 'CCJPS', 'Criminology', 'Instructor II', 'Faculty', 24, 'MA Psychology; RCrim; RPm', 'Corrections, victimology, therapeutic modalities, lie detection'),
  ('CCJPS-W1', 'Dr. Evangeline P. Soriano', 'CCJPS', 'Social Work', 'Associate Professor I', 'Department Chair', 15, 'PhD Social Work; RSW', 'Social welfare policy, research, administration'),
  ('CCJPS-W2', 'Ms. Rhea Lyn C. Galang', 'CCJPS', 'Social Work', 'Assistant Professor I', 'Field Instruction Coordinator', 24, 'MSW (Clinical); RSW', 'Casework, families, mental health, counseling skills'),
  ('CCJPS-W3', 'Mr. Emmanuel T. Dacanay', 'CCJPS', 'Social Work', 'Instructor III', 'Faculty', 24, 'MSW (Community Development); RSW', 'Community organizing, groups, disaster response, projects'),
  ('CCJPS-W4', 'Ms. Charisse M. Lopez', 'CCJPS', 'Social Work', 'Instructor II', 'Faculty', 24, 'MSW; RSW; MA Gender Studies', 'Human behavior, gender and development, older persons, ethics'),
  ('CICS-AD', 'Dr. Dolores R. Cayaban', 'CICS', 'Computer Science', 'Associate Professor V', 'Associate Dean', 6, 'PhD Computer Science', null),
  ('CICS-B1', 'Dr. Evelyn M. Lim', 'CICS', 'Library and Information Science', 'Associate Professor I', 'Department Chair', 15, 'PhD Library and Information Science; RL', 'Library management, research, legislation'),
  ('CICS-B3', 'Ms. Pauline A. de Guzman', 'CICS', 'Library and Information Science', 'Instructor III', 'Faculty', 24, 'MLIS; RL', 'Reference services, information literacy'),
  ('CICS-B4', 'Mr. Arvin C. Tan', 'CICS', 'Library and Information Science', 'Assistant Professor I', 'Library Technology Coordinator', 24, 'MLIS; RL', 'Library automation, digital libraries, retrieval'),
  ('CICS-C1', 'Dr. Arnel P. Macaraeg', 'CICS', 'Computer Science', 'Associate Professor I', 'Department Chair', 15, 'PhD Computer Science', 'Algorithms, theory of computation'),
  ('CICS-C2', 'Mr. Carlo Miguel D. Santiago', 'CICS', 'Computer Science', 'Assistant Professor I', 'Thesis and Practicum Coordinator', 24, 'MS Computer Science (Software Engineering)', 'Software engineering, programming'),
  ('CICS-C3', 'Dr. Jasmine T. Lorenzo', 'CICS', 'Computer Science', 'Assistant Professor II', 'Research Coordinator', 24, 'PhD Computer Science (Machine Learning)', 'Intelligent systems, machine learning, data'),
  ('CICS-C4', 'Mr. Noel B. Ferrer', 'CICS', 'Computer Science', 'Instructor III', 'Laboratory Coordinator', 24, 'MS Computer Science (Systems)', 'Architecture, operating systems, networks, security'),
  ('CICS-C5', 'Ms. Rhea Anne L. Cruz', 'CICS', 'Computer Science', 'Assistant Professor I', 'Faculty', 24, 'MS Applied Mathematics', 'Discrete mathematics, calculus, statistics'),
  ('CICS-C6', 'Mr. Kevin S. Domingo', 'CICS', 'Computer Science', 'Instructor II', 'Faculty', 24, 'Master in Information Technology', 'Programming, applications development, HCI'),
  ('CICS-T1', 'Dr. Marivic S. Pascual', 'CICS', 'Information Technology', 'Associate Professor I', 'Department Chair', 15, 'Doctor in Information Technology', 'Systems integration, IT management'),
  ('CICS-T2', 'Mr. Ramon J. Villareal', 'CICS', 'Information Technology', 'Assistant Professor I', 'Laboratory Coordinator', 24, 'Master in Information Technology; Cisco-certified', 'Networking, cloud, systems administration'),
  ('CICS-T3', 'Ms. Diane Mae R. Caballero', 'CICS', 'Information Technology', 'Instructor III', 'Faculty', 24, 'Master in Information Technology', 'Programming, web and mobile development, UX'),
  ('CICS-T4', 'Mr. Francis G. Ignacio', 'CICS', 'Information Technology', 'Assistant Professor I', 'Capstone and Practicum Coordinator', 24, 'MS Information Security', 'Information assurance and security'),
  ('CICS-T5', 'Ms. Jennifer C. Salazar', 'CICS', 'Information Technology', 'Instructor III', 'Faculty', 24, 'Master in Information Technology', 'Databases, data structures, integrative programming'),
  ('CICS-T6', 'Mr. Antonio L. Mendoza', 'CICS', 'Information Technology', 'Instructor II', 'Faculty', 24, 'Master in Information Technology; BS Applied Physics', 'Platform technologies, STS, quantitative methods'),
  ('COE-AD', 'Dr. Hillary Joy M. Rufino', 'COE', 'Secondary Education', 'Professor I', 'Associate Dean', 6, 'PhD Educational Management; LPT', null),
  ('COE-E1', 'Dr. Remedios A. Tamayo', 'COE', 'Elementary Education', 'Associate Professor I', 'Department Chair', 15, 'PhD Elementary Education; LPT', 'Curriculum, multigrade teaching, research'),
  ('COE-E2', 'Ms. Analyn F. Vasquez', 'COE', 'Elementary Education', 'Assistant Professor I', 'Faculty', 24, 'MAEd Reading; LPT', 'Reading, literacy, English language arts'),
  ('COE-E3', 'Mr. Virgilio S. Quijano', 'COE', 'Elementary Education', 'Assistant Professor I', 'Field Study and Internship Coordinator', 24, 'MAEd Mathematics; LPT', 'Mathematics and science teaching, assessment'),
  ('COE-E4', 'Ms. Josefina R. Obispo', 'COE', 'Elementary Education', 'Instructor III', 'Faculty', 24, 'MA Filipino; LPT', 'Filipino, social studies, values education'),
  ('COE-E5', 'Mr. Ariel M. Baltazar', 'COE', 'Elementary Education', 'Instructor III', 'Faculty', 24, 'MAEd Music, Arts, Physical Education, and Health; LPT', 'MAPEH, EPP, technology for teaching'),
  ('COE-S1', 'Dr. Teresa G. Evangelista', 'COE', 'Secondary Education', 'Associate Professor II', 'Department Chair', 15, 'PhD Educational Management; LPT', 'School leadership, curriculum, the teaching profession'),
  ('COE-S10', 'Ms. Divina P. Magbanua', 'COE', 'Secondary Education', 'Instructor III', 'Social Sciences Major Coordinator', 24, 'MA Social Studies Education; LPT', 'Social studies pedagogy, government, economics'),
  ('COE-S11', 'Dr. Amado T. Nepomuceno', 'COE', 'Secondary Education', 'Assistant Professor II', 'Filipino Major Coordinator', 24, 'PhD Filipino; LPT', 'Linggwistika, panitikan, pagsasaling-wika'),
  ('COE-S12', 'Ms. Liwayway C. Salvador', 'COE', 'Secondary Education', 'Instructor III', 'Faculty', 24, 'MA Filipino; LPT', 'Pagtuturo ng wika at panitikan'),
  ('COE-S13', 'Mr. Emilio D. Arceo', 'COE', 'Secondary Education', 'Instructor II', 'Faculty', 24, 'MA Filipino; LPT', 'Panitikan, malikhaing pagsulat, wika'),
  ('COE-S14', 'Ms. Rosario F. Guevarra', 'COE', 'Secondary Education', 'Instructor II', 'Faculty', 24, 'MA History; LPT', 'Philippine history, Rizal studies, heritage'),
  ('COE-S15', 'Ms. Bianca Mae T. Villanueva', 'COE', 'Secondary Education', 'Instructor II', 'Faculty', 24, 'MA English Language Teaching; LPT', 'Grammar, macroskills, purposive communication'),
  ('COE-S16', 'Mr. Jonathan R. Belmonte', 'COE', 'Secondary Education', 'Instructor II', 'Faculty', 24, 'MS Mathematics Education; LPT', 'Calculus, discrete mathematics, statistics'),
  ('COE-S2', 'Dr. Manuel A. Francisco', 'COE', 'Secondary Education', 'Associate Professor I', 'Field Study and Internship Coordinator', 24, 'EdD Curriculum and Instruction; LPT', 'Learner-centered teaching, assessment, field study'),
  ('COE-S4', 'Mr. Julius B. Natividad', 'COE', 'Secondary Education', 'Instructor III', 'Faculty', 24, 'MAEd Educational Technology; LPT', 'Technology for teaching and learning'),
  ('COE-S5', 'Dr. Rebecca L. Medina', 'COE', 'Secondary Education', 'Assistant Professor II', 'English Major Coordinator', 24, 'PhD English Language Education; LPT', 'Linguistics, language teaching, research'),
  ('COE-S6', 'Mr. Nathaniel C. Ortega', 'COE', 'Secondary Education', 'Instructor III', 'Faculty', 24, 'MA Literature; LPT', 'Literature, speech and theater, journalism'),
  ('COE-S7', 'Dr. Rodolfo M. Umali', 'COE', 'Secondary Education', 'Assistant Professor II', 'Mathematics Major Coordinator', 24, 'PhD Mathematics Education; LPT', 'Mathematics education, analysis, algebra'),
  ('COE-S8', 'Ms. Kimberly D. Saldana', 'COE', 'Secondary Education', 'Instructor III', 'Faculty', 24, 'MS Mathematics; LPT', 'Geometry, statistics, applied mathematics'),
  ('COE-S9', 'Mr. Rogelio O. Legaspi', 'COE', 'Secondary Education', 'Assistant Professor I', 'Faculty', 24, 'MA History; LPT', 'Philippine and world history, heritage'),
  ('CSS-AD', 'Dr. Marissa F. Prudencio', 'CSS', 'Psychology', 'Professor I', 'Associate Dean', 6, 'PhD Social Psychology', null),
  ('CSS-E1', 'Dr. Florante S. Mangubat', 'CSS', 'Economics', 'Associate Professor I', 'Department Chair', 15, 'PhD Economics', 'Macroeconomics, development economics, Philippine economy'),
  ('CSS-E2', 'Dr. Imelda R. Cabrera', 'CSS', 'Economics', 'Assistant Professor III', 'Research Coordinator', 24, 'PhD Economics', 'Microeconomics, econometrics, labor economics'),
  ('CSS-E4', 'Ms. Katrina V. Lucero', 'CSS', 'Economics', 'Instructor III', 'Internship Coordinator', 24, 'MA Development Economics', 'International and agricultural economics, globalization'),
  ('CSS-E5', 'Mr. Jose Emmanuel P. Sison', 'CSS', 'Economics', 'Instructor II', 'Faculty', 24, 'MA Economics', 'Money and banking, economic history, behavioral economics'),
  ('CSS-L1', 'Dr. Ernesto V. Dimaculangan', 'CSS', 'Political Science', 'Associate Professor I', 'Department Chair', 15, 'PhD Political Science', 'Political theory, Philippine politics'),
  ('CSS-L2', 'Atty. Mariel S. Agustin', 'CSS', 'Political Science', 'Assistant Professor II', 'Legal Studies Coordinator', 24, 'JD; MA Political Science; member of the Philippine Bar', 'Constitutional and public law'),
  ('CSS-L3', 'Atty. Rafael T. Bautista', 'CSS', 'Political Science', 'Assistant Professor I', 'Internship Coordinator', 24, 'JD; member of the Philippine Bar', 'Criminal law, civil law, advocacy'),
  ('CSS-L4', 'Mr. Paolo D. Ilagan', 'CSS', 'Political Science', 'Instructor III', 'Faculty', 24, 'MA International Studies', 'International relations, comparative politics'),
  ('CSS-M1', 'Dr. Teresita L. Valdez', 'CSS', 'Communication', 'Associate Professor I', 'Department Chair', 15, 'PhD Development Communication', 'Development communication, communication research'),
  ('CSS-M3', 'Mr. Daniel F. Robles', 'CSS', 'Communication', 'Instructor III', 'Media Laboratory Coordinator', 24, 'MA Media Studies (Broadcast and Film)', 'Audio, video, and digital production'),
  ('CSS-M4', 'Ms. Patricia Anne E. Yap', 'CSS', 'Communication', 'Assistant Professor I', 'Internship Coordinator', 24, 'MA Communication (Strategic Communication)', 'PR, advertising, organizational communication'),
  ('CSS-M5', 'Ms. Camille R. Navarro', 'CSS', 'Communication', 'Instructor II', 'Faculty', 24, 'MA Speech Communication', 'Purposive and speech communication'),
  ('CSS-P1', 'Dr. Rowena C. Dalisay', 'CSS', 'Psychology', 'Associate Professor II', 'Department Chair', 15, 'PhD Counseling Psychology; RPsy, RGC', 'Counseling, psychopathology'),
  ('CSS-P2', 'Ms. Kristine Joy M. Lacsamana', 'CSS', 'Psychology', 'Assistant Professor I', 'Faculty', 24, 'MA Clinical Psychology; RPsy', 'Assessment, clinical psychology'),
  ('CSS-P3', 'Mr. Joaquin R. Esguerra', 'CSS', 'Psychology', 'Assistant Professor I', 'I-O Track Coordinator', 24, 'MA Industrial-Organizational Psychology; RPm', 'I-O psychology, HR, cognition at work'),
  ('CSS-P4', 'Dr. Benedict A. Manalastas', 'CSS', 'Psychology', 'Assistant Professor III', 'Research Coordinator', 24, 'PhD Psychology (Experimental); RPm', 'Statistics, research methods, biological psychology'),
  ('CSS-P5', 'Ms. Angelica P. Tolentino', 'CSS', 'Psychology', 'Instructor III', 'Faculty', 24, 'MA Developmental Psychology; RPm', 'Self and identity, gender, development'),
  ('GE-G1', 'Dr. Ma. Luisa T. Pangilinan', 'GE', 'General Education', 'Associate Professor I', 'GE Department Coordinator', 15, 'PhD Philosophy', 'Logic, ethics, philosophy of religion'),
  ('GE-G10', 'Ms. Kathleen T. Robles', 'GE', 'General Education', 'Instructor III', 'Faculty', 24, 'MA Literature', 'Philippine literature, creative writing'),
  ('GE-G11', 'Ms. Danica F. Salvador', 'GE', 'General Education', 'Instructor II', 'Faculty', 24, 'MA English (Technical Communication)', 'Technical and workplace writing'),
  ('GE-G12', 'Mr. Dennis A. Cortez', 'GE', 'General Education', 'Instructor II', 'PE Coordinator', 24, 'MS Physical Education', 'Physical fitness, sports, dance'),
  ('GE-G13', 'Ms. Rowena J. Manzano', 'GE', 'General Education', 'Instructor III', 'Faculty', 24, 'MS Physical Education', 'Fitness, individual and dual sports'),
  ('GE-G14', 'Mr. Mark Joseph L. Tuazon', 'GE', 'General Education', 'Instructor II', 'Faculty', 24, 'MA Physical Education; licensed coach', 'Team sports, recreation'),
  ('GE-G15', 'Ms. Irene C. Mallari', 'GE', 'General Education', 'Instructor II', 'Faculty', 24, 'MA Dance Education', 'Dance, rhythmic activities'),
  ('GE-G16', 'Mr. Paulo V. Sison', 'GE', 'General Education', 'Instructor II', 'Faculty', 24, 'MS Sports Science', 'Fitness, wellness, team sports'),
  ('GE-G17', 'Ms. Maricar L. Bacani', 'GE', 'General Education', 'Instructor II', 'NSTP Coordinator', 24, 'MA Community Development', 'NSTP, civic welfare, community service'),
  ('GE-G18', 'Mr. Ramon D. Esteban', 'GE', 'General Education', 'Instructor II', 'Faculty', 24, 'MS Physical Education', 'Outdoor recreation, sports, NSTP'),
  ('GE-G19', 'Ms. Liezel P. Corpuz', 'GE', 'General Education', 'Instructor II', 'Faculty', 24, 'MA Public Administration', 'Civic education, volunteerism, local governance'),
  ('GE-G2', 'Mr. Bernardo C. Aquino', 'GE', 'General Education', 'Instructor III', 'Faculty', 24, 'MA Philosophy', 'Critical thinking, ethics'),
  ('GE-G3', 'Dr. Francis Xavier M. Tolentino', 'GE', 'General Education', 'Assistant Professor II', 'Faculty', 24, 'PhD Applied Ethics', 'Ethics, bioethics, business ethics'),
  ('GE-G4', 'Ms. Angelica R. Soriano', 'GE', 'General Education', 'Instructor III', 'Faculty', 24, 'MA Philosophy', 'Logic, critical thinking'),
  ('GE-G5', 'Ms. Hannah Grace V. Alvarez', 'GE', 'General Education', 'Instructor II', 'Humanities Coordinator', 24, 'MA Humanities', 'Art appreciation, literature, religion and culture'),
  ('GE-G6', 'Mr. Lorenzo P. Galvez', 'GE', 'General Education', 'Instructor III', 'Faculty', 24, 'MFA Visual Arts', 'Art history, visual arts, Philippine arts'),
  ('GE-G7', 'Ms. Bea Katrina L. Navarro', 'GE', 'General Education', 'Instructor II', 'Faculty', 24, 'MA Art Studies', 'Philippine art, music, performing arts'),
  ('GE-G8', 'Dr. Rosemarie D. Aguilar', 'GE', 'General Education', 'Assistant Professor I', 'Writing Coordinator', 24, 'PhD Literature', 'Philippine and world literature'),
  ('GE-G9', 'Mr. Joshua M. Cabanilla', 'GE', 'General Education', 'Instructor III', 'Faculty', 24, 'MA English Language Studies', 'Professional and technical writing, editing'),
  ('RE-RE1', 'Dr. Elijah M. Sablan', 'RE', 'Religious Education', 'Associate Professor I', 'Religious Education Coordinator', 15, null, null),
  ('RE-RE2', 'Mr. Joseph A. Malabanan', 'RE', 'Religious Education', 'Instructor III', 'Faculty', 24, null, null),
  ('RE-RE3', 'Ms. Esther Joy C. Paguio', 'RE', 'Religious Education', 'Instructor III', 'Faculty', 24, null, null),
  ('RE-RE4', 'Mr. Daniel S. Macalintal', 'RE', 'Religious Education', 'Instructor II', 'Faculty', 24, null, null),
  ('RE-RE5', 'Mr. Benjamin T. Cuevas', 'RE', 'Religious Education', 'Instructor II', 'Faculty', 24, null, null),
  ('RE-RE6', 'Ms. Ruth Anne L. Sarte', 'RE', 'Religious Education', 'Instructor II', 'Faculty', 24, null, null)
on conflict (key) do update set name = excluded.name, college = excluded.college, department = excluded.department, rank = excluded.rank, designation = excluded.designation, max_lu = excluded.max_lu, degree = excluded.degree, specialization = coalesce(public.faculty.specialization, excluded.specialization);
-- CISC is now CICS. Move what points at the old faculty keys to the new ones.
update public.faculty n set specialization = o.specialization from public.faculty o
  where o.key like 'CISC-%' and n.key = 'CICS-' || substr(o.key, 6) and o.specialization is not null;
update public.classes set plan_teacher = 'CICS-' || substr(plan_teacher, 6) where plan_teacher like 'CISC-%';
update public.teacher_changes set teacher = 'CICS-' || substr(teacher, 6) where teacher like 'CISC-%';
update public.ge_decisions set teacher = 'CICS-' || substr(teacher, 6) where teacher like 'CISC-%';
update public.staff set college = 'CICS' where college = 'CISC';
update public.ge_requests set college = 'CICS' where college = 'CISC';
update public.instructor_requests set college = 'CICS' where college = 'CISC';
update public.submissions set college = 'CICS' where college = 'CISC';
-- Faculty no longer in the plans: clear the classes given to them, then remove them.
update public.classes set plan_teacher = null where plan_teacher is not null and plan_teacher not in (select key from (values ('CBE-A1'), ('CBE-A2'), ('CBE-A3'), ('CBE-A4'), ('CBE-A5'), ('CBE-AD'), ('CBE-B1'), ('CBE-B2'), ('CBE-B3'), ('CBE-B4'), ('CBE-B5'), ('CBE-B6'), ('CBE-H1'), ('CBE-H2'), ('CBE-H3'), ('CBE-H4'), ('CBE-H5'), ('CBE-N1'), ('CBE-N2'), ('CBE-N4'), ('CCJPS-AD'), ('CCJPS-D1'), ('CCJPS-D2'), ('CCJPS-D3'), ('CCJPS-D4'), ('CCJPS-R1'), ('CCJPS-R2'), ('CCJPS-R3'), ('CCJPS-R4'), ('CCJPS-R5'), ('CCJPS-R6'), ('CCJPS-W1'), ('CCJPS-W2'), ('CCJPS-W3'), ('CCJPS-W4'), ('CICS-AD'), ('CICS-B1'), ('CICS-B3'), ('CICS-B4'), ('CICS-C1'), ('CICS-C2'), ('CICS-C3'), ('CICS-C4'), ('CICS-C5'), ('CICS-C6'), ('CICS-T1'), ('CICS-T2'), ('CICS-T3'), ('CICS-T4'), ('CICS-T5'), ('CICS-T6'), ('COE-AD'), ('COE-E1'), ('COE-E2'), ('COE-E3'), ('COE-E4'), ('COE-E5'), ('COE-S1'), ('COE-S10'), ('COE-S11'), ('COE-S12'), ('COE-S13'), ('COE-S14'), ('COE-S15'), ('COE-S16'), ('COE-S2'), ('COE-S4'), ('COE-S5'), ('COE-S6'), ('COE-S7'), ('COE-S8'), ('COE-S9'), ('CSS-AD'), ('CSS-E1'), ('CSS-E2'), ('CSS-E4'), ('CSS-E5'), ('CSS-L1'), ('CSS-L2'), ('CSS-L3'), ('CSS-L4'), ('CSS-M1'), ('CSS-M3'), ('CSS-M4'), ('CSS-M5'), ('CSS-P1'), ('CSS-P2'), ('CSS-P3'), ('CSS-P4'), ('CSS-P5'), ('GE-G1'), ('GE-G10'), ('GE-G11'), ('GE-G12'), ('GE-G13'), ('GE-G14'), ('GE-G15'), ('GE-G16'), ('GE-G17'), ('GE-G18'), ('GE-G19'), ('GE-G2'), ('GE-G3'), ('GE-G4'), ('GE-G5'), ('GE-G6'), ('GE-G7'), ('GE-G8'), ('GE-G9'), ('RE-RE1'), ('RE-RE2'), ('RE-RE3'), ('RE-RE4'), ('RE-RE5'), ('RE-RE6')) as s(key));
delete from public.teacher_changes where teacher is not null and teacher not in (select key from (values ('CBE-A1'), ('CBE-A2'), ('CBE-A3'), ('CBE-A4'), ('CBE-A5'), ('CBE-AD'), ('CBE-B1'), ('CBE-B2'), ('CBE-B3'), ('CBE-B4'), ('CBE-B5'), ('CBE-B6'), ('CBE-H1'), ('CBE-H2'), ('CBE-H3'), ('CBE-H4'), ('CBE-H5'), ('CBE-N1'), ('CBE-N2'), ('CBE-N4'), ('CCJPS-AD'), ('CCJPS-D1'), ('CCJPS-D2'), ('CCJPS-D3'), ('CCJPS-D4'), ('CCJPS-R1'), ('CCJPS-R2'), ('CCJPS-R3'), ('CCJPS-R4'), ('CCJPS-R5'), ('CCJPS-R6'), ('CCJPS-W1'), ('CCJPS-W2'), ('CCJPS-W3'), ('CCJPS-W4'), ('CICS-AD'), ('CICS-B1'), ('CICS-B3'), ('CICS-B4'), ('CICS-C1'), ('CICS-C2'), ('CICS-C3'), ('CICS-C4'), ('CICS-C5'), ('CICS-C6'), ('CICS-T1'), ('CICS-T2'), ('CICS-T3'), ('CICS-T4'), ('CICS-T5'), ('CICS-T6'), ('COE-AD'), ('COE-E1'), ('COE-E2'), ('COE-E3'), ('COE-E4'), ('COE-E5'), ('COE-S1'), ('COE-S10'), ('COE-S11'), ('COE-S12'), ('COE-S13'), ('COE-S14'), ('COE-S15'), ('COE-S16'), ('COE-S2'), ('COE-S4'), ('COE-S5'), ('COE-S6'), ('COE-S7'), ('COE-S8'), ('COE-S9'), ('CSS-AD'), ('CSS-E1'), ('CSS-E2'), ('CSS-E4'), ('CSS-E5'), ('CSS-L1'), ('CSS-L2'), ('CSS-L3'), ('CSS-L4'), ('CSS-M1'), ('CSS-M3'), ('CSS-M4'), ('CSS-M5'), ('CSS-P1'), ('CSS-P2'), ('CSS-P3'), ('CSS-P4'), ('CSS-P5'), ('GE-G1'), ('GE-G10'), ('GE-G11'), ('GE-G12'), ('GE-G13'), ('GE-G14'), ('GE-G15'), ('GE-G16'), ('GE-G17'), ('GE-G18'), ('GE-G19'), ('GE-G2'), ('GE-G3'), ('GE-G4'), ('GE-G5'), ('GE-G6'), ('GE-G7'), ('GE-G8'), ('GE-G9'), ('RE-RE1'), ('RE-RE2'), ('RE-RE3'), ('RE-RE4'), ('RE-RE5'), ('RE-RE6')) as s(key));
update public.ge_decisions set teacher = null where teacher is not null and teacher not in (select key from (values ('CBE-A1'), ('CBE-A2'), ('CBE-A3'), ('CBE-A4'), ('CBE-A5'), ('CBE-AD'), ('CBE-B1'), ('CBE-B2'), ('CBE-B3'), ('CBE-B4'), ('CBE-B5'), ('CBE-B6'), ('CBE-H1'), ('CBE-H2'), ('CBE-H3'), ('CBE-H4'), ('CBE-H5'), ('CBE-N1'), ('CBE-N2'), ('CBE-N4'), ('CCJPS-AD'), ('CCJPS-D1'), ('CCJPS-D2'), ('CCJPS-D3'), ('CCJPS-D4'), ('CCJPS-R1'), ('CCJPS-R2'), ('CCJPS-R3'), ('CCJPS-R4'), ('CCJPS-R5'), ('CCJPS-R6'), ('CCJPS-W1'), ('CCJPS-W2'), ('CCJPS-W3'), ('CCJPS-W4'), ('CICS-AD'), ('CICS-B1'), ('CICS-B3'), ('CICS-B4'), ('CICS-C1'), ('CICS-C2'), ('CICS-C3'), ('CICS-C4'), ('CICS-C5'), ('CICS-C6'), ('CICS-T1'), ('CICS-T2'), ('CICS-T3'), ('CICS-T4'), ('CICS-T5'), ('CICS-T6'), ('COE-AD'), ('COE-E1'), ('COE-E2'), ('COE-E3'), ('COE-E4'), ('COE-E5'), ('COE-S1'), ('COE-S10'), ('COE-S11'), ('COE-S12'), ('COE-S13'), ('COE-S14'), ('COE-S15'), ('COE-S16'), ('COE-S2'), ('COE-S4'), ('COE-S5'), ('COE-S6'), ('COE-S7'), ('COE-S8'), ('COE-S9'), ('CSS-AD'), ('CSS-E1'), ('CSS-E2'), ('CSS-E4'), ('CSS-E5'), ('CSS-L1'), ('CSS-L2'), ('CSS-L3'), ('CSS-L4'), ('CSS-M1'), ('CSS-M3'), ('CSS-M4'), ('CSS-M5'), ('CSS-P1'), ('CSS-P2'), ('CSS-P3'), ('CSS-P4'), ('CSS-P5'), ('GE-G1'), ('GE-G10'), ('GE-G11'), ('GE-G12'), ('GE-G13'), ('GE-G14'), ('GE-G15'), ('GE-G16'), ('GE-G17'), ('GE-G18'), ('GE-G19'), ('GE-G2'), ('GE-G3'), ('GE-G4'), ('GE-G5'), ('GE-G6'), ('GE-G7'), ('GE-G8'), ('GE-G9'), ('RE-RE1'), ('RE-RE2'), ('RE-RE3'), ('RE-RE4'), ('RE-RE5'), ('RE-RE6')) as s(key));
delete from public.faculty where key not in (select key from (values ('CBE-A1'), ('CBE-A2'), ('CBE-A3'), ('CBE-A4'), ('CBE-A5'), ('CBE-AD'), ('CBE-B1'), ('CBE-B2'), ('CBE-B3'), ('CBE-B4'), ('CBE-B5'), ('CBE-B6'), ('CBE-H1'), ('CBE-H2'), ('CBE-H3'), ('CBE-H4'), ('CBE-H5'), ('CBE-N1'), ('CBE-N2'), ('CBE-N4'), ('CCJPS-AD'), ('CCJPS-D1'), ('CCJPS-D2'), ('CCJPS-D3'), ('CCJPS-D4'), ('CCJPS-R1'), ('CCJPS-R2'), ('CCJPS-R3'), ('CCJPS-R4'), ('CCJPS-R5'), ('CCJPS-R6'), ('CCJPS-W1'), ('CCJPS-W2'), ('CCJPS-W3'), ('CCJPS-W4'), ('CICS-AD'), ('CICS-B1'), ('CICS-B3'), ('CICS-B4'), ('CICS-C1'), ('CICS-C2'), ('CICS-C3'), ('CICS-C4'), ('CICS-C5'), ('CICS-C6'), ('CICS-T1'), ('CICS-T2'), ('CICS-T3'), ('CICS-T4'), ('CICS-T5'), ('CICS-T6'), ('COE-AD'), ('COE-E1'), ('COE-E2'), ('COE-E3'), ('COE-E4'), ('COE-E5'), ('COE-S1'), ('COE-S10'), ('COE-S11'), ('COE-S12'), ('COE-S13'), ('COE-S14'), ('COE-S15'), ('COE-S16'), ('COE-S2'), ('COE-S4'), ('COE-S5'), ('COE-S6'), ('COE-S7'), ('COE-S8'), ('COE-S9'), ('CSS-AD'), ('CSS-E1'), ('CSS-E2'), ('CSS-E4'), ('CSS-E5'), ('CSS-L1'), ('CSS-L2'), ('CSS-L3'), ('CSS-L4'), ('CSS-M1'), ('CSS-M3'), ('CSS-M4'), ('CSS-M5'), ('CSS-P1'), ('CSS-P2'), ('CSS-P3'), ('CSS-P4'), ('CSS-P5'), ('GE-G1'), ('GE-G10'), ('GE-G11'), ('GE-G12'), ('GE-G13'), ('GE-G14'), ('GE-G15'), ('GE-G16'), ('GE-G17'), ('GE-G18'), ('GE-G19'), ('GE-G2'), ('GE-G3'), ('GE-G4'), ('GE-G5'), ('GE-G6'), ('GE-G7'), ('GE-G8'), ('GE-G9'), ('RE-RE1'), ('RE-RE2'), ('RE-RE3'), ('RE-RE4'), ('RE-RE5'), ('RE-RE6')) as s(key));
insert into public.classes (id, sem, course, section, program, college, department, is_ge, plan_teacher, house_dept, house_college) values
  ('S1-ACC101-BSA1A', 1, 'ACC 101', 'BSA 1A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC101-BSA1B', 1, 'ACC 101', 'BSA 1B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-BUS101-BSA1A', 1, 'BUS 101', 'BSA 1A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-BUS101-BSA1B', 1, 'BUS 101', 'BSA 1B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-MATH180-BSA1A', 1, 'MATH 180', 'BSA 1A', 'BSA', 'CBE', 'Accountancy', true, null, 'Secondary Education', 'COE'),
  ('S1-MATH180-BSA1B', 1, 'MATH 180', 'BSA 1B', 'BSA', 'CBE', 'Accountancy', true, null, 'Secondary Education', 'COE'),
  ('S1-SOCS195-BSA1A', 1, 'SOCS 195', 'BSA 1A', 'BSA', 'CBE', 'Accountancy', true, null, 'Economics', 'CSS'),
  ('S1-SOCS195-BSA1B', 1, 'SOCS 195', 'BSA 1B', 'BSA', 'CBE', 'Accountancy', true, null, 'Economics', 'CSS'),
  ('S1-PE101-BSA1A', 1, 'PE 101', 'BSA 1A', 'BSA', 'CBE', 'Accountancy', true, null, 'General Education', 'GE'),
  ('S1-PE101-BSA1B', 1, 'PE 101', 'BSA 1B', 'BSA', 'CBE', 'Accountancy', true, null, 'General Education', 'GE'),
  ('S1-CWTS101-BSA1A', 1, 'CWTS 101', 'BSA 1A', 'BSA', 'CBE', 'Accountancy', true, null, 'General Education', 'GE'),
  ('S1-CWTS101-BSA1B', 1, 'CWTS 101', 'BSA 1B', 'BSA', 'CBE', 'Accountancy', true, null, 'General Education', 'GE'),
  ('S1-UNI103-BSA1A', 1, 'UNI 103', 'BSA 1A', 'BSA', 'CBE', 'Accountancy', true, null, 'Accountancy', 'CBE'),
  ('S1-UNI103-BSA1B', 1, 'UNI 103', 'BSA 1B', 'BSA', 'CBE', 'Accountancy', true, null, 'Accountancy', 'CBE'),
  ('S1-REL103A-BSA1A', 1, 'REL 103A', 'BSA 1A', 'BSA', 'CBE', 'Accountancy', true, null, 'Religious Education', 'RE'),
  ('S1-REL103A-BSA1B', 1, 'REL 103A', 'BSA 1B', 'BSA', 'CBE', 'Accountancy', true, null, 'Religious Education', 'RE'),
  ('S1-ACC201-BSA2A', 1, 'ACC 201', 'BSA 2A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC201-BSA2B', 1, 'ACC 201', 'BSA 2B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC210-BSA2A', 1, 'ACC 210', 'BSA 2A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC210-BSA2B', 1, 'ACC 210', 'BSA 2B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC221-BSA2A', 1, 'ACC 221', 'BSA 2A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC221-BSA2B', 1, 'ACC 221', 'BSA 2B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-MATH350-BSA2A', 1, 'MATH 350', 'BSA 2A', 'BSA', 'CBE', 'Accountancy', true, null, 'Computer Science', 'CICS'),
  ('S1-MATH350-BSA2B', 1, 'MATH 350', 'BSA 2B', 'BSA', 'CBE', 'Accountancy', true, null, 'Computer Science', 'CICS'),
  ('S1-PSYC160-BSA2A', 1, 'PSYC 160', 'BSA 2A', 'BSA', 'CBE', 'Accountancy', true, null, 'Psychology', 'CSS'),
  ('S1-PSYC160-BSA2B', 1, 'PSYC 160', 'BSA 2B', 'BSA', 'CBE', 'Accountancy', true, null, 'Psychology', 'CSS'),
  ('S1-GAD171-BSA2A', 1, 'GAD 171', 'BSA 2A', 'BSA', 'CBE', 'Accountancy', true, null, 'Psychology', 'CSS'),
  ('S1-GAD171-BSA2B', 1, 'GAD 171', 'BSA 2B', 'BSA', 'CBE', 'Accountancy', true, null, 'Psychology', 'CSS'),
  ('S1-PE201-BSA2A', 1, 'PE 201', 'BSA 2A', 'BSA', 'CBE', 'Accountancy', true, null, 'General Education', 'GE'),
  ('S1-PE201-BSA2B', 1, 'PE 201', 'BSA 2B', 'BSA', 'CBE', 'Accountancy', true, null, 'General Education', 'GE'),
  ('S1-REL203A-BSA2A', 1, 'REL 203A', 'BSA 2A', 'BSA', 'CBE', 'Accountancy', true, null, 'Religious Education', 'RE'),
  ('S1-REL203A-BSA2B', 1, 'REL 203A', 'BSA 2B', 'BSA', 'CBE', 'Accountancy', true, null, 'Religious Education', 'RE'),
  ('S1-ACC203-BSA3A', 1, 'ACC 203', 'BSA 3A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC203-BSA3B', 1, 'ACC 203', 'BSA 3B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC231-BSA3A', 1, 'ACC 231', 'BSA 3A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC231-BSA3B', 1, 'ACC 231', 'BSA 3B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC241-BSA3A', 1, 'ACC 241', 'BSA 3A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC241-BSA3B', 1, 'ACC 241', 'BSA 3B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC250-BSA3A', 1, 'ACC 250', 'BSA 3A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC250-BSA3B', 1, 'ACC 250', 'BSA 3B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC301-BSA3A', 1, 'ACC 301', 'BSA 3A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC301-BSA3B', 1, 'ACC 301', 'BSA 3B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC222-BSA3A', 1, 'ACC 222', 'BSA 3A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC222-BSA3B', 1, 'ACC 222', 'BSA 3B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-PHIL190-BSA3A', 1, 'PHIL 190', 'BSA 3A', 'BSA', 'CBE', 'Accountancy', true, null, 'General Education', 'GE'),
  ('S1-PHIL190-BSA3B', 1, 'PHIL 190', 'BSA 3B', 'BSA', 'CBE', 'Accountancy', true, null, 'General Education', 'GE'),
  ('S1-REL303A-BSA3A', 1, 'REL 303A', 'BSA 3A', 'BSA', 'CBE', 'Accountancy', true, null, 'Religious Education', 'RE'),
  ('S1-REL303A-BSA3B', 1, 'REL 303A', 'BSA 3B', 'BSA', 'CBE', 'Accountancy', true, null, 'Religious Education', 'RE'),
  ('S1-ACC312-BSA4A', 1, 'ACC 312', 'BSA 4A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC312-BSA4B', 1, 'ACC 312', 'BSA 4B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC303-BSA4A', 1, 'ACC 303', 'BSA 4A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC303-BSA4B', 1, 'ACC 303', 'BSA 4B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC313-BSA4A', 1, 'ACC 313', 'BSA 4A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC313-BSA4B', 1, 'ACC 313', 'BSA 4B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC341-BSA4A', 1, 'ACC 341', 'BSA 4A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC341-BSA4B', 1, 'ACC 341', 'BSA 4B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC410-BSA4A', 1, 'ACC 410', 'BSA 4A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-ACC410-BSA4B', 1, 'ACC 410', 'BSA 4B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-HIST201-BSA4A', 1, 'HIST 201', 'BSA 4A', 'BSA', 'CBE', 'Accountancy', true, null, 'Secondary Education', 'COE'),
  ('S1-HIST201-BSA4B', 1, 'HIST 201', 'BSA 4B', 'BSA', 'CBE', 'Accountancy', true, null, 'Secondary Education', 'COE'),
  ('S1-ENGL302-BSA4A', 1, 'ENGL 302', 'BSA 4A', 'BSA', 'CBE', 'Accountancy', true, null, 'General Education', 'GE'),
  ('S1-ENGL302-BSA4B', 1, 'ENGL 302', 'BSA 4B', 'BSA', 'CBE', 'Accountancy', true, null, 'General Education', 'GE'),
  ('S1-REL403-BSA4A', 1, 'REL 403', 'BSA 4A', 'BSA', 'CBE', 'Accountancy', true, null, 'Religious Education', 'RE'),
  ('S1-REL403-BSA4B', 1, 'REL 403', 'BSA 4B', 'BSA', 'CBE', 'Accountancy', true, null, 'Religious Education', 'RE'),
  ('S1-ENT101-BSEntrep1', 1, 'ENT 101', 'BSEntrep 1', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-BUS101-BSEntrep1', 1, 'BUS 101', 'BSEntrep 1', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-MATH180-BSEntrep1', 1, 'MATH 180', 'BSEntrep 1', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Secondary Education', 'COE'),
  ('S1-PSYC160-BSEntrep1', 1, 'PSYC 160', 'BSEntrep 1', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Psychology', 'CSS'),
  ('S1-PE101-BSEntrep1', 1, 'PE 101', 'BSEntrep 1', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'General Education', 'GE'),
  ('S1-CWTS101-BSEntrep1', 1, 'CWTS 101', 'BSEntrep 1', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'General Education', 'GE'),
  ('S1-UNI103-BSEntrep1', 1, 'UNI 103', 'BSEntrep 1', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Entrepreneurship', 'CBE'),
  ('S1-REL103A-BSEntrep1', 1, 'REL 103A', 'BSEntrep 1', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Religious Education', 'RE'),
  ('S1-ENT201-BSEntrep2', 1, 'ENT 201', 'BSEntrep 2', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-ENT203-BSEntrep2', 1, 'ENT 203', 'BSEntrep 2', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-BUS201-BSEntrep2', 1, 'BUS 201', 'BSEntrep 2', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-MATH350-BSEntrep2', 1, 'MATH 350', 'BSEntrep 2', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Computer Science', 'CICS'),
  ('S1-FIL207-BSEntrep2', 1, 'FIL 207', 'BSEntrep 2', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Secondary Education', 'COE'),
  ('S1-PE201-BSEntrep2', 1, 'PE 201', 'BSEntrep 2', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'General Education', 'GE'),
  ('S1-REL203A-BSEntrep2', 1, 'REL 203A', 'BSEntrep 2', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Religious Education', 'RE'),
  ('S1-ENT210-BSEntrep3', 1, 'ENT 210', 'BSEntrep 3', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-ENT301-BSEntrep3', 1, 'ENT 301', 'BSEntrep 3', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-BUS220-BSEntrep3', 1, 'BUS 220', 'BSEntrep 3', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-BUS230-BSEntrep3', 1, 'BUS 230', 'BSEntrep 3', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-ENT310-BSEntrep3', 1, 'ENT 310', 'BSEntrep 3', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-PHIL190-BSEntrep3', 1, 'PHIL 190', 'BSEntrep 3', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'General Education', 'GE'),
  ('S1-ARTS101-BSEntrep3', 1, 'ARTS 101', 'BSEntrep 3', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'General Education', 'GE'),
  ('S1-REL303A-BSEntrep3', 1, 'REL 303A', 'BSEntrep 3', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Religious Education', 'RE'),
  ('S1-ENT401-BSEntrep4', 1, 'ENT 401', 'BSEntrep 4', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-BUS302-BSEntrep4', 1, 'BUS 302', 'BSEntrep 4', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-HIST220-BSEntrep4', 1, 'HIST 220', 'BSEntrep 4', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Secondary Education', 'COE'),
  ('S1-GAD171-BSEntrep4', 1, 'GAD 171', 'BSEntrep 4', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Psychology', 'CSS'),
  ('S1-REL403-BSEntrep4', 1, 'REL 403', 'BSEntrep 4', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Religious Education', 'RE'),
  ('S1-BUS101-BSBA1A', 1, 'BUS 101', 'BSBA 1A', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-BUS101-BSBA1B', 1, 'BUS 101', 'BSBA 1B', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-BUS110-BSBA1A', 1, 'BUS 110', 'BSBA 1A', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-BUS110-BSBA1B', 1, 'BUS 110', 'BSBA 1B', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-MATH180-BSBA1A', 1, 'MATH 180', 'BSBA 1A', 'BSBA', 'CBE', 'Business Administration', true, null, 'Secondary Education', 'COE'),
  ('S1-MATH180-BSBA1B', 1, 'MATH 180', 'BSBA 1B', 'BSBA', 'CBE', 'Business Administration', true, null, 'Secondary Education', 'COE'),
  ('S1-PSYC160-BSBA1A', 1, 'PSYC 160', 'BSBA 1A', 'BSBA', 'CBE', 'Business Administration', true, null, 'Psychology', 'CSS'),
  ('S1-PSYC160-BSBA1B', 1, 'PSYC 160', 'BSBA 1B', 'BSBA', 'CBE', 'Business Administration', true, null, 'Psychology', 'CSS'),
  ('S1-PE101-BSBA1A', 1, 'PE 101', 'BSBA 1A', 'BSBA', 'CBE', 'Business Administration', true, null, 'General Education', 'GE'),
  ('S1-PE101-BSBA1B', 1, 'PE 101', 'BSBA 1B', 'BSBA', 'CBE', 'Business Administration', true, null, 'General Education', 'GE'),
  ('S1-CWTS101-BSBA1A', 1, 'CWTS 101', 'BSBA 1A', 'BSBA', 'CBE', 'Business Administration', true, null, 'General Education', 'GE'),
  ('S1-CWTS101-BSBA1B', 1, 'CWTS 101', 'BSBA 1B', 'BSBA', 'CBE', 'Business Administration', true, null, 'General Education', 'GE'),
  ('S1-UNI103-BSBA1A', 1, 'UNI 103', 'BSBA 1A', 'BSBA', 'CBE', 'Business Administration', true, null, 'Business Administration', 'CBE'),
  ('S1-UNI103-BSBA1B', 1, 'UNI 103', 'BSBA 1B', 'BSBA', 'CBE', 'Business Administration', true, null, 'Business Administration', 'CBE'),
  ('S1-REL103A-BSBA1A', 1, 'REL 103A', 'BSBA 1A', 'BSBA', 'CBE', 'Business Administration', true, null, 'Religious Education', 'RE'),
  ('S1-REL103A-BSBA1B', 1, 'REL 103A', 'BSBA 1B', 'BSBA', 'CBE', 'Business Administration', true, null, 'Religious Education', 'RE'),
  ('S1-BUS121-BSBA2A', 1, 'BUS 121', 'BSBA 2A', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-BUS121-BSBA2B', 1, 'BUS 121', 'BSBA 2B', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-BUS201-BSBA2A', 1, 'BUS 201', 'BSBA 2A', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-BUS201-BSBA2B', 1, 'BUS 201', 'BSBA 2B', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-BUS210-BSBA2A', 1, 'BUS 210', 'BSBA 2A', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-BUS210-BSBA2B', 1, 'BUS 210', 'BSBA 2B', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-STS180-BSBA2A', 1, 'STS 180', 'BSBA 2A', 'BSBA', 'CBE', 'Business Administration', true, null, 'Information Technology', 'CICS'),
  ('S1-STS180-BSBA2B', 1, 'STS 180', 'BSBA 2B', 'BSBA', 'CBE', 'Business Administration', true, null, 'Information Technology', 'CICS'),
  ('S1-PE201-BSBA2A', 1, 'PE 201', 'BSBA 2A', 'BSBA', 'CBE', 'Business Administration', true, null, 'General Education', 'GE'),
  ('S1-PE201-BSBA2B', 1, 'PE 201', 'BSBA 2B', 'BSBA', 'CBE', 'Business Administration', true, null, 'General Education', 'GE'),
  ('S1-REL203A-BSBA2A', 1, 'REL 203A', 'BSBA 2A', 'BSBA', 'CBE', 'Business Administration', true, null, 'Religious Education', 'RE'),
  ('S1-REL203A-BSBA2B', 1, 'REL 203A', 'BSBA 2B', 'BSBA', 'CBE', 'Business Administration', true, null, 'Religious Education', 'RE'),
  ('S1-BUS220-BSBA3A', 1, 'BUS 220', 'BSBA 3A', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-BUS220-BSBA3B', 1, 'BUS 220', 'BSBA 3B', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-BUS230-BSBA3A', 1, 'BUS 230', 'BSBA 3A', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-BUS230-BSBA3B', 1, 'BUS 230', 'BSBA 3B', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-FM301-BSBA3-FM', 1, 'FM 301', 'BSBA 3-FM', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-FM303-BSBA3-FM', 1, 'FM 303', 'BSBA 3-FM', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-MKT301-BSBA3-MKT', 1, 'MKT 301', 'BSBA 3-MKT', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-MKT302-BSBA3-MKT', 1, 'MKT 302', 'BSBA 3-MKT', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-BAN301-BSBA3-BAN', 1, 'BAN 301', 'BSBA 3-BAN', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-BAN302-BSBA3-BAN', 1, 'BAN 302', 'BSBA 3-BAN', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-PHIL220-BSBA3A', 1, 'PHIL 220', 'BSBA 3A', 'BSBA', 'CBE', 'Business Administration', true, null, 'General Education', 'GE'),
  ('S1-PHIL220-BSBA3B', 1, 'PHIL 220', 'BSBA 3B', 'BSBA', 'CBE', 'Business Administration', true, null, 'General Education', 'GE'),
  ('S1-ARTS101-BSBA3A', 1, 'ARTS 101', 'BSBA 3A', 'BSBA', 'CBE', 'Business Administration', true, null, 'General Education', 'GE'),
  ('S1-ARTS101-BSBA3B', 1, 'ARTS 101', 'BSBA 3B', 'BSBA', 'CBE', 'Business Administration', true, null, 'General Education', 'GE'),
  ('S1-REL303A-BSBA3A', 1, 'REL 303A', 'BSBA 3A', 'BSBA', 'CBE', 'Business Administration', true, null, 'Religious Education', 'RE'),
  ('S1-REL303A-BSBA3B', 1, 'REL 303A', 'BSBA 3B', 'BSBA', 'CBE', 'Business Administration', true, null, 'Religious Education', 'RE'),
  ('S1-BUS302-BSBA4A', 1, 'BUS 302', 'BSBA 4A', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-BUS302-BSBA4B', 1, 'BUS 302', 'BSBA 4B', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-BUS304-BSBA4A', 1, 'BUS 304', 'BSBA 4A', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-BUS304-BSBA4B', 1, 'BUS 304', 'BSBA 4B', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-FM401-BSBA4-FM', 1, 'FM 401', 'BSBA 4-FM', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-FM402-BSBA4-FM', 1, 'FM 402', 'BSBA 4-FM', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-MKT401-BSBA4-MKT', 1, 'MKT 401', 'BSBA 4-MKT', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-MKT402-BSBA4-MKT', 1, 'MKT 402', 'BSBA 4-MKT', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-BAN401-BSBA4-BAN', 1, 'BAN 401', 'BSBA 4-BAN', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-BAN402-BSBA4-BAN', 1, 'BAN 402', 'BSBA 4-BAN', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-HIST220-BSBA4A', 1, 'HIST 220', 'BSBA 4A', 'BSBA', 'CBE', 'Business Administration', true, null, 'Secondary Education', 'COE'),
  ('S1-HIST220-BSBA4B', 1, 'HIST 220', 'BSBA 4B', 'BSBA', 'CBE', 'Business Administration', true, null, 'Secondary Education', 'COE'),
  ('S1-REL403-BSBA4A', 1, 'REL 403', 'BSBA 4A', 'BSBA', 'CBE', 'Business Administration', true, null, 'Religious Education', 'RE'),
  ('S1-REL403-BSBA4B', 1, 'REL 403', 'BSBA 4B', 'BSBA', 'CBE', 'Business Administration', true, null, 'Religious Education', 'RE'),
  ('S1-THM101-BSTHM1A', 1, 'THM 101', 'BSTHM 1A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-THM101-BSTHM1B', 1, 'THM 101', 'BSTHM 1B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-THM110-BSTHM1A', 1, 'THM 110', 'BSTHM 1A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-THM110-BSTHM1B', 1, 'THM 110', 'BSTHM 1B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-MATH180-BSTHM1A', 1, 'MATH 180', 'BSTHM 1A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Secondary Education', 'COE'),
  ('S1-MATH180-BSTHM1B', 1, 'MATH 180', 'BSTHM 1B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Secondary Education', 'COE'),
  ('S1-PSYC160-BSTHM1A', 1, 'PSYC 160', 'BSTHM 1A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Psychology', 'CSS'),
  ('S1-PSYC160-BSTHM1B', 1, 'PSYC 160', 'BSTHM 1B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Psychology', 'CSS'),
  ('S1-PE101-BSTHM1A', 1, 'PE 101', 'BSTHM 1A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'General Education', 'GE'),
  ('S1-PE101-BSTHM1B', 1, 'PE 101', 'BSTHM 1B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'General Education', 'GE'),
  ('S1-CWTS101-BSTHM1A', 1, 'CWTS 101', 'BSTHM 1A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'General Education', 'GE'),
  ('S1-CWTS101-BSTHM1B', 1, 'CWTS 101', 'BSTHM 1B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'General Education', 'GE'),
  ('S1-UNI103-BSTHM1A', 1, 'UNI 103', 'BSTHM 1A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Tourism and Hospitality Management', 'CBE'),
  ('S1-UNI103-BSTHM1B', 1, 'UNI 103', 'BSTHM 1B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Tourism and Hospitality Management', 'CBE'),
  ('S1-REL103A-BSTHM1A', 1, 'REL 103A', 'BSTHM 1A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Religious Education', 'RE'),
  ('S1-REL103A-BSTHM1B', 1, 'REL 103A', 'BSTHM 1B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Religious Education', 'RE'),
  ('S1-THM201-BSTHM2A', 1, 'THM 201', 'BSTHM 2A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-THM201-BSTHM2B', 1, 'THM 201', 'BSTHM 2B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-THM202-BSTHM2A', 1, 'THM 202', 'BSTHM 2A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-THM202-BSTHM2B', 1, 'THM 202', 'BSTHM 2B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-THM203-BSTHM2A', 1, 'THM 203', 'BSTHM 2A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-THM203-BSTHM2B', 1, 'THM 203', 'BSTHM 2B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-FIL207-BSTHM2A', 1, 'FIL 207', 'BSTHM 2A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Secondary Education', 'COE'),
  ('S1-FIL207-BSTHM2B', 1, 'FIL 207', 'BSTHM 2B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Secondary Education', 'COE'),
  ('S1-PE201-BSTHM2A', 1, 'PE 201', 'BSTHM 2A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'General Education', 'GE'),
  ('S1-PE201-BSTHM2B', 1, 'PE 201', 'BSTHM 2B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'General Education', 'GE'),
  ('S1-REL203A-BSTHM2A', 1, 'REL 203A', 'BSTHM 2A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Religious Education', 'RE'),
  ('S1-REL203A-BSTHM2B', 1, 'REL 203A', 'BSTHM 2B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Religious Education', 'RE'),
  ('S1-THM212-BSTHM3A', 1, 'THM 212', 'BSTHM 3A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-THM212-BSTHM3B', 1, 'THM 212', 'BSTHM 3B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-THM220-BSTHM3A', 1, 'THM 220', 'BSTHM 3A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-THM220-BSTHM3B', 1, 'THM 220', 'BSTHM 3B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-THM231-BSTHM3A', 1, 'THM 231', 'BSTHM 3A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-THM231-BSTHM3B', 1, 'THM 231', 'BSTHM 3B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-THM301-BSTHM3A', 1, 'THM 301', 'BSTHM 3A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-THM301-BSTHM3B', 1, 'THM 301', 'BSTHM 3B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-THM303-BSTHM3A', 1, 'THM 303', 'BSTHM 3A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-THM303-BSTHM3B', 1, 'THM 303', 'BSTHM 3B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-PHIL190-BSTHM3A', 1, 'PHIL 190', 'BSTHM 3A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'General Education', 'GE'),
  ('S1-PHIL190-BSTHM3B', 1, 'PHIL 190', 'BSTHM 3B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'General Education', 'GE'),
  ('S1-ARTS101-BSTHM3A', 1, 'ARTS 101', 'BSTHM 3A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'General Education', 'GE'),
  ('S1-ARTS101-BSTHM3B', 1, 'ARTS 101', 'BSTHM 3B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'General Education', 'GE'),
  ('S1-REL303A-BSTHM3A', 1, 'REL 303A', 'BSTHM 3A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Religious Education', 'RE'),
  ('S1-REL303A-BSTHM3B', 1, 'REL 303A', 'BSTHM 3B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Religious Education', 'RE'),
  ('S1-THM311-BSTHM4A', 1, 'THM 311', 'BSTHM 4A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-THM311-BSTHM4B', 1, 'THM 311', 'BSTHM 4B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-THM321-BSTHM4A', 1, 'THM 321', 'BSTHM 4A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-THM321-BSTHM4B', 1, 'THM 321', 'BSTHM 4B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-HIST201-BSTHM4A', 1, 'HIST 201', 'BSTHM 4A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Secondary Education', 'COE'),
  ('S1-HIST201-BSTHM4B', 1, 'HIST 201', 'BSTHM 4B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Secondary Education', 'COE'),
  ('S1-HIST220-BSTHM4A', 1, 'HIST 220', 'BSTHM 4A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Secondary Education', 'COE'),
  ('S1-HIST220-BSTHM4B', 1, 'HIST 220', 'BSTHM 4B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Secondary Education', 'COE'),
  ('S1-GAD171-BSTHM4A', 1, 'GAD 171', 'BSTHM 4A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Psychology', 'CSS'),
  ('S1-GAD171-BSTHM4B', 1, 'GAD 171', 'BSTHM 4B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Psychology', 'CSS'),
  ('S1-REL403-BSTHM4A', 1, 'REL 403', 'BSTHM 4A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Religious Education', 'RE'),
  ('S1-REL403-BSTHM4B', 1, 'REL 403', 'BSTHM 4B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Religious Education', 'RE'),
  ('S1-CRIM101-BSCrim1A', 1, 'CRIM 101', 'BSCrim 1A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-CRIM101-BSCrim1B', 1, 'CRIM 101', 'BSCrim 1B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-CLJ101-BSCrim1A', 1, 'CLJ 101', 'BSCrim 1A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-CLJ101-BSCrim1B', 1, 'CLJ 101', 'BSCrim 1B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-CRIM104-BSCrim1A', 1, 'CRIM 104', 'BSCrim 1A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-CRIM104-BSCrim1B', 1, 'CRIM 104', 'BSCrim 1B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-MATH180-BSCrim1A', 1, 'MATH 180', 'BSCrim 1A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Secondary Education', 'COE'),
  ('S1-MATH180-BSCrim1B', 1, 'MATH 180', 'BSCrim 1B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Secondary Education', 'COE'),
  ('S1-PSYC160-BSCrim1A', 1, 'PSYC 160', 'BSCrim 1A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Psychology', 'CSS'),
  ('S1-PSYC160-BSCrim1B', 1, 'PSYC 160', 'BSCrim 1B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Psychology', 'CSS'),
  ('S1-COMM120-BSCrim1A', 1, 'COMM 120', 'BSCrim 1A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Communication', 'CSS'),
  ('S1-COMM120-BSCrim1B', 1, 'COMM 120', 'BSCrim 1B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Communication', 'CSS'),
  ('S1-PE101-BSCrim1A', 1, 'PE 101', 'BSCrim 1A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'General Education', 'GE'),
  ('S1-PE101-BSCrim1B', 1, 'PE 101', 'BSCrim 1B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'General Education', 'GE'),
  ('S1-CWTS101-BSCrim1A', 1, 'CWTS 101', 'BSCrim 1A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'General Education', 'GE'),
  ('S1-CWTS101-BSCrim1B', 1, 'CWTS 101', 'BSCrim 1B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'General Education', 'GE'),
  ('S1-UNI103-BSCrim1A', 1, 'UNI 103', 'BSCrim 1A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Criminology', 'CCJPS'),
  ('S1-UNI103-BSCrim1B', 1, 'UNI 103', 'BSCrim 1B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Criminology', 'CCJPS'),
  ('S1-REL103A-BSCrim1A', 1, 'REL 103A', 'BSCrim 1A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Religious Education', 'RE'),
  ('S1-REL103A-BSCrim1B', 1, 'REL 103A', 'BSCrim 1B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Religious Education', 'RE'),
  ('S1-LEA101-BSCrim2A', 1, 'LEA 101', 'BSCrim 2A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-LEA101-BSCrim2B', 1, 'LEA 101', 'BSCrim 2B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-CDI101-BSCrim2A', 1, 'CDI 101', 'BSCrim 2A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-CDI101-BSCrim2B', 1, 'CDI 101', 'BSCrim 2B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-CA101-BSCrim2A', 1, 'CA 101', 'BSCrim 2A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-CA101-BSCrim2B', 1, 'CA 101', 'BSCrim 2B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-CLJ104-BSCrim2A', 1, 'CLJ 104', 'BSCrim 2A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-CLJ104-BSCrim2B', 1, 'CLJ 104', 'BSCrim 2B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-CLJ105-BSCrim2A', 1, 'CLJ 105', 'BSCrim 2A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-CLJ105-BSCrim2B', 1, 'CLJ 105', 'BSCrim 2B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-FOR102-BSCrim2A', 1, 'FOR 102', 'BSCrim 2A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-FOR102-BSCrim2B', 1, 'FOR 102', 'BSCrim 2B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-PE201-BSCrim2A', 1, 'PE 201', 'BSCrim 2A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'General Education', 'GE'),
  ('S1-PE201-BSCrim2B', 1, 'PE 201', 'BSCrim 2B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'General Education', 'GE'),
  ('S1-REL203A-BSCrim2A', 1, 'REL 203A', 'BSCrim 2A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Religious Education', 'RE'),
  ('S1-REL203A-BSCrim2B', 1, 'REL 203A', 'BSCrim 2B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Religious Education', 'RE'),
  ('S1-LEA104-BSCrim3A', 1, 'LEA 104', 'BSCrim 3A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-LEA104-BSCrim3B', 1, 'LEA 104', 'BSCrim 3B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-CDI104-BSCrim3A', 1, 'CDI 104', 'BSCrim 3A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-CDI104-BSCrim3B', 1, 'CDI 104', 'BSCrim 3B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-CDI105-BSCrim3A', 1, 'CDI 105', 'BSCrim 3A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-CDI105-BSCrim3B', 1, 'CDI 105', 'BSCrim 3B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-CLJ106-BSCrim3A', 1, 'CLJ 106', 'BSCrim 3A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-CLJ106-BSCrim3B', 1, 'CLJ 106', 'BSCrim 3B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-FOR104-BSCrim3A', 1, 'FOR 104', 'BSCrim 3A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-FOR104-BSCrim3B', 1, 'FOR 104', 'BSCrim 3B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-CRIM107-BSCrim3A', 1, 'CRIM 107', 'BSCrim 3A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-CRIM107-BSCrim3B', 1, 'CRIM 107', 'BSCrim 3B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-FIL207-BSCrim3A', 1, 'FIL 207', 'BSCrim 3A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Secondary Education', 'COE'),
  ('S1-FIL207-BSCrim3B', 1, 'FIL 207', 'BSCrim 3B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Secondary Education', 'COE'),
  ('S1-REL303A-BSCrim3A', 1, 'REL 303A', 'BSCrim 3A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Religious Education', 'RE'),
  ('S1-REL303A-BSCrim3B', 1, 'REL 303A', 'BSCrim 3B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Religious Education', 'RE'),
  ('S1-LEA106-BSCrim4A', 1, 'LEA 106', 'BSCrim 4A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-LEA106-BSCrim4B', 1, 'LEA 106', 'BSCrim 4B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-CDI108-BSCrim4A', 1, 'CDI 108', 'BSCrim 4A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-CDI108-BSCrim4B', 1, 'CDI 108', 'BSCrim 4B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-FOR106-BSCrim4A', 1, 'FOR 106', 'BSCrim 4A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-FOR106-BSCrim4B', 1, 'FOR 106', 'BSCrim 4B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-PHIL190-BSCrim4A', 1, 'PHIL 190', 'BSCrim 4A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'General Education', 'GE'),
  ('S1-PHIL190-BSCrim4B', 1, 'PHIL 190', 'BSCrim 4B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'General Education', 'GE'),
  ('S1-ARTS101-BSCrim4A', 1, 'ARTS 101', 'BSCrim 4A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'General Education', 'GE'),
  ('S1-ARTS101-BSCrim4B', 1, 'ARTS 101', 'BSCrim 4B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'General Education', 'GE'),
  ('S1-HIST201-BSCrim4A', 1, 'HIST 201', 'BSCrim 4A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Secondary Education', 'COE'),
  ('S1-HIST201-BSCrim4B', 1, 'HIST 201', 'BSCrim 4B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Secondary Education', 'COE'),
  ('S1-GAD171-BSCrim4A', 1, 'GAD 171', 'BSCrim 4A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Psychology', 'CSS'),
  ('S1-GAD171-BSCrim4B', 1, 'GAD 171', 'BSCrim 4B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Psychology', 'CSS'),
  ('S1-REL403-BSCrim4A', 1, 'REL 403', 'BSCrim 4A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Religious Education', 'RE'),
  ('S1-REL403-BSCrim4B', 1, 'REL 403', 'BSCrim 4B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Religious Education', 'RE'),
  ('S1-PAD101-ABPA1', 1, 'PAD 101', 'ABPA 1', 'ABPA', 'CCJPS', 'Public Administration', false, null, null, null),
  ('S1-SOCS195-ABPA1', 1, 'SOCS 195', 'ABPA 1', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'Economics', 'CSS'),
  ('S1-COMM120-ABPA1', 1, 'COMM 120', 'ABPA 1', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'Communication', 'CSS'),
  ('S1-MATH180-ABPA1', 1, 'MATH 180', 'ABPA 1', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'Secondary Education', 'COE'),
  ('S1-PE101-ABPA1', 1, 'PE 101', 'ABPA 1', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'General Education', 'GE'),
  ('S1-CWTS101-ABPA1', 1, 'CWTS 101', 'ABPA 1', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'General Education', 'GE'),
  ('S1-UNI103-ABPA1', 1, 'UNI 103', 'ABPA 1', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'Public Administration', 'CCJPS'),
  ('S1-REL103A-ABPA1', 1, 'REL 103A', 'ABPA 1', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'Religious Education', 'RE'),
  ('S1-PAD104-ABPA2', 1, 'PAD 104', 'ABPA 2', 'ABPA', 'CCJPS', 'Public Administration', false, null, null, null),
  ('S1-PAD105-ABPA2', 1, 'PAD 105', 'ABPA 2', 'ABPA', 'CCJPS', 'Public Administration', false, null, null, null),
  ('S1-PAD201-ABPA2', 1, 'PAD 201', 'ABPA 2', 'ABPA', 'CCJPS', 'Public Administration', false, null, null, null),
  ('S1-MATH350-ABPA2', 1, 'MATH 350', 'ABPA 2', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'Computer Science', 'CICS'),
  ('S1-PHIL190-ABPA2', 1, 'PHIL 190', 'ABPA 2', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'General Education', 'GE'),
  ('S1-PE201-ABPA2', 1, 'PE 201', 'ABPA 2', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'General Education', 'GE'),
  ('S1-REL203A-ABPA2', 1, 'REL 203A', 'ABPA 2', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'Religious Education', 'RE'),
  ('S1-PAD204-ABPA3', 1, 'PAD 204', 'ABPA 3', 'ABPA', 'CCJPS', 'Public Administration', false, null, null, null),
  ('S1-PAD206-ABPA3', 1, 'PAD 206', 'ABPA 3', 'ABPA', 'CCJPS', 'Public Administration', false, null, null, null),
  ('S1-PAD205-ABPA3', 1, 'PAD 205', 'ABPA 3', 'ABPA', 'CCJPS', 'Public Administration', false, null, null, null),
  ('S1-PAD305-ABPA3', 1, 'PAD 305', 'ABPA 3', 'ABPA', 'CCJPS', 'Public Administration', false, null, null, null),
  ('S1-PAD309-ABPA3', 1, 'PAD 309', 'ABPA 3', 'ABPA', 'CCJPS', 'Public Administration', false, null, null, null),
  ('S1-PHIL220-ABPA3', 1, 'PHIL 220', 'ABPA 3', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'General Education', 'GE'),
  ('S1-ARTS101-ABPA3', 1, 'ARTS 101', 'ABPA 3', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'General Education', 'GE'),
  ('S1-REL303A-ABPA3', 1, 'REL 303A', 'ABPA 3', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'Religious Education', 'RE'),
  ('S1-PAD410-ABPA4', 1, 'PAD 410', 'ABPA 4', 'ABPA', 'CCJPS', 'Public Administration', false, null, null, null),
  ('S1-HIST220-ABPA4', 1, 'HIST 220', 'ABPA 4', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'Secondary Education', 'COE'),
  ('S1-GAD171-ABPA4', 1, 'GAD 171', 'ABPA 4', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'Psychology', 'CSS'),
  ('S1-REL403-ABPA4', 1, 'REL 403', 'ABPA 4', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'Religious Education', 'RE'),
  ('S1-SW101-BSSW1', 1, 'SW 101', 'BSSW 1', 'BSSW', 'CCJPS', 'Social Work', false, null, null, null),
  ('S1-MATH180-BSSW1', 1, 'MATH 180', 'BSSW 1', 'BSSW', 'CCJPS', 'Social Work', true, null, 'Secondary Education', 'COE'),
  ('S1-PSYC160-BSSW1', 1, 'PSYC 160', 'BSSW 1', 'BSSW', 'CCJPS', 'Social Work', true, null, 'Psychology', 'CSS'),
  ('S1-COMM120-BSSW1', 1, 'COMM 120', 'BSSW 1', 'BSSW', 'CCJPS', 'Social Work', true, null, 'Communication', 'CSS'),
  ('S1-SOCS195-BSSW1', 1, 'SOCS 195', 'BSSW 1', 'BSSW', 'CCJPS', 'Social Work', true, null, 'Economics', 'CSS'),
  ('S1-PE101-BSSW1', 1, 'PE 101', 'BSSW 1', 'BSSW', 'CCJPS', 'Social Work', true, null, 'General Education', 'GE'),
  ('S1-CWTS101-BSSW1', 1, 'CWTS 101', 'BSSW 1', 'BSSW', 'CCJPS', 'Social Work', true, null, 'General Education', 'GE'),
  ('S1-UNI103-BSSW1', 1, 'UNI 103', 'BSSW 1', 'BSSW', 'CCJPS', 'Social Work', true, null, 'Social Work', 'CCJPS'),
  ('S1-REL103A-BSSW1', 1, 'REL 103A', 'BSSW 1', 'BSSW', 'CCJPS', 'Social Work', true, null, 'Religious Education', 'RE'),
  ('S1-SW201-BSSW2', 1, 'SW 201', 'BSSW 2', 'BSSW', 'CCJPS', 'Social Work', false, null, null, null),
  ('S1-SW202-BSSW2', 1, 'SW 202', 'BSSW 2', 'BSSW', 'CCJPS', 'Social Work', false, null, null, null),
  ('S1-SW205-BSSW2', 1, 'SW 205', 'BSSW 2', 'BSSW', 'CCJPS', 'Social Work', false, null, null, null),
  ('S1-MATH350-BSSW2', 1, 'MATH 350', 'BSSW 2', 'BSSW', 'CCJPS', 'Social Work', true, null, 'Computer Science', 'CICS'),
  ('S1-PE201-BSSW2', 1, 'PE 201', 'BSSW 2', 'BSSW', 'CCJPS', 'Social Work', true, null, 'General Education', 'GE'),
  ('S1-REL203A-BSSW2', 1, 'REL 203A', 'BSSW 2', 'BSSW', 'CCJPS', 'Social Work', true, null, 'Religious Education', 'RE'),
  ('S1-SW301-BSSW3', 1, 'SW 301', 'BSSW 3', 'BSSW', 'CCJPS', 'Social Work', false, null, null, null),
  ('S1-SW305-BSSW3', 1, 'SW 305', 'BSSW 3', 'BSSW', 'CCJPS', 'Social Work', false, null, null, null),
  ('S1-SW306-BSSW3', 1, 'SW 306', 'BSSW 3', 'BSSW', 'CCJPS', 'Social Work', false, null, null, null),
  ('S1-SW308-BSSW3', 1, 'SW 308', 'BSSW 3', 'BSSW', 'CCJPS', 'Social Work', false, null, null, null),
  ('S1-SW310-BSSW3', 1, 'SW 310', 'BSSW 3', 'BSSW', 'CCJPS', 'Social Work', false, null, null, null),
  ('S1-PHIL190-BSSW3', 1, 'PHIL 190', 'BSSW 3', 'BSSW', 'CCJPS', 'Social Work', true, null, 'General Education', 'GE'),
  ('S1-ARTS101-BSSW3', 1, 'ARTS 101', 'BSSW 3', 'BSSW', 'CCJPS', 'Social Work', true, null, 'General Education', 'GE'),
  ('S1-ENGL302-BSSW3', 1, 'ENGL 302', 'BSSW 3', 'BSSW', 'CCJPS', 'Social Work', true, null, 'General Education', 'GE'),
  ('S1-REL303A-BSSW3', 1, 'REL 303A', 'BSSW 3', 'BSSW', 'CCJPS', 'Social Work', true, null, 'Religious Education', 'RE'),
  ('S1-SW490-BSSW4', 1, 'SW 490', 'BSSW 4', 'BSSW', 'CCJPS', 'Social Work', false, null, null, null),
  ('S1-SW313-BSSW4', 1, 'SW 313', 'BSSW 4', 'BSSW', 'CCJPS', 'Social Work', false, null, null, null),
  ('S1-HIST220-BSSW4', 1, 'HIST 220', 'BSSW 4', 'BSSW', 'CCJPS', 'Social Work', true, null, 'Secondary Education', 'COE'),
  ('S1-REL403-BSSW4', 1, 'REL 403', 'BSSW 4', 'BSSW', 'CCJPS', 'Social Work', true, null, 'Religious Education', 'RE'),
  ('S1-CCS101-BSCS1A', 1, 'CCS 101', 'BSCS 1A', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-CCS101-BSCS1B', 1, 'CCS 101', 'BSCS 1B', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-CCS102-BSCS1A', 1, 'CCS 102', 'BSCS 1A', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-CCS102-BSCS1B', 1, 'CCS 102', 'BSCS 1B', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-CS110-BSCS1A', 1, 'CS 110', 'BSCS 1A', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-CS110-BSCS1B', 1, 'CS 110', 'BSCS 1B', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-SOCS195-BSCS1A', 1, 'SOCS 195', 'BSCS 1A', 'BSCS', 'CICS', 'Computer Science', true, null, 'Economics', 'CSS'),
  ('S1-SOCS195-BSCS1B', 1, 'SOCS 195', 'BSCS 1B', 'BSCS', 'CICS', 'Computer Science', true, null, 'Economics', 'CSS'),
  ('S1-MATH180-BSCS1A', 1, 'MATH 180', 'BSCS 1A', 'BSCS', 'CICS', 'Computer Science', true, null, 'Secondary Education', 'COE'),
  ('S1-MATH180-BSCS1B', 1, 'MATH 180', 'BSCS 1B', 'BSCS', 'CICS', 'Computer Science', true, null, 'Secondary Education', 'COE'),
  ('S1-PE101-BSCS1A', 1, 'PE 101', 'BSCS 1A', 'BSCS', 'CICS', 'Computer Science', true, null, 'General Education', 'GE'),
  ('S1-PE101-BSCS1B', 1, 'PE 101', 'BSCS 1B', 'BSCS', 'CICS', 'Computer Science', true, null, 'General Education', 'GE'),
  ('S1-CWTS101-BSCS1A', 1, 'CWTS 101', 'BSCS 1A', 'BSCS', 'CICS', 'Computer Science', true, null, 'General Education', 'GE'),
  ('S1-CWTS101-BSCS1B', 1, 'CWTS 101', 'BSCS 1B', 'BSCS', 'CICS', 'Computer Science', true, null, 'General Education', 'GE'),
  ('S1-UNI103-BSCS1A', 1, 'UNI 103', 'BSCS 1A', 'BSCS', 'CICS', 'Computer Science', true, null, 'Computer Science', 'CICS'),
  ('S1-UNI103-BSCS1B', 1, 'UNI 103', 'BSCS 1B', 'BSCS', 'CICS', 'Computer Science', true, null, 'Computer Science', 'CICS'),
  ('S1-REL103A-BSCS1A', 1, 'REL 103A', 'BSCS 1A', 'BSCS', 'CICS', 'Computer Science', true, null, 'Religious Education', 'RE'),
  ('S1-REL103A-BSCS1B', 1, 'REL 103A', 'BSCS 1B', 'BSCS', 'CICS', 'Computer Science', true, null, 'Religious Education', 'RE'),
  ('S1-CCS201-BSCS2A', 1, 'CCS 201', 'BSCS 2A', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-CCS201-BSCS2B', 1, 'CCS 201', 'BSCS 2B', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-CS230-BSCS2A', 1, 'CS 230', 'BSCS 2A', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-CS230-BSCS2B', 1, 'CS 230', 'BSCS 2B', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-CS220-BSCS2A', 1, 'CS 220', 'BSCS 2A', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-CS220-BSCS2B', 1, 'CS 220', 'BSCS 2B', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-CS240-BSCS2A', 1, 'CS 240', 'BSCS 2A', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-CS240-BSCS2B', 1, 'CS 240', 'BSCS 2B', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-PSYC160-BSCS2A', 1, 'PSYC 160', 'BSCS 2A', 'BSCS', 'CICS', 'Computer Science', true, null, 'Psychology', 'CSS'),
  ('S1-PSYC160-BSCS2B', 1, 'PSYC 160', 'BSCS 2B', 'BSCS', 'CICS', 'Computer Science', true, null, 'Psychology', 'CSS'),
  ('S1-PE201-BSCS2A', 1, 'PE 201', 'BSCS 2A', 'BSCS', 'CICS', 'Computer Science', true, null, 'General Education', 'GE'),
  ('S1-PE201-BSCS2B', 1, 'PE 201', 'BSCS 2B', 'BSCS', 'CICS', 'Computer Science', true, null, 'General Education', 'GE'),
  ('S1-REL203A-BSCS2A', 1, 'REL 203A', 'BSCS 2A', 'BSCS', 'CICS', 'Computer Science', true, null, 'Religious Education', 'RE'),
  ('S1-REL203A-BSCS2B', 1, 'REL 203A', 'BSCS 2B', 'BSCS', 'CICS', 'Computer Science', true, null, 'Religious Education', 'RE'),
  ('S1-CS310-BSCS3A', 1, 'CS 310', 'BSCS 3A', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-CS310-BSCS3B', 1, 'CS 310', 'BSCS 3B', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-CS330-BSCS3A', 1, 'CS 330', 'BSCS 3A', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-CS330-BSCS3B', 1, 'CS 330', 'BSCS 3B', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-CS350-BSCS3A', 1, 'CS 350', 'BSCS 3A', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-CS350-BSCS3B', 1, 'CS 350', 'BSCS 3B', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-CS390-BSCS3A', 1, 'CS 390', 'BSCS 3A', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-CS390-BSCS3B', 1, 'CS 390', 'BSCS 3B', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-MATH350-BSCS3A', 1, 'MATH 350', 'BSCS 3A', 'BSCS', 'CICS', 'Computer Science', true, null, 'Computer Science', 'CICS'),
  ('S1-MATH350-BSCS3B', 1, 'MATH 350', 'BSCS 3B', 'BSCS', 'CICS', 'Computer Science', true, null, 'Computer Science', 'CICS'),
  ('S1-ARTS101-BSCS3A', 1, 'ARTS 101', 'BSCS 3A', 'BSCS', 'CICS', 'Computer Science', true, null, 'General Education', 'GE'),
  ('S1-ARTS101-BSCS3B', 1, 'ARTS 101', 'BSCS 3B', 'BSCS', 'CICS', 'Computer Science', true, null, 'General Education', 'GE'),
  ('S1-PHIL190-BSCS3A', 1, 'PHIL 190', 'BSCS 3A', 'BSCS', 'CICS', 'Computer Science', true, null, 'General Education', 'GE'),
  ('S1-PHIL190-BSCS3B', 1, 'PHIL 190', 'BSCS 3B', 'BSCS', 'CICS', 'Computer Science', true, null, 'General Education', 'GE'),
  ('S1-REL303A-BSCS3A', 1, 'REL 303A', 'BSCS 3A', 'BSCS', 'CICS', 'Computer Science', true, null, 'Religious Education', 'RE'),
  ('S1-REL303A-BSCS3B', 1, 'REL 303A', 'BSCS 3B', 'BSCS', 'CICS', 'Computer Science', true, null, 'Religious Education', 'RE'),
  ('S1-CS430-BSCS4A', 1, 'CS 430', 'BSCS 4A', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-CS430-BSCS4B', 1, 'CS 430', 'BSCS 4B', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-CS410-BSCS4A', 1, 'CS 410', 'BSCS 4A', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-CS410-BSCS4B', 1, 'CS 410', 'BSCS 4B', 'BSCS', 'CICS', 'Computer Science', false, null, null, null),
  ('S1-HIST201-BSCS4A', 1, 'HIST 201', 'BSCS 4A', 'BSCS', 'CICS', 'Computer Science', true, null, 'Secondary Education', 'COE'),
  ('S1-HIST201-BSCS4B', 1, 'HIST 201', 'BSCS 4B', 'BSCS', 'CICS', 'Computer Science', true, null, 'Secondary Education', 'COE'),
  ('S1-HIST220-BSCS4A', 1, 'HIST 220', 'BSCS 4A', 'BSCS', 'CICS', 'Computer Science', true, null, 'Secondary Education', 'COE'),
  ('S1-HIST220-BSCS4B', 1, 'HIST 220', 'BSCS 4B', 'BSCS', 'CICS', 'Computer Science', true, null, 'Secondary Education', 'COE'),
  ('S1-ENGL302-BSCS4A', 1, 'ENGL 302', 'BSCS 4A', 'BSCS', 'CICS', 'Computer Science', true, null, 'General Education', 'GE'),
  ('S1-ENGL302-BSCS4B', 1, 'ENGL 302', 'BSCS 4B', 'BSCS', 'CICS', 'Computer Science', true, null, 'General Education', 'GE'),
  ('S1-GAD171-BSCS4A', 1, 'GAD 171', 'BSCS 4A', 'BSCS', 'CICS', 'Computer Science', true, null, 'Psychology', 'CSS'),
  ('S1-GAD171-BSCS4B', 1, 'GAD 171', 'BSCS 4B', 'BSCS', 'CICS', 'Computer Science', true, null, 'Psychology', 'CSS'),
  ('S1-REL403-BSCS4A', 1, 'REL 403', 'BSCS 4A', 'BSCS', 'CICS', 'Computer Science', true, null, 'Religious Education', 'RE'),
  ('S1-REL403-BSCS4B', 1, 'REL 403', 'BSCS 4B', 'BSCS', 'CICS', 'Computer Science', true, null, 'Religious Education', 'RE'),
  ('S1-CCS101-BSIT1A', 1, 'CCS 101', 'BSIT 1A', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-CCS101-BSIT1B', 1, 'CCS 101', 'BSIT 1B', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-CCS102-BSIT1A', 1, 'CCS 102', 'BSIT 1A', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-CCS102-BSIT1B', 1, 'CCS 102', 'BSIT 1B', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-IT110-BSIT1A', 1, 'IT 110', 'BSIT 1A', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-IT110-BSIT1B', 1, 'IT 110', 'BSIT 1B', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-COMM120-BSIT1A', 1, 'COMM 120', 'BSIT 1A', 'BSIT', 'CICS', 'Information Technology', true, null, 'Communication', 'CSS'),
  ('S1-COMM120-BSIT1B', 1, 'COMM 120', 'BSIT 1B', 'BSIT', 'CICS', 'Information Technology', true, null, 'Communication', 'CSS'),
  ('S1-MATH180-BSIT1A', 1, 'MATH 180', 'BSIT 1A', 'BSIT', 'CICS', 'Information Technology', true, null, 'Secondary Education', 'COE'),
  ('S1-MATH180-BSIT1B', 1, 'MATH 180', 'BSIT 1B', 'BSIT', 'CICS', 'Information Technology', true, null, 'Secondary Education', 'COE'),
  ('S1-PE101-BSIT1A', 1, 'PE 101', 'BSIT 1A', 'BSIT', 'CICS', 'Information Technology', true, null, 'General Education', 'GE'),
  ('S1-PE101-BSIT1B', 1, 'PE 101', 'BSIT 1B', 'BSIT', 'CICS', 'Information Technology', true, null, 'General Education', 'GE'),
  ('S1-CWTS101-BSIT1A', 1, 'CWTS 101', 'BSIT 1A', 'BSIT', 'CICS', 'Information Technology', true, null, 'General Education', 'GE'),
  ('S1-CWTS101-BSIT1B', 1, 'CWTS 101', 'BSIT 1B', 'BSIT', 'CICS', 'Information Technology', true, null, 'General Education', 'GE'),
  ('S1-UNI103-BSIT1A', 1, 'UNI 103', 'BSIT 1A', 'BSIT', 'CICS', 'Information Technology', true, null, 'Information Technology', 'CICS'),
  ('S1-UNI103-BSIT1B', 1, 'UNI 103', 'BSIT 1B', 'BSIT', 'CICS', 'Information Technology', true, null, 'Information Technology', 'CICS'),
  ('S1-REL103A-BSIT1A', 1, 'REL 103A', 'BSIT 1A', 'BSIT', 'CICS', 'Information Technology', true, null, 'Religious Education', 'RE'),
  ('S1-REL103A-BSIT1B', 1, 'REL 103A', 'BSIT 1B', 'BSIT', 'CICS', 'Information Technology', true, null, 'Religious Education', 'RE'),
  ('S1-CCS201-BSIT2A', 1, 'CCS 201', 'BSIT 2A', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-CCS201-BSIT2B', 1, 'CCS 201', 'BSIT 2B', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-IT210-BSIT2A', 1, 'IT 210', 'BSIT 2A', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-IT210-BSIT2B', 1, 'IT 210', 'BSIT 2B', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-IT230-BSIT2A', 1, 'IT 230', 'BSIT 2A', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-IT230-BSIT2B', 1, 'IT 230', 'BSIT 2B', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-STS180-BSIT2A', 1, 'STS 180', 'BSIT 2A', 'BSIT', 'CICS', 'Information Technology', true, null, 'Information Technology', 'CICS'),
  ('S1-STS180-BSIT2B', 1, 'STS 180', 'BSIT 2B', 'BSIT', 'CICS', 'Information Technology', true, null, 'Information Technology', 'CICS'),
  ('S1-MATH350-BSIT2A', 1, 'MATH 350', 'BSIT 2A', 'BSIT', 'CICS', 'Information Technology', true, null, 'Computer Science', 'CICS'),
  ('S1-MATH350-BSIT2B', 1, 'MATH 350', 'BSIT 2B', 'BSIT', 'CICS', 'Information Technology', true, null, 'Computer Science', 'CICS'),
  ('S1-SOCS195-BSIT2A', 1, 'SOCS 195', 'BSIT 2A', 'BSIT', 'CICS', 'Information Technology', true, null, 'Economics', 'CSS'),
  ('S1-SOCS195-BSIT2B', 1, 'SOCS 195', 'BSIT 2B', 'BSIT', 'CICS', 'Information Technology', true, null, 'Economics', 'CSS'),
  ('S1-PE201-BSIT2A', 1, 'PE 201', 'BSIT 2A', 'BSIT', 'CICS', 'Information Technology', true, null, 'General Education', 'GE'),
  ('S1-PE201-BSIT2B', 1, 'PE 201', 'BSIT 2B', 'BSIT', 'CICS', 'Information Technology', true, null, 'General Education', 'GE'),
  ('S1-REL203A-BSIT2A', 1, 'REL 203A', 'BSIT 2A', 'BSIT', 'CICS', 'Information Technology', true, null, 'Religious Education', 'RE'),
  ('S1-REL203A-BSIT2B', 1, 'REL 203A', 'BSIT 2B', 'BSIT', 'CICS', 'Information Technology', true, null, 'Religious Education', 'RE'),
  ('S1-IT250-BSIT3A', 1, 'IT 250', 'BSIT 3A', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-IT250-BSIT3B', 1, 'IT 250', 'BSIT 3B', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-IT310-BSIT3A', 1, 'IT 310', 'BSIT 3A', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-IT310-BSIT3B', 1, 'IT 310', 'BSIT 3B', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-IT330-BSIT3A', 1, 'IT 330', 'BSIT 3A', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-IT330-BSIT3B', 1, 'IT 330', 'BSIT 3B', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-IT360-BSIT3A', 1, 'IT 360', 'BSIT 3A', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-IT360-BSIT3B', 1, 'IT 360', 'BSIT 3B', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-IT370-BSIT3A', 1, 'IT 370', 'BSIT 3A', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-IT370-BSIT3B', 1, 'IT 370', 'BSIT 3B', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-ENGL302-BSIT3A', 1, 'ENGL 302', 'BSIT 3A', 'BSIT', 'CICS', 'Information Technology', true, null, 'General Education', 'GE'),
  ('S1-ENGL302-BSIT3B', 1, 'ENGL 302', 'BSIT 3B', 'BSIT', 'CICS', 'Information Technology', true, null, 'General Education', 'GE'),
  ('S1-PHIL190-BSIT3A', 1, 'PHIL 190', 'BSIT 3A', 'BSIT', 'CICS', 'Information Technology', true, null, 'General Education', 'GE'),
  ('S1-PHIL190-BSIT3B', 1, 'PHIL 190', 'BSIT 3B', 'BSIT', 'CICS', 'Information Technology', true, null, 'General Education', 'GE'),
  ('S1-REL303A-BSIT3A', 1, 'REL 303A', 'BSIT 3A', 'BSIT', 'CICS', 'Information Technology', true, null, 'Religious Education', 'RE'),
  ('S1-REL303A-BSIT3B', 1, 'REL 303A', 'BSIT 3B', 'BSIT', 'CICS', 'Information Technology', true, null, 'Religious Education', 'RE'),
  ('S1-IT430-BSIT4A', 1, 'IT 430', 'BSIT 4A', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-IT430-BSIT4B', 1, 'IT 430', 'BSIT 4B', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-IT390-BSIT4A', 1, 'IT 390', 'BSIT 4A', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-IT390-BSIT4B', 1, 'IT 390', 'BSIT 4B', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-IT410-BSIT4A', 1, 'IT 410', 'BSIT 4A', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-IT410-BSIT4B', 1, 'IT 410', 'BSIT 4B', 'BSIT', 'CICS', 'Information Technology', false, null, null, null),
  ('S1-HIST201-BSIT4A', 1, 'HIST 201', 'BSIT 4A', 'BSIT', 'CICS', 'Information Technology', true, null, 'Secondary Education', 'COE'),
  ('S1-HIST201-BSIT4B', 1, 'HIST 201', 'BSIT 4B', 'BSIT', 'CICS', 'Information Technology', true, null, 'Secondary Education', 'COE'),
  ('S1-HIST220-BSIT4A', 1, 'HIST 220', 'BSIT 4A', 'BSIT', 'CICS', 'Information Technology', true, null, 'Secondary Education', 'COE'),
  ('S1-HIST220-BSIT4B', 1, 'HIST 220', 'BSIT 4B', 'BSIT', 'CICS', 'Information Technology', true, null, 'Secondary Education', 'COE'),
  ('S1-GAD171-BSIT4A', 1, 'GAD 171', 'BSIT 4A', 'BSIT', 'CICS', 'Information Technology', true, null, 'Psychology', 'CSS'),
  ('S1-GAD171-BSIT4B', 1, 'GAD 171', 'BSIT 4B', 'BSIT', 'CICS', 'Information Technology', true, null, 'Psychology', 'CSS'),
  ('S1-REL403-BSIT4A', 1, 'REL 403', 'BSIT 4A', 'BSIT', 'CICS', 'Information Technology', true, null, 'Religious Education', 'RE'),
  ('S1-REL403-BSIT4B', 1, 'REL 403', 'BSIT 4B', 'BSIT', 'CICS', 'Information Technology', true, null, 'Religious Education', 'RE'),
  ('S1-LIS101-BLIS1', 1, 'LIS 101', 'BLIS 1', 'BLIS', 'CICS', 'Library and Information Science', false, null, null, null),
  ('S1-LIS102-BLIS1', 1, 'LIS 102', 'BLIS 1', 'BLIS', 'CICS', 'Library and Information Science', false, null, null, null),
  ('S1-COMM120-BLIS1', 1, 'COMM 120', 'BLIS 1', 'BLIS', 'CICS', 'Library and Information Science', true, null, 'Communication', 'CSS'),
  ('S1-MATH180-BLIS1', 1, 'MATH 180', 'BLIS 1', 'BLIS', 'CICS', 'Library and Information Science', true, null, 'Secondary Education', 'COE'),
  ('S1-PE101-BLIS1', 1, 'PE 101', 'BLIS 1', 'BLIS', 'CICS', 'Library and Information Science', true, null, 'General Education', 'GE'),
  ('S1-CWTS101-BLIS1', 1, 'CWTS 101', 'BLIS 1', 'BLIS', 'CICS', 'Library and Information Science', true, null, 'General Education', 'GE'),
  ('S1-UNI103-BLIS1', 1, 'UNI 103', 'BLIS 1', 'BLIS', 'CICS', 'Library and Information Science', true, null, 'Library and Information Science', 'CICS'),
  ('S1-REL103A-BLIS1', 1, 'REL 103A', 'BLIS 1', 'BLIS', 'CICS', 'Library and Information Science', true, null, 'Religious Education', 'RE'),
  ('S1-LIS201-BLIS2', 1, 'LIS 201', 'BLIS 2', 'BLIS', 'CICS', 'Library and Information Science', false, null, null, null),
  ('S1-LIS211-BLIS2', 1, 'LIS 211', 'BLIS 2', 'BLIS', 'CICS', 'Library and Information Science', false, null, null, null),
  ('S1-LIS230-BLIS2', 1, 'LIS 230', 'BLIS 2', 'BLIS', 'CICS', 'Library and Information Science', false, null, null, null),
  ('S1-SOCS195-BLIS2', 1, 'SOCS 195', 'BLIS 2', 'BLIS', 'CICS', 'Library and Information Science', true, null, 'Economics', 'CSS'),
  ('S1-MATH350-BLIS2', 1, 'MATH 350', 'BLIS 2', 'BLIS', 'CICS', 'Library and Information Science', true, null, 'Computer Science', 'CICS'),
  ('S1-ENGL302-BLIS2', 1, 'ENGL 302', 'BLIS 2', 'BLIS', 'CICS', 'Library and Information Science', true, null, 'General Education', 'GE'),
  ('S1-PE201-BLIS2', 1, 'PE 201', 'BLIS 2', 'BLIS', 'CICS', 'Library and Information Science', true, null, 'General Education', 'GE'),
  ('S1-REL203A-BLIS2', 1, 'REL 203A', 'BLIS 2', 'BLIS', 'CICS', 'Library and Information Science', true, null, 'Religious Education', 'RE'),
  ('S1-LIS220-BLIS3', 1, 'LIS 220', 'BLIS 3', 'BLIS', 'CICS', 'Library and Information Science', false, null, null, null),
  ('S1-LIS240-BLIS3', 1, 'LIS 240', 'BLIS 3', 'BLIS', 'CICS', 'Library and Information Science', false, null, null, null),
  ('S1-LIS301-BLIS3', 1, 'LIS 301', 'BLIS 3', 'BLIS', 'CICS', 'Library and Information Science', false, null, null, null),
  ('S1-LIS304-BLIS3', 1, 'LIS 304', 'BLIS 3', 'BLIS', 'CICS', 'Library and Information Science', false, null, null, null),
  ('S1-LIS330-BLIS3', 1, 'LIS 330', 'BLIS 3', 'BLIS', 'CICS', 'Library and Information Science', false, null, null, null),
  ('S1-PHIL190-BLIS3', 1, 'PHIL 190', 'BLIS 3', 'BLIS', 'CICS', 'Library and Information Science', true, null, 'General Education', 'GE'),
  ('S1-ARTS101-BLIS3', 1, 'ARTS 101', 'BLIS 3', 'BLIS', 'CICS', 'Library and Information Science', true, null, 'General Education', 'GE'),
  ('S1-REL303A-BLIS3', 1, 'REL 303A', 'BLIS 3', 'BLIS', 'CICS', 'Library and Information Science', true, null, 'Religious Education', 'RE'),
  ('S1-LIS410-BLIS4', 1, 'LIS 410', 'BLIS 4', 'BLIS', 'CICS', 'Library and Information Science', false, null, null, null),
  ('S1-LIS320-BLIS4', 1, 'LIS 320', 'BLIS 4', 'BLIS', 'CICS', 'Library and Information Science', false, null, null, null),
  ('S1-HIST220-BLIS4', 1, 'HIST 220', 'BLIS 4', 'BLIS', 'CICS', 'Library and Information Science', true, null, 'Secondary Education', 'COE'),
  ('S1-GAD171-BLIS4', 1, 'GAD 171', 'BLIS 4', 'BLIS', 'CICS', 'Library and Information Science', true, null, 'Psychology', 'CSS'),
  ('S1-REL403-BLIS4', 1, 'REL 403', 'BLIS 4', 'BLIS', 'CICS', 'Library and Information Science', true, null, 'Religious Education', 'RE'),
  ('S1-ED101-BEEd1', 1, 'ED 101', 'BEEd 1', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-ED102-BEEd1', 1, 'ED 102', 'BEEd 1', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-MATH180-BEEd1', 1, 'MATH 180', 'BEEd 1', 'BEEd', 'COE', 'Elementary Education', true, null, 'Secondary Education', 'COE'),
  ('S1-SOCS195-BEEd1', 1, 'SOCS 195', 'BEEd 1', 'BEEd', 'COE', 'Elementary Education', true, null, 'Economics', 'CSS'),
  ('S1-PE101-BEEd1', 1, 'PE 101', 'BEEd 1', 'BEEd', 'COE', 'Elementary Education', true, null, 'General Education', 'GE'),
  ('S1-CWTS101-BEEd1', 1, 'CWTS 101', 'BEEd 1', 'BEEd', 'COE', 'Elementary Education', true, null, 'General Education', 'GE'),
  ('S1-PSYC160-BEEd1', 1, 'PSYC 160', 'BEEd 1', 'BEEd', 'COE', 'Elementary Education', true, null, 'Psychology', 'CSS'),
  ('S1-UNI103-BEEd1', 1, 'UNI 103', 'BEEd 1', 'BEEd', 'COE', 'Elementary Education', true, null, 'Elementary Education', 'COE'),
  ('S1-REL103A-BEEd1', 1, 'REL 103A', 'BEEd 1', 'BEEd', 'COE', 'Elementary Education', true, null, 'Religious Education', 'RE'),
  ('S1-ED201-BEEd2', 1, 'ED 201', 'BEEd 2', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-ED202-BEEd2', 1, 'ED 202', 'BEEd 2', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-ED204-BEEd2', 1, 'ED 204', 'BEEd 2', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-EED101-BEEd2', 1, 'EED 101', 'BEEd 2', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-EED140-BEEd2', 1, 'EED 140', 'BEEd 2', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-EED150-BEEd2', 1, 'EED 150', 'BEEd 2', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-PE201-BEEd2', 1, 'PE 201', 'BEEd 2', 'BEEd', 'COE', 'Elementary Education', true, null, 'General Education', 'GE'),
  ('S1-REL203A-BEEd2', 1, 'REL 203A', 'BEEd 2', 'BEEd', 'COE', 'Elementary Education', true, null, 'Religious Education', 'RE'),
  ('S1-ED301-BEEd3', 1, 'ED 301', 'BEEd 3', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-ED303-BEEd3', 1, 'ED 303', 'BEEd 3', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-ED304-BEEd3', 1, 'ED 304', 'BEEd 3', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-EED102-BEEd3', 1, 'EED 102', 'BEEd 3', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-EED151-BEEd3', 1, 'EED 151', 'BEEd 3', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-EED160-BEEd3', 1, 'EED 160', 'BEEd 3', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-EED180-BEEd3', 1, 'EED 180', 'BEEd 3', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-PHIL190-BEEd3', 1, 'PHIL 190', 'BEEd 3', 'BEEd', 'COE', 'Elementary Education', true, null, 'General Education', 'GE'),
  ('S1-REL303A-BEEd3', 1, 'REL 303A', 'BEEd 3', 'BEEd', 'COE', 'Elementary Education', true, null, 'Religious Education', 'RE'),
  ('S1-ED401-BEEd4', 1, 'ED 401', 'BEEd 4', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-ED402-BEEd4', 1, 'ED 402', 'BEEd 4', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-EED181-BEEd4', 1, 'EED 181', 'BEEd 4', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-ENGL302-BEEd4', 1, 'ENGL 302', 'BEEd 4', 'BEEd', 'COE', 'Elementary Education', true, null, 'General Education', 'GE'),
  ('S1-HIST201-BEEd4', 1, 'HIST 201', 'BEEd 4', 'BEEd', 'COE', 'Elementary Education', true, null, 'Secondary Education', 'COE'),
  ('S1-HIST220-BEEd4', 1, 'HIST 220', 'BEEd 4', 'BEEd', 'COE', 'Elementary Education', true, null, 'Secondary Education', 'COE'),
  ('S1-GAD171-BEEd4', 1, 'GAD 171', 'BEEd 4', 'BEEd', 'COE', 'Elementary Education', true, null, 'Psychology', 'CSS'),
  ('S1-REL403-BEEd4', 1, 'REL 403', 'BEEd 4', 'BEEd', 'COE', 'Elementary Education', true, null, 'Religious Education', 'RE'),
  ('S1-ED101-BSEd-E1', 1, 'ED 101', 'BSEd-E 1', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEE101-BSEd-E1', 1, 'SEE 101', 'BSEd-E 1', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-MATH180-BSEd-E1', 1, 'MATH 180', 'BSEd-E 1', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'Secondary Education', 'COE'),
  ('S1-PSYC160-BSEd-E1', 1, 'PSYC 160', 'BSEd-E 1', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'Psychology', 'CSS'),
  ('S1-COMM120-BSEd-E1', 1, 'COMM 120', 'BSEd-E 1', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'Communication', 'CSS'),
  ('S1-CWTS101-BSEd-E1', 1, 'CWTS 101', 'BSEd-E 1', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-PE101-BSEd-E1', 1, 'PE 101', 'BSEd-E 1', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-UNI103-BSEd-E1', 1, 'UNI 103', 'BSEd-E 1', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'Secondary Education', 'COE'),
  ('S1-REL103A-BSEd-E1', 1, 'REL 103A', 'BSEd-E 1', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'Religious Education', 'RE'),
  ('S1-ED201-BSEd-E2', 1, 'ED 201', 'BSEd-E 2', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-ED202-BSEd-E2', 1, 'ED 202', 'BSEd-E 2', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-ED204-BSEd-E2', 1, 'ED 204', 'BSEd-E 2', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEE201-BSEd-E2', 1, 'SEE 201', 'BSEd-E 2', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEE202-BSEd-E2', 1, 'SEE 202', 'BSEd-E 2', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-MATH350-BSEd-E2', 1, 'MATH 350', 'BSEd-E 2', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'Computer Science', 'CICS'),
  ('S1-PHIL190-BSEd-E2', 1, 'PHIL 190', 'BSEd-E 2', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-PE201-BSEd-E2', 1, 'PE 201', 'BSEd-E 2', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-REL203A-BSEd-E2', 1, 'REL 203A', 'BSEd-E 2', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'Religious Education', 'RE'),
  ('S1-ED301-BSEd-E3', 1, 'ED 301', 'BSEd-E 3', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-ED303-BSEd-E3', 1, 'ED 303', 'BSEd-E 3', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-ED304-BSEd-E3', 1, 'ED 304', 'BSEd-E 3', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEE301-BSEd-E3', 1, 'SEE 301', 'BSEd-E 3', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEE302-BSEd-E3', 1, 'SEE 302', 'BSEd-E 3', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEE303-BSEd-E3', 1, 'SEE 303', 'BSEd-E 3', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-PHIL220-BSEd-E3', 1, 'PHIL 220', 'BSEd-E 3', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-ENGL302-BSEd-E3', 1, 'ENGL 302', 'BSEd-E 3', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-REL303A-BSEd-E3', 1, 'REL 303A', 'BSEd-E 3', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'Religious Education', 'RE'),
  ('S1-ED401-BSEd-E4', 1, 'ED 401', 'BSEd-E 4', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-ED402-BSEd-E4', 1, 'ED 402', 'BSEd-E 4', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEE401-BSEd-E4', 1, 'SEE 401', 'BSEd-E 4', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEE402-BSEd-E4', 1, 'SEE 402', 'BSEd-E 4', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEE403-BSEd-E4', 1, 'SEE 403', 'BSEd-E 4', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEE404-BSEd-E4', 1, 'SEE 404', 'BSEd-E 4', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEE405-BSEd-E4', 1, 'SEE 405', 'BSEd-E 4', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-REL403-BSEd-E4', 1, 'REL 403', 'BSEd-E 4', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'Religious Education', 'RE'),
  ('S1-ED101-BSEd-M1', 1, 'ED 101', 'BSEd-M 1', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEM101-BSEd-M1', 1, 'SEM 101', 'BSEd-M 1', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-MATH180-BSEd-M1', 1, 'MATH 180', 'BSEd-M 1', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'Secondary Education', 'COE'),
  ('S1-PSYC160-BSEd-M1', 1, 'PSYC 160', 'BSEd-M 1', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'Psychology', 'CSS'),
  ('S1-COMM120-BSEd-M1', 1, 'COMM 120', 'BSEd-M 1', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'Communication', 'CSS'),
  ('S1-CWTS101-BSEd-M1', 1, 'CWTS 101', 'BSEd-M 1', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-PE101-BSEd-M1', 1, 'PE 101', 'BSEd-M 1', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-UNI103-BSEd-M1', 1, 'UNI 103', 'BSEd-M 1', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'Secondary Education', 'COE'),
  ('S1-REL103A-BSEd-M1', 1, 'REL 103A', 'BSEd-M 1', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'Religious Education', 'RE'),
  ('S1-ED201-BSEd-M2', 1, 'ED 201', 'BSEd-M 2', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-ED202-BSEd-M2', 1, 'ED 202', 'BSEd-M 2', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-ED204-BSEd-M2', 1, 'ED 204', 'BSEd-M 2', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEM201-BSEd-M2', 1, 'SEM 201', 'BSEd-M 2', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEM202-BSEd-M2', 1, 'SEM 202', 'BSEd-M 2', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-MATH350-BSEd-M2', 1, 'MATH 350', 'BSEd-M 2', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'Computer Science', 'CICS'),
  ('S1-PHIL190-BSEd-M2', 1, 'PHIL 190', 'BSEd-M 2', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-PE201-BSEd-M2', 1, 'PE 201', 'BSEd-M 2', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-REL203A-BSEd-M2', 1, 'REL 203A', 'BSEd-M 2', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'Religious Education', 'RE'),
  ('S1-ED301-BSEd-M3', 1, 'ED 301', 'BSEd-M 3', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-ED303-BSEd-M3', 1, 'ED 303', 'BSEd-M 3', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-ED304-BSEd-M3', 1, 'ED 304', 'BSEd-M 3', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEM301-BSEd-M3', 1, 'SEM 301', 'BSEd-M 3', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEM302-BSEd-M3', 1, 'SEM 302', 'BSEd-M 3', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEM303-BSEd-M3', 1, 'SEM 303', 'BSEd-M 3', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-PHIL220-BSEd-M3', 1, 'PHIL 220', 'BSEd-M 3', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-ENGL302-BSEd-M3', 1, 'ENGL 302', 'BSEd-M 3', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-REL303A-BSEd-M3', 1, 'REL 303A', 'BSEd-M 3', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'Religious Education', 'RE'),
  ('S1-ED401-BSEd-M4', 1, 'ED 401', 'BSEd-M 4', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-ED402-BSEd-M4', 1, 'ED 402', 'BSEd-M 4', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEM401-BSEd-M4', 1, 'SEM 401', 'BSEd-M 4', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEM402-BSEd-M4', 1, 'SEM 402', 'BSEd-M 4', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEM403-BSEd-M4', 1, 'SEM 403', 'BSEd-M 4', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEM404-BSEd-M4', 1, 'SEM 404', 'BSEd-M 4', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEM405-BSEd-M4', 1, 'SEM 405', 'BSEd-M 4', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-REL403-BSEd-M4', 1, 'REL 403', 'BSEd-M 4', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'Religious Education', 'RE'),
  ('S1-ED101-BSEd-SS1', 1, 'ED 101', 'BSEd-SS 1', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SES101-BSEd-SS1', 1, 'SES 101', 'BSEd-SS 1', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-MATH180-BSEd-SS1', 1, 'MATH 180', 'BSEd-SS 1', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'Secondary Education', 'COE'),
  ('S1-PSYC160-BSEd-SS1', 1, 'PSYC 160', 'BSEd-SS 1', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'Psychology', 'CSS'),
  ('S1-COMM120-BSEd-SS1', 1, 'COMM 120', 'BSEd-SS 1', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'Communication', 'CSS'),
  ('S1-CWTS101-BSEd-SS1', 1, 'CWTS 101', 'BSEd-SS 1', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-PE101-BSEd-SS1', 1, 'PE 101', 'BSEd-SS 1', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-UNI103-BSEd-SS1', 1, 'UNI 103', 'BSEd-SS 1', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'Secondary Education', 'COE'),
  ('S1-REL103A-BSEd-SS1', 1, 'REL 103A', 'BSEd-SS 1', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'Religious Education', 'RE'),
  ('S1-ED201-BSEd-SS2', 1, 'ED 201', 'BSEd-SS 2', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-ED202-BSEd-SS2', 1, 'ED 202', 'BSEd-SS 2', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-ED204-BSEd-SS2', 1, 'ED 204', 'BSEd-SS 2', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SES201-BSEd-SS2', 1, 'SES 201', 'BSEd-SS 2', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SES202-BSEd-SS2', 1, 'SES 202', 'BSEd-SS 2', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-MATH350-BSEd-SS2', 1, 'MATH 350', 'BSEd-SS 2', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'Computer Science', 'CICS'),
  ('S1-PHIL190-BSEd-SS2', 1, 'PHIL 190', 'BSEd-SS 2', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-PE201-BSEd-SS2', 1, 'PE 201', 'BSEd-SS 2', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-REL203A-BSEd-SS2', 1, 'REL 203A', 'BSEd-SS 2', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'Religious Education', 'RE'),
  ('S1-ED301-BSEd-SS3', 1, 'ED 301', 'BSEd-SS 3', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-ED303-BSEd-SS3', 1, 'ED 303', 'BSEd-SS 3', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-ED304-BSEd-SS3', 1, 'ED 304', 'BSEd-SS 3', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SES301-BSEd-SS3', 1, 'SES 301', 'BSEd-SS 3', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SES302-BSEd-SS3', 1, 'SES 302', 'BSEd-SS 3', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SES303-BSEd-SS3', 1, 'SES 303', 'BSEd-SS 3', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-PHIL220-BSEd-SS3', 1, 'PHIL 220', 'BSEd-SS 3', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-ENGL302-BSEd-SS3', 1, 'ENGL 302', 'BSEd-SS 3', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-REL303A-BSEd-SS3', 1, 'REL 303A', 'BSEd-SS 3', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'Religious Education', 'RE'),
  ('S1-ED401-BSEd-SS4', 1, 'ED 401', 'BSEd-SS 4', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-ED402-BSEd-SS4', 1, 'ED 402', 'BSEd-SS 4', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SES401-BSEd-SS4', 1, 'SES 401', 'BSEd-SS 4', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SES402-BSEd-SS4', 1, 'SES 402', 'BSEd-SS 4', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SES403-BSEd-SS4', 1, 'SES 403', 'BSEd-SS 4', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SES404-BSEd-SS4', 1, 'SES 404', 'BSEd-SS 4', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SES405-BSEd-SS4', 1, 'SES 405', 'BSEd-SS 4', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-REL403-BSEd-SS4', 1, 'REL 403', 'BSEd-SS 4', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'Religious Education', 'RE'),
  ('S1-ED101-BSEd-F1', 1, 'ED 101', 'BSEd-F 1', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEF101-BSEd-F1', 1, 'SEF 101', 'BSEd-F 1', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-MATH180-BSEd-F1', 1, 'MATH 180', 'BSEd-F 1', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'Secondary Education', 'COE'),
  ('S1-PSYC160-BSEd-F1', 1, 'PSYC 160', 'BSEd-F 1', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'Psychology', 'CSS'),
  ('S1-COMM120-BSEd-F1', 1, 'COMM 120', 'BSEd-F 1', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'Communication', 'CSS'),
  ('S1-CWTS101-BSEd-F1', 1, 'CWTS 101', 'BSEd-F 1', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-PE101-BSEd-F1', 1, 'PE 101', 'BSEd-F 1', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-UNI103-BSEd-F1', 1, 'UNI 103', 'BSEd-F 1', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'Secondary Education', 'COE'),
  ('S1-REL103A-BSEd-F1', 1, 'REL 103A', 'BSEd-F 1', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'Religious Education', 'RE'),
  ('S1-ED201-BSEd-F2', 1, 'ED 201', 'BSEd-F 2', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-ED202-BSEd-F2', 1, 'ED 202', 'BSEd-F 2', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-ED204-BSEd-F2', 1, 'ED 204', 'BSEd-F 2', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEF201-BSEd-F2', 1, 'SEF 201', 'BSEd-F 2', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEF202-BSEd-F2', 1, 'SEF 202', 'BSEd-F 2', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-MATH350-BSEd-F2', 1, 'MATH 350', 'BSEd-F 2', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'Computer Science', 'CICS'),
  ('S1-PHIL190-BSEd-F2', 1, 'PHIL 190', 'BSEd-F 2', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-PE201-BSEd-F2', 1, 'PE 201', 'BSEd-F 2', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-REL203A-BSEd-F2', 1, 'REL 203A', 'BSEd-F 2', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'Religious Education', 'RE'),
  ('S1-ED301-BSEd-F3', 1, 'ED 301', 'BSEd-F 3', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-ED303-BSEd-F3', 1, 'ED 303', 'BSEd-F 3', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-ED304-BSEd-F3', 1, 'ED 304', 'BSEd-F 3', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEF301-BSEd-F3', 1, 'SEF 301', 'BSEd-F 3', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEF302-BSEd-F3', 1, 'SEF 302', 'BSEd-F 3', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEF303-BSEd-F3', 1, 'SEF 303', 'BSEd-F 3', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-PHIL220-BSEd-F3', 1, 'PHIL 220', 'BSEd-F 3', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-ENGL302-BSEd-F3', 1, 'ENGL 302', 'BSEd-F 3', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-REL303A-BSEd-F3', 1, 'REL 303A', 'BSEd-F 3', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'Religious Education', 'RE'),
  ('S1-ED401-BSEd-F4', 1, 'ED 401', 'BSEd-F 4', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-ED402-BSEd-F4', 1, 'ED 402', 'BSEd-F 4', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEF401-BSEd-F4', 1, 'SEF 401', 'BSEd-F 4', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEF402-BSEd-F4', 1, 'SEF 402', 'BSEd-F 4', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEF403-BSEd-F4', 1, 'SEF 403', 'BSEd-F 4', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEF404-BSEd-F4', 1, 'SEF 404', 'BSEd-F 4', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-SEF405-BSEd-F4', 1, 'SEF 405', 'BSEd-F 4', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-REL403-BSEd-F4', 1, 'REL 403', 'BSEd-F 4', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'Religious Education', 'RE'),
  ('S1-PSYC101-BSP1A', 1, 'PSYC 101', 'BSP 1A', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-PSYC101-BSP1B', 1, 'PSYC 101', 'BSP 1B', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-PSYC160-BSP1A', 1, 'PSYC 160', 'BSP 1A', 'BSP', 'CSS', 'Psychology', true, null, 'Psychology', 'CSS'),
  ('S1-PSYC160-BSP1B', 1, 'PSYC 160', 'BSP 1B', 'BSP', 'CSS', 'Psychology', true, null, 'Psychology', 'CSS'),
  ('S1-MATH180-BSP1A', 1, 'MATH 180', 'BSP 1A', 'BSP', 'CSS', 'Psychology', true, null, 'Secondary Education', 'COE'),
  ('S1-MATH180-BSP1B', 1, 'MATH 180', 'BSP 1B', 'BSP', 'CSS', 'Psychology', true, null, 'Secondary Education', 'COE'),
  ('S1-STS180-BSP1A', 1, 'STS 180', 'BSP 1A', 'BSP', 'CSS', 'Psychology', true, null, 'Information Technology', 'CICS'),
  ('S1-STS180-BSP1B', 1, 'STS 180', 'BSP 1B', 'BSP', 'CSS', 'Psychology', true, null, 'Information Technology', 'CICS'),
  ('S1-PE101-BSP1A', 1, 'PE 101', 'BSP 1A', 'BSP', 'CSS', 'Psychology', true, null, 'General Education', 'GE'),
  ('S1-PE101-BSP1B', 1, 'PE 101', 'BSP 1B', 'BSP', 'CSS', 'Psychology', true, null, 'General Education', 'GE'),
  ('S1-CWTS101-BSP1A', 1, 'CWTS 101', 'BSP 1A', 'BSP', 'CSS', 'Psychology', true, null, 'General Education', 'GE'),
  ('S1-CWTS101-BSP1B', 1, 'CWTS 101', 'BSP 1B', 'BSP', 'CSS', 'Psychology', true, null, 'General Education', 'GE'),
  ('S1-UNI103-BSP1A', 1, 'UNI 103', 'BSP 1A', 'BSP', 'CSS', 'Psychology', true, null, 'Psychology', 'CSS'),
  ('S1-UNI103-BSP1B', 1, 'UNI 103', 'BSP 1B', 'BSP', 'CSS', 'Psychology', true, null, 'Psychology', 'CSS'),
  ('S1-REL103A-BSP1A', 1, 'REL 103A', 'BSP 1A', 'BSP', 'CSS', 'Psychology', true, null, 'Religious Education', 'RE'),
  ('S1-REL103A-BSP1B', 1, 'REL 103A', 'BSP 1B', 'BSP', 'CSS', 'Psychology', true, null, 'Religious Education', 'RE'),
  ('S1-PSYC130-BSP2A', 1, 'PSYC 130', 'BSP 2A', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-PSYC130-BSP2B', 1, 'PSYC 130', 'BSP 2B', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-PSYC210-BSP2A', 1, 'PSYC 210', 'BSP 2A', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-PSYC210-BSP2B', 1, 'PSYC 210', 'BSP 2B', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-PSYC220-BSP2A', 1, 'PSYC 220', 'BSP 2A', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-PSYC220-BSP2B', 1, 'PSYC 220', 'BSP 2B', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-SOCS195-BSP2A', 1, 'SOCS 195', 'BSP 2A', 'BSP', 'CSS', 'Psychology', true, null, 'Economics', 'CSS'),
  ('S1-SOCS195-BSP2B', 1, 'SOCS 195', 'BSP 2B', 'BSP', 'CSS', 'Psychology', true, null, 'Economics', 'CSS'),
  ('S1-PHIL190-BSP2A', 1, 'PHIL 190', 'BSP 2A', 'BSP', 'CSS', 'Psychology', true, null, 'General Education', 'GE'),
  ('S1-PHIL190-BSP2B', 1, 'PHIL 190', 'BSP 2B', 'BSP', 'CSS', 'Psychology', true, null, 'General Education', 'GE'),
  ('S1-PE201-BSP2A', 1, 'PE 201', 'BSP 2A', 'BSP', 'CSS', 'Psychology', true, null, 'General Education', 'GE'),
  ('S1-PE201-BSP2B', 1, 'PE 201', 'BSP 2B', 'BSP', 'CSS', 'Psychology', true, null, 'General Education', 'GE'),
  ('S1-REL203A-BSP2A', 1, 'REL 203A', 'BSP 2A', 'BSP', 'CSS', 'Psychology', true, null, 'Religious Education', 'RE'),
  ('S1-REL203A-BSP2B', 1, 'REL 203A', 'BSP 2B', 'BSP', 'CSS', 'Psychology', true, null, 'Religious Education', 'RE'),
  ('S1-PSYC240-BSP3C', 1, 'PSYC 240', 'BSP 3C', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-PSYC240-BSP3IO', 1, 'PSYC 240', 'BSP 3IO', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-PSYC280-BSP3C', 1, 'PSYC 280', 'BSP 3C', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-PSYC280-BSP3IO', 1, 'PSYC 280', 'BSP 3IO', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-PSYC310-BSP3C', 1, 'PSYC 310', 'BSP 3C', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-PSYC310-BSP3IO', 1, 'PSYC 310', 'BSP 3IO', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-PSYC320-BSP3C', 1, 'PSYC 320', 'BSP 3C', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-PSYC320-BSP3IO', 1, 'PSYC 320', 'BSP 3IO', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-PSYC351-BSP3C', 1, 'PSYC 351', 'BSP 3C', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-PSYC361-BSP3IO', 1, 'PSYC 361', 'BSP 3IO', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-HIST201-BSP3C', 1, 'HIST 201', 'BSP 3C', 'BSP', 'CSS', 'Psychology', true, null, 'Secondary Education', 'COE'),
  ('S1-HIST201-BSP3IO', 1, 'HIST 201', 'BSP 3IO', 'BSP', 'CSS', 'Psychology', true, null, 'Secondary Education', 'COE'),
  ('S1-ARTS101-BSP3C', 1, 'ARTS 101', 'BSP 3C', 'BSP', 'CSS', 'Psychology', true, null, 'General Education', 'GE'),
  ('S1-ARTS101-BSP3IO', 1, 'ARTS 101', 'BSP 3IO', 'BSP', 'CSS', 'Psychology', true, null, 'General Education', 'GE'),
  ('S1-REL303A-BSP3C', 1, 'REL 303A', 'BSP 3C', 'BSP', 'CSS', 'Psychology', true, null, 'Religious Education', 'RE'),
  ('S1-REL303A-BSP3IO', 1, 'REL 303A', 'BSP 3IO', 'BSP', 'CSS', 'Psychology', true, null, 'Religious Education', 'RE'),
  ('S1-PSYC410-BSP4C', 1, 'PSYC 410', 'BSP 4C', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-PSYC410-BSP4IO', 1, 'PSYC 410', 'BSP 4IO', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-PSYC451-BSP4C', 1, 'PSYC 451', 'BSP 4C', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-PSYC452-BSP4C', 1, 'PSYC 452', 'BSP 4C', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-PSYC461-BSP4IO', 1, 'PSYC 461', 'BSP 4IO', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-PSYC462-BSP4IO', 1, 'PSYC 462', 'BSP 4IO', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-REL403-BSP4C', 1, 'REL 403', 'BSP 4C', 'BSP', 'CSS', 'Psychology', true, null, 'Religious Education', 'RE'),
  ('S1-REL403-BSP4IO', 1, 'REL 403', 'BSP 4IO', 'BSP', 'CSS', 'Psychology', true, null, 'Religious Education', 'RE'),
  ('S1-POLS101-ABPS1A', 1, 'POLS 101', 'ABPS 1A', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-POLS101-ABPS1B', 1, 'POLS 101', 'ABPS 1B', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-SOCS195-ABPS1A', 1, 'SOCS 195', 'ABPS 1A', 'ABPS', 'CSS', 'Political Science', true, null, 'Economics', 'CSS'),
  ('S1-SOCS195-ABPS1B', 1, 'SOCS 195', 'ABPS 1B', 'ABPS', 'CSS', 'Political Science', true, null, 'Economics', 'CSS'),
  ('S1-COMM120-ABPS1A', 1, 'COMM 120', 'ABPS 1A', 'ABPS', 'CSS', 'Political Science', true, null, 'Communication', 'CSS'),
  ('S1-COMM120-ABPS1B', 1, 'COMM 120', 'ABPS 1B', 'ABPS', 'CSS', 'Political Science', true, null, 'Communication', 'CSS'),
  ('S1-MATH180-ABPS1A', 1, 'MATH 180', 'ABPS 1A', 'ABPS', 'CSS', 'Political Science', true, null, 'Secondary Education', 'COE'),
  ('S1-MATH180-ABPS1B', 1, 'MATH 180', 'ABPS 1B', 'ABPS', 'CSS', 'Political Science', true, null, 'Secondary Education', 'COE'),
  ('S1-PE101-ABPS1A', 1, 'PE 101', 'ABPS 1A', 'ABPS', 'CSS', 'Political Science', true, null, 'General Education', 'GE'),
  ('S1-PE101-ABPS1B', 1, 'PE 101', 'ABPS 1B', 'ABPS', 'CSS', 'Political Science', true, null, 'General Education', 'GE'),
  ('S1-CWTS101-ABPS1A', 1, 'CWTS 101', 'ABPS 1A', 'ABPS', 'CSS', 'Political Science', true, null, 'General Education', 'GE'),
  ('S1-CWTS101-ABPS1B', 1, 'CWTS 101', 'ABPS 1B', 'ABPS', 'CSS', 'Political Science', true, null, 'General Education', 'GE'),
  ('S1-UNI103-ABPS1A', 1, 'UNI 103', 'ABPS 1A', 'ABPS', 'CSS', 'Political Science', true, null, 'Political Science', 'CSS'),
  ('S1-UNI103-ABPS1B', 1, 'UNI 103', 'ABPS 1B', 'ABPS', 'CSS', 'Political Science', true, null, 'Political Science', 'CSS'),
  ('S1-REL103A-ABPS1A', 1, 'REL 103A', 'ABPS 1A', 'ABPS', 'CSS', 'Political Science', true, null, 'Religious Education', 'RE'),
  ('S1-REL103A-ABPS1B', 1, 'REL 103A', 'ABPS 1B', 'ABPS', 'CSS', 'Political Science', true, null, 'Religious Education', 'RE'),
  ('S1-POLS210-ABPS2A', 1, 'POLS 210', 'ABPS 2A', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-POLS210-ABPS2B', 1, 'POLS 210', 'ABPS 2B', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-POLS220-ABPS2A', 1, 'POLS 220', 'ABPS 2A', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-POLS220-ABPS2B', 1, 'POLS 220', 'ABPS 2B', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-LGLS201-ABPS2A', 1, 'LGLS 201', 'ABPS 2A', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-LGLS201-ABPS2B', 1, 'LGLS 201', 'ABPS 2B', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-PSYC160-ABPS2A', 1, 'PSYC 160', 'ABPS 2A', 'ABPS', 'CSS', 'Political Science', true, null, 'Psychology', 'CSS'),
  ('S1-PSYC160-ABPS2B', 1, 'PSYC 160', 'ABPS 2B', 'ABPS', 'CSS', 'Political Science', true, null, 'Psychology', 'CSS'),
  ('S1-PHIL190-ABPS2A', 1, 'PHIL 190', 'ABPS 2A', 'ABPS', 'CSS', 'Political Science', true, null, 'General Education', 'GE'),
  ('S1-PHIL190-ABPS2B', 1, 'PHIL 190', 'ABPS 2B', 'ABPS', 'CSS', 'Political Science', true, null, 'General Education', 'GE'),
  ('S1-PE201-ABPS2A', 1, 'PE 201', 'ABPS 2A', 'ABPS', 'CSS', 'Political Science', true, null, 'General Education', 'GE'),
  ('S1-PE201-ABPS2B', 1, 'PE 201', 'ABPS 2B', 'ABPS', 'CSS', 'Political Science', true, null, 'General Education', 'GE'),
  ('S1-REL203A-ABPS2A', 1, 'REL 203A', 'ABPS 2A', 'ABPS', 'CSS', 'Political Science', true, null, 'Religious Education', 'RE'),
  ('S1-REL203A-ABPS2B', 1, 'REL 203A', 'ABPS 2B', 'ABPS', 'CSS', 'Political Science', true, null, 'Religious Education', 'RE'),
  ('S1-POLS250-ABPS3A', 1, 'POLS 250', 'ABPS 3A', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-POLS250-ABPS3B', 1, 'POLS 250', 'ABPS 3B', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-POLS260-ABPS3A', 1, 'POLS 260', 'ABPS 3A', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-POLS260-ABPS3B', 1, 'POLS 260', 'ABPS 3B', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-LGLS302-ABPS3A', 1, 'LGLS 302', 'ABPS 3A', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-LGLS302-ABPS3B', 1, 'LGLS 302', 'ABPS 3B', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-LGLS303-ABPS3A', 1, 'LGLS 303', 'ABPS 3A', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-LGLS303-ABPS3B', 1, 'LGLS 303', 'ABPS 3B', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-ENGL302-ABPS3A', 1, 'ENGL 302', 'ABPS 3A', 'ABPS', 'CSS', 'Political Science', true, null, 'General Education', 'GE'),
  ('S1-ENGL302-ABPS3B', 1, 'ENGL 302', 'ABPS 3B', 'ABPS', 'CSS', 'Political Science', true, null, 'General Education', 'GE'),
  ('S1-HIST201-ABPS3A', 1, 'HIST 201', 'ABPS 3A', 'ABPS', 'CSS', 'Political Science', true, null, 'Secondary Education', 'COE'),
  ('S1-HIST201-ABPS3B', 1, 'HIST 201', 'ABPS 3B', 'ABPS', 'CSS', 'Political Science', true, null, 'Secondary Education', 'COE'),
  ('S1-HIST220-ABPS3A', 1, 'HIST 220', 'ABPS 3A', 'ABPS', 'CSS', 'Political Science', true, null, 'Secondary Education', 'COE'),
  ('S1-HIST220-ABPS3B', 1, 'HIST 220', 'ABPS 3B', 'ABPS', 'CSS', 'Political Science', true, null, 'Secondary Education', 'COE'),
  ('S1-REL303A-ABPS3A', 1, 'REL 303A', 'ABPS 3A', 'ABPS', 'CSS', 'Political Science', true, null, 'Religious Education', 'RE'),
  ('S1-REL303A-ABPS3B', 1, 'REL 303A', 'ABPS 3B', 'ABPS', 'CSS', 'Political Science', true, null, 'Religious Education', 'RE'),
  ('S1-POLS410-ABPS4A', 1, 'POLS 410', 'ABPS 4A', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-POLS410-ABPS4B', 1, 'POLS 410', 'ABPS 4B', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-LGLS402-ABPS4A', 1, 'LGLS 402', 'ABPS 4A', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-LGLS402-ABPS4B', 1, 'LGLS 402', 'ABPS 4B', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-LGLS403-ABPS4A', 1, 'LGLS 403', 'ABPS 4A', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-LGLS403-ABPS4B', 1, 'LGLS 403', 'ABPS 4B', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-LGLS404-ABPS4A', 1, 'LGLS 404', 'ABPS 4A', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-LGLS404-ABPS4B', 1, 'LGLS 404', 'ABPS 4B', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-REL403-ABPS4A', 1, 'REL 403', 'ABPS 4A', 'ABPS', 'CSS', 'Political Science', true, null, 'Religious Education', 'RE'),
  ('S1-REL403-ABPS4B', 1, 'REL 403', 'ABPS 4B', 'ABPS', 'CSS', 'Political Science', true, null, 'Religious Education', 'RE'),
  ('S1-COMM101-ABC1', 1, 'COMM 101', 'ABC 1', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-COMM120-ABC1', 1, 'COMM 120', 'ABC 1', 'ABC', 'CSS', 'Communication', true, null, 'Communication', 'CSS'),
  ('S1-MATH180-ABC1', 1, 'MATH 180', 'ABC 1', 'ABC', 'CSS', 'Communication', true, null, 'Secondary Education', 'COE'),
  ('S1-ARTS101-ABC1', 1, 'ARTS 101', 'ABC 1', 'ABC', 'CSS', 'Communication', true, null, 'General Education', 'GE'),
  ('S1-PE101-ABC1', 1, 'PE 101', 'ABC 1', 'ABC', 'CSS', 'Communication', true, null, 'General Education', 'GE'),
  ('S1-CWTS101-ABC1', 1, 'CWTS 101', 'ABC 1', 'ABC', 'CSS', 'Communication', true, null, 'General Education', 'GE'),
  ('S1-UNI103-ABC1', 1, 'UNI 103', 'ABC 1', 'ABC', 'CSS', 'Communication', true, null, 'Communication', 'CSS'),
  ('S1-REL103A-ABC1', 1, 'REL 103A', 'ABC 1', 'ABC', 'CSS', 'Communication', true, null, 'Religious Education', 'RE'),
  ('S1-COMM112-ABC2', 1, 'COMM 112', 'ABC 2', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-COMM210-ABC2', 1, 'COMM 210', 'ABC 2', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-COMM221-ABC2', 1, 'COMM 221', 'ABC 2', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-SOCS195-ABC2', 1, 'SOCS 195', 'ABC 2', 'ABC', 'CSS', 'Communication', true, null, 'Economics', 'CSS'),
  ('S1-STS180-ABC2', 1, 'STS 180', 'ABC 2', 'ABC', 'CSS', 'Communication', true, null, 'Information Technology', 'CICS'),
  ('S1-HIST201-ABC2', 1, 'HIST 201', 'ABC 2', 'ABC', 'CSS', 'Communication', true, null, 'Secondary Education', 'COE'),
  ('S1-PE201-ABC2', 1, 'PE 201', 'ABC 2', 'ABC', 'CSS', 'Communication', true, null, 'General Education', 'GE'),
  ('S1-REL203A-ABC2', 1, 'REL 203A', 'ABC 2', 'ABC', 'CSS', 'Communication', true, null, 'Religious Education', 'RE'),
  ('S1-COMM212-ABC3', 1, 'COMM 212', 'ABC 3', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-COMM220-ABC3', 1, 'COMM 220', 'ABC 3', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-COMM240-ABC3', 1, 'COMM 240', 'ABC 3', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-COMM310-ABC3', 1, 'COMM 310', 'ABC 3', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-COMM311-ABC3', 1, 'COMM 311', 'ABC 3', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-PHIL190-ABC3', 1, 'PHIL 190', 'ABC 3', 'ABC', 'CSS', 'Communication', true, null, 'General Education', 'GE'),
  ('S1-GAD171-ABC3', 1, 'GAD 171', 'ABC 3', 'ABC', 'CSS', 'Communication', true, null, 'Psychology', 'CSS'),
  ('S1-REL303A-ABC3', 1, 'REL 303A', 'ABC 3', 'ABC', 'CSS', 'Communication', true, null, 'Religious Education', 'RE'),
  ('S1-COMM410-ABC4', 1, 'COMM 410', 'ABC 4', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-COMM331-ABC4', 1, 'COMM 331', 'ABC 4', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-COMM340-ABC4', 1, 'COMM 340', 'ABC 4', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-HIST220-ABC4', 1, 'HIST 220', 'ABC 4', 'ABC', 'CSS', 'Communication', true, null, 'Secondary Education', 'COE'),
  ('S1-REL403-ABC4', 1, 'REL 403', 'ABC 4', 'ABC', 'CSS', 'Communication', true, null, 'Religious Education', 'RE'),
  ('S1-ECON101-ABEcon1', 1, 'ECON 101', 'ABEcon 1', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-ECON130-ABEcon1', 1, 'ECON 130', 'ABEcon 1', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-COMM120-ABEcon1', 1, 'COMM 120', 'ABEcon 1', 'ABEcon', 'CSS', 'Economics', true, null, 'Communication', 'CSS'),
  ('S1-MATH180-ABEcon1', 1, 'MATH 180', 'ABEcon 1', 'ABEcon', 'CSS', 'Economics', true, null, 'Secondary Education', 'COE'),
  ('S1-PE101-ABEcon1', 1, 'PE 101', 'ABEcon 1', 'ABEcon', 'CSS', 'Economics', true, null, 'General Education', 'GE'),
  ('S1-CWTS101-ABEcon1', 1, 'CWTS 101', 'ABEcon 1', 'ABEcon', 'CSS', 'Economics', true, null, 'General Education', 'GE'),
  ('S1-UNI103-ABEcon1', 1, 'UNI 103', 'ABEcon 1', 'ABEcon', 'CSS', 'Economics', true, null, 'Economics', 'CSS'),
  ('S1-REL103A-ABEcon1', 1, 'REL 103A', 'ABEcon 1', 'ABEcon', 'CSS', 'Economics', true, null, 'Religious Education', 'RE'),
  ('S1-ECON120-ABEcon2', 1, 'ECON 120', 'ABEcon 2', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-ECON121-ABEcon2', 1, 'ECON 121', 'ABEcon 2', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-ECON210-ABEcon2', 1, 'ECON 210', 'ABEcon 2', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-MATH350-ABEcon2', 1, 'MATH 350', 'ABEcon 2', 'ABEcon', 'CSS', 'Economics', true, null, 'Computer Science', 'CICS'),
  ('S1-SOCS195-ABEcon2', 1, 'SOCS 195', 'ABEcon 2', 'ABEcon', 'CSS', 'Economics', true, null, 'Economics', 'CSS'),
  ('S1-ARTS101-ABEcon2', 1, 'ARTS 101', 'ABEcon 2', 'ABEcon', 'CSS', 'Economics', true, null, 'General Education', 'GE'),
  ('S1-PE201-ABEcon2', 1, 'PE 201', 'ABEcon 2', 'ABEcon', 'CSS', 'Economics', true, null, 'General Education', 'GE'),
  ('S1-REL203A-ABEcon2', 1, 'REL 203A', 'ABEcon 2', 'ABEcon', 'CSS', 'Economics', true, null, 'Religious Education', 'RE'),
  ('S1-ECON220-ABEcon3', 1, 'ECON 220', 'ABEcon 3', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-ECON221-ABEcon3', 1, 'ECON 221', 'ABEcon 3', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-ECON222-ABEcon3', 1, 'ECON 222', 'ABEcon 3', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-ECON231-ABEcon3', 1, 'ECON 231', 'ABEcon 3', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-ECON310-ABEcon3', 1, 'ECON 310', 'ABEcon 3', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-PHIL220-ABEcon3', 1, 'PHIL 220', 'ABEcon 3', 'ABEcon', 'CSS', 'Economics', true, null, 'General Education', 'GE'),
  ('S1-ENGL302-ABEcon3', 1, 'ENGL 302', 'ABEcon 3', 'ABEcon', 'CSS', 'Economics', true, null, 'General Education', 'GE'),
  ('S1-REL303A-ABEcon3', 1, 'REL 303A', 'ABEcon 3', 'ABEcon', 'CSS', 'Economics', true, null, 'Religious Education', 'RE'),
  ('S1-ECON410-ABEcon4', 1, 'ECON 410', 'ABEcon 4', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-ECON330-ABEcon4', 1, 'ECON 330', 'ABEcon 4', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-GAD171-ABEcon4', 1, 'GAD 171', 'ABEcon 4', 'ABEcon', 'CSS', 'Economics', true, null, 'Psychology', 'CSS'),
  ('S1-HIST220-ABEcon4', 1, 'HIST 220', 'ABEcon 4', 'ABEcon', 'CSS', 'Economics', true, null, 'Secondary Education', 'COE'),
  ('S1-REL403-ABEcon4', 1, 'REL 403', 'ABEcon 4', 'ABEcon', 'CSS', 'Economics', true, null, 'Religious Education', 'RE')
on conflict (id) do update set course = excluded.course, section = excluded.section, program = excluded.program, college = excluded.college, department = excluded.department, is_ge = excluded.is_ge, plan_teacher = excluded.plan_teacher, house_dept = excluded.house_dept, house_college = excluded.house_college;
-- Move what was booked under older class ids to the same course and section.
with keep as (select id from (values ('S1-ACC101-BSA1A'), ('S1-ACC101-BSA1B'), ('S1-BUS101-BSA1A'), ('S1-BUS101-BSA1B'), ('S1-MATH180-BSA1A'), ('S1-MATH180-BSA1B'), ('S1-SOCS195-BSA1A'), ('S1-SOCS195-BSA1B'), ('S1-PE101-BSA1A'), ('S1-PE101-BSA1B'), ('S1-CWTS101-BSA1A'), ('S1-CWTS101-BSA1B'), ('S1-UNI103-BSA1A'), ('S1-UNI103-BSA1B'), ('S1-REL103A-BSA1A'), ('S1-REL103A-BSA1B'), ('S1-ACC201-BSA2A'), ('S1-ACC201-BSA2B'), ('S1-ACC210-BSA2A'), ('S1-ACC210-BSA2B'), ('S1-ACC221-BSA2A'), ('S1-ACC221-BSA2B'), ('S1-MATH350-BSA2A'), ('S1-MATH350-BSA2B'), ('S1-PSYC160-BSA2A'), ('S1-PSYC160-BSA2B'), ('S1-GAD171-BSA2A'), ('S1-GAD171-BSA2B'), ('S1-PE201-BSA2A'), ('S1-PE201-BSA2B'), ('S1-REL203A-BSA2A'), ('S1-REL203A-BSA2B'), ('S1-ACC203-BSA3A'), ('S1-ACC203-BSA3B'), ('S1-ACC231-BSA3A'), ('S1-ACC231-BSA3B'), ('S1-ACC241-BSA3A'), ('S1-ACC241-BSA3B'), ('S1-ACC250-BSA3A'), ('S1-ACC250-BSA3B'), ('S1-ACC301-BSA3A'), ('S1-ACC301-BSA3B'), ('S1-ACC222-BSA3A'), ('S1-ACC222-BSA3B'), ('S1-PHIL190-BSA3A'), ('S1-PHIL190-BSA3B'), ('S1-REL303A-BSA3A'), ('S1-REL303A-BSA3B'), ('S1-ACC312-BSA4A'), ('S1-ACC312-BSA4B'), ('S1-ACC303-BSA4A'), ('S1-ACC303-BSA4B'), ('S1-ACC313-BSA4A'), ('S1-ACC313-BSA4B'), ('S1-ACC341-BSA4A'), ('S1-ACC341-BSA4B'), ('S1-ACC410-BSA4A'), ('S1-ACC410-BSA4B'), ('S1-HIST201-BSA4A'), ('S1-HIST201-BSA4B'), ('S1-ENGL302-BSA4A'), ('S1-ENGL302-BSA4B'), ('S1-REL403-BSA4A'), ('S1-REL403-BSA4B'), ('S1-ENT101-BSEntrep1'), ('S1-BUS101-BSEntrep1'), ('S1-MATH180-BSEntrep1'), ('S1-PSYC160-BSEntrep1'), ('S1-PE101-BSEntrep1'), ('S1-CWTS101-BSEntrep1'), ('S1-UNI103-BSEntrep1'), ('S1-REL103A-BSEntrep1'), ('S1-ENT201-BSEntrep2'), ('S1-ENT203-BSEntrep2'), ('S1-BUS201-BSEntrep2'), ('S1-MATH350-BSEntrep2'), ('S1-FIL207-BSEntrep2'), ('S1-PE201-BSEntrep2'), ('S1-REL203A-BSEntrep2'), ('S1-ENT210-BSEntrep3'), ('S1-ENT301-BSEntrep3'), ('S1-BUS220-BSEntrep3'), ('S1-BUS230-BSEntrep3'), ('S1-ENT310-BSEntrep3'), ('S1-PHIL190-BSEntrep3'), ('S1-ARTS101-BSEntrep3'), ('S1-REL303A-BSEntrep3'), ('S1-ENT401-BSEntrep4'), ('S1-BUS302-BSEntrep4'), ('S1-HIST220-BSEntrep4'), ('S1-GAD171-BSEntrep4'), ('S1-REL403-BSEntrep4'), ('S1-BUS101-BSBA1A'), ('S1-BUS101-BSBA1B'), ('S1-BUS110-BSBA1A'), ('S1-BUS110-BSBA1B'), ('S1-MATH180-BSBA1A'), ('S1-MATH180-BSBA1B'), ('S1-PSYC160-BSBA1A'), ('S1-PSYC160-BSBA1B'), ('S1-PE101-BSBA1A'), ('S1-PE101-BSBA1B'), ('S1-CWTS101-BSBA1A'), ('S1-CWTS101-BSBA1B'), ('S1-UNI103-BSBA1A'), ('S1-UNI103-BSBA1B'), ('S1-REL103A-BSBA1A'), ('S1-REL103A-BSBA1B'), ('S1-BUS121-BSBA2A'), ('S1-BUS121-BSBA2B'), ('S1-BUS201-BSBA2A'), ('S1-BUS201-BSBA2B'), ('S1-BUS210-BSBA2A'), ('S1-BUS210-BSBA2B'), ('S1-STS180-BSBA2A'), ('S1-STS180-BSBA2B'), ('S1-PE201-BSBA2A'), ('S1-PE201-BSBA2B'), ('S1-REL203A-BSBA2A'), ('S1-REL203A-BSBA2B'), ('S1-BUS220-BSBA3A'), ('S1-BUS220-BSBA3B'), ('S1-BUS230-BSBA3A'), ('S1-BUS230-BSBA3B'), ('S1-FM301-BSBA3-FM'), ('S1-FM303-BSBA3-FM'), ('S1-MKT301-BSBA3-MKT'), ('S1-MKT302-BSBA3-MKT'), ('S1-BAN301-BSBA3-BAN'), ('S1-BAN302-BSBA3-BAN'), ('S1-PHIL220-BSBA3A'), ('S1-PHIL220-BSBA3B'), ('S1-ARTS101-BSBA3A'), ('S1-ARTS101-BSBA3B'), ('S1-REL303A-BSBA3A'), ('S1-REL303A-BSBA3B'), ('S1-BUS302-BSBA4A'), ('S1-BUS302-BSBA4B'), ('S1-BUS304-BSBA4A'), ('S1-BUS304-BSBA4B'), ('S1-FM401-BSBA4-FM'), ('S1-FM402-BSBA4-FM'), ('S1-MKT401-BSBA4-MKT'), ('S1-MKT402-BSBA4-MKT'), ('S1-BAN401-BSBA4-BAN'), ('S1-BAN402-BSBA4-BAN'), ('S1-HIST220-BSBA4A'), ('S1-HIST220-BSBA4B'), ('S1-REL403-BSBA4A'), ('S1-REL403-BSBA4B'), ('S1-THM101-BSTHM1A'), ('S1-THM101-BSTHM1B'), ('S1-THM110-BSTHM1A'), ('S1-THM110-BSTHM1B'), ('S1-MATH180-BSTHM1A'), ('S1-MATH180-BSTHM1B'), ('S1-PSYC160-BSTHM1A'), ('S1-PSYC160-BSTHM1B'), ('S1-PE101-BSTHM1A'), ('S1-PE101-BSTHM1B'), ('S1-CWTS101-BSTHM1A'), ('S1-CWTS101-BSTHM1B'), ('S1-UNI103-BSTHM1A'), ('S1-UNI103-BSTHM1B'), ('S1-REL103A-BSTHM1A'), ('S1-REL103A-BSTHM1B'), ('S1-THM201-BSTHM2A'), ('S1-THM201-BSTHM2B'), ('S1-THM202-BSTHM2A'), ('S1-THM202-BSTHM2B'), ('S1-THM203-BSTHM2A'), ('S1-THM203-BSTHM2B'), ('S1-FIL207-BSTHM2A'), ('S1-FIL207-BSTHM2B'), ('S1-PE201-BSTHM2A'), ('S1-PE201-BSTHM2B'), ('S1-REL203A-BSTHM2A'), ('S1-REL203A-BSTHM2B'), ('S1-THM212-BSTHM3A'), ('S1-THM212-BSTHM3B'), ('S1-THM220-BSTHM3A'), ('S1-THM220-BSTHM3B'), ('S1-THM231-BSTHM3A'), ('S1-THM231-BSTHM3B'), ('S1-THM301-BSTHM3A'), ('S1-THM301-BSTHM3B'), ('S1-THM303-BSTHM3A'), ('S1-THM303-BSTHM3B'), ('S1-PHIL190-BSTHM3A'), ('S1-PHIL190-BSTHM3B'), ('S1-ARTS101-BSTHM3A'), ('S1-ARTS101-BSTHM3B'), ('S1-REL303A-BSTHM3A'), ('S1-REL303A-BSTHM3B'), ('S1-THM311-BSTHM4A'), ('S1-THM311-BSTHM4B'), ('S1-THM321-BSTHM4A'), ('S1-THM321-BSTHM4B'), ('S1-HIST201-BSTHM4A'), ('S1-HIST201-BSTHM4B'), ('S1-HIST220-BSTHM4A'), ('S1-HIST220-BSTHM4B'), ('S1-GAD171-BSTHM4A'), ('S1-GAD171-BSTHM4B'), ('S1-REL403-BSTHM4A'), ('S1-REL403-BSTHM4B'), ('S1-CRIM101-BSCrim1A'), ('S1-CRIM101-BSCrim1B'), ('S1-CLJ101-BSCrim1A'), ('S1-CLJ101-BSCrim1B'), ('S1-CRIM104-BSCrim1A'), ('S1-CRIM104-BSCrim1B'), ('S1-MATH180-BSCrim1A'), ('S1-MATH180-BSCrim1B'), ('S1-PSYC160-BSCrim1A'), ('S1-PSYC160-BSCrim1B'), ('S1-COMM120-BSCrim1A'), ('S1-COMM120-BSCrim1B'), ('S1-PE101-BSCrim1A'), ('S1-PE101-BSCrim1B'), ('S1-CWTS101-BSCrim1A'), ('S1-CWTS101-BSCrim1B'), ('S1-UNI103-BSCrim1A'), ('S1-UNI103-BSCrim1B'), ('S1-REL103A-BSCrim1A'), ('S1-REL103A-BSCrim1B'), ('S1-LEA101-BSCrim2A'), ('S1-LEA101-BSCrim2B'), ('S1-CDI101-BSCrim2A'), ('S1-CDI101-BSCrim2B'), ('S1-CA101-BSCrim2A'), ('S1-CA101-BSCrim2B'), ('S1-CLJ104-BSCrim2A'), ('S1-CLJ104-BSCrim2B'), ('S1-CLJ105-BSCrim2A'), ('S1-CLJ105-BSCrim2B'), ('S1-FOR102-BSCrim2A'), ('S1-FOR102-BSCrim2B'), ('S1-PE201-BSCrim2A'), ('S1-PE201-BSCrim2B'), ('S1-REL203A-BSCrim2A'), ('S1-REL203A-BSCrim2B'), ('S1-LEA104-BSCrim3A'), ('S1-LEA104-BSCrim3B'), ('S1-CDI104-BSCrim3A'), ('S1-CDI104-BSCrim3B'), ('S1-CDI105-BSCrim3A'), ('S1-CDI105-BSCrim3B'), ('S1-CLJ106-BSCrim3A'), ('S1-CLJ106-BSCrim3B'), ('S1-FOR104-BSCrim3A'), ('S1-FOR104-BSCrim3B'), ('S1-CRIM107-BSCrim3A'), ('S1-CRIM107-BSCrim3B'), ('S1-FIL207-BSCrim3A'), ('S1-FIL207-BSCrim3B'), ('S1-REL303A-BSCrim3A'), ('S1-REL303A-BSCrim3B'), ('S1-LEA106-BSCrim4A'), ('S1-LEA106-BSCrim4B'), ('S1-CDI108-BSCrim4A'), ('S1-CDI108-BSCrim4B'), ('S1-FOR106-BSCrim4A'), ('S1-FOR106-BSCrim4B'), ('S1-PHIL190-BSCrim4A'), ('S1-PHIL190-BSCrim4B'), ('S1-ARTS101-BSCrim4A'), ('S1-ARTS101-BSCrim4B'), ('S1-HIST201-BSCrim4A'), ('S1-HIST201-BSCrim4B'), ('S1-GAD171-BSCrim4A'), ('S1-GAD171-BSCrim4B'), ('S1-REL403-BSCrim4A'), ('S1-REL403-BSCrim4B'), ('S1-PAD101-ABPA1'), ('S1-SOCS195-ABPA1'), ('S1-COMM120-ABPA1'), ('S1-MATH180-ABPA1'), ('S1-PE101-ABPA1'), ('S1-CWTS101-ABPA1'), ('S1-UNI103-ABPA1'), ('S1-REL103A-ABPA1'), ('S1-PAD104-ABPA2'), ('S1-PAD105-ABPA2'), ('S1-PAD201-ABPA2'), ('S1-MATH350-ABPA2'), ('S1-PHIL190-ABPA2'), ('S1-PE201-ABPA2'), ('S1-REL203A-ABPA2'), ('S1-PAD204-ABPA3'), ('S1-PAD206-ABPA3'), ('S1-PAD205-ABPA3'), ('S1-PAD305-ABPA3'), ('S1-PAD309-ABPA3'), ('S1-PHIL220-ABPA3'), ('S1-ARTS101-ABPA3'), ('S1-REL303A-ABPA3'), ('S1-PAD410-ABPA4'), ('S1-HIST220-ABPA4'), ('S1-GAD171-ABPA4'), ('S1-REL403-ABPA4'), ('S1-SW101-BSSW1'), ('S1-MATH180-BSSW1'), ('S1-PSYC160-BSSW1'), ('S1-COMM120-BSSW1'), ('S1-SOCS195-BSSW1'), ('S1-PE101-BSSW1'), ('S1-CWTS101-BSSW1'), ('S1-UNI103-BSSW1'), ('S1-REL103A-BSSW1'), ('S1-SW201-BSSW2'), ('S1-SW202-BSSW2'), ('S1-SW205-BSSW2'), ('S1-MATH350-BSSW2'), ('S1-PE201-BSSW2'), ('S1-REL203A-BSSW2'), ('S1-SW301-BSSW3'), ('S1-SW305-BSSW3'), ('S1-SW306-BSSW3'), ('S1-SW308-BSSW3'), ('S1-SW310-BSSW3'), ('S1-PHIL190-BSSW3'), ('S1-ARTS101-BSSW3'), ('S1-ENGL302-BSSW3'), ('S1-REL303A-BSSW3'), ('S1-SW490-BSSW4'), ('S1-SW313-BSSW4'), ('S1-HIST220-BSSW4'), ('S1-REL403-BSSW4'), ('S1-CCS101-BSCS1A'), ('S1-CCS101-BSCS1B'), ('S1-CCS102-BSCS1A'), ('S1-CCS102-BSCS1B'), ('S1-CS110-BSCS1A'), ('S1-CS110-BSCS1B'), ('S1-SOCS195-BSCS1A'), ('S1-SOCS195-BSCS1B'), ('S1-MATH180-BSCS1A'), ('S1-MATH180-BSCS1B'), ('S1-PE101-BSCS1A'), ('S1-PE101-BSCS1B'), ('S1-CWTS101-BSCS1A'), ('S1-CWTS101-BSCS1B'), ('S1-UNI103-BSCS1A'), ('S1-UNI103-BSCS1B'), ('S1-REL103A-BSCS1A'), ('S1-REL103A-BSCS1B'), ('S1-CCS201-BSCS2A'), ('S1-CCS201-BSCS2B'), ('S1-CS230-BSCS2A'), ('S1-CS230-BSCS2B'), ('S1-CS220-BSCS2A'), ('S1-CS220-BSCS2B'), ('S1-CS240-BSCS2A'), ('S1-CS240-BSCS2B'), ('S1-PSYC160-BSCS2A'), ('S1-PSYC160-BSCS2B'), ('S1-PE201-BSCS2A'), ('S1-PE201-BSCS2B'), ('S1-REL203A-BSCS2A'), ('S1-REL203A-BSCS2B'), ('S1-CS310-BSCS3A'), ('S1-CS310-BSCS3B'), ('S1-CS330-BSCS3A'), ('S1-CS330-BSCS3B'), ('S1-CS350-BSCS3A'), ('S1-CS350-BSCS3B'), ('S1-CS390-BSCS3A'), ('S1-CS390-BSCS3B'), ('S1-MATH350-BSCS3A'), ('S1-MATH350-BSCS3B'), ('S1-ARTS101-BSCS3A'), ('S1-ARTS101-BSCS3B'), ('S1-PHIL190-BSCS3A'), ('S1-PHIL190-BSCS3B'), ('S1-REL303A-BSCS3A'), ('S1-REL303A-BSCS3B'), ('S1-CS430-BSCS4A'), ('S1-CS430-BSCS4B'), ('S1-CS410-BSCS4A'), ('S1-CS410-BSCS4B'), ('S1-HIST201-BSCS4A'), ('S1-HIST201-BSCS4B'), ('S1-HIST220-BSCS4A'), ('S1-HIST220-BSCS4B'), ('S1-ENGL302-BSCS4A'), ('S1-ENGL302-BSCS4B'), ('S1-GAD171-BSCS4A'), ('S1-GAD171-BSCS4B'), ('S1-REL403-BSCS4A'), ('S1-REL403-BSCS4B'), ('S1-CCS101-BSIT1A'), ('S1-CCS101-BSIT1B'), ('S1-CCS102-BSIT1A'), ('S1-CCS102-BSIT1B'), ('S1-IT110-BSIT1A'), ('S1-IT110-BSIT1B'), ('S1-COMM120-BSIT1A'), ('S1-COMM120-BSIT1B'), ('S1-MATH180-BSIT1A'), ('S1-MATH180-BSIT1B'), ('S1-PE101-BSIT1A'), ('S1-PE101-BSIT1B'), ('S1-CWTS101-BSIT1A'), ('S1-CWTS101-BSIT1B'), ('S1-UNI103-BSIT1A'), ('S1-UNI103-BSIT1B'), ('S1-REL103A-BSIT1A'), ('S1-REL103A-BSIT1B'), ('S1-CCS201-BSIT2A'), ('S1-CCS201-BSIT2B'), ('S1-IT210-BSIT2A'), ('S1-IT210-BSIT2B'), ('S1-IT230-BSIT2A'), ('S1-IT230-BSIT2B'), ('S1-STS180-BSIT2A'), ('S1-STS180-BSIT2B'), ('S1-MATH350-BSIT2A'), ('S1-MATH350-BSIT2B'), ('S1-SOCS195-BSIT2A'), ('S1-SOCS195-BSIT2B'), ('S1-PE201-BSIT2A'), ('S1-PE201-BSIT2B'), ('S1-REL203A-BSIT2A'), ('S1-REL203A-BSIT2B'), ('S1-IT250-BSIT3A'), ('S1-IT250-BSIT3B'), ('S1-IT310-BSIT3A'), ('S1-IT310-BSIT3B'), ('S1-IT330-BSIT3A'), ('S1-IT330-BSIT3B'), ('S1-IT360-BSIT3A'), ('S1-IT360-BSIT3B'), ('S1-IT370-BSIT3A'), ('S1-IT370-BSIT3B'), ('S1-ENGL302-BSIT3A'), ('S1-ENGL302-BSIT3B'), ('S1-PHIL190-BSIT3A'), ('S1-PHIL190-BSIT3B'), ('S1-REL303A-BSIT3A'), ('S1-REL303A-BSIT3B'), ('S1-IT430-BSIT4A'), ('S1-IT430-BSIT4B'), ('S1-IT390-BSIT4A'), ('S1-IT390-BSIT4B'), ('S1-IT410-BSIT4A'), ('S1-IT410-BSIT4B'), ('S1-HIST201-BSIT4A'), ('S1-HIST201-BSIT4B'), ('S1-HIST220-BSIT4A'), ('S1-HIST220-BSIT4B'), ('S1-GAD171-BSIT4A'), ('S1-GAD171-BSIT4B'), ('S1-REL403-BSIT4A'), ('S1-REL403-BSIT4B'), ('S1-LIS101-BLIS1'), ('S1-LIS102-BLIS1'), ('S1-COMM120-BLIS1'), ('S1-MATH180-BLIS1'), ('S1-PE101-BLIS1'), ('S1-CWTS101-BLIS1'), ('S1-UNI103-BLIS1'), ('S1-REL103A-BLIS1'), ('S1-LIS201-BLIS2'), ('S1-LIS211-BLIS2'), ('S1-LIS230-BLIS2'), ('S1-SOCS195-BLIS2'), ('S1-MATH350-BLIS2'), ('S1-ENGL302-BLIS2'), ('S1-PE201-BLIS2'), ('S1-REL203A-BLIS2'), ('S1-LIS220-BLIS3'), ('S1-LIS240-BLIS3'), ('S1-LIS301-BLIS3'), ('S1-LIS304-BLIS3'), ('S1-LIS330-BLIS3'), ('S1-PHIL190-BLIS3'), ('S1-ARTS101-BLIS3'), ('S1-REL303A-BLIS3'), ('S1-LIS410-BLIS4'), ('S1-LIS320-BLIS4'), ('S1-HIST220-BLIS4'), ('S1-GAD171-BLIS4'), ('S1-REL403-BLIS4'), ('S1-ED101-BEEd1'), ('S1-ED102-BEEd1'), ('S1-MATH180-BEEd1'), ('S1-SOCS195-BEEd1'), ('S1-PE101-BEEd1'), ('S1-CWTS101-BEEd1'), ('S1-PSYC160-BEEd1'), ('S1-UNI103-BEEd1'), ('S1-REL103A-BEEd1'), ('S1-ED201-BEEd2'), ('S1-ED202-BEEd2'), ('S1-ED204-BEEd2'), ('S1-EED101-BEEd2'), ('S1-EED140-BEEd2'), ('S1-EED150-BEEd2'), ('S1-PE201-BEEd2'), ('S1-REL203A-BEEd2'), ('S1-ED301-BEEd3'), ('S1-ED303-BEEd3'), ('S1-ED304-BEEd3'), ('S1-EED102-BEEd3'), ('S1-EED151-BEEd3'), ('S1-EED160-BEEd3'), ('S1-EED180-BEEd3'), ('S1-PHIL190-BEEd3'), ('S1-REL303A-BEEd3'), ('S1-ED401-BEEd4'), ('S1-ED402-BEEd4'), ('S1-EED181-BEEd4'), ('S1-ENGL302-BEEd4'), ('S1-HIST201-BEEd4'), ('S1-HIST220-BEEd4'), ('S1-GAD171-BEEd4'), ('S1-REL403-BEEd4'), ('S1-ED101-BSEd-E1'), ('S1-SEE101-BSEd-E1'), ('S1-MATH180-BSEd-E1'), ('S1-PSYC160-BSEd-E1'), ('S1-COMM120-BSEd-E1'), ('S1-CWTS101-BSEd-E1'), ('S1-PE101-BSEd-E1'), ('S1-UNI103-BSEd-E1'), ('S1-REL103A-BSEd-E1'), ('S1-ED201-BSEd-E2'), ('S1-ED202-BSEd-E2'), ('S1-ED204-BSEd-E2'), ('S1-SEE201-BSEd-E2'), ('S1-SEE202-BSEd-E2'), ('S1-MATH350-BSEd-E2'), ('S1-PHIL190-BSEd-E2'), ('S1-PE201-BSEd-E2'), ('S1-REL203A-BSEd-E2'), ('S1-ED301-BSEd-E3'), ('S1-ED303-BSEd-E3'), ('S1-ED304-BSEd-E3'), ('S1-SEE301-BSEd-E3'), ('S1-SEE302-BSEd-E3'), ('S1-SEE303-BSEd-E3'), ('S1-PHIL220-BSEd-E3'), ('S1-ENGL302-BSEd-E3'), ('S1-REL303A-BSEd-E3'), ('S1-ED401-BSEd-E4'), ('S1-ED402-BSEd-E4'), ('S1-SEE401-BSEd-E4'), ('S1-SEE402-BSEd-E4'), ('S1-SEE403-BSEd-E4'), ('S1-SEE404-BSEd-E4'), ('S1-SEE405-BSEd-E4'), ('S1-REL403-BSEd-E4'), ('S1-ED101-BSEd-M1'), ('S1-SEM101-BSEd-M1'), ('S1-MATH180-BSEd-M1'), ('S1-PSYC160-BSEd-M1'), ('S1-COMM120-BSEd-M1'), ('S1-CWTS101-BSEd-M1'), ('S1-PE101-BSEd-M1'), ('S1-UNI103-BSEd-M1'), ('S1-REL103A-BSEd-M1'), ('S1-ED201-BSEd-M2'), ('S1-ED202-BSEd-M2'), ('S1-ED204-BSEd-M2'), ('S1-SEM201-BSEd-M2'), ('S1-SEM202-BSEd-M2'), ('S1-MATH350-BSEd-M2'), ('S1-PHIL190-BSEd-M2'), ('S1-PE201-BSEd-M2'), ('S1-REL203A-BSEd-M2'), ('S1-ED301-BSEd-M3'), ('S1-ED303-BSEd-M3'), ('S1-ED304-BSEd-M3'), ('S1-SEM301-BSEd-M3'), ('S1-SEM302-BSEd-M3'), ('S1-SEM303-BSEd-M3'), ('S1-PHIL220-BSEd-M3'), ('S1-ENGL302-BSEd-M3'), ('S1-REL303A-BSEd-M3'), ('S1-ED401-BSEd-M4'), ('S1-ED402-BSEd-M4'), ('S1-SEM401-BSEd-M4'), ('S1-SEM402-BSEd-M4'), ('S1-SEM403-BSEd-M4'), ('S1-SEM404-BSEd-M4'), ('S1-SEM405-BSEd-M4'), ('S1-REL403-BSEd-M4'), ('S1-ED101-BSEd-SS1'), ('S1-SES101-BSEd-SS1'), ('S1-MATH180-BSEd-SS1'), ('S1-PSYC160-BSEd-SS1'), ('S1-COMM120-BSEd-SS1'), ('S1-CWTS101-BSEd-SS1'), ('S1-PE101-BSEd-SS1'), ('S1-UNI103-BSEd-SS1'), ('S1-REL103A-BSEd-SS1'), ('S1-ED201-BSEd-SS2'), ('S1-ED202-BSEd-SS2'), ('S1-ED204-BSEd-SS2'), ('S1-SES201-BSEd-SS2'), ('S1-SES202-BSEd-SS2'), ('S1-MATH350-BSEd-SS2'), ('S1-PHIL190-BSEd-SS2'), ('S1-PE201-BSEd-SS2'), ('S1-REL203A-BSEd-SS2'), ('S1-ED301-BSEd-SS3'), ('S1-ED303-BSEd-SS3'), ('S1-ED304-BSEd-SS3'), ('S1-SES301-BSEd-SS3'), ('S1-SES302-BSEd-SS3'), ('S1-SES303-BSEd-SS3'), ('S1-PHIL220-BSEd-SS3'), ('S1-ENGL302-BSEd-SS3'), ('S1-REL303A-BSEd-SS3'), ('S1-ED401-BSEd-SS4'), ('S1-ED402-BSEd-SS4'), ('S1-SES401-BSEd-SS4'), ('S1-SES402-BSEd-SS4'), ('S1-SES403-BSEd-SS4'), ('S1-SES404-BSEd-SS4'), ('S1-SES405-BSEd-SS4'), ('S1-REL403-BSEd-SS4'), ('S1-ED101-BSEd-F1'), ('S1-SEF101-BSEd-F1'), ('S1-MATH180-BSEd-F1'), ('S1-PSYC160-BSEd-F1'), ('S1-COMM120-BSEd-F1'), ('S1-CWTS101-BSEd-F1'), ('S1-PE101-BSEd-F1'), ('S1-UNI103-BSEd-F1'), ('S1-REL103A-BSEd-F1'), ('S1-ED201-BSEd-F2'), ('S1-ED202-BSEd-F2'), ('S1-ED204-BSEd-F2'), ('S1-SEF201-BSEd-F2'), ('S1-SEF202-BSEd-F2'), ('S1-MATH350-BSEd-F2'), ('S1-PHIL190-BSEd-F2'), ('S1-PE201-BSEd-F2'), ('S1-REL203A-BSEd-F2'), ('S1-ED301-BSEd-F3'), ('S1-ED303-BSEd-F3'), ('S1-ED304-BSEd-F3'), ('S1-SEF301-BSEd-F3'), ('S1-SEF302-BSEd-F3'), ('S1-SEF303-BSEd-F3'), ('S1-PHIL220-BSEd-F3'), ('S1-ENGL302-BSEd-F3'), ('S1-REL303A-BSEd-F3'), ('S1-ED401-BSEd-F4'), ('S1-ED402-BSEd-F4'), ('S1-SEF401-BSEd-F4'), ('S1-SEF402-BSEd-F4'), ('S1-SEF403-BSEd-F4'), ('S1-SEF404-BSEd-F4'), ('S1-SEF405-BSEd-F4'), ('S1-REL403-BSEd-F4'), ('S1-PSYC101-BSP1A'), ('S1-PSYC101-BSP1B'), ('S1-PSYC160-BSP1A'), ('S1-PSYC160-BSP1B'), ('S1-MATH180-BSP1A'), ('S1-MATH180-BSP1B'), ('S1-STS180-BSP1A'), ('S1-STS180-BSP1B'), ('S1-PE101-BSP1A'), ('S1-PE101-BSP1B'), ('S1-CWTS101-BSP1A'), ('S1-CWTS101-BSP1B'), ('S1-UNI103-BSP1A'), ('S1-UNI103-BSP1B'), ('S1-REL103A-BSP1A'), ('S1-REL103A-BSP1B'), ('S1-PSYC130-BSP2A'), ('S1-PSYC130-BSP2B'), ('S1-PSYC210-BSP2A'), ('S1-PSYC210-BSP2B'), ('S1-PSYC220-BSP2A'), ('S1-PSYC220-BSP2B'), ('S1-SOCS195-BSP2A'), ('S1-SOCS195-BSP2B'), ('S1-PHIL190-BSP2A'), ('S1-PHIL190-BSP2B'), ('S1-PE201-BSP2A'), ('S1-PE201-BSP2B'), ('S1-REL203A-BSP2A'), ('S1-REL203A-BSP2B'), ('S1-PSYC240-BSP3C'), ('S1-PSYC240-BSP3IO'), ('S1-PSYC280-BSP3C'), ('S1-PSYC280-BSP3IO'), ('S1-PSYC310-BSP3C'), ('S1-PSYC310-BSP3IO'), ('S1-PSYC320-BSP3C'), ('S1-PSYC320-BSP3IO'), ('S1-PSYC351-BSP3C'), ('S1-PSYC361-BSP3IO'), ('S1-HIST201-BSP3C'), ('S1-HIST201-BSP3IO'), ('S1-ARTS101-BSP3C'), ('S1-ARTS101-BSP3IO'), ('S1-REL303A-BSP3C'), ('S1-REL303A-BSP3IO'), ('S1-PSYC410-BSP4C'), ('S1-PSYC410-BSP4IO'), ('S1-PSYC451-BSP4C'), ('S1-PSYC452-BSP4C'), ('S1-PSYC461-BSP4IO'), ('S1-PSYC462-BSP4IO'), ('S1-REL403-BSP4C'), ('S1-REL403-BSP4IO'), ('S1-POLS101-ABPS1A'), ('S1-POLS101-ABPS1B'), ('S1-SOCS195-ABPS1A'), ('S1-SOCS195-ABPS1B'), ('S1-COMM120-ABPS1A'), ('S1-COMM120-ABPS1B'), ('S1-MATH180-ABPS1A'), ('S1-MATH180-ABPS1B'), ('S1-PE101-ABPS1A'), ('S1-PE101-ABPS1B'), ('S1-CWTS101-ABPS1A'), ('S1-CWTS101-ABPS1B'), ('S1-UNI103-ABPS1A'), ('S1-UNI103-ABPS1B'), ('S1-REL103A-ABPS1A'), ('S1-REL103A-ABPS1B'), ('S1-POLS210-ABPS2A'), ('S1-POLS210-ABPS2B'), ('S1-POLS220-ABPS2A'), ('S1-POLS220-ABPS2B'), ('S1-LGLS201-ABPS2A'), ('S1-LGLS201-ABPS2B'), ('S1-PSYC160-ABPS2A'), ('S1-PSYC160-ABPS2B'), ('S1-PHIL190-ABPS2A'), ('S1-PHIL190-ABPS2B'), ('S1-PE201-ABPS2A'), ('S1-PE201-ABPS2B'), ('S1-REL203A-ABPS2A'), ('S1-REL203A-ABPS2B'), ('S1-POLS250-ABPS3A'), ('S1-POLS250-ABPS3B'), ('S1-POLS260-ABPS3A'), ('S1-POLS260-ABPS3B'), ('S1-LGLS302-ABPS3A'), ('S1-LGLS302-ABPS3B'), ('S1-LGLS303-ABPS3A'), ('S1-LGLS303-ABPS3B'), ('S1-ENGL302-ABPS3A'), ('S1-ENGL302-ABPS3B'), ('S1-HIST201-ABPS3A'), ('S1-HIST201-ABPS3B'), ('S1-HIST220-ABPS3A'), ('S1-HIST220-ABPS3B'), ('S1-REL303A-ABPS3A'), ('S1-REL303A-ABPS3B'), ('S1-POLS410-ABPS4A'), ('S1-POLS410-ABPS4B'), ('S1-LGLS402-ABPS4A'), ('S1-LGLS402-ABPS4B'), ('S1-LGLS403-ABPS4A'), ('S1-LGLS403-ABPS4B'), ('S1-LGLS404-ABPS4A'), ('S1-LGLS404-ABPS4B'), ('S1-REL403-ABPS4A'), ('S1-REL403-ABPS4B'), ('S1-COMM101-ABC1'), ('S1-COMM120-ABC1'), ('S1-MATH180-ABC1'), ('S1-ARTS101-ABC1'), ('S1-PE101-ABC1'), ('S1-CWTS101-ABC1'), ('S1-UNI103-ABC1'), ('S1-REL103A-ABC1'), ('S1-COMM112-ABC2'), ('S1-COMM210-ABC2'), ('S1-COMM221-ABC2'), ('S1-SOCS195-ABC2'), ('S1-STS180-ABC2'), ('S1-HIST201-ABC2'), ('S1-PE201-ABC2'), ('S1-REL203A-ABC2'), ('S1-COMM212-ABC3'), ('S1-COMM220-ABC3'), ('S1-COMM240-ABC3'), ('S1-COMM310-ABC3'), ('S1-COMM311-ABC3'), ('S1-PHIL190-ABC3'), ('S1-GAD171-ABC3'), ('S1-REL303A-ABC3'), ('S1-COMM410-ABC4'), ('S1-COMM331-ABC4'), ('S1-COMM340-ABC4'), ('S1-HIST220-ABC4'), ('S1-REL403-ABC4'), ('S1-ECON101-ABEcon1'), ('S1-ECON130-ABEcon1'), ('S1-COMM120-ABEcon1'), ('S1-MATH180-ABEcon1'), ('S1-PE101-ABEcon1'), ('S1-CWTS101-ABEcon1'), ('S1-UNI103-ABEcon1'), ('S1-REL103A-ABEcon1'), ('S1-ECON120-ABEcon2'), ('S1-ECON121-ABEcon2'), ('S1-ECON210-ABEcon2'), ('S1-MATH350-ABEcon2'), ('S1-SOCS195-ABEcon2'), ('S1-ARTS101-ABEcon2'), ('S1-PE201-ABEcon2'), ('S1-REL203A-ABEcon2'), ('S1-ECON220-ABEcon3'), ('S1-ECON221-ABEcon3'), ('S1-ECON222-ABEcon3'), ('S1-ECON231-ABEcon3'), ('S1-ECON310-ABEcon3'), ('S1-PHIL220-ABEcon3'), ('S1-ENGL302-ABEcon3'), ('S1-REL303A-ABEcon3'), ('S1-ECON410-ABEcon4'), ('S1-ECON330-ABEcon4'), ('S1-GAD171-ABEcon4'), ('S1-HIST220-ABEcon4'), ('S1-REL403-ABEcon4')) as s(id)),
  m as (select o.id as old_id, n.id as new_id from public.classes o
    join public.classes n on n.sem = o.sem and n.course = o.course
     and (n.section = o.section or (o.section ~ '^(ABC|ABEcon|BLIS|BSEntrep) [1-4]A$' and n.section = left(o.section, -1)))
    where o.sem = 1 and o.id not in (select id from keep) and n.id in (select id from keep)),
  b as (update public.bookings b set class_id = m.new_id from m
    where b.class_id = m.old_id and not exists (select 1 from public.bookings x where x.class_id = m.new_id and x.part = b.part) returning 1),
  t as (update public.teacher_changes t set class_id = m.new_id from m
    where t.class_id = m.old_id and not exists (select 1 from public.teacher_changes x where x.class_id = m.new_id) returning 1),
  r as (update public.ge_requests t set class_id = m.new_id from m
    where t.class_id = m.old_id and not exists (select 1 from public.ge_requests x where x.class_id = m.new_id) returning 1),
  d as (update public.ge_decisions t set class_id = m.new_id from m
    where t.class_id = m.old_id and not exists (select 1 from public.ge_decisions x where x.class_id = m.new_id) returning 1),
  i as (update public.instructor_requests t set class_id = m.new_id from m
    where t.class_id = m.old_id and not exists (select 1 from public.instructor_requests x where x.class_id = m.new_id) returning 1)
select (select count(*) from b) as bookings_moved, (select count(*) from t) as teachers_moved,
  (select count(*) from r) + (select count(*) from d) + (select count(*) from i) as requests_moved;
-- Classes no longer in the curricula go, with whatever was booked for them.
delete from public.classes where sem = 1 and id not in (select id from (values ('S1-ACC101-BSA1A'), ('S1-ACC101-BSA1B'), ('S1-BUS101-BSA1A'), ('S1-BUS101-BSA1B'), ('S1-MATH180-BSA1A'), ('S1-MATH180-BSA1B'), ('S1-SOCS195-BSA1A'), ('S1-SOCS195-BSA1B'), ('S1-PE101-BSA1A'), ('S1-PE101-BSA1B'), ('S1-CWTS101-BSA1A'), ('S1-CWTS101-BSA1B'), ('S1-UNI103-BSA1A'), ('S1-UNI103-BSA1B'), ('S1-REL103A-BSA1A'), ('S1-REL103A-BSA1B'), ('S1-ACC201-BSA2A'), ('S1-ACC201-BSA2B'), ('S1-ACC210-BSA2A'), ('S1-ACC210-BSA2B'), ('S1-ACC221-BSA2A'), ('S1-ACC221-BSA2B'), ('S1-MATH350-BSA2A'), ('S1-MATH350-BSA2B'), ('S1-PSYC160-BSA2A'), ('S1-PSYC160-BSA2B'), ('S1-GAD171-BSA2A'), ('S1-GAD171-BSA2B'), ('S1-PE201-BSA2A'), ('S1-PE201-BSA2B'), ('S1-REL203A-BSA2A'), ('S1-REL203A-BSA2B'), ('S1-ACC203-BSA3A'), ('S1-ACC203-BSA3B'), ('S1-ACC231-BSA3A'), ('S1-ACC231-BSA3B'), ('S1-ACC241-BSA3A'), ('S1-ACC241-BSA3B'), ('S1-ACC250-BSA3A'), ('S1-ACC250-BSA3B'), ('S1-ACC301-BSA3A'), ('S1-ACC301-BSA3B'), ('S1-ACC222-BSA3A'), ('S1-ACC222-BSA3B'), ('S1-PHIL190-BSA3A'), ('S1-PHIL190-BSA3B'), ('S1-REL303A-BSA3A'), ('S1-REL303A-BSA3B'), ('S1-ACC312-BSA4A'), ('S1-ACC312-BSA4B'), ('S1-ACC303-BSA4A'), ('S1-ACC303-BSA4B'), ('S1-ACC313-BSA4A'), ('S1-ACC313-BSA4B'), ('S1-ACC341-BSA4A'), ('S1-ACC341-BSA4B'), ('S1-ACC410-BSA4A'), ('S1-ACC410-BSA4B'), ('S1-HIST201-BSA4A'), ('S1-HIST201-BSA4B'), ('S1-ENGL302-BSA4A'), ('S1-ENGL302-BSA4B'), ('S1-REL403-BSA4A'), ('S1-REL403-BSA4B'), ('S1-ENT101-BSEntrep1'), ('S1-BUS101-BSEntrep1'), ('S1-MATH180-BSEntrep1'), ('S1-PSYC160-BSEntrep1'), ('S1-PE101-BSEntrep1'), ('S1-CWTS101-BSEntrep1'), ('S1-UNI103-BSEntrep1'), ('S1-REL103A-BSEntrep1'), ('S1-ENT201-BSEntrep2'), ('S1-ENT203-BSEntrep2'), ('S1-BUS201-BSEntrep2'), ('S1-MATH350-BSEntrep2'), ('S1-FIL207-BSEntrep2'), ('S1-PE201-BSEntrep2'), ('S1-REL203A-BSEntrep2'), ('S1-ENT210-BSEntrep3'), ('S1-ENT301-BSEntrep3'), ('S1-BUS220-BSEntrep3'), ('S1-BUS230-BSEntrep3'), ('S1-ENT310-BSEntrep3'), ('S1-PHIL190-BSEntrep3'), ('S1-ARTS101-BSEntrep3'), ('S1-REL303A-BSEntrep3'), ('S1-ENT401-BSEntrep4'), ('S1-BUS302-BSEntrep4'), ('S1-HIST220-BSEntrep4'), ('S1-GAD171-BSEntrep4'), ('S1-REL403-BSEntrep4'), ('S1-BUS101-BSBA1A'), ('S1-BUS101-BSBA1B'), ('S1-BUS110-BSBA1A'), ('S1-BUS110-BSBA1B'), ('S1-MATH180-BSBA1A'), ('S1-MATH180-BSBA1B'), ('S1-PSYC160-BSBA1A'), ('S1-PSYC160-BSBA1B'), ('S1-PE101-BSBA1A'), ('S1-PE101-BSBA1B'), ('S1-CWTS101-BSBA1A'), ('S1-CWTS101-BSBA1B'), ('S1-UNI103-BSBA1A'), ('S1-UNI103-BSBA1B'), ('S1-REL103A-BSBA1A'), ('S1-REL103A-BSBA1B'), ('S1-BUS121-BSBA2A'), ('S1-BUS121-BSBA2B'), ('S1-BUS201-BSBA2A'), ('S1-BUS201-BSBA2B'), ('S1-BUS210-BSBA2A'), ('S1-BUS210-BSBA2B'), ('S1-STS180-BSBA2A'), ('S1-STS180-BSBA2B'), ('S1-PE201-BSBA2A'), ('S1-PE201-BSBA2B'), ('S1-REL203A-BSBA2A'), ('S1-REL203A-BSBA2B'), ('S1-BUS220-BSBA3A'), ('S1-BUS220-BSBA3B'), ('S1-BUS230-BSBA3A'), ('S1-BUS230-BSBA3B'), ('S1-FM301-BSBA3-FM'), ('S1-FM303-BSBA3-FM'), ('S1-MKT301-BSBA3-MKT'), ('S1-MKT302-BSBA3-MKT'), ('S1-BAN301-BSBA3-BAN'), ('S1-BAN302-BSBA3-BAN'), ('S1-PHIL220-BSBA3A'), ('S1-PHIL220-BSBA3B'), ('S1-ARTS101-BSBA3A'), ('S1-ARTS101-BSBA3B'), ('S1-REL303A-BSBA3A'), ('S1-REL303A-BSBA3B'), ('S1-BUS302-BSBA4A'), ('S1-BUS302-BSBA4B'), ('S1-BUS304-BSBA4A'), ('S1-BUS304-BSBA4B'), ('S1-FM401-BSBA4-FM'), ('S1-FM402-BSBA4-FM'), ('S1-MKT401-BSBA4-MKT'), ('S1-MKT402-BSBA4-MKT'), ('S1-BAN401-BSBA4-BAN'), ('S1-BAN402-BSBA4-BAN'), ('S1-HIST220-BSBA4A'), ('S1-HIST220-BSBA4B'), ('S1-REL403-BSBA4A'), ('S1-REL403-BSBA4B'), ('S1-THM101-BSTHM1A'), ('S1-THM101-BSTHM1B'), ('S1-THM110-BSTHM1A'), ('S1-THM110-BSTHM1B'), ('S1-MATH180-BSTHM1A'), ('S1-MATH180-BSTHM1B'), ('S1-PSYC160-BSTHM1A'), ('S1-PSYC160-BSTHM1B'), ('S1-PE101-BSTHM1A'), ('S1-PE101-BSTHM1B'), ('S1-CWTS101-BSTHM1A'), ('S1-CWTS101-BSTHM1B'), ('S1-UNI103-BSTHM1A'), ('S1-UNI103-BSTHM1B'), ('S1-REL103A-BSTHM1A'), ('S1-REL103A-BSTHM1B'), ('S1-THM201-BSTHM2A'), ('S1-THM201-BSTHM2B'), ('S1-THM202-BSTHM2A'), ('S1-THM202-BSTHM2B'), ('S1-THM203-BSTHM2A'), ('S1-THM203-BSTHM2B'), ('S1-FIL207-BSTHM2A'), ('S1-FIL207-BSTHM2B'), ('S1-PE201-BSTHM2A'), ('S1-PE201-BSTHM2B'), ('S1-REL203A-BSTHM2A'), ('S1-REL203A-BSTHM2B'), ('S1-THM212-BSTHM3A'), ('S1-THM212-BSTHM3B'), ('S1-THM220-BSTHM3A'), ('S1-THM220-BSTHM3B'), ('S1-THM231-BSTHM3A'), ('S1-THM231-BSTHM3B'), ('S1-THM301-BSTHM3A'), ('S1-THM301-BSTHM3B'), ('S1-THM303-BSTHM3A'), ('S1-THM303-BSTHM3B'), ('S1-PHIL190-BSTHM3A'), ('S1-PHIL190-BSTHM3B'), ('S1-ARTS101-BSTHM3A'), ('S1-ARTS101-BSTHM3B'), ('S1-REL303A-BSTHM3A'), ('S1-REL303A-BSTHM3B'), ('S1-THM311-BSTHM4A'), ('S1-THM311-BSTHM4B'), ('S1-THM321-BSTHM4A'), ('S1-THM321-BSTHM4B'), ('S1-HIST201-BSTHM4A'), ('S1-HIST201-BSTHM4B'), ('S1-HIST220-BSTHM4A'), ('S1-HIST220-BSTHM4B'), ('S1-GAD171-BSTHM4A'), ('S1-GAD171-BSTHM4B'), ('S1-REL403-BSTHM4A'), ('S1-REL403-BSTHM4B'), ('S1-CRIM101-BSCrim1A'), ('S1-CRIM101-BSCrim1B'), ('S1-CLJ101-BSCrim1A'), ('S1-CLJ101-BSCrim1B'), ('S1-CRIM104-BSCrim1A'), ('S1-CRIM104-BSCrim1B'), ('S1-MATH180-BSCrim1A'), ('S1-MATH180-BSCrim1B'), ('S1-PSYC160-BSCrim1A'), ('S1-PSYC160-BSCrim1B'), ('S1-COMM120-BSCrim1A'), ('S1-COMM120-BSCrim1B'), ('S1-PE101-BSCrim1A'), ('S1-PE101-BSCrim1B'), ('S1-CWTS101-BSCrim1A'), ('S1-CWTS101-BSCrim1B'), ('S1-UNI103-BSCrim1A'), ('S1-UNI103-BSCrim1B'), ('S1-REL103A-BSCrim1A'), ('S1-REL103A-BSCrim1B'), ('S1-LEA101-BSCrim2A'), ('S1-LEA101-BSCrim2B'), ('S1-CDI101-BSCrim2A'), ('S1-CDI101-BSCrim2B'), ('S1-CA101-BSCrim2A'), ('S1-CA101-BSCrim2B'), ('S1-CLJ104-BSCrim2A'), ('S1-CLJ104-BSCrim2B'), ('S1-CLJ105-BSCrim2A'), ('S1-CLJ105-BSCrim2B'), ('S1-FOR102-BSCrim2A'), ('S1-FOR102-BSCrim2B'), ('S1-PE201-BSCrim2A'), ('S1-PE201-BSCrim2B'), ('S1-REL203A-BSCrim2A'), ('S1-REL203A-BSCrim2B'), ('S1-LEA104-BSCrim3A'), ('S1-LEA104-BSCrim3B'), ('S1-CDI104-BSCrim3A'), ('S1-CDI104-BSCrim3B'), ('S1-CDI105-BSCrim3A'), ('S1-CDI105-BSCrim3B'), ('S1-CLJ106-BSCrim3A'), ('S1-CLJ106-BSCrim3B'), ('S1-FOR104-BSCrim3A'), ('S1-FOR104-BSCrim3B'), ('S1-CRIM107-BSCrim3A'), ('S1-CRIM107-BSCrim3B'), ('S1-FIL207-BSCrim3A'), ('S1-FIL207-BSCrim3B'), ('S1-REL303A-BSCrim3A'), ('S1-REL303A-BSCrim3B'), ('S1-LEA106-BSCrim4A'), ('S1-LEA106-BSCrim4B'), ('S1-CDI108-BSCrim4A'), ('S1-CDI108-BSCrim4B'), ('S1-FOR106-BSCrim4A'), ('S1-FOR106-BSCrim4B'), ('S1-PHIL190-BSCrim4A'), ('S1-PHIL190-BSCrim4B'), ('S1-ARTS101-BSCrim4A'), ('S1-ARTS101-BSCrim4B'), ('S1-HIST201-BSCrim4A'), ('S1-HIST201-BSCrim4B'), ('S1-GAD171-BSCrim4A'), ('S1-GAD171-BSCrim4B'), ('S1-REL403-BSCrim4A'), ('S1-REL403-BSCrim4B'), ('S1-PAD101-ABPA1'), ('S1-SOCS195-ABPA1'), ('S1-COMM120-ABPA1'), ('S1-MATH180-ABPA1'), ('S1-PE101-ABPA1'), ('S1-CWTS101-ABPA1'), ('S1-UNI103-ABPA1'), ('S1-REL103A-ABPA1'), ('S1-PAD104-ABPA2'), ('S1-PAD105-ABPA2'), ('S1-PAD201-ABPA2'), ('S1-MATH350-ABPA2'), ('S1-PHIL190-ABPA2'), ('S1-PE201-ABPA2'), ('S1-REL203A-ABPA2'), ('S1-PAD204-ABPA3'), ('S1-PAD206-ABPA3'), ('S1-PAD205-ABPA3'), ('S1-PAD305-ABPA3'), ('S1-PAD309-ABPA3'), ('S1-PHIL220-ABPA3'), ('S1-ARTS101-ABPA3'), ('S1-REL303A-ABPA3'), ('S1-PAD410-ABPA4'), ('S1-HIST220-ABPA4'), ('S1-GAD171-ABPA4'), ('S1-REL403-ABPA4'), ('S1-SW101-BSSW1'), ('S1-MATH180-BSSW1'), ('S1-PSYC160-BSSW1'), ('S1-COMM120-BSSW1'), ('S1-SOCS195-BSSW1'), ('S1-PE101-BSSW1'), ('S1-CWTS101-BSSW1'), ('S1-UNI103-BSSW1'), ('S1-REL103A-BSSW1'), ('S1-SW201-BSSW2'), ('S1-SW202-BSSW2'), ('S1-SW205-BSSW2'), ('S1-MATH350-BSSW2'), ('S1-PE201-BSSW2'), ('S1-REL203A-BSSW2'), ('S1-SW301-BSSW3'), ('S1-SW305-BSSW3'), ('S1-SW306-BSSW3'), ('S1-SW308-BSSW3'), ('S1-SW310-BSSW3'), ('S1-PHIL190-BSSW3'), ('S1-ARTS101-BSSW3'), ('S1-ENGL302-BSSW3'), ('S1-REL303A-BSSW3'), ('S1-SW490-BSSW4'), ('S1-SW313-BSSW4'), ('S1-HIST220-BSSW4'), ('S1-REL403-BSSW4'), ('S1-CCS101-BSCS1A'), ('S1-CCS101-BSCS1B'), ('S1-CCS102-BSCS1A'), ('S1-CCS102-BSCS1B'), ('S1-CS110-BSCS1A'), ('S1-CS110-BSCS1B'), ('S1-SOCS195-BSCS1A'), ('S1-SOCS195-BSCS1B'), ('S1-MATH180-BSCS1A'), ('S1-MATH180-BSCS1B'), ('S1-PE101-BSCS1A'), ('S1-PE101-BSCS1B'), ('S1-CWTS101-BSCS1A'), ('S1-CWTS101-BSCS1B'), ('S1-UNI103-BSCS1A'), ('S1-UNI103-BSCS1B'), ('S1-REL103A-BSCS1A'), ('S1-REL103A-BSCS1B'), ('S1-CCS201-BSCS2A'), ('S1-CCS201-BSCS2B'), ('S1-CS230-BSCS2A'), ('S1-CS230-BSCS2B'), ('S1-CS220-BSCS2A'), ('S1-CS220-BSCS2B'), ('S1-CS240-BSCS2A'), ('S1-CS240-BSCS2B'), ('S1-PSYC160-BSCS2A'), ('S1-PSYC160-BSCS2B'), ('S1-PE201-BSCS2A'), ('S1-PE201-BSCS2B'), ('S1-REL203A-BSCS2A'), ('S1-REL203A-BSCS2B'), ('S1-CS310-BSCS3A'), ('S1-CS310-BSCS3B'), ('S1-CS330-BSCS3A'), ('S1-CS330-BSCS3B'), ('S1-CS350-BSCS3A'), ('S1-CS350-BSCS3B'), ('S1-CS390-BSCS3A'), ('S1-CS390-BSCS3B'), ('S1-MATH350-BSCS3A'), ('S1-MATH350-BSCS3B'), ('S1-ARTS101-BSCS3A'), ('S1-ARTS101-BSCS3B'), ('S1-PHIL190-BSCS3A'), ('S1-PHIL190-BSCS3B'), ('S1-REL303A-BSCS3A'), ('S1-REL303A-BSCS3B'), ('S1-CS430-BSCS4A'), ('S1-CS430-BSCS4B'), ('S1-CS410-BSCS4A'), ('S1-CS410-BSCS4B'), ('S1-HIST201-BSCS4A'), ('S1-HIST201-BSCS4B'), ('S1-HIST220-BSCS4A'), ('S1-HIST220-BSCS4B'), ('S1-ENGL302-BSCS4A'), ('S1-ENGL302-BSCS4B'), ('S1-GAD171-BSCS4A'), ('S1-GAD171-BSCS4B'), ('S1-REL403-BSCS4A'), ('S1-REL403-BSCS4B'), ('S1-CCS101-BSIT1A'), ('S1-CCS101-BSIT1B'), ('S1-CCS102-BSIT1A'), ('S1-CCS102-BSIT1B'), ('S1-IT110-BSIT1A'), ('S1-IT110-BSIT1B'), ('S1-COMM120-BSIT1A'), ('S1-COMM120-BSIT1B'), ('S1-MATH180-BSIT1A'), ('S1-MATH180-BSIT1B'), ('S1-PE101-BSIT1A'), ('S1-PE101-BSIT1B'), ('S1-CWTS101-BSIT1A'), ('S1-CWTS101-BSIT1B'), ('S1-UNI103-BSIT1A'), ('S1-UNI103-BSIT1B'), ('S1-REL103A-BSIT1A'), ('S1-REL103A-BSIT1B'), ('S1-CCS201-BSIT2A'), ('S1-CCS201-BSIT2B'), ('S1-IT210-BSIT2A'), ('S1-IT210-BSIT2B'), ('S1-IT230-BSIT2A'), ('S1-IT230-BSIT2B'), ('S1-STS180-BSIT2A'), ('S1-STS180-BSIT2B'), ('S1-MATH350-BSIT2A'), ('S1-MATH350-BSIT2B'), ('S1-SOCS195-BSIT2A'), ('S1-SOCS195-BSIT2B'), ('S1-PE201-BSIT2A'), ('S1-PE201-BSIT2B'), ('S1-REL203A-BSIT2A'), ('S1-REL203A-BSIT2B'), ('S1-IT250-BSIT3A'), ('S1-IT250-BSIT3B'), ('S1-IT310-BSIT3A'), ('S1-IT310-BSIT3B'), ('S1-IT330-BSIT3A'), ('S1-IT330-BSIT3B'), ('S1-IT360-BSIT3A'), ('S1-IT360-BSIT3B'), ('S1-IT370-BSIT3A'), ('S1-IT370-BSIT3B'), ('S1-ENGL302-BSIT3A'), ('S1-ENGL302-BSIT3B'), ('S1-PHIL190-BSIT3A'), ('S1-PHIL190-BSIT3B'), ('S1-REL303A-BSIT3A'), ('S1-REL303A-BSIT3B'), ('S1-IT430-BSIT4A'), ('S1-IT430-BSIT4B'), ('S1-IT390-BSIT4A'), ('S1-IT390-BSIT4B'), ('S1-IT410-BSIT4A'), ('S1-IT410-BSIT4B'), ('S1-HIST201-BSIT4A'), ('S1-HIST201-BSIT4B'), ('S1-HIST220-BSIT4A'), ('S1-HIST220-BSIT4B'), ('S1-GAD171-BSIT4A'), ('S1-GAD171-BSIT4B'), ('S1-REL403-BSIT4A'), ('S1-REL403-BSIT4B'), ('S1-LIS101-BLIS1'), ('S1-LIS102-BLIS1'), ('S1-COMM120-BLIS1'), ('S1-MATH180-BLIS1'), ('S1-PE101-BLIS1'), ('S1-CWTS101-BLIS1'), ('S1-UNI103-BLIS1'), ('S1-REL103A-BLIS1'), ('S1-LIS201-BLIS2'), ('S1-LIS211-BLIS2'), ('S1-LIS230-BLIS2'), ('S1-SOCS195-BLIS2'), ('S1-MATH350-BLIS2'), ('S1-ENGL302-BLIS2'), ('S1-PE201-BLIS2'), ('S1-REL203A-BLIS2'), ('S1-LIS220-BLIS3'), ('S1-LIS240-BLIS3'), ('S1-LIS301-BLIS3'), ('S1-LIS304-BLIS3'), ('S1-LIS330-BLIS3'), ('S1-PHIL190-BLIS3'), ('S1-ARTS101-BLIS3'), ('S1-REL303A-BLIS3'), ('S1-LIS410-BLIS4'), ('S1-LIS320-BLIS4'), ('S1-HIST220-BLIS4'), ('S1-GAD171-BLIS4'), ('S1-REL403-BLIS4'), ('S1-ED101-BEEd1'), ('S1-ED102-BEEd1'), ('S1-MATH180-BEEd1'), ('S1-SOCS195-BEEd1'), ('S1-PE101-BEEd1'), ('S1-CWTS101-BEEd1'), ('S1-PSYC160-BEEd1'), ('S1-UNI103-BEEd1'), ('S1-REL103A-BEEd1'), ('S1-ED201-BEEd2'), ('S1-ED202-BEEd2'), ('S1-ED204-BEEd2'), ('S1-EED101-BEEd2'), ('S1-EED140-BEEd2'), ('S1-EED150-BEEd2'), ('S1-PE201-BEEd2'), ('S1-REL203A-BEEd2'), ('S1-ED301-BEEd3'), ('S1-ED303-BEEd3'), ('S1-ED304-BEEd3'), ('S1-EED102-BEEd3'), ('S1-EED151-BEEd3'), ('S1-EED160-BEEd3'), ('S1-EED180-BEEd3'), ('S1-PHIL190-BEEd3'), ('S1-REL303A-BEEd3'), ('S1-ED401-BEEd4'), ('S1-ED402-BEEd4'), ('S1-EED181-BEEd4'), ('S1-ENGL302-BEEd4'), ('S1-HIST201-BEEd4'), ('S1-HIST220-BEEd4'), ('S1-GAD171-BEEd4'), ('S1-REL403-BEEd4'), ('S1-ED101-BSEd-E1'), ('S1-SEE101-BSEd-E1'), ('S1-MATH180-BSEd-E1'), ('S1-PSYC160-BSEd-E1'), ('S1-COMM120-BSEd-E1'), ('S1-CWTS101-BSEd-E1'), ('S1-PE101-BSEd-E1'), ('S1-UNI103-BSEd-E1'), ('S1-REL103A-BSEd-E1'), ('S1-ED201-BSEd-E2'), ('S1-ED202-BSEd-E2'), ('S1-ED204-BSEd-E2'), ('S1-SEE201-BSEd-E2'), ('S1-SEE202-BSEd-E2'), ('S1-MATH350-BSEd-E2'), ('S1-PHIL190-BSEd-E2'), ('S1-PE201-BSEd-E2'), ('S1-REL203A-BSEd-E2'), ('S1-ED301-BSEd-E3'), ('S1-ED303-BSEd-E3'), ('S1-ED304-BSEd-E3'), ('S1-SEE301-BSEd-E3'), ('S1-SEE302-BSEd-E3'), ('S1-SEE303-BSEd-E3'), ('S1-PHIL220-BSEd-E3'), ('S1-ENGL302-BSEd-E3'), ('S1-REL303A-BSEd-E3'), ('S1-ED401-BSEd-E4'), ('S1-ED402-BSEd-E4'), ('S1-SEE401-BSEd-E4'), ('S1-SEE402-BSEd-E4'), ('S1-SEE403-BSEd-E4'), ('S1-SEE404-BSEd-E4'), ('S1-SEE405-BSEd-E4'), ('S1-REL403-BSEd-E4'), ('S1-ED101-BSEd-M1'), ('S1-SEM101-BSEd-M1'), ('S1-MATH180-BSEd-M1'), ('S1-PSYC160-BSEd-M1'), ('S1-COMM120-BSEd-M1'), ('S1-CWTS101-BSEd-M1'), ('S1-PE101-BSEd-M1'), ('S1-UNI103-BSEd-M1'), ('S1-REL103A-BSEd-M1'), ('S1-ED201-BSEd-M2'), ('S1-ED202-BSEd-M2'), ('S1-ED204-BSEd-M2'), ('S1-SEM201-BSEd-M2'), ('S1-SEM202-BSEd-M2'), ('S1-MATH350-BSEd-M2'), ('S1-PHIL190-BSEd-M2'), ('S1-PE201-BSEd-M2'), ('S1-REL203A-BSEd-M2'), ('S1-ED301-BSEd-M3'), ('S1-ED303-BSEd-M3'), ('S1-ED304-BSEd-M3'), ('S1-SEM301-BSEd-M3'), ('S1-SEM302-BSEd-M3'), ('S1-SEM303-BSEd-M3'), ('S1-PHIL220-BSEd-M3'), ('S1-ENGL302-BSEd-M3'), ('S1-REL303A-BSEd-M3'), ('S1-ED401-BSEd-M4'), ('S1-ED402-BSEd-M4'), ('S1-SEM401-BSEd-M4'), ('S1-SEM402-BSEd-M4'), ('S1-SEM403-BSEd-M4'), ('S1-SEM404-BSEd-M4'), ('S1-SEM405-BSEd-M4'), ('S1-REL403-BSEd-M4'), ('S1-ED101-BSEd-SS1'), ('S1-SES101-BSEd-SS1'), ('S1-MATH180-BSEd-SS1'), ('S1-PSYC160-BSEd-SS1'), ('S1-COMM120-BSEd-SS1'), ('S1-CWTS101-BSEd-SS1'), ('S1-PE101-BSEd-SS1'), ('S1-UNI103-BSEd-SS1'), ('S1-REL103A-BSEd-SS1'), ('S1-ED201-BSEd-SS2'), ('S1-ED202-BSEd-SS2'), ('S1-ED204-BSEd-SS2'), ('S1-SES201-BSEd-SS2'), ('S1-SES202-BSEd-SS2'), ('S1-MATH350-BSEd-SS2'), ('S1-PHIL190-BSEd-SS2'), ('S1-PE201-BSEd-SS2'), ('S1-REL203A-BSEd-SS2'), ('S1-ED301-BSEd-SS3'), ('S1-ED303-BSEd-SS3'), ('S1-ED304-BSEd-SS3'), ('S1-SES301-BSEd-SS3'), ('S1-SES302-BSEd-SS3'), ('S1-SES303-BSEd-SS3'), ('S1-PHIL220-BSEd-SS3'), ('S1-ENGL302-BSEd-SS3'), ('S1-REL303A-BSEd-SS3'), ('S1-ED401-BSEd-SS4'), ('S1-ED402-BSEd-SS4'), ('S1-SES401-BSEd-SS4'), ('S1-SES402-BSEd-SS4'), ('S1-SES403-BSEd-SS4'), ('S1-SES404-BSEd-SS4'), ('S1-SES405-BSEd-SS4'), ('S1-REL403-BSEd-SS4'), ('S1-ED101-BSEd-F1'), ('S1-SEF101-BSEd-F1'), ('S1-MATH180-BSEd-F1'), ('S1-PSYC160-BSEd-F1'), ('S1-COMM120-BSEd-F1'), ('S1-CWTS101-BSEd-F1'), ('S1-PE101-BSEd-F1'), ('S1-UNI103-BSEd-F1'), ('S1-REL103A-BSEd-F1'), ('S1-ED201-BSEd-F2'), ('S1-ED202-BSEd-F2'), ('S1-ED204-BSEd-F2'), ('S1-SEF201-BSEd-F2'), ('S1-SEF202-BSEd-F2'), ('S1-MATH350-BSEd-F2'), ('S1-PHIL190-BSEd-F2'), ('S1-PE201-BSEd-F2'), ('S1-REL203A-BSEd-F2'), ('S1-ED301-BSEd-F3'), ('S1-ED303-BSEd-F3'), ('S1-ED304-BSEd-F3'), ('S1-SEF301-BSEd-F3'), ('S1-SEF302-BSEd-F3'), ('S1-SEF303-BSEd-F3'), ('S1-PHIL220-BSEd-F3'), ('S1-ENGL302-BSEd-F3'), ('S1-REL303A-BSEd-F3'), ('S1-ED401-BSEd-F4'), ('S1-ED402-BSEd-F4'), ('S1-SEF401-BSEd-F4'), ('S1-SEF402-BSEd-F4'), ('S1-SEF403-BSEd-F4'), ('S1-SEF404-BSEd-F4'), ('S1-SEF405-BSEd-F4'), ('S1-REL403-BSEd-F4'), ('S1-PSYC101-BSP1A'), ('S1-PSYC101-BSP1B'), ('S1-PSYC160-BSP1A'), ('S1-PSYC160-BSP1B'), ('S1-MATH180-BSP1A'), ('S1-MATH180-BSP1B'), ('S1-STS180-BSP1A'), ('S1-STS180-BSP1B'), ('S1-PE101-BSP1A'), ('S1-PE101-BSP1B'), ('S1-CWTS101-BSP1A'), ('S1-CWTS101-BSP1B'), ('S1-UNI103-BSP1A'), ('S1-UNI103-BSP1B'), ('S1-REL103A-BSP1A'), ('S1-REL103A-BSP1B'), ('S1-PSYC130-BSP2A'), ('S1-PSYC130-BSP2B'), ('S1-PSYC210-BSP2A'), ('S1-PSYC210-BSP2B'), ('S1-PSYC220-BSP2A'), ('S1-PSYC220-BSP2B'), ('S1-SOCS195-BSP2A'), ('S1-SOCS195-BSP2B'), ('S1-PHIL190-BSP2A'), ('S1-PHIL190-BSP2B'), ('S1-PE201-BSP2A'), ('S1-PE201-BSP2B'), ('S1-REL203A-BSP2A'), ('S1-REL203A-BSP2B'), ('S1-PSYC240-BSP3C'), ('S1-PSYC240-BSP3IO'), ('S1-PSYC280-BSP3C'), ('S1-PSYC280-BSP3IO'), ('S1-PSYC310-BSP3C'), ('S1-PSYC310-BSP3IO'), ('S1-PSYC320-BSP3C'), ('S1-PSYC320-BSP3IO'), ('S1-PSYC351-BSP3C'), ('S1-PSYC361-BSP3IO'), ('S1-HIST201-BSP3C'), ('S1-HIST201-BSP3IO'), ('S1-ARTS101-BSP3C'), ('S1-ARTS101-BSP3IO'), ('S1-REL303A-BSP3C'), ('S1-REL303A-BSP3IO'), ('S1-PSYC410-BSP4C'), ('S1-PSYC410-BSP4IO'), ('S1-PSYC451-BSP4C'), ('S1-PSYC452-BSP4C'), ('S1-PSYC461-BSP4IO'), ('S1-PSYC462-BSP4IO'), ('S1-REL403-BSP4C'), ('S1-REL403-BSP4IO'), ('S1-POLS101-ABPS1A'), ('S1-POLS101-ABPS1B'), ('S1-SOCS195-ABPS1A'), ('S1-SOCS195-ABPS1B'), ('S1-COMM120-ABPS1A'), ('S1-COMM120-ABPS1B'), ('S1-MATH180-ABPS1A'), ('S1-MATH180-ABPS1B'), ('S1-PE101-ABPS1A'), ('S1-PE101-ABPS1B'), ('S1-CWTS101-ABPS1A'), ('S1-CWTS101-ABPS1B'), ('S1-UNI103-ABPS1A'), ('S1-UNI103-ABPS1B'), ('S1-REL103A-ABPS1A'), ('S1-REL103A-ABPS1B'), ('S1-POLS210-ABPS2A'), ('S1-POLS210-ABPS2B'), ('S1-POLS220-ABPS2A'), ('S1-POLS220-ABPS2B'), ('S1-LGLS201-ABPS2A'), ('S1-LGLS201-ABPS2B'), ('S1-PSYC160-ABPS2A'), ('S1-PSYC160-ABPS2B'), ('S1-PHIL190-ABPS2A'), ('S1-PHIL190-ABPS2B'), ('S1-PE201-ABPS2A'), ('S1-PE201-ABPS2B'), ('S1-REL203A-ABPS2A'), ('S1-REL203A-ABPS2B'), ('S1-POLS250-ABPS3A'), ('S1-POLS250-ABPS3B'), ('S1-POLS260-ABPS3A'), ('S1-POLS260-ABPS3B'), ('S1-LGLS302-ABPS3A'), ('S1-LGLS302-ABPS3B'), ('S1-LGLS303-ABPS3A'), ('S1-LGLS303-ABPS3B'), ('S1-ENGL302-ABPS3A'), ('S1-ENGL302-ABPS3B'), ('S1-HIST201-ABPS3A'), ('S1-HIST201-ABPS3B'), ('S1-HIST220-ABPS3A'), ('S1-HIST220-ABPS3B'), ('S1-REL303A-ABPS3A'), ('S1-REL303A-ABPS3B'), ('S1-POLS410-ABPS4A'), ('S1-POLS410-ABPS4B'), ('S1-LGLS402-ABPS4A'), ('S1-LGLS402-ABPS4B'), ('S1-LGLS403-ABPS4A'), ('S1-LGLS403-ABPS4B'), ('S1-LGLS404-ABPS4A'), ('S1-LGLS404-ABPS4B'), ('S1-REL403-ABPS4A'), ('S1-REL403-ABPS4B'), ('S1-COMM101-ABC1'), ('S1-COMM120-ABC1'), ('S1-MATH180-ABC1'), ('S1-ARTS101-ABC1'), ('S1-PE101-ABC1'), ('S1-CWTS101-ABC1'), ('S1-UNI103-ABC1'), ('S1-REL103A-ABC1'), ('S1-COMM112-ABC2'), ('S1-COMM210-ABC2'), ('S1-COMM221-ABC2'), ('S1-SOCS195-ABC2'), ('S1-STS180-ABC2'), ('S1-HIST201-ABC2'), ('S1-PE201-ABC2'), ('S1-REL203A-ABC2'), ('S1-COMM212-ABC3'), ('S1-COMM220-ABC3'), ('S1-COMM240-ABC3'), ('S1-COMM310-ABC3'), ('S1-COMM311-ABC3'), ('S1-PHIL190-ABC3'), ('S1-GAD171-ABC3'), ('S1-REL303A-ABC3'), ('S1-COMM410-ABC4'), ('S1-COMM331-ABC4'), ('S1-COMM340-ABC4'), ('S1-HIST220-ABC4'), ('S1-REL403-ABC4'), ('S1-ECON101-ABEcon1'), ('S1-ECON130-ABEcon1'), ('S1-COMM120-ABEcon1'), ('S1-MATH180-ABEcon1'), ('S1-PE101-ABEcon1'), ('S1-CWTS101-ABEcon1'), ('S1-UNI103-ABEcon1'), ('S1-REL103A-ABEcon1'), ('S1-ECON120-ABEcon2'), ('S1-ECON121-ABEcon2'), ('S1-ECON210-ABEcon2'), ('S1-MATH350-ABEcon2'), ('S1-SOCS195-ABEcon2'), ('S1-ARTS101-ABEcon2'), ('S1-PE201-ABEcon2'), ('S1-REL203A-ABEcon2'), ('S1-ECON220-ABEcon3'), ('S1-ECON221-ABEcon3'), ('S1-ECON222-ABEcon3'), ('S1-ECON231-ABEcon3'), ('S1-ECON310-ABEcon3'), ('S1-PHIL220-ABEcon3'), ('S1-ENGL302-ABEcon3'), ('S1-REL303A-ABEcon3'), ('S1-ECON410-ABEcon4'), ('S1-ECON330-ABEcon4'), ('S1-GAD171-ABEcon4'), ('S1-HIST220-ABEcon4'), ('S1-REL403-ABEcon4')) as s(id));
-- Departments that may teach each GE course (kept as edited on the Settings page).
update public.ge_teachers set college = 'CICS' where college = 'CISC';
insert into public.ge_teachers (course, department, college) values
  ('COMM 120', 'Communication', 'CSS'),
  ('COMM 120', 'Secondary Education', 'COE'),
  ('FIL 207', 'Secondary Education', 'COE'),
  ('GAD 171', 'Elementary Education', 'COE'),
  ('GAD 171', 'Psychology', 'CSS'),
  ('GAD 171', 'Social Work', 'CCJPS'),
  ('HIST 201', 'Secondary Education', 'COE'),
  ('HIST 220', 'Secondary Education', 'COE'),
  ('MATH 180', 'Elementary Education', 'COE'),
  ('MATH 180', 'Secondary Education', 'COE'),
  ('MATH 350', 'Computer Science', 'CICS'),
  ('MATH 350', 'Secondary Education', 'COE'),
  ('PSYC 160', 'Elementary Education', 'COE'),
  ('PSYC 160', 'Psychology', 'CSS'),
  ('PSYC 160', 'Social Work', 'CCJPS'),
  ('SOCS 195', 'Economics', 'CSS'),
  ('SOCS 195', 'Public Administration', 'CCJPS'),
  ('SOCS 195', 'Secondary Education', 'COE'),
  ('STS 180', 'Information Technology', 'CICS'),
  ('UNI 103', 'Accountancy', 'CBE'),
  ('UNI 103', 'Business Administration', 'CBE'),
  ('UNI 103', 'Communication', 'CSS'),
  ('UNI 103', 'Computer Science', 'CICS'),
  ('UNI 103', 'Criminology', 'CCJPS'),
  ('UNI 103', 'Economics', 'CSS'),
  ('UNI 103', 'Elementary Education', 'COE'),
  ('UNI 103', 'Entrepreneurship', 'CBE'),
  ('UNI 103', 'Information Technology', 'CICS'),
  ('UNI 103', 'Library and Information Science', 'CICS'),
  ('UNI 103', 'Political Science', 'CSS'),
  ('UNI 103', 'Psychology', 'CSS'),
  ('UNI 103', 'Public Administration', 'CCJPS'),
  ('UNI 103', 'Secondary Education', 'COE'),
  ('UNI 103', 'Social Work', 'CCJPS'),
  ('UNI 103', 'Tourism and Hospitality Management', 'CBE')
on conflict (course, department) do nothing;
-- Working tables made by an earlier version of this script.
drop schema if exists seed cascade;

-- The first account with full access (the Registrar). Add everyone else on the Settings page.
insert into public.staff (email, full_name, role) values ('agbayanispencer@gmail.com', 'University Registrar', 'registrar')
on conflict (email) do nothing;

-- Remove requests that an earlier setup sent by itself (chairs now ask instructors of submitted departments).
delete from public.ge_decisions where class_id in (select class_id from public.ge_requests where requested_by = 'setup');
delete from public.ge_requests where requested_by = 'setup';
