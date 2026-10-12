-- Class Scheduling: database schema, roles, and access rules for Supabase.
--
-- Who can do what (enforced here, in the database, not only in the page):
--   registrar, dean    everything, manage staff and GE teaching lists, publish, open GE Department scheduling
--   chair              major classes of their own department, with their own faculty.
--                      GE classes of their own sections that their department may teach, with their own faculty.
--                      Other GE classes of their own sections: they book the time and ask a department that
--                      may teach the course, once all their own GE classes are booked.
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
  mine := (me.role = 'associate_dean' and c.college = me.college) or (me.role = 'chair' and c.department = me.department);
  if kind = 'borrowed' then return mine and public.own_ge_left(c.department) = 0; end if;
  return mine;
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

-- Ask department d to teach a borrowed GE class. Any earlier answer is cleared. The teacher stays
-- only if the loading plan already gives the class to a teacher of d.
create or replace function public.request_ge(cid text, d text) returns text
language plpgsql volatile security definer set search_path = public as $$
declare
  c  public.classes;
  dc text;
  pd text;
begin
  if (public.my_staff()).email is null then raise exception 'Your account has no role yet'; end if;
  if public.class_kind(cid) is distinct from 'borrowed' then raise exception 'This class is not asked of another department'; end if;
  if not public.can_edit_class(cid) then
    raise exception 'Book every GE class your department teaches for its own sections first, or this class is not yours';
  end if;
  select * into c from public.classes where id = cid;
  if not public.may_teach(c.course, d) then raise exception 'The % department does not teach %', d, c.course; end if;
  if public.own_ge_left(d) > 0 then raise exception 'The % department has not finished booking its own GE classes', d; end if;
  select college into dc from public.ge_teachers where course = c.course and department = d;
  insert into public.ge_requests (class_id, department, college, requested_by) values (cid, d, dc, (public.my_staff()).email)
    on conflict (class_id) do update set department = excluded.department, college = excluded.college,
      requested_by = excluded.requested_by, requested_at = now();
  delete from public.ge_decisions where class_id = cid;
  select f.department into pd from public.faculty f where f.key = c.plan_teacher;
  if pd is not distinct from d then
    delete from public.teacher_changes where class_id = cid;
  else
    insert into public.teacher_changes (class_id, sem, teacher) values (cid, c.sem, null)
      on conflict (class_id) do update set teacher = null;
  end if;
  return 'asked';
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
    if not (public.can_edit_class(cid) or public.can_decide(cid)) then raise exception 'Not allowed'; end if;
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
    return 'rejected';
  end if;
  raise exception 'Unknown decision %', decision;
end $$;

-- Classes of the sections of department d still incomplete: no time, no teacher, or a borrowed GE
-- class not approved for its current time and teacher. GE Department courses do not count.
create or replace function public.dept_missing(d text) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.classes c
  where c.department = d and public.class_kind(c.id) <> 'gedept'
    and (not exists (select 1 from public.bookings b where b.class_id = c.id)
         or public.class_teacher(c.id) is null
         or (public.class_kind(c.id) = 'borrowed' and not exists (
               select 1 from public.ge_decisions g join public.ge_requests r on r.class_id = g.class_id
               where g.class_id = c.id and g.department = r.department and g.approved_at is not null
                 and g.schedule = public.class_schedule(c.id) and g.teacher is not distinct from public.class_teacher(c.id))))
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

drop policy if exists read_faculty on public.faculty;
create policy read_faculty on public.faculty for select to authenticated using (public.has_role());
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

-- Submissions are written only through submit_schedule().
drop policy if exists read_submissions on public.submissions;
create policy read_submissions on public.submissions for select to authenticated using (public.has_role());

drop policy if exists read_settings on public.settings;
create policy read_settings on public.settings for select to authenticated using (public.has_role());
drop policy if exists admin_settings on public.settings;
create policy admin_settings on public.settings for update to authenticated using (public.is_admin()) with check (public.is_admin());

grant usage on schema public to authenticated;
grant select on public.faculty, public.classes, public.ge_requests, public.ge_decisions, public.submissions to authenticated;
grant select, insert, update, delete on public.staff, public.bookings, public.teacher_changes, public.ge_teachers to authenticated;
grant select, update on public.settings to authenticated;
-- Every helper the access rules call must be runnable by signed-in users (some projects do not grant this by default).
grant execute on function public.my_staff(), public.is_admin(), public.has_role(), public.class_teacher(text),
  public.class_schedule(text), public.may_teach(text, text), public.class_kind(text), public.own_ge_left(text),
  public.request_dept(text), public.request_college(text), public.can_edit_class(text), public.can_decide(text),
  public.can_assign(text, text), public.needs_approval(text), public.request_ge(text, text),
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
do $$ begin
  begin alter publication supabase_realtime add table public.bookings; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.teacher_changes; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.ge_requests; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.ge_decisions; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.ge_teachers; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.settings; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.submissions; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.staff; exception when duplicate_object then null; end;
end $$;
