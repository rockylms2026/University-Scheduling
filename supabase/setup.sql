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
  college    text not null,          -- CSS, CISC, CBE, COE, CCJPS, GE
  department text not null,
  rank       text,
  designation text,
  max_lu     int not null default 24
);
-- What each instructor specializes in, typed on the Faculty Profiles page by the Registrar or the Dean.
alter table public.faculty add column if not exists specialization text;

create table if not exists public.classes (
  id           text primary key,     -- e.g. S1-0646
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
  role       text not null check (role in ('registrar', 'dean', 'associate_dean', 'chair', 'ge_coordinator')),
  college    text,                   -- associate deans and chairs
  department text,                   -- chairs
  updated_at timestamptz not null default now(),
  check (role <> 'associate_dean' or college is not null),
  check (role <> 'chair' or (college is not null and department is not null))
);

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
  if t is null or me.role <> 'chair' then return true; end if;
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
begin;
insert into public.faculty (key, name, college, department, rank, designation, max_lu) values
  ('CBE-A1', 'Dr. Leonora B. Velasco', 'CBE', 'Accountancy', 'Associate Professor I', 'Department Chair', 15),
  ('CBE-A2', 'Atty. Ronaldo P. Marquez', 'CBE', 'Accountancy', 'Assistant Professor II', 'Faculty', 24),
  ('CBE-A3', 'Ms. Charmaine D. Uy', 'CBE', 'Accountancy', 'Assistant Professor I', 'Review Coordinator', 24),
  ('CBE-A4', 'Mr. Jerico M. Valencia', 'CBE', 'Accountancy', 'Assistant Professor I', 'Internship Coordinator', 24),
  ('CBE-A5', 'Ms. Abigail T. Flores', 'CBE', 'Accountancy', 'Instructor III', 'Faculty', 24),
  ('CBE-B1', 'Dr. Estela M. Torres', 'CBE', 'Business Administration', 'Associate Professor I', 'Department Chair', 15),
  ('CBE-B2', 'Mr. Rodel P. Morales', 'CBE', 'Business Administration', 'Assistant Professor I', 'Financial Management Coordinator', 24),
  ('CBE-B3', 'Ms. Liezl G. Castro', 'CBE', 'Business Administration', 'Assistant Professor I', 'Marketing Coordinator', 24),
  ('CBE-B4', 'Mr. Adrian V. Ramirez', 'CBE', 'Business Administration', 'Instructor III', 'Business Analytics Coordinator', 24),
  ('CBE-B5', 'Ms. Josephine L. Delos Reyes', 'CBE', 'Business Administration', 'Instructor III', 'Department GE Handler; Internship Coordinator', 24),
  ('CBE-B6', 'Mr. Francis Noel D. Galang', 'CBE', 'Business Administration', 'Instructor III', 'Faculty', 24),
  ('CBE-H1', 'Dr. Marilou C. Padilla', 'CBE', 'Tourism and Hospitality Management', 'Associate Professor I', 'Department Chair', 15),
  ('CBE-H2', 'Mr. Paolo R. Gutierrez', 'CBE', 'Tourism and Hospitality Management', 'Instructor III', 'Kitchen Laboratory Coordinator', 24),
  ('CBE-H3', 'Ms. Trisha M. Samonte', 'CBE', 'Tourism and Hospitality Management', 'Assistant Professor I', 'Faculty', 24),
  ('CBE-H4', 'Mr. Lorenzo D. Buenaventura', 'CBE', 'Tourism and Hospitality Management', 'Assistant Professor I', 'Practicum Coordinator', 24),
  ('CBE-H5', 'Ms. Jasmin L. Sarmiento', 'CBE', 'Tourism and Hospitality Management', 'Instructor II', 'Faculty', 24),
  ('CBE-N1', 'Dr. Ramil S. Gonzales', 'CBE', 'Entrepreneurship', 'Associate Professor I', 'Department Chair', 15),
  ('CBE-N2', 'Ms. Kristel A. Rivera', 'CBE', 'Entrepreneurship', 'Assistant Professor I', 'Faculty', 24),
  ('CBE-N3', 'Mr. Joel C. Aguilar', 'CBE', 'Entrepreneurship', 'Instructor III', 'Faculty', 24),
  ('CBE-N4', 'Ms. Aileen R. Javier', 'CBE', 'Entrepreneurship', 'Instructor III', 'Incubation Coordinator', 24),
  ('CCJPS-D1', 'Dr. Reynaldo C. Villamor', 'CCJPS', 'Public Administration', 'Associate Professor I', 'Department Chair', 15),
  ('CCJPS-D2', 'Ms. Lorna G. Fabian', 'CCJPS', 'Public Administration', 'Assistant Professor I', 'Faculty', 24),
  ('CCJPS-D3', 'Mr. Joel R. Macapagal', 'CCJPS', 'Public Administration', 'Instructor III', 'Internship Coordinator; Department GE Handler (SOCS 195)', 24),
  ('CCJPS-D4', 'Atty. Kristine D. Ramos', 'CCJPS', 'Public Administration', 'Instructor III', 'Department GE Handler (SOCS 195)', 24),
  ('CCJPS-R1', 'Dr. Nestor B. Alcaraz', 'CCJPS', 'Criminology', 'Associate Professor I', 'Department Chair', 15),
  ('CCJPS-R2', 'Atty. Celeste M. Rivera', 'CCJPS', 'Criminology', 'Assistant Professor II', 'Faculty', 24),
  ('CCJPS-R3', 'Mr. Herminio D. Bagasbas', 'CCJPS', 'Criminology', 'Assistant Professor I', 'Internship Coordinator', 24),
  ('CCJPS-R4', 'Ms. Janine F. Corpuz', 'CCJPS', 'Criminology', 'Instructor III', 'Crime Laboratory Coordinator', 24),
  ('CCJPS-R5', 'Mr. Rodrigo P. Salvador', 'CCJPS', 'Criminology', 'Instructor III', 'Faculty', 24),
  ('CCJPS-R6', 'Ms. Marjorie L. Pascual', 'CCJPS', 'Criminology', 'Instructor II', 'Faculty', 24),
  ('CCJPS-W1', 'Dr. Evangeline P. Soriano', 'CCJPS', 'Social Work', 'Associate Professor I', 'Department Chair', 15),
  ('CCJPS-W2', 'Ms. Rhea Lyn C. Galang', 'CCJPS', 'Social Work', 'Assistant Professor I', 'Field Instruction Coordinator; Department GE Handler (PSYC 160)', 24),
  ('CCJPS-W3', 'Mr. Emmanuel T. Dacanay', 'CCJPS', 'Social Work', 'Instructor III', 'Faculty', 24),
  ('CCJPS-W4', 'Ms. Charisse M. Lopez', 'CCJPS', 'Social Work', 'Instructor II', 'Department GE Handler (GAD 171, PSYC 160)', 24),
  ('CISC-B1', 'Dr. Evelyn M. Lim', 'CISC', 'Library and Information Science', 'Associate Professor I', 'Department Chair', 15),
  ('CISC-B2', 'Ms. Rosalind T. Garcia', 'CISC', 'Library and Information Science', 'Assistant Professor I', 'Faculty; second GE handler', 24),
  ('CISC-B3', 'Ms. Pauline A. de Guzman', 'CISC', 'Library and Information Science', 'Instructor III', 'Department GE Handler', 24),
  ('CISC-B4', 'Mr. Arvin C. Tan', 'CISC', 'Library and Information Science', 'Assistant Professor I', 'Library Technology Coordinator', 24),
  ('CISC-B5', 'Ms. Grace L. Bernardo', 'CISC', 'Library and Information Science', 'Instructor III', 'Practicum Coordinator', 24),
  ('CISC-C1', 'Dr. Arnel P. Macaraeg', 'CISC', 'Computer Science', 'Associate Professor I', 'Department Chair', 15),
  ('CISC-C2', 'Mr. Carlo Miguel D. Santiago', 'CISC', 'Computer Science', 'Assistant Professor I', 'Thesis and Practicum Coordinator', 24),
  ('CISC-C3', 'Dr. Jasmine T. Lorenzo', 'CISC', 'Computer Science', 'Assistant Professor II', 'Research Coordinator; second GE handler', 24),
  ('CISC-C4', 'Mr. Noel B. Ferrer', 'CISC', 'Computer Science', 'Instructor III', 'Laboratory Coordinator', 24),
  ('CISC-C5', 'Ms. Rhea Anne L. Cruz', 'CISC', 'Computer Science', 'Assistant Professor I', 'Department GE Handler', 24),
  ('CISC-C6', 'Mr. Kevin S. Domingo', 'CISC', 'Computer Science', 'Instructor II', 'Faculty', 24),
  ('CISC-T1', 'Dr. Marivic S. Pascual', 'CISC', 'Information Technology', 'Associate Professor I', 'Department Chair', 15),
  ('CISC-T2', 'Mr. Ramon J. Villareal', 'CISC', 'Information Technology', 'Assistant Professor I', 'Laboratory Coordinator; second GE handler', 24),
  ('CISC-T3', 'Ms. Diane Mae R. Caballero', 'CISC', 'Information Technology', 'Instructor III', 'Faculty', 24),
  ('CISC-T4', 'Mr. Francis G. Ignacio', 'CISC', 'Information Technology', 'Assistant Professor I', 'Capstone and Practicum Coordinator', 24),
  ('CISC-T5', 'Ms. Jennifer C. Salazar', 'CISC', 'Information Technology', 'Instructor III', 'Faculty', 24),
  ('CISC-T6', 'Mr. Antonio L. Mendoza', 'CISC', 'Information Technology', 'Instructor II', 'Department GE Handler', 24),
  ('COE-E1', 'Dr. Remedios A. Tamayo', 'COE', 'Elementary Education', 'Associate Professor I', 'Department Chair', 15),
  ('COE-E2', 'Ms. Analyn F. Vasquez', 'COE', 'Elementary Education', 'Assistant Professor I', 'Faculty', 24),
  ('COE-E3', 'Mr. Virgilio S. Quijano', 'COE', 'Elementary Education', 'Assistant Professor I', 'Field Study and Internship Coordinator', 24),
  ('COE-E4', 'Ms. Josefina R. Obispo', 'COE', 'Elementary Education', 'Instructor III', 'Faculty', 24),
  ('COE-E5', 'Mr. Ariel M. Baltazar', 'COE', 'Elementary Education', 'Instructor III', 'Faculty', 24),
  ('COE-S1', 'Dr. Teresa G. Evangelista', 'COE', 'Secondary Education', 'Associate Professor II', 'Department Chair', 15),
  ('COE-S10', 'Ms. Divina P. Magbanua', 'COE', 'Secondary Education', 'Instructor III', 'Social Sciences Major Coordinator', 24),
  ('COE-S11', 'Dr. Amado T. Nepomuceno', 'COE', 'Secondary Education', 'Assistant Professor II', 'Filipino Major Coordinator', 24),
  ('COE-S12', 'Ms. Liwayway C. Salvador', 'COE', 'Secondary Education', 'Instructor III', 'Department GE Handler (FIL 207)', 24),
  ('COE-S13', 'Mr. Emilio D. Arceo', 'COE', 'Secondary Education', 'Instructor II', 'Faculty', 24),
  ('COE-S14', 'Ms. Rosario F. Guevarra', 'COE', 'Secondary Education', 'Instructor II', 'Faculty', 24),
  ('COE-S15', 'Ms. Bianca Mae T. Villanueva', 'COE', 'Secondary Education', 'Instructor II', 'Faculty', 24),
  ('COE-S16', 'Mr. Jonathan R. Belmonte', 'COE', 'Secondary Education', 'Instructor II', 'Faculty', 24),
  ('COE-S2', 'Dr. Manuel A. Francisco', 'COE', 'Secondary Education', 'Associate Professor I', 'Field Study and Internship Coordinator', 24),
  ('COE-S4', 'Mr. Julius B. Natividad', 'COE', 'Secondary Education', 'Instructor III', 'Faculty', 24),
  ('COE-S5', 'Dr. Rebecca L. Medina', 'COE', 'Secondary Education', 'Assistant Professor II', 'English Major Coordinator', 24),
  ('COE-S6', 'Mr. Nathaniel C. Ortega', 'COE', 'Secondary Education', 'Instructor III', 'Faculty', 24),
  ('COE-S7', 'Dr. Rodolfo M. Umali', 'COE', 'Secondary Education', 'Assistant Professor II', 'Mathematics Major Coordinator', 24),
  ('COE-S8', 'Ms. Kimberly D. Saldana', 'COE', 'Secondary Education', 'Instructor III', 'Department GE Handler (MATH 180, MATH 350)', 24),
  ('COE-S9', 'Mr. Rogelio O. Legaspi', 'COE', 'Secondary Education', 'Assistant Professor I', 'Department GE Handler (HIST 201, HIST 220)', 24),
  ('CSS-E1', 'Dr. Florante S. Mangubat', 'CSS', 'Economics', 'Associate Professor I', 'Department Chair', 15),
  ('CSS-E2', 'Dr. Imelda R. Cabrera', 'CSS', 'Economics', 'Assistant Professor III', 'Research Coordinator', 24),
  ('CSS-E3', 'Mr. Ronnel T. Salonga', 'CSS', 'Economics', 'Assistant Professor I', 'Faculty', 24),
  ('CSS-E4', 'Ms. Katrina V. Lucero', 'CSS', 'Economics', 'Instructor III', 'Department GE Handler; Internship Coordinator', 24),
  ('CSS-E5', 'Mr. Jose Emmanuel P. Sison', 'CSS', 'Economics', 'Instructor II', 'Department GE Handler', 24),
  ('CSS-L1', 'Dr. Ernesto V. Dimaculangan', 'CSS', 'Political Science', 'Associate Professor I', 'Department Chair', 15),
  ('CSS-L2', 'Atty. Mariel S. Agustin', 'CSS', 'Political Science', 'Assistant Professor II', 'Legal Studies Coordinator; second GE handler', 24),
  ('CSS-L3', 'Atty. Rafael T. Bautista', 'CSS', 'Political Science', 'Assistant Professor I', 'Internship Coordinator', 24),
  ('CSS-L4', 'Mr. Paolo D. Ilagan', 'CSS', 'Political Science', 'Instructor III', 'Department GE Handler', 24),
  ('CSS-L5', 'Ms. Liza Marie G. Soriano', 'CSS', 'Political Science', 'Instructor III', 'Department GE Handler', 24),
  ('CSS-M1', 'Dr. Teresita L. Valdez', 'CSS', 'Communication', 'Associate Professor I', 'Department Chair', 15),
  ('CSS-M2', 'Mr. Gabriel N. Ocampo', 'CSS', 'Communication', 'Assistant Professor I', 'Faculty', 24),
  ('CSS-M3', 'Mr. Daniel F. Robles', 'CSS', 'Communication', 'Instructor III', 'Media Laboratory Coordinator', 24),
  ('CSS-M4', 'Ms. Patricia Anne E. Yap', 'CSS', 'Communication', 'Assistant Professor I', 'Internship Coordinator; second GE handler', 24),
  ('CSS-M5', 'Ms. Camille R. Navarro', 'CSS', 'Communication', 'Instructor II', 'Department GE Handler', 24),
  ('CSS-P1', 'Dr. Rowena C. Dalisay', 'CSS', 'Psychology', 'Associate Professor II', 'Department Chair', 15),
  ('CSS-P2', 'Ms. Kristine Joy M. Lacsamana', 'CSS', 'Psychology', 'Assistant Professor I', 'Faculty; second GE handler', 24),
  ('CSS-P3', 'Mr. Joaquin R. Esguerra', 'CSS', 'Psychology', 'Assistant Professor I', 'I-O Track Coordinator', 24),
  ('CSS-P4', 'Dr. Benedict A. Manalastas', 'CSS', 'Psychology', 'Assistant Professor III', 'Research Coordinator', 24),
  ('CSS-P5', 'Ms. Angelica P. Tolentino', 'CSS', 'Psychology', 'Instructor III', 'Department GE Handler', 24),
  ('GE-G1', 'Dr. Ma. Luisa T. Pangilinan', 'GE', 'General Education', 'Associate Professor I', 'GE Department Coordinator', 15),
  ('GE-G10', 'Ms. Kathleen T. Robles', 'GE', 'General Education', 'Instructor III', 'Faculty', 24),
  ('GE-G11', 'Ms. Danica F. Salvador', 'GE', 'General Education', 'Instructor II', 'Faculty', 24),
  ('GE-G12', 'Mr. Dennis A. Cortez', 'GE', 'General Education', 'Instructor II', 'PE Coordinator', 24),
  ('GE-G13', 'Ms. Rowena J. Manzano', 'GE', 'General Education', 'Instructor III', 'Faculty', 24),
  ('GE-G14', 'Mr. Mark Joseph L. Tuazon', 'GE', 'General Education', 'Instructor II', 'Faculty', 24),
  ('GE-G15', 'Ms. Irene C. Mallari', 'GE', 'General Education', 'Instructor II', 'Faculty', 24),
  ('GE-G16', 'Mr. Paulo V. Sison', 'GE', 'General Education', 'Instructor II', 'Faculty', 24),
  ('GE-G17', 'Ms. Maricar L. Bacani', 'GE', 'General Education', 'Instructor II', 'NSTP Coordinator', 24),
  ('GE-G18', 'Mr. Ramon D. Esteban', 'GE', 'General Education', 'Instructor II', 'Faculty', 24),
  ('GE-G19', 'Ms. Liezel P. Corpuz', 'GE', 'General Education', 'Instructor II', 'Faculty', 24),
  ('GE-G2', 'Mr. Bernardo C. Aquino', 'GE', 'General Education', 'Instructor III', 'Faculty', 24),
  ('GE-G3', 'Dr. Francis Xavier M. Tolentino', 'GE', 'General Education', 'Assistant Professor II', 'Faculty', 24),
  ('GE-G4', 'Ms. Angelica R. Soriano', 'GE', 'General Education', 'Instructor III', 'Faculty', 24),
  ('GE-G5', 'Ms. Hannah Grace V. Alvarez', 'GE', 'General Education', 'Instructor II', 'Humanities Coordinator', 24),
  ('GE-G6', 'Mr. Lorenzo P. Galvez', 'GE', 'General Education', 'Instructor III', 'Faculty', 24),
  ('GE-G7', 'Ms. Bea Katrina L. Navarro', 'GE', 'General Education', 'Instructor II', 'Faculty', 24),
  ('GE-G8', 'Dr. Rosemarie D. Aguilar', 'GE', 'General Education', 'Assistant Professor I', 'Writing Coordinator', 24),
  ('GE-G9', 'Mr. Joshua M. Cabanilla', 'GE', 'General Education', 'Instructor III', 'Faculty', 24)
on conflict (key) do update set name = excluded.name, college = excluded.college, department = excluded.department, rank = excluded.rank, designation = excluded.designation, max_lu = excluded.max_lu;
insert into public.classes (id, sem, course, section, program, college, department, is_ge, plan_teacher, house_dept, house_college) values
  ('S1-0001', 1, 'ACC 101', 'BSA 1A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0002', 1, 'ACC 101', 'BSA 1B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0003', 1, 'BUS 101', 'BSA 1A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0004', 1, 'BUS 101', 'BSA 1B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0005', 1, 'MATH 180', 'BSA 1A', 'BSA', 'CBE', 'Accountancy', true, null, 'Secondary Education', 'COE'),
  ('S1-0006', 1, 'MATH 180', 'BSA 1B', 'BSA', 'CBE', 'Accountancy', true, null, 'Secondary Education', 'COE'),
  ('S1-0007', 1, 'SOCS 195', 'BSA 1A', 'BSA', 'CBE', 'Accountancy', true, null, 'Economics', 'CSS'),
  ('S1-0008', 1, 'SOCS 195', 'BSA 1B', 'BSA', 'CBE', 'Accountancy', true, null, 'Economics', 'CSS'),
  ('S1-0009', 1, 'PE 101', 'BSA 1A', 'BSA', 'CBE', 'Accountancy', true, null, 'General Education', 'GE'),
  ('S1-0010', 1, 'PE 101', 'BSA 1B', 'BSA', 'CBE', 'Accountancy', true, null, 'General Education', 'GE'),
  ('S1-0011', 1, 'CWTS 101', 'BSA 1A', 'BSA', 'CBE', 'Accountancy', true, null, 'General Education', 'GE'),
  ('S1-0012', 1, 'CWTS 101', 'BSA 1B', 'BSA', 'CBE', 'Accountancy', true, null, 'General Education', 'GE'),
  ('S1-0013', 1, 'UNI 103', 'BSA 1A', 'BSA', 'CBE', 'Accountancy', true, null, 'Accountancy', 'CBE'),
  ('S1-0014', 1, 'UNI 103', 'BSA 1B', 'BSA', 'CBE', 'Accountancy', true, null, 'Accountancy', 'CBE'),
  ('S1-0015', 1, 'ACC 201', 'BSA 2A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0016', 1, 'ACC 201', 'BSA 2B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0017', 1, 'ACC 210', 'BSA 2A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0018', 1, 'ACC 210', 'BSA 2B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0019', 1, 'ACC 221', 'BSA 2A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0020', 1, 'ACC 221', 'BSA 2B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0021', 1, 'MATH 350', 'BSA 2A', 'BSA', 'CBE', 'Accountancy', true, null, 'Computer Science', 'CISC'),
  ('S1-0022', 1, 'MATH 350', 'BSA 2B', 'BSA', 'CBE', 'Accountancy', true, null, 'Computer Science', 'CISC'),
  ('S1-0023', 1, 'PSYC 160', 'BSA 2A', 'BSA', 'CBE', 'Accountancy', true, null, 'Psychology', 'CSS'),
  ('S1-0024', 1, 'PSYC 160', 'BSA 2B', 'BSA', 'CBE', 'Accountancy', true, null, 'Psychology', 'CSS'),
  ('S1-0025', 1, 'GAD 171', 'BSA 2A', 'BSA', 'CBE', 'Accountancy', true, null, 'Psychology', 'CSS'),
  ('S1-0026', 1, 'GAD 171', 'BSA 2B', 'BSA', 'CBE', 'Accountancy', true, null, 'Psychology', 'CSS'),
  ('S1-0027', 1, 'PE 201', 'BSA 2A', 'BSA', 'CBE', 'Accountancy', true, null, 'General Education', 'GE'),
  ('S1-0028', 1, 'PE 201', 'BSA 2B', 'BSA', 'CBE', 'Accountancy', true, null, 'General Education', 'GE'),
  ('S1-0029', 1, 'ACC 203', 'BSA 3A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0030', 1, 'ACC 203', 'BSA 3B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0031', 1, 'ACC 231', 'BSA 3A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0032', 1, 'ACC 231', 'BSA 3B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0033', 1, 'ACC 241', 'BSA 3A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0034', 1, 'ACC 241', 'BSA 3B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0035', 1, 'ACC 250', 'BSA 3A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0036', 1, 'ACC 250', 'BSA 3B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0037', 1, 'ACC 301', 'BSA 3A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0038', 1, 'ACC 301', 'BSA 3B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0039', 1, 'ACC 222', 'BSA 3A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0040', 1, 'ACC 222', 'BSA 3B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0041', 1, 'PHIL 190', 'BSA 3A', 'BSA', 'CBE', 'Accountancy', true, null, 'General Education', 'GE'),
  ('S1-0042', 1, 'PHIL 190', 'BSA 3B', 'BSA', 'CBE', 'Accountancy', true, null, 'General Education', 'GE'),
  ('S1-0043', 1, 'ACC 312', 'BSA 4A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0044', 1, 'ACC 312', 'BSA 4B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0045', 1, 'ACC 303', 'BSA 4A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0046', 1, 'ACC 303', 'BSA 4B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0047', 1, 'ACC 313', 'BSA 4A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0048', 1, 'ACC 313', 'BSA 4B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0049', 1, 'ACC 341', 'BSA 4A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0050', 1, 'ACC 341', 'BSA 4B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0051', 1, 'ACC 410', 'BSA 4A', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0052', 1, 'ACC 410', 'BSA 4B', 'BSA', 'CBE', 'Accountancy', false, null, null, null),
  ('S1-0053', 1, 'HIST 201', 'BSA 4A', 'BSA', 'CBE', 'Accountancy', true, null, 'Secondary Education', 'COE'),
  ('S1-0054', 1, 'HIST 201', 'BSA 4B', 'BSA', 'CBE', 'Accountancy', true, null, 'Secondary Education', 'COE'),
  ('S1-0055', 1, 'ENGL 302', 'BSA 4A', 'BSA', 'CBE', 'Accountancy', true, null, 'General Education', 'GE'),
  ('S1-0056', 1, 'ENGL 302', 'BSA 4B', 'BSA', 'CBE', 'Accountancy', true, null, 'General Education', 'GE'),
  ('S1-0057', 1, 'ENT 101', 'BSEntrep 1A', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-0058', 1, 'ENT 101', 'BSEntrep 1B', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-0059', 1, 'BUS 101', 'BSEntrep 1A', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-0060', 1, 'BUS 101', 'BSEntrep 1B', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-0061', 1, 'MATH 180', 'BSEntrep 1A', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Secondary Education', 'COE'),
  ('S1-0062', 1, 'MATH 180', 'BSEntrep 1B', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Secondary Education', 'COE'),
  ('S1-0063', 1, 'PSYC 160', 'BSEntrep 1A', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Psychology', 'CSS'),
  ('S1-0064', 1, 'PSYC 160', 'BSEntrep 1B', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Psychology', 'CSS'),
  ('S1-0065', 1, 'PE 101', 'BSEntrep 1A', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'General Education', 'GE'),
  ('S1-0066', 1, 'PE 101', 'BSEntrep 1B', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'General Education', 'GE'),
  ('S1-0067', 1, 'CWTS 101', 'BSEntrep 1A', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'General Education', 'GE'),
  ('S1-0068', 1, 'CWTS 101', 'BSEntrep 1B', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'General Education', 'GE'),
  ('S1-0069', 1, 'UNI 103', 'BSEntrep 1A', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Entrepreneurship', 'CBE'),
  ('S1-0070', 1, 'UNI 103', 'BSEntrep 1B', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Entrepreneurship', 'CBE'),
  ('S1-0071', 1, 'ENT 201', 'BSEntrep 2A', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-0072', 1, 'ENT 201', 'BSEntrep 2B', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-0073', 1, 'ENT 203', 'BSEntrep 2A', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-0074', 1, 'ENT 203', 'BSEntrep 2B', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-0075', 1, 'BUS 201', 'BSEntrep 2A', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-0076', 1, 'BUS 201', 'BSEntrep 2B', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-0077', 1, 'MATH 350', 'BSEntrep 2A', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Computer Science', 'CISC'),
  ('S1-0078', 1, 'MATH 350', 'BSEntrep 2B', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Computer Science', 'CISC'),
  ('S1-0079', 1, 'FIL 207', 'BSEntrep 2A', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Secondary Education', 'COE'),
  ('S1-0080', 1, 'FIL 207', 'BSEntrep 2B', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Secondary Education', 'COE'),
  ('S1-0081', 1, 'PE 201', 'BSEntrep 2A', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'General Education', 'GE'),
  ('S1-0082', 1, 'PE 201', 'BSEntrep 2B', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'General Education', 'GE'),
  ('S1-0083', 1, 'ENT 210', 'BSEntrep 3A', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-0084', 1, 'ENT 210', 'BSEntrep 3B', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-0085', 1, 'ENT 301', 'BSEntrep 3A', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-0086', 1, 'ENT 301', 'BSEntrep 3B', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-0087', 1, 'BUS 220', 'BSEntrep 3A', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-0088', 1, 'BUS 220', 'BSEntrep 3B', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-0089', 1, 'BUS 230', 'BSEntrep 3A', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-0090', 1, 'BUS 230', 'BSEntrep 3B', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-0091', 1, 'ENT 310', 'BSEntrep 3A', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-0092', 1, 'ENT 310', 'BSEntrep 3B', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-0093', 1, 'PHIL 190', 'BSEntrep 3A', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'General Education', 'GE'),
  ('S1-0094', 1, 'PHIL 190', 'BSEntrep 3B', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'General Education', 'GE'),
  ('S1-0095', 1, 'ARTS 101', 'BSEntrep 3A', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'General Education', 'GE'),
  ('S1-0096', 1, 'ARTS 101', 'BSEntrep 3B', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'General Education', 'GE'),
  ('S1-0097', 1, 'ENT 401', 'BSEntrep 4A', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-0098', 1, 'ENT 401', 'BSEntrep 4B', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-0099', 1, 'BUS 302', 'BSEntrep 4A', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-0100', 1, 'BUS 302', 'BSEntrep 4B', 'BSEntrep', 'CBE', 'Entrepreneurship', false, null, null, null),
  ('S1-0101', 1, 'HIST 220', 'BSEntrep 4A', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Secondary Education', 'COE'),
  ('S1-0102', 1, 'HIST 220', 'BSEntrep 4B', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Secondary Education', 'COE'),
  ('S1-0103', 1, 'GAD 171', 'BSEntrep 4A', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Psychology', 'CSS'),
  ('S1-0104', 1, 'GAD 171', 'BSEntrep 4B', 'BSEntrep', 'CBE', 'Entrepreneurship', true, null, 'Psychology', 'CSS'),
  ('S1-0105', 1, 'BUS 101', 'BSBA 1A', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0106', 1, 'BUS 101', 'BSBA 1B', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0107', 1, 'BUS 110', 'BSBA 1A', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0108', 1, 'BUS 110', 'BSBA 1B', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0109', 1, 'MATH 180', 'BSBA 1A', 'BSBA', 'CBE', 'Business Administration', true, null, 'Secondary Education', 'COE'),
  ('S1-0110', 1, 'MATH 180', 'BSBA 1B', 'BSBA', 'CBE', 'Business Administration', true, null, 'Secondary Education', 'COE'),
  ('S1-0111', 1, 'PSYC 160', 'BSBA 1A', 'BSBA', 'CBE', 'Business Administration', true, null, 'Psychology', 'CSS'),
  ('S1-0112', 1, 'PSYC 160', 'BSBA 1B', 'BSBA', 'CBE', 'Business Administration', true, null, 'Psychology', 'CSS'),
  ('S1-0113', 1, 'PE 101', 'BSBA 1A', 'BSBA', 'CBE', 'Business Administration', true, null, 'General Education', 'GE'),
  ('S1-0114', 1, 'PE 101', 'BSBA 1B', 'BSBA', 'CBE', 'Business Administration', true, null, 'General Education', 'GE'),
  ('S1-0115', 1, 'CWTS 101', 'BSBA 1A', 'BSBA', 'CBE', 'Business Administration', true, null, 'General Education', 'GE'),
  ('S1-0116', 1, 'CWTS 101', 'BSBA 1B', 'BSBA', 'CBE', 'Business Administration', true, null, 'General Education', 'GE'),
  ('S1-0117', 1, 'UNI 103', 'BSBA 1A', 'BSBA', 'CBE', 'Business Administration', true, null, 'Business Administration', 'CBE'),
  ('S1-0118', 1, 'UNI 103', 'BSBA 1B', 'BSBA', 'CBE', 'Business Administration', true, null, 'Business Administration', 'CBE'),
  ('S1-0119', 1, 'BUS 121', 'BSBA 2A', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0120', 1, 'BUS 121', 'BSBA 2B', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0121', 1, 'BUS 201', 'BSBA 2A', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0122', 1, 'BUS 201', 'BSBA 2B', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0123', 1, 'BUS 210', 'BSBA 2A', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0124', 1, 'BUS 210', 'BSBA 2B', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0125', 1, 'STS 180', 'BSBA 2A', 'BSBA', 'CBE', 'Business Administration', true, null, 'Information Technology', 'CISC'),
  ('S1-0126', 1, 'STS 180', 'BSBA 2B', 'BSBA', 'CBE', 'Business Administration', true, null, 'Information Technology', 'CISC'),
  ('S1-0127', 1, 'PE 201', 'BSBA 2A', 'BSBA', 'CBE', 'Business Administration', true, null, 'General Education', 'GE'),
  ('S1-0128', 1, 'PE 201', 'BSBA 2B', 'BSBA', 'CBE', 'Business Administration', true, null, 'General Education', 'GE'),
  ('S1-0129', 1, 'BUS 220', 'BSBA 3A', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0130', 1, 'BUS 220', 'BSBA 3B', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0131', 1, 'BUS 230', 'BSBA 3A', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0132', 1, 'BUS 230', 'BSBA 3B', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0133', 1, 'FM 301', 'BSBA 3-FM', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0134', 1, 'FM 303', 'BSBA 3-FM', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0135', 1, 'MKT 301', 'BSBA 3-MKT', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0136', 1, 'MKT 302', 'BSBA 3-MKT', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0137', 1, 'BAN 301', 'BSBA 3-BAN', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0138', 1, 'BAN 302', 'BSBA 3-BAN', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0139', 1, 'PHIL 220', 'BSBA 3A', 'BSBA', 'CBE', 'Business Administration', true, null, 'General Education', 'GE'),
  ('S1-0140', 1, 'PHIL 220', 'BSBA 3B', 'BSBA', 'CBE', 'Business Administration', true, null, 'General Education', 'GE'),
  ('S1-0141', 1, 'ARTS 101', 'BSBA 3A', 'BSBA', 'CBE', 'Business Administration', true, null, 'General Education', 'GE'),
  ('S1-0142', 1, 'ARTS 101', 'BSBA 3B', 'BSBA', 'CBE', 'Business Administration', true, null, 'General Education', 'GE'),
  ('S1-0143', 1, 'BUS 302', 'BSBA 4A', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0144', 1, 'BUS 302', 'BSBA 4B', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0145', 1, 'BUS 304', 'BSBA 4A', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0146', 1, 'BUS 304', 'BSBA 4B', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0147', 1, 'FM 401', 'BSBA 4-FM', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0148', 1, 'FM 402', 'BSBA 4-FM', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0149', 1, 'MKT 401', 'BSBA 4-MKT', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0150', 1, 'MKT 402', 'BSBA 4-MKT', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0151', 1, 'BAN 401', 'BSBA 4-BAN', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0152', 1, 'BAN 402', 'BSBA 4-BAN', 'BSBA', 'CBE', 'Business Administration', false, null, null, null),
  ('S1-0153', 1, 'HIST 220', 'BSBA 4A', 'BSBA', 'CBE', 'Business Administration', true, null, 'Secondary Education', 'COE'),
  ('S1-0154', 1, 'HIST 220', 'BSBA 4B', 'BSBA', 'CBE', 'Business Administration', true, null, 'Secondary Education', 'COE'),
  ('S1-0155', 1, 'THM 101', 'BSTHM 1A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-0156', 1, 'THM 101', 'BSTHM 1B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-0157', 1, 'THM 110', 'BSTHM 1A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-0158', 1, 'THM 110', 'BSTHM 1B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-0159', 1, 'MATH 180', 'BSTHM 1A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Secondary Education', 'COE'),
  ('S1-0160', 1, 'MATH 180', 'BSTHM 1B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Secondary Education', 'COE'),
  ('S1-0161', 1, 'PSYC 160', 'BSTHM 1A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Psychology', 'CSS'),
  ('S1-0162', 1, 'PSYC 160', 'BSTHM 1B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Psychology', 'CSS'),
  ('S1-0163', 1, 'PE 101', 'BSTHM 1A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'General Education', 'GE'),
  ('S1-0164', 1, 'PE 101', 'BSTHM 1B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'General Education', 'GE'),
  ('S1-0165', 1, 'CWTS 101', 'BSTHM 1A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'General Education', 'GE'),
  ('S1-0166', 1, 'CWTS 101', 'BSTHM 1B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'General Education', 'GE'),
  ('S1-0167', 1, 'UNI 103', 'BSTHM 1A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Tourism and Hospitality Management', 'CBE'),
  ('S1-0168', 1, 'UNI 103', 'BSTHM 1B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Tourism and Hospitality Management', 'CBE'),
  ('S1-0169', 1, 'THM 201', 'BSTHM 2A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-0170', 1, 'THM 201', 'BSTHM 2B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-0171', 1, 'THM 202', 'BSTHM 2A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-0172', 1, 'THM 202', 'BSTHM 2B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-0173', 1, 'THM 203', 'BSTHM 2A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-0174', 1, 'THM 203', 'BSTHM 2B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-0175', 1, 'FIL 207', 'BSTHM 2A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Secondary Education', 'COE'),
  ('S1-0176', 1, 'FIL 207', 'BSTHM 2B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Secondary Education', 'COE'),
  ('S1-0177', 1, 'PE 201', 'BSTHM 2A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'General Education', 'GE'),
  ('S1-0178', 1, 'PE 201', 'BSTHM 2B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'General Education', 'GE'),
  ('S1-0179', 1, 'THM 212', 'BSTHM 3A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-0180', 1, 'THM 212', 'BSTHM 3B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-0181', 1, 'THM 220', 'BSTHM 3A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-0182', 1, 'THM 220', 'BSTHM 3B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-0183', 1, 'THM 231', 'BSTHM 3A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-0184', 1, 'THM 231', 'BSTHM 3B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-0185', 1, 'THM 301', 'BSTHM 3A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-0186', 1, 'THM 301', 'BSTHM 3B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-0187', 1, 'THM 303', 'BSTHM 3A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-0188', 1, 'THM 303', 'BSTHM 3B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-0189', 1, 'PHIL 190', 'BSTHM 3A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'General Education', 'GE'),
  ('S1-0190', 1, 'PHIL 190', 'BSTHM 3B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'General Education', 'GE'),
  ('S1-0191', 1, 'ARTS 101', 'BSTHM 3A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'General Education', 'GE'),
  ('S1-0192', 1, 'ARTS 101', 'BSTHM 3B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'General Education', 'GE'),
  ('S1-0193', 1, 'THM 311', 'BSTHM 4A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-0194', 1, 'THM 311', 'BSTHM 4B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-0195', 1, 'THM 321', 'BSTHM 4A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-0196', 1, 'THM 321', 'BSTHM 4B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', false, null, null, null),
  ('S1-0197', 1, 'HIST 201', 'BSTHM 4A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Secondary Education', 'COE'),
  ('S1-0198', 1, 'HIST 201', 'BSTHM 4B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Secondary Education', 'COE'),
  ('S1-0199', 1, 'HIST 220', 'BSTHM 4A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Secondary Education', 'COE'),
  ('S1-0200', 1, 'HIST 220', 'BSTHM 4B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Secondary Education', 'COE'),
  ('S1-0201', 1, 'GAD 171', 'BSTHM 4A', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Psychology', 'CSS'),
  ('S1-0202', 1, 'GAD 171', 'BSTHM 4B', 'BSTHM', 'CBE', 'Tourism and Hospitality Management', true, null, 'Psychology', 'CSS'),
  ('S1-0203', 1, 'CRIM 101', 'BSCrim 1A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0204', 1, 'CRIM 101', 'BSCrim 1B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0205', 1, 'CLJ 101', 'BSCrim 1A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0206', 1, 'CLJ 101', 'BSCrim 1B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0207', 1, 'CRIM 104', 'BSCrim 1A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0208', 1, 'CRIM 104', 'BSCrim 1B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0209', 1, 'MATH 180', 'BSCrim 1A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Secondary Education', 'COE'),
  ('S1-0210', 1, 'MATH 180', 'BSCrim 1B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Secondary Education', 'COE'),
  ('S1-0211', 1, 'PSYC 160', 'BSCrim 1A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Psychology', 'CSS'),
  ('S1-0212', 1, 'PSYC 160', 'BSCrim 1B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Psychology', 'CSS'),
  ('S1-0213', 1, 'COMM 120', 'BSCrim 1A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Communication', 'CSS'),
  ('S1-0214', 1, 'COMM 120', 'BSCrim 1B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Communication', 'CSS'),
  ('S1-0215', 1, 'PE 101', 'BSCrim 1A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'General Education', 'GE'),
  ('S1-0216', 1, 'PE 101', 'BSCrim 1B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'General Education', 'GE'),
  ('S1-0217', 1, 'CWTS 101', 'BSCrim 1A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'General Education', 'GE'),
  ('S1-0218', 1, 'CWTS 101', 'BSCrim 1B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'General Education', 'GE'),
  ('S1-0219', 1, 'UNI 103', 'BSCrim 1A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Criminology', 'CCJPS'),
  ('S1-0220', 1, 'UNI 103', 'BSCrim 1B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Criminology', 'CCJPS'),
  ('S1-0221', 1, 'LEA 101', 'BSCrim 2A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0222', 1, 'LEA 101', 'BSCrim 2B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0223', 1, 'CDI 101', 'BSCrim 2A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0224', 1, 'CDI 101', 'BSCrim 2B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0225', 1, 'CA 101', 'BSCrim 2A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0226', 1, 'CA 101', 'BSCrim 2B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0227', 1, 'CLJ 104', 'BSCrim 2A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0228', 1, 'CLJ 104', 'BSCrim 2B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0229', 1, 'CLJ 105', 'BSCrim 2A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0230', 1, 'CLJ 105', 'BSCrim 2B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0231', 1, 'FOR 102', 'BSCrim 2A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0232', 1, 'FOR 102', 'BSCrim 2B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0233', 1, 'PE 201', 'BSCrim 2A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'General Education', 'GE'),
  ('S1-0234', 1, 'PE 201', 'BSCrim 2B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'General Education', 'GE'),
  ('S1-0235', 1, 'LEA 104', 'BSCrim 3A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0236', 1, 'LEA 104', 'BSCrim 3B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0237', 1, 'CDI 104', 'BSCrim 3A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0238', 1, 'CDI 104', 'BSCrim 3B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0239', 1, 'CDI 105', 'BSCrim 3A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0240', 1, 'CDI 105', 'BSCrim 3B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0241', 1, 'CLJ 106', 'BSCrim 3A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0242', 1, 'CLJ 106', 'BSCrim 3B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0243', 1, 'FOR 104', 'BSCrim 3A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0244', 1, 'FOR 104', 'BSCrim 3B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0245', 1, 'CRIM 107', 'BSCrim 3A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0246', 1, 'CRIM 107', 'BSCrim 3B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0247', 1, 'FIL 207', 'BSCrim 3A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Secondary Education', 'COE'),
  ('S1-0248', 1, 'FIL 207', 'BSCrim 3B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Secondary Education', 'COE'),
  ('S1-0249', 1, 'LEA 106', 'BSCrim 4A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0250', 1, 'LEA 106', 'BSCrim 4B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0251', 1, 'CDI 108', 'BSCrim 4A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0252', 1, 'CDI 108', 'BSCrim 4B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0253', 1, 'FOR 106', 'BSCrim 4A', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0254', 1, 'FOR 106', 'BSCrim 4B', 'BSCrim', 'CCJPS', 'Criminology', false, null, null, null),
  ('S1-0255', 1, 'PHIL 190', 'BSCrim 4A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'General Education', 'GE'),
  ('S1-0256', 1, 'PHIL 190', 'BSCrim 4B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'General Education', 'GE'),
  ('S1-0257', 1, 'ARTS 101', 'BSCrim 4A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'General Education', 'GE'),
  ('S1-0258', 1, 'ARTS 101', 'BSCrim 4B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'General Education', 'GE'),
  ('S1-0259', 1, 'HIST 201', 'BSCrim 4A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Secondary Education', 'COE'),
  ('S1-0260', 1, 'HIST 201', 'BSCrim 4B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Secondary Education', 'COE'),
  ('S1-0261', 1, 'HIST 220', 'BSCrim 4A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Secondary Education', 'COE'),
  ('S1-0262', 1, 'HIST 220', 'BSCrim 4B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Secondary Education', 'COE'),
  ('S1-0263', 1, 'GAD 171', 'BSCrim 4A', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Psychology', 'CSS'),
  ('S1-0264', 1, 'GAD 171', 'BSCrim 4B', 'BSCrim', 'CCJPS', 'Criminology', true, null, 'Psychology', 'CSS'),
  ('S1-0265', 1, 'PAD 101', 'ABPA 1', 'ABPA', 'CCJPS', 'Public Administration', false, null, null, null),
  ('S1-0266', 1, 'SOCS 195', 'ABPA 1', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'Economics', 'CSS'),
  ('S1-0267', 1, 'COMM 120', 'ABPA 1', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'Communication', 'CSS'),
  ('S1-0268', 1, 'MATH 180', 'ABPA 1', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'Secondary Education', 'COE'),
  ('S1-0269', 1, 'PE 101', 'ABPA 1', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'General Education', 'GE'),
  ('S1-0270', 1, 'CWTS 101', 'ABPA 1', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'General Education', 'GE'),
  ('S1-0271', 1, 'UNI 103', 'ABPA 1', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'Public Administration', 'CCJPS'),
  ('S1-0272', 1, 'PAD 104', 'ABPA 2', 'ABPA', 'CCJPS', 'Public Administration', false, null, null, null),
  ('S1-0273', 1, 'PAD 105', 'ABPA 2', 'ABPA', 'CCJPS', 'Public Administration', false, null, null, null),
  ('S1-0274', 1, 'PAD 201', 'ABPA 2', 'ABPA', 'CCJPS', 'Public Administration', false, null, null, null),
  ('S1-0275', 1, 'MATH 350', 'ABPA 2', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'Computer Science', 'CISC'),
  ('S1-0276', 1, 'PHIL 190', 'ABPA 2', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'General Education', 'GE'),
  ('S1-0277', 1, 'PE 201', 'ABPA 2', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'General Education', 'GE'),
  ('S1-0278', 1, 'PAD 204', 'ABPA 3', 'ABPA', 'CCJPS', 'Public Administration', false, null, null, null),
  ('S1-0279', 1, 'PAD 206', 'ABPA 3', 'ABPA', 'CCJPS', 'Public Administration', false, null, null, null),
  ('S1-0280', 1, 'PAD 205', 'ABPA 3', 'ABPA', 'CCJPS', 'Public Administration', false, null, null, null),
  ('S1-0281', 1, 'PAD 305', 'ABPA 3', 'ABPA', 'CCJPS', 'Public Administration', false, null, null, null),
  ('S1-0282', 1, 'PAD 309', 'ABPA 3', 'ABPA', 'CCJPS', 'Public Administration', false, null, null, null),
  ('S1-0283', 1, 'PHIL 220', 'ABPA 3', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'General Education', 'GE'),
  ('S1-0284', 1, 'ARTS 101', 'ABPA 3', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'General Education', 'GE'),
  ('S1-0285', 1, 'PAD 410', 'ABPA 4', 'ABPA', 'CCJPS', 'Public Administration', false, null, null, null),
  ('S1-0286', 1, 'HIST 220', 'ABPA 4', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'Secondary Education', 'COE'),
  ('S1-0287', 1, 'GAD 171', 'ABPA 4', 'ABPA', 'CCJPS', 'Public Administration', true, null, 'Psychology', 'CSS'),
  ('S1-0288', 1, 'SW 101', 'BSSW 1', 'BSSW', 'CCJPS', 'Social Work', false, null, null, null),
  ('S1-0289', 1, 'MATH 180', 'BSSW 1', 'BSSW', 'CCJPS', 'Social Work', true, null, 'Secondary Education', 'COE'),
  ('S1-0290', 1, 'PSYC 160', 'BSSW 1', 'BSSW', 'CCJPS', 'Social Work', true, null, 'Psychology', 'CSS'),
  ('S1-0291', 1, 'COMM 120', 'BSSW 1', 'BSSW', 'CCJPS', 'Social Work', true, null, 'Communication', 'CSS'),
  ('S1-0292', 1, 'SOCS 195', 'BSSW 1', 'BSSW', 'CCJPS', 'Social Work', true, null, 'Economics', 'CSS'),
  ('S1-0293', 1, 'PE 101', 'BSSW 1', 'BSSW', 'CCJPS', 'Social Work', true, null, 'General Education', 'GE'),
  ('S1-0294', 1, 'CWTS 101', 'BSSW 1', 'BSSW', 'CCJPS', 'Social Work', true, null, 'General Education', 'GE'),
  ('S1-0295', 1, 'UNI 103', 'BSSW 1', 'BSSW', 'CCJPS', 'Social Work', true, null, 'Social Work', 'CCJPS'),
  ('S1-0296', 1, 'SW 201', 'BSSW 2', 'BSSW', 'CCJPS', 'Social Work', false, null, null, null),
  ('S1-0297', 1, 'SW 202', 'BSSW 2', 'BSSW', 'CCJPS', 'Social Work', false, null, null, null),
  ('S1-0298', 1, 'SW 205', 'BSSW 2', 'BSSW', 'CCJPS', 'Social Work', false, null, null, null),
  ('S1-0299', 1, 'MATH 350', 'BSSW 2', 'BSSW', 'CCJPS', 'Social Work', true, null, 'Computer Science', 'CISC'),
  ('S1-0300', 1, 'PE 201', 'BSSW 2', 'BSSW', 'CCJPS', 'Social Work', true, null, 'General Education', 'GE'),
  ('S1-0301', 1, 'SW 301', 'BSSW 3', 'BSSW', 'CCJPS', 'Social Work', false, null, null, null),
  ('S1-0302', 1, 'SW 305', 'BSSW 3', 'BSSW', 'CCJPS', 'Social Work', false, null, null, null),
  ('S1-0303', 1, 'SW 306', 'BSSW 3', 'BSSW', 'CCJPS', 'Social Work', false, null, null, null),
  ('S1-0304', 1, 'SW 308', 'BSSW 3', 'BSSW', 'CCJPS', 'Social Work', false, null, null, null),
  ('S1-0305', 1, 'SW 310', 'BSSW 3', 'BSSW', 'CCJPS', 'Social Work', false, null, null, null),
  ('S1-0306', 1, 'PHIL 190', 'BSSW 3', 'BSSW', 'CCJPS', 'Social Work', true, null, 'General Education', 'GE'),
  ('S1-0307', 1, 'ARTS 101', 'BSSW 3', 'BSSW', 'CCJPS', 'Social Work', true, null, 'General Education', 'GE'),
  ('S1-0308', 1, 'ENGL 302', 'BSSW 3', 'BSSW', 'CCJPS', 'Social Work', true, null, 'General Education', 'GE'),
  ('S1-0309', 1, 'SW 490', 'BSSW 4', 'BSSW', 'CCJPS', 'Social Work', false, null, null, null),
  ('S1-0310', 1, 'SW 313', 'BSSW 4', 'BSSW', 'CCJPS', 'Social Work', false, null, null, null),
  ('S1-0311', 1, 'HIST 220', 'BSSW 4', 'BSSW', 'CCJPS', 'Social Work', true, null, 'Secondary Education', 'COE'),
  ('S1-0312', 1, 'CCS 101', 'BSCS 1A', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0313', 1, 'CCS 101', 'BSCS 1B', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0314', 1, 'CCS 102', 'BSCS 1A', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0315', 1, 'CCS 102', 'BSCS 1B', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0316', 1, 'CS 110', 'BSCS 1A', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0317', 1, 'CS 110', 'BSCS 1B', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0318', 1, 'SOCS 195', 'BSCS 1A', 'BSCS', 'CISC', 'Computer Science', true, null, 'Economics', 'CSS'),
  ('S1-0319', 1, 'SOCS 195', 'BSCS 1B', 'BSCS', 'CISC', 'Computer Science', true, null, 'Economics', 'CSS'),
  ('S1-0320', 1, 'MATH 180', 'BSCS 1A', 'BSCS', 'CISC', 'Computer Science', true, null, 'Secondary Education', 'COE'),
  ('S1-0321', 1, 'MATH 180', 'BSCS 1B', 'BSCS', 'CISC', 'Computer Science', true, null, 'Secondary Education', 'COE'),
  ('S1-0322', 1, 'PE 101', 'BSCS 1A', 'BSCS', 'CISC', 'Computer Science', true, null, 'General Education', 'GE'),
  ('S1-0323', 1, 'PE 101', 'BSCS 1B', 'BSCS', 'CISC', 'Computer Science', true, null, 'General Education', 'GE'),
  ('S1-0324', 1, 'CWTS 101', 'BSCS 1A', 'BSCS', 'CISC', 'Computer Science', true, null, 'General Education', 'GE'),
  ('S1-0325', 1, 'CWTS 101', 'BSCS 1B', 'BSCS', 'CISC', 'Computer Science', true, null, 'General Education', 'GE'),
  ('S1-0326', 1, 'UNI 103', 'BSCS 1A', 'BSCS', 'CISC', 'Computer Science', true, null, 'Computer Science', 'CISC'),
  ('S1-0327', 1, 'UNI 103', 'BSCS 1B', 'BSCS', 'CISC', 'Computer Science', true, null, 'Computer Science', 'CISC'),
  ('S1-0328', 1, 'CCS 201', 'BSCS 2A', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0329', 1, 'CCS 201', 'BSCS 2B', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0330', 1, 'CS 230', 'BSCS 2A', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0331', 1, 'CS 230', 'BSCS 2B', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0332', 1, 'CS 220', 'BSCS 2A', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0333', 1, 'CS 220', 'BSCS 2B', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0334', 1, 'CS 240', 'BSCS 2A', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0335', 1, 'CS 240', 'BSCS 2B', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0336', 1, 'PSYC 160', 'BSCS 2A', 'BSCS', 'CISC', 'Computer Science', true, null, 'Psychology', 'CSS'),
  ('S1-0337', 1, 'PSYC 160', 'BSCS 2B', 'BSCS', 'CISC', 'Computer Science', true, null, 'Psychology', 'CSS'),
  ('S1-0338', 1, 'PE 201', 'BSCS 2A', 'BSCS', 'CISC', 'Computer Science', true, null, 'General Education', 'GE'),
  ('S1-0339', 1, 'PE 201', 'BSCS 2B', 'BSCS', 'CISC', 'Computer Science', true, null, 'General Education', 'GE'),
  ('S1-0340', 1, 'CS 310', 'BSCS 3A', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0341', 1, 'CS 310', 'BSCS 3B', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0342', 1, 'CS 330', 'BSCS 3A', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0343', 1, 'CS 330', 'BSCS 3B', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0344', 1, 'CS 350', 'BSCS 3A', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0345', 1, 'CS 350', 'BSCS 3B', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0346', 1, 'CS 390', 'BSCS 3A', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0347', 1, 'CS 390', 'BSCS 3B', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0348', 1, 'MATH 350', 'BSCS 3A', 'BSCS', 'CISC', 'Computer Science', true, null, 'Computer Science', 'CISC'),
  ('S1-0349', 1, 'MATH 350', 'BSCS 3B', 'BSCS', 'CISC', 'Computer Science', true, null, 'Computer Science', 'CISC'),
  ('S1-0350', 1, 'ARTS 101', 'BSCS 3A', 'BSCS', 'CISC', 'Computer Science', true, null, 'General Education', 'GE'),
  ('S1-0351', 1, 'ARTS 101', 'BSCS 3B', 'BSCS', 'CISC', 'Computer Science', true, null, 'General Education', 'GE'),
  ('S1-0352', 1, 'PHIL 190', 'BSCS 3A', 'BSCS', 'CISC', 'Computer Science', true, null, 'General Education', 'GE'),
  ('S1-0353', 1, 'PHIL 190', 'BSCS 3B', 'BSCS', 'CISC', 'Computer Science', true, null, 'General Education', 'GE'),
  ('S1-0354', 1, 'CS 430', 'BSCS 4A', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0355', 1, 'CS 430', 'BSCS 4B', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0356', 1, 'CS 410', 'BSCS 4A', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0357', 1, 'CS 410', 'BSCS 4B', 'BSCS', 'CISC', 'Computer Science', false, null, null, null),
  ('S1-0358', 1, 'HIST 201', 'BSCS 4A', 'BSCS', 'CISC', 'Computer Science', true, null, 'Secondary Education', 'COE'),
  ('S1-0359', 1, 'HIST 201', 'BSCS 4B', 'BSCS', 'CISC', 'Computer Science', true, null, 'Secondary Education', 'COE'),
  ('S1-0360', 1, 'HIST 220', 'BSCS 4A', 'BSCS', 'CISC', 'Computer Science', true, null, 'Secondary Education', 'COE'),
  ('S1-0361', 1, 'HIST 220', 'BSCS 4B', 'BSCS', 'CISC', 'Computer Science', true, null, 'Secondary Education', 'COE'),
  ('S1-0362', 1, 'ENGL 302', 'BSCS 4A', 'BSCS', 'CISC', 'Computer Science', true, null, 'General Education', 'GE'),
  ('S1-0363', 1, 'ENGL 302', 'BSCS 4B', 'BSCS', 'CISC', 'Computer Science', true, null, 'General Education', 'GE'),
  ('S1-0364', 1, 'GAD 171', 'BSCS 4A', 'BSCS', 'CISC', 'Computer Science', true, null, 'Psychology', 'CSS'),
  ('S1-0365', 1, 'GAD 171', 'BSCS 4B', 'BSCS', 'CISC', 'Computer Science', true, null, 'Psychology', 'CSS'),
  ('S1-0366', 1, 'CCS 101', 'BSIT 1A', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0367', 1, 'CCS 101', 'BSIT 1B', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0368', 1, 'CCS 102', 'BSIT 1A', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0369', 1, 'CCS 102', 'BSIT 1B', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0370', 1, 'IT 110', 'BSIT 1A', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0371', 1, 'IT 110', 'BSIT 1B', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0372', 1, 'COMM 120', 'BSIT 1A', 'BSIT', 'CISC', 'Information Technology', true, null, 'Communication', 'CSS'),
  ('S1-0373', 1, 'COMM 120', 'BSIT 1B', 'BSIT', 'CISC', 'Information Technology', true, null, 'Communication', 'CSS'),
  ('S1-0374', 1, 'MATH 180', 'BSIT 1A', 'BSIT', 'CISC', 'Information Technology', true, null, 'Secondary Education', 'COE'),
  ('S1-0375', 1, 'MATH 180', 'BSIT 1B', 'BSIT', 'CISC', 'Information Technology', true, null, 'Secondary Education', 'COE'),
  ('S1-0376', 1, 'PE 101', 'BSIT 1A', 'BSIT', 'CISC', 'Information Technology', true, null, 'General Education', 'GE'),
  ('S1-0377', 1, 'PE 101', 'BSIT 1B', 'BSIT', 'CISC', 'Information Technology', true, null, 'General Education', 'GE'),
  ('S1-0378', 1, 'CWTS 101', 'BSIT 1A', 'BSIT', 'CISC', 'Information Technology', true, null, 'General Education', 'GE'),
  ('S1-0379', 1, 'CWTS 101', 'BSIT 1B', 'BSIT', 'CISC', 'Information Technology', true, null, 'General Education', 'GE'),
  ('S1-0380', 1, 'UNI 103', 'BSIT 1A', 'BSIT', 'CISC', 'Information Technology', true, null, 'Information Technology', 'CISC'),
  ('S1-0381', 1, 'UNI 103', 'BSIT 1B', 'BSIT', 'CISC', 'Information Technology', true, null, 'Information Technology', 'CISC'),
  ('S1-0382', 1, 'CCS 201', 'BSIT 2A', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0383', 1, 'CCS 201', 'BSIT 2B', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0384', 1, 'IT 210', 'BSIT 2A', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0385', 1, 'IT 210', 'BSIT 2B', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0386', 1, 'IT 230', 'BSIT 2A', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0387', 1, 'IT 230', 'BSIT 2B', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0388', 1, 'STS 180', 'BSIT 2A', 'BSIT', 'CISC', 'Information Technology', true, null, 'Information Technology', 'CISC'),
  ('S1-0389', 1, 'STS 180', 'BSIT 2B', 'BSIT', 'CISC', 'Information Technology', true, null, 'Information Technology', 'CISC'),
  ('S1-0390', 1, 'MATH 350', 'BSIT 2A', 'BSIT', 'CISC', 'Information Technology', true, null, 'Computer Science', 'CISC'),
  ('S1-0391', 1, 'MATH 350', 'BSIT 2B', 'BSIT', 'CISC', 'Information Technology', true, null, 'Computer Science', 'CISC'),
  ('S1-0392', 1, 'SOCS 195', 'BSIT 2A', 'BSIT', 'CISC', 'Information Technology', true, null, 'Economics', 'CSS'),
  ('S1-0393', 1, 'SOCS 195', 'BSIT 2B', 'BSIT', 'CISC', 'Information Technology', true, null, 'Economics', 'CSS'),
  ('S1-0394', 1, 'PE 201', 'BSIT 2A', 'BSIT', 'CISC', 'Information Technology', true, null, 'General Education', 'GE'),
  ('S1-0395', 1, 'PE 201', 'BSIT 2B', 'BSIT', 'CISC', 'Information Technology', true, null, 'General Education', 'GE'),
  ('S1-0396', 1, 'IT 250', 'BSIT 3A', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0397', 1, 'IT 250', 'BSIT 3B', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0398', 1, 'IT 310', 'BSIT 3A', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0399', 1, 'IT 310', 'BSIT 3B', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0400', 1, 'IT 330', 'BSIT 3A', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0401', 1, 'IT 330', 'BSIT 3B', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0402', 1, 'IT 360', 'BSIT 3A', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0403', 1, 'IT 360', 'BSIT 3B', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0404', 1, 'IT 370', 'BSIT 3A', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0405', 1, 'IT 370', 'BSIT 3B', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0406', 1, 'ENGL 302', 'BSIT 3A', 'BSIT', 'CISC', 'Information Technology', true, null, 'General Education', 'GE'),
  ('S1-0407', 1, 'ENGL 302', 'BSIT 3B', 'BSIT', 'CISC', 'Information Technology', true, null, 'General Education', 'GE'),
  ('S1-0408', 1, 'PHIL 190', 'BSIT 3A', 'BSIT', 'CISC', 'Information Technology', true, null, 'General Education', 'GE'),
  ('S1-0409', 1, 'PHIL 190', 'BSIT 3B', 'BSIT', 'CISC', 'Information Technology', true, null, 'General Education', 'GE'),
  ('S1-0410', 1, 'IT 430', 'BSIT 4A', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0411', 1, 'IT 430', 'BSIT 4B', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0412', 1, 'IT 390', 'BSIT 4A', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0413', 1, 'IT 390', 'BSIT 4B', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0414', 1, 'IT 410', 'BSIT 4A', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0415', 1, 'IT 410', 'BSIT 4B', 'BSIT', 'CISC', 'Information Technology', false, null, null, null),
  ('S1-0416', 1, 'HIST 201', 'BSIT 4A', 'BSIT', 'CISC', 'Information Technology', true, null, 'Secondary Education', 'COE'),
  ('S1-0417', 1, 'HIST 201', 'BSIT 4B', 'BSIT', 'CISC', 'Information Technology', true, null, 'Secondary Education', 'COE'),
  ('S1-0418', 1, 'HIST 220', 'BSIT 4A', 'BSIT', 'CISC', 'Information Technology', true, null, 'Secondary Education', 'COE'),
  ('S1-0419', 1, 'HIST 220', 'BSIT 4B', 'BSIT', 'CISC', 'Information Technology', true, null, 'Secondary Education', 'COE'),
  ('S1-0420', 1, 'GAD 171', 'BSIT 4A', 'BSIT', 'CISC', 'Information Technology', true, null, 'Psychology', 'CSS'),
  ('S1-0421', 1, 'GAD 171', 'BSIT 4B', 'BSIT', 'CISC', 'Information Technology', true, null, 'Psychology', 'CSS'),
  ('S1-0422', 1, 'LIS 101', 'BLIS 1A', 'BLIS', 'CISC', 'Library and Information Science', false, null, null, null),
  ('S1-0423', 1, 'LIS 101', 'BLIS 1B', 'BLIS', 'CISC', 'Library and Information Science', false, null, null, null),
  ('S1-0424', 1, 'LIS 102', 'BLIS 1A', 'BLIS', 'CISC', 'Library and Information Science', false, null, null, null),
  ('S1-0425', 1, 'LIS 102', 'BLIS 1B', 'BLIS', 'CISC', 'Library and Information Science', false, null, null, null),
  ('S1-0426', 1, 'COMM 120', 'BLIS 1A', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'Communication', 'CSS'),
  ('S1-0427', 1, 'COMM 120', 'BLIS 1B', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'Communication', 'CSS'),
  ('S1-0428', 1, 'MATH 180', 'BLIS 1A', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'Secondary Education', 'COE'),
  ('S1-0429', 1, 'MATH 180', 'BLIS 1B', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'Secondary Education', 'COE'),
  ('S1-0430', 1, 'PE 101', 'BLIS 1A', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'General Education', 'GE'),
  ('S1-0431', 1, 'PE 101', 'BLIS 1B', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'General Education', 'GE'),
  ('S1-0432', 1, 'CWTS 101', 'BLIS 1A', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'General Education', 'GE'),
  ('S1-0433', 1, 'CWTS 101', 'BLIS 1B', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'General Education', 'GE'),
  ('S1-0434', 1, 'UNI 103', 'BLIS 1A', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'Library and Information Science', 'CISC'),
  ('S1-0435', 1, 'UNI 103', 'BLIS 1B', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'Library and Information Science', 'CISC'),
  ('S1-0436', 1, 'LIS 201', 'BLIS 2A', 'BLIS', 'CISC', 'Library and Information Science', false, null, null, null),
  ('S1-0437', 1, 'LIS 201', 'BLIS 2B', 'BLIS', 'CISC', 'Library and Information Science', false, null, null, null),
  ('S1-0438', 1, 'LIS 211', 'BLIS 2A', 'BLIS', 'CISC', 'Library and Information Science', false, null, null, null),
  ('S1-0439', 1, 'LIS 211', 'BLIS 2B', 'BLIS', 'CISC', 'Library and Information Science', false, null, null, null),
  ('S1-0440', 1, 'LIS 230', 'BLIS 2A', 'BLIS', 'CISC', 'Library and Information Science', false, null, null, null),
  ('S1-0441', 1, 'LIS 230', 'BLIS 2B', 'BLIS', 'CISC', 'Library and Information Science', false, null, null, null),
  ('S1-0442', 1, 'SOCS 195', 'BLIS 2A', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'Economics', 'CSS'),
  ('S1-0443', 1, 'SOCS 195', 'BLIS 2B', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'Economics', 'CSS'),
  ('S1-0444', 1, 'MATH 350', 'BLIS 2A', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'Computer Science', 'CISC'),
  ('S1-0445', 1, 'MATH 350', 'BLIS 2B', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'Computer Science', 'CISC'),
  ('S1-0446', 1, 'ENGL 302', 'BLIS 2A', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'General Education', 'GE'),
  ('S1-0447', 1, 'ENGL 302', 'BLIS 2B', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'General Education', 'GE'),
  ('S1-0448', 1, 'PE 201', 'BLIS 2A', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'General Education', 'GE'),
  ('S1-0449', 1, 'PE 201', 'BLIS 2B', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'General Education', 'GE'),
  ('S1-0450', 1, 'LIS 220', 'BLIS 3A', 'BLIS', 'CISC', 'Library and Information Science', false, null, null, null),
  ('S1-0451', 1, 'LIS 220', 'BLIS 3B', 'BLIS', 'CISC', 'Library and Information Science', false, null, null, null),
  ('S1-0452', 1, 'LIS 240', 'BLIS 3A', 'BLIS', 'CISC', 'Library and Information Science', false, null, null, null),
  ('S1-0453', 1, 'LIS 240', 'BLIS 3B', 'BLIS', 'CISC', 'Library and Information Science', false, null, null, null),
  ('S1-0454', 1, 'LIS 301', 'BLIS 3A', 'BLIS', 'CISC', 'Library and Information Science', false, null, null, null),
  ('S1-0455', 1, 'LIS 301', 'BLIS 3B', 'BLIS', 'CISC', 'Library and Information Science', false, null, null, null),
  ('S1-0456', 1, 'LIS 304', 'BLIS 3A', 'BLIS', 'CISC', 'Library and Information Science', false, null, null, null),
  ('S1-0457', 1, 'LIS 304', 'BLIS 3B', 'BLIS', 'CISC', 'Library and Information Science', false, null, null, null),
  ('S1-0458', 1, 'LIS 330', 'BLIS 3A', 'BLIS', 'CISC', 'Library and Information Science', false, null, null, null),
  ('S1-0459', 1, 'LIS 330', 'BLIS 3B', 'BLIS', 'CISC', 'Library and Information Science', false, null, null, null),
  ('S1-0460', 1, 'PHIL 190', 'BLIS 3A', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'General Education', 'GE'),
  ('S1-0461', 1, 'PHIL 190', 'BLIS 3B', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'General Education', 'GE'),
  ('S1-0462', 1, 'ARTS 101', 'BLIS 3A', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'General Education', 'GE'),
  ('S1-0463', 1, 'ARTS 101', 'BLIS 3B', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'General Education', 'GE'),
  ('S1-0464', 1, 'LIS 410', 'BLIS 4A', 'BLIS', 'CISC', 'Library and Information Science', false, null, null, null),
  ('S1-0465', 1, 'LIS 410', 'BLIS 4B', 'BLIS', 'CISC', 'Library and Information Science', false, null, null, null),
  ('S1-0466', 1, 'LIS 320', 'BLIS 4A', 'BLIS', 'CISC', 'Library and Information Science', false, null, null, null),
  ('S1-0467', 1, 'LIS 320', 'BLIS 4B', 'BLIS', 'CISC', 'Library and Information Science', false, null, null, null),
  ('S1-0468', 1, 'HIST 220', 'BLIS 4A', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'Secondary Education', 'COE'),
  ('S1-0469', 1, 'HIST 220', 'BLIS 4B', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'Secondary Education', 'COE'),
  ('S1-0470', 1, 'GAD 171', 'BLIS 4A', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'Psychology', 'CSS'),
  ('S1-0471', 1, 'GAD 171', 'BLIS 4B', 'BLIS', 'CISC', 'Library and Information Science', true, null, 'Psychology', 'CSS'),
  ('S1-0472', 1, 'ED 101', 'BEEd 1', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-0473', 1, 'ED 102', 'BEEd 1', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-0474', 1, 'MATH 180', 'BEEd 1', 'BEEd', 'COE', 'Elementary Education', true, null, 'Secondary Education', 'COE'),
  ('S1-0475', 1, 'SOCS 195', 'BEEd 1', 'BEEd', 'COE', 'Elementary Education', true, null, 'Economics', 'CSS'),
  ('S1-0476', 1, 'PE 101', 'BEEd 1', 'BEEd', 'COE', 'Elementary Education', true, null, 'General Education', 'GE'),
  ('S1-0477', 1, 'CWTS 101', 'BEEd 1', 'BEEd', 'COE', 'Elementary Education', true, null, 'General Education', 'GE'),
  ('S1-0478', 1, 'PSYC 160', 'BEEd 1', 'BEEd', 'COE', 'Elementary Education', true, null, 'Psychology', 'CSS'),
  ('S1-0479', 1, 'UNI 103', 'BEEd 1', 'BEEd', 'COE', 'Elementary Education', true, null, 'Elementary Education', 'COE'),
  ('S1-0480', 1, 'ED 201', 'BEEd 2', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-0481', 1, 'ED 202', 'BEEd 2', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-0482', 1, 'ED 204', 'BEEd 2', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-0483', 1, 'EED 101', 'BEEd 2', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-0484', 1, 'EED 140', 'BEEd 2', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-0485', 1, 'EED 150', 'BEEd 2', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-0486', 1, 'PE 201', 'BEEd 2', 'BEEd', 'COE', 'Elementary Education', true, null, 'General Education', 'GE'),
  ('S1-0487', 1, 'ED 301', 'BEEd 3', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-0488', 1, 'ED 303', 'BEEd 3', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-0489', 1, 'ED 304', 'BEEd 3', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-0490', 1, 'EED 102', 'BEEd 3', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-0491', 1, 'EED 151', 'BEEd 3', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-0492', 1, 'EED 160', 'BEEd 3', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-0493', 1, 'EED 180', 'BEEd 3', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-0494', 1, 'PHIL 190', 'BEEd 3', 'BEEd', 'COE', 'Elementary Education', true, null, 'General Education', 'GE'),
  ('S1-0495', 1, 'ED 401', 'BEEd 4', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-0496', 1, 'ED 402', 'BEEd 4', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-0497', 1, 'EED 181', 'BEEd 4', 'BEEd', 'COE', 'Elementary Education', false, null, null, null),
  ('S1-0498', 1, 'ENGL 302', 'BEEd 4', 'BEEd', 'COE', 'Elementary Education', true, null, 'General Education', 'GE'),
  ('S1-0499', 1, 'HIST 201', 'BEEd 4', 'BEEd', 'COE', 'Elementary Education', true, null, 'Secondary Education', 'COE'),
  ('S1-0500', 1, 'HIST 220', 'BEEd 4', 'BEEd', 'COE', 'Elementary Education', true, null, 'Secondary Education', 'COE'),
  ('S1-0501', 1, 'GAD 171', 'BEEd 4', 'BEEd', 'COE', 'Elementary Education', true, null, 'Psychology', 'CSS'),
  ('S1-0502', 1, 'ED 101', 'BSEd-E 1', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0503', 1, 'SEE 101', 'BSEd-E 1', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0504', 1, 'MATH 180', 'BSEd-E 1', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'Secondary Education', 'COE'),
  ('S1-0505', 1, 'PSYC 160', 'BSEd-E 1', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'Psychology', 'CSS'),
  ('S1-0506', 1, 'COMM 120', 'BSEd-E 1', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'Communication', 'CSS'),
  ('S1-0507', 1, 'CWTS 101', 'BSEd-E 1', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-0508', 1, 'PE 101', 'BSEd-E 1', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-0509', 1, 'UNI 103', 'BSEd-E 1', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'Secondary Education', 'COE'),
  ('S1-0510', 1, 'ED 201', 'BSEd-E 2', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0511', 1, 'ED 202', 'BSEd-E 2', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0512', 1, 'ED 204', 'BSEd-E 2', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0513', 1, 'SEE 201', 'BSEd-E 2', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0514', 1, 'SEE 202', 'BSEd-E 2', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0515', 1, 'MATH 350', 'BSEd-E 2', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'Computer Science', 'CISC'),
  ('S1-0516', 1, 'PHIL 190', 'BSEd-E 2', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-0517', 1, 'PE 201', 'BSEd-E 2', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-0518', 1, 'ED 301', 'BSEd-E 3', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0519', 1, 'ED 303', 'BSEd-E 3', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0520', 1, 'ED 304', 'BSEd-E 3', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0521', 1, 'SEE 301', 'BSEd-E 3', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0522', 1, 'SEE 302', 'BSEd-E 3', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0523', 1, 'SEE 303', 'BSEd-E 3', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0524', 1, 'PHIL 220', 'BSEd-E 3', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-0525', 1, 'ENGL 302', 'BSEd-E 3', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-0526', 1, 'ED 401', 'BSEd-E 4', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0527', 1, 'ED 402', 'BSEd-E 4', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0528', 1, 'SEE 401', 'BSEd-E 4', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0529', 1, 'SEE 402', 'BSEd-E 4', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0530', 1, 'SEE 403', 'BSEd-E 4', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0531', 1, 'SEE 404', 'BSEd-E 4', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0532', 1, 'SEE 405', 'BSEd-E 4', 'BSEd-E', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0533', 1, 'GAD 171', 'BSEd-E 4', 'BSEd-E', 'COE', 'Secondary Education', true, null, 'Psychology', 'CSS'),
  ('S1-0534', 1, 'ED 101', 'BSEd-M 1', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0535', 1, 'SEM 101', 'BSEd-M 1', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0536', 1, 'MATH 180', 'BSEd-M 1', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'Secondary Education', 'COE'),
  ('S1-0537', 1, 'PSYC 160', 'BSEd-M 1', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'Psychology', 'CSS'),
  ('S1-0538', 1, 'COMM 120', 'BSEd-M 1', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'Communication', 'CSS'),
  ('S1-0539', 1, 'CWTS 101', 'BSEd-M 1', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-0540', 1, 'PE 101', 'BSEd-M 1', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-0541', 1, 'UNI 103', 'BSEd-M 1', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'Secondary Education', 'COE'),
  ('S1-0542', 1, 'ED 201', 'BSEd-M 2', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0543', 1, 'ED 202', 'BSEd-M 2', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0544', 1, 'ED 204', 'BSEd-M 2', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0545', 1, 'SEM 201', 'BSEd-M 2', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0546', 1, 'SEM 202', 'BSEd-M 2', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0547', 1, 'MATH 350', 'BSEd-M 2', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'Computer Science', 'CISC'),
  ('S1-0548', 1, 'PHIL 190', 'BSEd-M 2', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-0549', 1, 'PE 201', 'BSEd-M 2', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-0550', 1, 'ED 301', 'BSEd-M 3', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0551', 1, 'ED 303', 'BSEd-M 3', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0552', 1, 'ED 304', 'BSEd-M 3', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0553', 1, 'SEM 301', 'BSEd-M 3', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0554', 1, 'SEM 302', 'BSEd-M 3', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0555', 1, 'SEM 303', 'BSEd-M 3', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0556', 1, 'PHIL 220', 'BSEd-M 3', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-0557', 1, 'ENGL 302', 'BSEd-M 3', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-0558', 1, 'ED 401', 'BSEd-M 4', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0559', 1, 'ED 402', 'BSEd-M 4', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0560', 1, 'SEM 401', 'BSEd-M 4', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0561', 1, 'SEM 402', 'BSEd-M 4', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0562', 1, 'SEM 403', 'BSEd-M 4', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0563', 1, 'SEM 404', 'BSEd-M 4', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0564', 1, 'SEM 405', 'BSEd-M 4', 'BSEd-M', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0565', 1, 'GAD 171', 'BSEd-M 4', 'BSEd-M', 'COE', 'Secondary Education', true, null, 'Psychology', 'CSS'),
  ('S1-0566', 1, 'ED 101', 'BSEd-SS 1', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0567', 1, 'SES 101', 'BSEd-SS 1', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0568', 1, 'MATH 180', 'BSEd-SS 1', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'Secondary Education', 'COE'),
  ('S1-0569', 1, 'PSYC 160', 'BSEd-SS 1', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'Psychology', 'CSS'),
  ('S1-0570', 1, 'COMM 120', 'BSEd-SS 1', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'Communication', 'CSS'),
  ('S1-0571', 1, 'CWTS 101', 'BSEd-SS 1', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-0572', 1, 'PE 101', 'BSEd-SS 1', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-0573', 1, 'UNI 103', 'BSEd-SS 1', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'Secondary Education', 'COE'),
  ('S1-0574', 1, 'ED 201', 'BSEd-SS 2', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0575', 1, 'ED 202', 'BSEd-SS 2', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0576', 1, 'ED 204', 'BSEd-SS 2', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0577', 1, 'SES 201', 'BSEd-SS 2', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0578', 1, 'SES 202', 'BSEd-SS 2', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0579', 1, 'MATH 350', 'BSEd-SS 2', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'Computer Science', 'CISC'),
  ('S1-0580', 1, 'PHIL 190', 'BSEd-SS 2', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-0581', 1, 'PE 201', 'BSEd-SS 2', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-0582', 1, 'ED 301', 'BSEd-SS 3', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0583', 1, 'ED 303', 'BSEd-SS 3', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0584', 1, 'ED 304', 'BSEd-SS 3', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0585', 1, 'SES 301', 'BSEd-SS 3', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0586', 1, 'SES 302', 'BSEd-SS 3', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0587', 1, 'SES 303', 'BSEd-SS 3', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0588', 1, 'PHIL 220', 'BSEd-SS 3', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-0589', 1, 'ENGL 302', 'BSEd-SS 3', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-0590', 1, 'ED 401', 'BSEd-SS 4', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0591', 1, 'ED 402', 'BSEd-SS 4', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0592', 1, 'SES 401', 'BSEd-SS 4', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0593', 1, 'SES 402', 'BSEd-SS 4', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0594', 1, 'SES 403', 'BSEd-SS 4', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0595', 1, 'SES 404', 'BSEd-SS 4', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0596', 1, 'SES 405', 'BSEd-SS 4', 'BSEd-SS', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0597', 1, 'GAD 171', 'BSEd-SS 4', 'BSEd-SS', 'COE', 'Secondary Education', true, null, 'Psychology', 'CSS'),
  ('S1-0598', 1, 'ED 101', 'BSEd-F 1', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0599', 1, 'SEF 101', 'BSEd-F 1', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0600', 1, 'MATH 180', 'BSEd-F 1', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'Secondary Education', 'COE'),
  ('S1-0601', 1, 'PSYC 160', 'BSEd-F 1', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'Psychology', 'CSS'),
  ('S1-0602', 1, 'COMM 120', 'BSEd-F 1', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'Communication', 'CSS'),
  ('S1-0603', 1, 'CWTS 101', 'BSEd-F 1', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-0604', 1, 'PE 101', 'BSEd-F 1', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-0605', 1, 'UNI 103', 'BSEd-F 1', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'Secondary Education', 'COE'),
  ('S1-0606', 1, 'ED 201', 'BSEd-F 2', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0607', 1, 'ED 202', 'BSEd-F 2', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0608', 1, 'ED 204', 'BSEd-F 2', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0609', 1, 'SEF 201', 'BSEd-F 2', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0610', 1, 'SEF 202', 'BSEd-F 2', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0611', 1, 'MATH 350', 'BSEd-F 2', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'Computer Science', 'CISC'),
  ('S1-0612', 1, 'PHIL 190', 'BSEd-F 2', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-0613', 1, 'PE 201', 'BSEd-F 2', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-0614', 1, 'ED 301', 'BSEd-F 3', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0615', 1, 'ED 303', 'BSEd-F 3', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0616', 1, 'ED 304', 'BSEd-F 3', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0617', 1, 'SEF 301', 'BSEd-F 3', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0618', 1, 'SEF 302', 'BSEd-F 3', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0619', 1, 'SEF 303', 'BSEd-F 3', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0620', 1, 'PHIL 220', 'BSEd-F 3', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-0621', 1, 'ENGL 302', 'BSEd-F 3', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'General Education', 'GE'),
  ('S1-0622', 1, 'ED 401', 'BSEd-F 4', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0623', 1, 'ED 402', 'BSEd-F 4', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0624', 1, 'SEF 401', 'BSEd-F 4', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0625', 1, 'SEF 402', 'BSEd-F 4', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0626', 1, 'SEF 403', 'BSEd-F 4', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0627', 1, 'SEF 404', 'BSEd-F 4', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0628', 1, 'SEF 405', 'BSEd-F 4', 'BSEd-F', 'COE', 'Secondary Education', false, null, null, null),
  ('S1-0629', 1, 'GAD 171', 'BSEd-F 4', 'BSEd-F', 'COE', 'Secondary Education', true, null, 'Psychology', 'CSS'),
  ('S1-0630', 1, 'PSYC 101', 'BSP 1A', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-0631', 1, 'PSYC 101', 'BSP 1B', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-0632', 1, 'PSYC 160', 'BSP 1A', 'BSP', 'CSS', 'Psychology', true, null, 'Psychology', 'CSS'),
  ('S1-0633', 1, 'PSYC 160', 'BSP 1B', 'BSP', 'CSS', 'Psychology', true, null, 'Psychology', 'CSS'),
  ('S1-0634', 1, 'MATH 180', 'BSP 1A', 'BSP', 'CSS', 'Psychology', true, null, 'Secondary Education', 'COE'),
  ('S1-0635', 1, 'MATH 180', 'BSP 1B', 'BSP', 'CSS', 'Psychology', true, null, 'Secondary Education', 'COE'),
  ('S1-0636', 1, 'STS 180', 'BSP 1A', 'BSP', 'CSS', 'Psychology', true, null, 'Information Technology', 'CISC'),
  ('S1-0637', 1, 'STS 180', 'BSP 1B', 'BSP', 'CSS', 'Psychology', true, null, 'Information Technology', 'CISC'),
  ('S1-0638', 1, 'PE 101', 'BSP 1A', 'BSP', 'CSS', 'Psychology', true, null, 'General Education', 'GE'),
  ('S1-0639', 1, 'PE 101', 'BSP 1B', 'BSP', 'CSS', 'Psychology', true, null, 'General Education', 'GE'),
  ('S1-0640', 1, 'CWTS 101', 'BSP 1A', 'BSP', 'CSS', 'Psychology', true, null, 'General Education', 'GE'),
  ('S1-0641', 1, 'CWTS 101', 'BSP 1B', 'BSP', 'CSS', 'Psychology', true, null, 'General Education', 'GE'),
  ('S1-0642', 1, 'UNI 103', 'BSP 1A', 'BSP', 'CSS', 'Psychology', true, null, 'Psychology', 'CSS'),
  ('S1-0643', 1, 'UNI 103', 'BSP 1B', 'BSP', 'CSS', 'Psychology', true, null, 'Psychology', 'CSS'),
  ('S1-0644', 1, 'PSYC 130', 'BSP 2A', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-0645', 1, 'PSYC 130', 'BSP 2B', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-0646', 1, 'PSYC 210', 'BSP 2A', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-0647', 1, 'PSYC 210', 'BSP 2B', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-0648', 1, 'PSYC 220', 'BSP 2A', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-0649', 1, 'PSYC 220', 'BSP 2B', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-0650', 1, 'SOCS 195', 'BSP 2A', 'BSP', 'CSS', 'Psychology', true, null, 'Economics', 'CSS'),
  ('S1-0651', 1, 'SOCS 195', 'BSP 2B', 'BSP', 'CSS', 'Psychology', true, null, 'Economics', 'CSS'),
  ('S1-0652', 1, 'PHIL 190', 'BSP 2A', 'BSP', 'CSS', 'Psychology', true, null, 'General Education', 'GE'),
  ('S1-0653', 1, 'PHIL 190', 'BSP 2B', 'BSP', 'CSS', 'Psychology', true, null, 'General Education', 'GE'),
  ('S1-0654', 1, 'PE 201', 'BSP 2A', 'BSP', 'CSS', 'Psychology', true, null, 'General Education', 'GE'),
  ('S1-0655', 1, 'PE 201', 'BSP 2B', 'BSP', 'CSS', 'Psychology', true, null, 'General Education', 'GE'),
  ('S1-0656', 1, 'PSYC 240', 'BSP 3C', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-0657', 1, 'PSYC 240', 'BSP 3IO', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-0658', 1, 'PSYC 280', 'BSP 3C', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-0659', 1, 'PSYC 280', 'BSP 3IO', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-0660', 1, 'PSYC 310', 'BSP 3C', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-0661', 1, 'PSYC 310', 'BSP 3IO', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-0662', 1, 'PSYC 320', 'BSP 3C', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-0663', 1, 'PSYC 320', 'BSP 3IO', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-0664', 1, 'PSYC 351', 'BSP 3C', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-0665', 1, 'PSYC 361', 'BSP 3IO', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-0666', 1, 'HIST 201', 'BSP 3C', 'BSP', 'CSS', 'Psychology', true, null, 'Secondary Education', 'COE'),
  ('S1-0667', 1, 'HIST 201', 'BSP 3IO', 'BSP', 'CSS', 'Psychology', true, null, 'Secondary Education', 'COE'),
  ('S1-0668', 1, 'ARTS 101', 'BSP 3C', 'BSP', 'CSS', 'Psychology', true, null, 'General Education', 'GE'),
  ('S1-0669', 1, 'ARTS 101', 'BSP 3IO', 'BSP', 'CSS', 'Psychology', true, null, 'General Education', 'GE'),
  ('S1-0670', 1, 'PSYC 410', 'BSP 4C', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-0671', 1, 'PSYC 410', 'BSP 4IO', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-0672', 1, 'PSYC 451', 'BSP 4C', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-0673', 1, 'PSYC 452', 'BSP 4C', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-0674', 1, 'PSYC 461', 'BSP 4IO', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-0675', 1, 'PSYC 462', 'BSP 4IO', 'BSP', 'CSS', 'Psychology', false, null, null, null),
  ('S1-0676', 1, 'POLS 101', 'ABPS 1A', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-0677', 1, 'POLS 101', 'ABPS 1B', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-0678', 1, 'SOCS 195', 'ABPS 1A', 'ABPS', 'CSS', 'Political Science', true, null, 'Economics', 'CSS'),
  ('S1-0679', 1, 'SOCS 195', 'ABPS 1B', 'ABPS', 'CSS', 'Political Science', true, null, 'Economics', 'CSS'),
  ('S1-0680', 1, 'COMM 120', 'ABPS 1A', 'ABPS', 'CSS', 'Political Science', true, null, 'Communication', 'CSS'),
  ('S1-0681', 1, 'COMM 120', 'ABPS 1B', 'ABPS', 'CSS', 'Political Science', true, null, 'Communication', 'CSS'),
  ('S1-0682', 1, 'MATH 180', 'ABPS 1A', 'ABPS', 'CSS', 'Political Science', true, null, 'Secondary Education', 'COE'),
  ('S1-0683', 1, 'MATH 180', 'ABPS 1B', 'ABPS', 'CSS', 'Political Science', true, null, 'Secondary Education', 'COE'),
  ('S1-0684', 1, 'PE 101', 'ABPS 1A', 'ABPS', 'CSS', 'Political Science', true, null, 'General Education', 'GE'),
  ('S1-0685', 1, 'PE 101', 'ABPS 1B', 'ABPS', 'CSS', 'Political Science', true, null, 'General Education', 'GE'),
  ('S1-0686', 1, 'CWTS 101', 'ABPS 1A', 'ABPS', 'CSS', 'Political Science', true, null, 'General Education', 'GE'),
  ('S1-0687', 1, 'CWTS 101', 'ABPS 1B', 'ABPS', 'CSS', 'Political Science', true, null, 'General Education', 'GE'),
  ('S1-0688', 1, 'UNI 103', 'ABPS 1A', 'ABPS', 'CSS', 'Political Science', true, null, 'Political Science', 'CSS'),
  ('S1-0689', 1, 'UNI 103', 'ABPS 1B', 'ABPS', 'CSS', 'Political Science', true, null, 'Political Science', 'CSS'),
  ('S1-0690', 1, 'POLS 210', 'ABPS 2A', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-0691', 1, 'POLS 210', 'ABPS 2B', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-0692', 1, 'POLS 220', 'ABPS 2A', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-0693', 1, 'POLS 220', 'ABPS 2B', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-0694', 1, 'LGLS 201', 'ABPS 2A', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-0695', 1, 'LGLS 201', 'ABPS 2B', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-0696', 1, 'PSYC 160', 'ABPS 2A', 'ABPS', 'CSS', 'Political Science', true, null, 'Psychology', 'CSS'),
  ('S1-0697', 1, 'PSYC 160', 'ABPS 2B', 'ABPS', 'CSS', 'Political Science', true, null, 'Psychology', 'CSS'),
  ('S1-0698', 1, 'PHIL 190', 'ABPS 2A', 'ABPS', 'CSS', 'Political Science', true, null, 'General Education', 'GE'),
  ('S1-0699', 1, 'PHIL 190', 'ABPS 2B', 'ABPS', 'CSS', 'Political Science', true, null, 'General Education', 'GE'),
  ('S1-0700', 1, 'PE 201', 'ABPS 2A', 'ABPS', 'CSS', 'Political Science', true, null, 'General Education', 'GE'),
  ('S1-0701', 1, 'PE 201', 'ABPS 2B', 'ABPS', 'CSS', 'Political Science', true, null, 'General Education', 'GE'),
  ('S1-0702', 1, 'POLS 250', 'ABPS 3A', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-0703', 1, 'POLS 250', 'ABPS 3B', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-0704', 1, 'POLS 260', 'ABPS 3A', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-0705', 1, 'POLS 260', 'ABPS 3B', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-0706', 1, 'LGLS 302', 'ABPS 3A', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-0707', 1, 'LGLS 302', 'ABPS 3B', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-0708', 1, 'LGLS 303', 'ABPS 3A', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-0709', 1, 'LGLS 303', 'ABPS 3B', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-0710', 1, 'ENGL 302', 'ABPS 3A', 'ABPS', 'CSS', 'Political Science', true, null, 'General Education', 'GE'),
  ('S1-0711', 1, 'ENGL 302', 'ABPS 3B', 'ABPS', 'CSS', 'Political Science', true, null, 'General Education', 'GE'),
  ('S1-0712', 1, 'HIST 201', 'ABPS 3A', 'ABPS', 'CSS', 'Political Science', true, null, 'Secondary Education', 'COE'),
  ('S1-0713', 1, 'HIST 201', 'ABPS 3B', 'ABPS', 'CSS', 'Political Science', true, null, 'Secondary Education', 'COE'),
  ('S1-0714', 1, 'HIST 220', 'ABPS 3A', 'ABPS', 'CSS', 'Political Science', true, null, 'Secondary Education', 'COE'),
  ('S1-0715', 1, 'HIST 220', 'ABPS 3B', 'ABPS', 'CSS', 'Political Science', true, null, 'Secondary Education', 'COE'),
  ('S1-0716', 1, 'POLS 410', 'ABPS 4A', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-0717', 1, 'POLS 410', 'ABPS 4B', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-0718', 1, 'LGLS 402', 'ABPS 4A', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-0719', 1, 'LGLS 402', 'ABPS 4B', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-0720', 1, 'LGLS 403', 'ABPS 4A', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-0721', 1, 'LGLS 403', 'ABPS 4B', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-0722', 1, 'LGLS 404', 'ABPS 4A', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-0723', 1, 'LGLS 404', 'ABPS 4B', 'ABPS', 'CSS', 'Political Science', false, null, null, null),
  ('S1-0724', 1, 'COMM 101', 'ABC 1A', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-0725', 1, 'COMM 101', 'ABC 1B', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-0726', 1, 'COMM 120', 'ABC 1A', 'ABC', 'CSS', 'Communication', true, null, 'Communication', 'CSS'),
  ('S1-0727', 1, 'COMM 120', 'ABC 1B', 'ABC', 'CSS', 'Communication', true, null, 'Communication', 'CSS'),
  ('S1-0728', 1, 'MATH 180', 'ABC 1A', 'ABC', 'CSS', 'Communication', true, null, 'Secondary Education', 'COE'),
  ('S1-0729', 1, 'MATH 180', 'ABC 1B', 'ABC', 'CSS', 'Communication', true, null, 'Secondary Education', 'COE'),
  ('S1-0730', 1, 'ARTS 101', 'ABC 1A', 'ABC', 'CSS', 'Communication', true, null, 'General Education', 'GE'),
  ('S1-0731', 1, 'ARTS 101', 'ABC 1B', 'ABC', 'CSS', 'Communication', true, null, 'General Education', 'GE'),
  ('S1-0732', 1, 'PE 101', 'ABC 1A', 'ABC', 'CSS', 'Communication', true, null, 'General Education', 'GE'),
  ('S1-0733', 1, 'PE 101', 'ABC 1B', 'ABC', 'CSS', 'Communication', true, null, 'General Education', 'GE'),
  ('S1-0734', 1, 'CWTS 101', 'ABC 1A', 'ABC', 'CSS', 'Communication', true, null, 'General Education', 'GE'),
  ('S1-0735', 1, 'CWTS 101', 'ABC 1B', 'ABC', 'CSS', 'Communication', true, null, 'General Education', 'GE'),
  ('S1-0736', 1, 'UNI 103', 'ABC 1A', 'ABC', 'CSS', 'Communication', true, null, 'Communication', 'CSS'),
  ('S1-0737', 1, 'UNI 103', 'ABC 1B', 'ABC', 'CSS', 'Communication', true, null, 'Communication', 'CSS'),
  ('S1-0738', 1, 'COMM 112', 'ABC 2A', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-0739', 1, 'COMM 112', 'ABC 2B', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-0740', 1, 'COMM 210', 'ABC 2A', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-0741', 1, 'COMM 210', 'ABC 2B', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-0742', 1, 'COMM 221', 'ABC 2A', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-0743', 1, 'COMM 221', 'ABC 2B', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-0744', 1, 'SOCS 195', 'ABC 2A', 'ABC', 'CSS', 'Communication', true, null, 'Economics', 'CSS'),
  ('S1-0745', 1, 'SOCS 195', 'ABC 2B', 'ABC', 'CSS', 'Communication', true, null, 'Economics', 'CSS'),
  ('S1-0746', 1, 'STS 180', 'ABC 2A', 'ABC', 'CSS', 'Communication', true, null, 'Information Technology', 'CISC'),
  ('S1-0747', 1, 'STS 180', 'ABC 2B', 'ABC', 'CSS', 'Communication', true, null, 'Information Technology', 'CISC'),
  ('S1-0748', 1, 'HIST 201', 'ABC 2A', 'ABC', 'CSS', 'Communication', true, null, 'Secondary Education', 'COE'),
  ('S1-0749', 1, 'HIST 201', 'ABC 2B', 'ABC', 'CSS', 'Communication', true, null, 'Secondary Education', 'COE'),
  ('S1-0750', 1, 'PE 201', 'ABC 2A', 'ABC', 'CSS', 'Communication', true, null, 'General Education', 'GE'),
  ('S1-0751', 1, 'PE 201', 'ABC 2B', 'ABC', 'CSS', 'Communication', true, null, 'General Education', 'GE'),
  ('S1-0752', 1, 'COMM 212', 'ABC 3A', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-0753', 1, 'COMM 212', 'ABC 3B', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-0754', 1, 'COMM 220', 'ABC 3A', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-0755', 1, 'COMM 220', 'ABC 3B', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-0756', 1, 'COMM 240', 'ABC 3A', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-0757', 1, 'COMM 240', 'ABC 3B', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-0758', 1, 'COMM 310', 'ABC 3A', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-0759', 1, 'COMM 310', 'ABC 3B', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-0760', 1, 'COMM 311', 'ABC 3A', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-0761', 1, 'COMM 311', 'ABC 3B', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-0762', 1, 'PHIL 190', 'ABC 3A', 'ABC', 'CSS', 'Communication', true, null, 'General Education', 'GE'),
  ('S1-0763', 1, 'PHIL 190', 'ABC 3B', 'ABC', 'CSS', 'Communication', true, null, 'General Education', 'GE'),
  ('S1-0764', 1, 'GAD 171', 'ABC 3A', 'ABC', 'CSS', 'Communication', true, null, 'Psychology', 'CSS'),
  ('S1-0765', 1, 'GAD 171', 'ABC 3B', 'ABC', 'CSS', 'Communication', true, null, 'Psychology', 'CSS'),
  ('S1-0766', 1, 'COMM 410', 'ABC 4A', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-0767', 1, 'COMM 410', 'ABC 4B', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-0768', 1, 'COMM 331', 'ABC 4A', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-0769', 1, 'COMM 331', 'ABC 4B', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-0770', 1, 'COMM 340', 'ABC 4A', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-0771', 1, 'COMM 340', 'ABC 4B', 'ABC', 'CSS', 'Communication', false, null, null, null),
  ('S1-0772', 1, 'HIST 220', 'ABC 4A', 'ABC', 'CSS', 'Communication', true, null, 'Secondary Education', 'COE'),
  ('S1-0773', 1, 'HIST 220', 'ABC 4B', 'ABC', 'CSS', 'Communication', true, null, 'Secondary Education', 'COE'),
  ('S1-0774', 1, 'ECON 101', 'ABEcon 1A', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-0775', 1, 'ECON 101', 'ABEcon 1B', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-0776', 1, 'ECON 130', 'ABEcon 1A', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-0777', 1, 'ECON 130', 'ABEcon 1B', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-0778', 1, 'COMM 120', 'ABEcon 1A', 'ABEcon', 'CSS', 'Economics', true, null, 'Communication', 'CSS'),
  ('S1-0779', 1, 'COMM 120', 'ABEcon 1B', 'ABEcon', 'CSS', 'Economics', true, null, 'Communication', 'CSS'),
  ('S1-0780', 1, 'MATH 180', 'ABEcon 1A', 'ABEcon', 'CSS', 'Economics', true, null, 'Secondary Education', 'COE'),
  ('S1-0781', 1, 'MATH 180', 'ABEcon 1B', 'ABEcon', 'CSS', 'Economics', true, null, 'Secondary Education', 'COE'),
  ('S1-0782', 1, 'PE 101', 'ABEcon 1A', 'ABEcon', 'CSS', 'Economics', true, null, 'General Education', 'GE'),
  ('S1-0783', 1, 'PE 101', 'ABEcon 1B', 'ABEcon', 'CSS', 'Economics', true, null, 'General Education', 'GE'),
  ('S1-0784', 1, 'CWTS 101', 'ABEcon 1A', 'ABEcon', 'CSS', 'Economics', true, null, 'General Education', 'GE'),
  ('S1-0785', 1, 'CWTS 101', 'ABEcon 1B', 'ABEcon', 'CSS', 'Economics', true, null, 'General Education', 'GE'),
  ('S1-0786', 1, 'UNI 103', 'ABEcon 1A', 'ABEcon', 'CSS', 'Economics', true, null, 'Economics', 'CSS'),
  ('S1-0787', 1, 'UNI 103', 'ABEcon 1B', 'ABEcon', 'CSS', 'Economics', true, null, 'Economics', 'CSS'),
  ('S1-0788', 1, 'ECON 120', 'ABEcon 2A', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-0789', 1, 'ECON 120', 'ABEcon 2B', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-0790', 1, 'ECON 121', 'ABEcon 2A', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-0791', 1, 'ECON 121', 'ABEcon 2B', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-0792', 1, 'ECON 210', 'ABEcon 2A', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-0793', 1, 'ECON 210', 'ABEcon 2B', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-0794', 1, 'MATH 350', 'ABEcon 2A', 'ABEcon', 'CSS', 'Economics', true, null, 'Computer Science', 'CISC'),
  ('S1-0795', 1, 'MATH 350', 'ABEcon 2B', 'ABEcon', 'CSS', 'Economics', true, null, 'Computer Science', 'CISC'),
  ('S1-0796', 1, 'SOCS 195', 'ABEcon 2A', 'ABEcon', 'CSS', 'Economics', true, null, 'Economics', 'CSS'),
  ('S1-0797', 1, 'SOCS 195', 'ABEcon 2B', 'ABEcon', 'CSS', 'Economics', true, null, 'Economics', 'CSS'),
  ('S1-0798', 1, 'ARTS 101', 'ABEcon 2A', 'ABEcon', 'CSS', 'Economics', true, null, 'General Education', 'GE'),
  ('S1-0799', 1, 'ARTS 101', 'ABEcon 2B', 'ABEcon', 'CSS', 'Economics', true, null, 'General Education', 'GE'),
  ('S1-0800', 1, 'PE 201', 'ABEcon 2A', 'ABEcon', 'CSS', 'Economics', true, null, 'General Education', 'GE'),
  ('S1-0801', 1, 'PE 201', 'ABEcon 2B', 'ABEcon', 'CSS', 'Economics', true, null, 'General Education', 'GE'),
  ('S1-0802', 1, 'ECON 220', 'ABEcon 3A', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-0803', 1, 'ECON 220', 'ABEcon 3B', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-0804', 1, 'ECON 221', 'ABEcon 3A', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-0805', 1, 'ECON 221', 'ABEcon 3B', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-0806', 1, 'ECON 222', 'ABEcon 3A', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-0807', 1, 'ECON 222', 'ABEcon 3B', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-0808', 1, 'ECON 231', 'ABEcon 3A', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-0809', 1, 'ECON 231', 'ABEcon 3B', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-0810', 1, 'ECON 310', 'ABEcon 3A', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-0811', 1, 'ECON 310', 'ABEcon 3B', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-0812', 1, 'PHIL 220', 'ABEcon 3A', 'ABEcon', 'CSS', 'Economics', true, null, 'General Education', 'GE'),
  ('S1-0813', 1, 'PHIL 220', 'ABEcon 3B', 'ABEcon', 'CSS', 'Economics', true, null, 'General Education', 'GE'),
  ('S1-0814', 1, 'ENGL 302', 'ABEcon 3A', 'ABEcon', 'CSS', 'Economics', true, null, 'General Education', 'GE'),
  ('S1-0815', 1, 'ENGL 302', 'ABEcon 3B', 'ABEcon', 'CSS', 'Economics', true, null, 'General Education', 'GE'),
  ('S1-0816', 1, 'ECON 410', 'ABEcon 4A', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-0817', 1, 'ECON 410', 'ABEcon 4B', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-0818', 1, 'ECON 330', 'ABEcon 4A', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-0819', 1, 'ECON 330', 'ABEcon 4B', 'ABEcon', 'CSS', 'Economics', false, null, null, null),
  ('S1-0820', 1, 'GAD 171', 'ABEcon 4A', 'ABEcon', 'CSS', 'Economics', true, null, 'Psychology', 'CSS'),
  ('S1-0821', 1, 'GAD 171', 'ABEcon 4B', 'ABEcon', 'CSS', 'Economics', true, null, 'Psychology', 'CSS'),
  ('S1-0822', 1, 'HIST 220', 'ABEcon 4A', 'ABEcon', 'CSS', 'Economics', true, null, 'Secondary Education', 'COE'),
  ('S1-0823', 1, 'HIST 220', 'ABEcon 4B', 'ABEcon', 'CSS', 'Economics', true, null, 'Secondary Education', 'COE')
on conflict (id) do update set course = excluded.course, section = excluded.section, program = excluded.program, college = excluded.college, department = excluded.department, is_ge = excluded.is_ge, plan_teacher = excluded.plan_teacher, house_dept = excluded.house_dept, house_college = excluded.house_college;
-- Departments that may teach each GE course (kept as edited on the Settings page).
insert into public.ge_teachers (course, department, college) values
  ('COMM 120', 'Communication', 'CSS'),
  ('COMM 120', 'Secondary Education', 'COE'),
  ('FIL 207', 'Secondary Education', 'COE'),
  ('GAD 171', 'Elementary Education', 'COE'),
  ('GAD 171', 'Psychology', 'CSS'),
  ('GAD 171', 'Secondary Education', 'COE'),
  ('GAD 171', 'Social Work', 'CCJPS'),
  ('HIST 201', 'Secondary Education', 'COE'),
  ('HIST 220', 'Secondary Education', 'COE'),
  ('MATH 180', 'Secondary Education', 'COE'),
  ('MATH 350', 'Computer Science', 'CISC'),
  ('MATH 350', 'Secondary Education', 'COE'),
  ('PSYC 160', 'Elementary Education', 'COE'),
  ('PSYC 160', 'Psychology', 'CSS'),
  ('PSYC 160', 'Social Work', 'CCJPS'),
  ('SOCS 195', 'Economics', 'CSS'),
  ('SOCS 195', 'Political Science', 'CSS'),
  ('SOCS 195', 'Public Administration', 'CCJPS'),
  ('SOCS 195', 'Secondary Education', 'COE'),
  ('STS 180', 'Information Technology', 'CISC'),
  ('UNI 103', 'Accountancy', 'CBE'),
  ('UNI 103', 'Business Administration', 'CBE'),
  ('UNI 103', 'Communication', 'CSS'),
  ('UNI 103', 'Computer Science', 'CISC'),
  ('UNI 103', 'Criminology', 'CCJPS'),
  ('UNI 103', 'Economics', 'CSS'),
  ('UNI 103', 'Elementary Education', 'COE'),
  ('UNI 103', 'Entrepreneurship', 'CBE'),
  ('UNI 103', 'Information Technology', 'CISC'),
  ('UNI 103', 'Library and Information Science', 'CISC'),
  ('UNI 103', 'Political Science', 'CSS'),
  ('UNI 103', 'Psychology', 'CSS'),
  ('UNI 103', 'Public Administration', 'CCJPS'),
  ('UNI 103', 'Secondary Education', 'COE'),
  ('UNI 103', 'Social Work', 'CCJPS'),
  ('UNI 103', 'Tourism and Hospitality Management', 'CBE')
on conflict (course, department) do nothing;
commit;

-- The first account with full access (the Registrar). Add everyone else on the Settings page.
insert into public.staff (email, full_name, role) values ('agbayanispencer@gmail.com', 'University Registrar', 'registrar')
on conflict (email) do nothing;

-- Remove requests that an earlier setup sent by itself (chairs now ask instructors of submitted departments).
delete from public.ge_decisions where class_id in (select class_id from public.ge_requests where requested_by = 'setup');
delete from public.ge_requests where requested_by = 'setup';
