-- Class Scheduling: database schema, roles, and access rules for Supabase.
--
-- Who can do what (enforced here, in the database, not only in the page):
--   registrar, dean    everything, manage staff, publish, open GE Department scheduling
--   chair              major classes of their own department, with their own faculty.
--                      GE courses their department holds, for their own sections, with no approval.
--                      GE courses another department holds, for their own sections: they book the time,
--                      and the class waits for approval. The holding department picks the teacher.
--   associate_dean     the classes of the sections of their own college (as a chair would),
--                      and approves GE classes that other colleges borrow from their college
--   ge_coordinator     courses of the GE Department, once the Registrar or Dean opens them, with no approval
-- Everyone with a role can read the whole timetable, because conflict checks need it.
--
-- The holding department of a GE class is the department whose teacher the loading plan gives it
-- (Social Work teaching PSYC 160, for example), or the house department of the course (housed_by)
-- when the plan names no teacher. A holding department that lacks an instructor may hand the class
-- to the house department, which then holds it.
--
-- Approval of a borrowed GE class (a GE course held by another department):
--   holding department in the same college    the chair of the holding department approves
--   holding department in another college     the associate dean of that college approves
-- The approver also picks the teacher from the holding department. A new time or teacher asks again.

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
  holder_dept  text,                 -- GE only: the department holding the class (see above)
  holder_college text,               -- and its college (GE for the GE Department)
  house_dept   text,                 -- GE only: the department in housed_by
  house_college text
);
alter table public.classes add column if not exists holder_dept text;
alter table public.classes add column if not exists holder_college text;
alter table public.classes add column if not exists house_dept text;
alter table public.classes add column if not exists house_college text;

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

-- The decision on a borrowed GE class, for one schedule and one teacher.
drop table if exists public.ge_approvals cascade;          -- replaced by ge_decisions
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

-- A GE class handed to its house department because the holding department lacks an instructor.
create table if not exists public.ge_holders (
  class_id       text primary key references public.classes(id) on delete cascade,
  holder_dept    text not null,
  holder_college text not null,
  handed_by      text,
  handed_at      timestamptz not null default now()
);

create table if not exists public.settings (
  id             int primary key default 1 check (id = 1),
  ge_open        boolean not null default false,   -- chairs schedule first, then GE opens
  approval_scope text not null default 'all' check (approval_scope in ('all', 'cross')),
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

-- The department holding a class now, after any hand-over, and its college.
create or replace function public.holder_dept_of(cid text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(h.holder_dept, c.holder_dept) from public.classes c left join public.ge_holders h on h.class_id = c.id where c.id = cid
$$;
create or replace function public.holder_college_of(cid text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(h.holder_college, c.holder_college) from public.classes c left join public.ge_holders h on h.class_id = c.id where c.id = cid
$$;

-- What kind of class is this? major, gedept (a GE Department course), own (a GE course the
-- department of the section holds), or borrowed (a GE course another department holds).
create or replace function public.class_kind(cid text) returns text
language sql stable security definer set search_path = public as $$
  select case when not c.is_ge then 'major'
              when public.holder_dept_of(cid) is null or public.holder_dept_of(cid) = 'General Education' then 'gedept'
              when public.holder_dept_of(cid) = c.department then 'own'
              else 'borrowed' end
  from public.classes c where c.id = cid
$$;

-- May the signed-in person book the time and room of this class?
create or replace function public.can_edit_class(cid text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  me public.staff := public.my_staff();
  c  public.classes;
  kind text := public.class_kind(cid);
  ge_is_open boolean;
begin
  if me.email is null or kind is null then return false; end if;
  if me.role in ('registrar', 'dean') then return true; end if;
  select * into c from public.classes where id = cid;
  if kind = 'gedept' then
    select ge_open into ge_is_open from public.settings where id = 1;
    return me.role = 'ge_coordinator' and coalesce(ge_is_open, false);
  end if;
  if me.role = 'associate_dean' then return c.college = me.college; end if;
  if me.role = 'chair' then return c.department = me.department; end if;
  return false;
end $$;

-- May the signed-in person give this class to teacher t (t null means no teacher yet)?
-- Borrowed GE classes get their teacher from the holding department.
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
  select * into c from public.classes where id = cid;
  select * into f from public.faculty where key = t;
  if kind = 'borrowed' then
    if t is not null and f.department <> public.holder_dept_of(cid) then return false; end if;
    return (me.role = 'chair' and me.department = public.holder_dept_of(cid))
        or (me.role = 'associate_dean' and me.college = public.holder_college_of(cid));
  end if;
  if not public.can_edit_class(cid) then return false; end if;
  if t is null or me.role <> 'chair' then return true; end if;
  return f.department = me.department;
end $$;

-- Does this class wait for approval? Only borrowed GE classes do.
create or replace function public.needs_approval(cid text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.class_kind(cid) = 'borrowed', false)
$$;

-- May the signed-in person approve or reject this borrowed GE class?
create or replace function public.can_decide(cid text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  me public.staff := public.my_staff();
  c  public.classes;
begin
  if me.email is null or not public.needs_approval(cid) then return false; end if;
  if me.role in ('registrar', 'dean') then return true; end if;
  select * into c from public.classes where id = cid;
  if public.holder_college_of(cid) = c.college then
    return me.role = 'chair' and me.department = public.holder_dept_of(cid);
  end if;
  return me.role = 'associate_dean' and me.college = public.holder_college_of(cid);
end $$;

-- Approve, reject, or reopen a borrowed GE class. On approval the approver may name the teacher.
drop function if exists public.decide_ge(text, text, text);
drop function if exists public.needs_adean(text);
create or replace function public.decide_ge(cid text, decision text, note text default null, teacher text default null)
returns text
language plpgsql volatile security definer set search_path = public as $$
declare
  me public.staff := public.my_staff();
  c  public.classes;
  sched text := public.class_schedule(cid);
  t text;
begin
  if me.email is null then raise exception 'Your account has no role yet'; end if;
  if not public.needs_approval(cid) then raise exception 'This class does not need approval'; end if;
  select * into c from public.classes where id = cid;
  if decision = 'reopen' then
    if not (public.can_edit_class(cid) or public.can_decide(cid)) then raise exception 'Not allowed'; end if;
    delete from public.ge_decisions where class_id = cid;
    return 'reopened';
  end if;
  if not public.can_decide(cid) then
    if public.holder_college_of(cid) = c.college then raise exception 'Only the % chair can decide this', public.holder_dept_of(cid); end if;
    raise exception 'Only the % associate dean can decide this', public.holder_college_of(cid);
  end if;
  if sched = '' then raise exception 'The class has no booked time yet'; end if;
  if decision = 'approve' then
    if decide_ge.teacher is not null then
      if not exists (select 1 from public.faculty f where f.key = decide_ge.teacher and f.department = public.holder_dept_of(cid)) and not public.is_admin() then
        raise exception 'Choose a teacher from the % department', public.holder_dept_of(cid);
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
    insert into public.ge_decisions (class_id, schedule, teacher, approved_by, approved_at, note)
      values (cid, sched, t, me.email, now(), decide_ge.note)
      on conflict (class_id) do update set schedule = excluded.schedule, teacher = excluded.teacher,
        approved_by = excluded.approved_by, approved_at = excluded.approved_at,
        rejected_by = null, rejected_at = null, note = excluded.note;
    return 'approved';
  elsif decision = 'reject' then
    insert into public.ge_decisions (class_id, schedule, teacher, rejected_by, rejected_at, note)
      values (cid, sched, public.class_teacher(cid), me.email, now(), decide_ge.note)
      on conflict (class_id) do update set schedule = excluded.schedule, teacher = excluded.teacher,
        rejected_by = excluded.rejected_by, rejected_at = excluded.rejected_at,
        approved_by = null, approved_at = null, note = excluded.note;
    return 'rejected';
  end if;
  raise exception 'Unknown decision %', decision;
end $$;

-- Hand a GE class to its house department (or take it back, with undo). For the department
-- the loading plan gives the class to, when it lacks an instructor. The class starts over:
-- no teacher, no decision.
create or replace function public.hand_to_house(cid text, undo boolean default false) returns text
language plpgsql volatile security definer set search_path = public as $$
declare
  me public.staff := public.my_staff();
  c  public.classes;
  allowed boolean;
begin
  if me.email is null then raise exception 'Your account has no role yet'; end if;
  select * into c from public.classes where id = cid;
  if not found or not c.is_ge or c.house_dept is null or c.house_dept = c.holder_dept then
    raise exception 'This class is already with its house department';
  end if;
  allowed := public.is_admin()
          or (me.role = 'chair' and me.department = c.holder_dept)
          or (me.role = 'associate_dean' and me.college = c.holder_college);
  if not allowed then raise exception 'Only the % department can hand this class over', c.holder_dept; end if;
  if undo then
    delete from public.ge_holders where class_id = cid;
    delete from public.teacher_changes where class_id = cid;
  else
    insert into public.ge_holders (class_id, holder_dept, holder_college, handed_by)
      values (cid, c.house_dept, c.house_college, me.email)
      on conflict (class_id) do update set holder_dept = excluded.holder_dept, holder_college = excluded.holder_college,
        handed_by = excluded.handed_by, handed_at = now();
    insert into public.teacher_changes (class_id, sem, teacher) values (cid, c.sem, null)
      on conflict (class_id) do update set teacher = null;
  end if;
  delete from public.ge_decisions where class_id = cid;
  return case when undo then 'taken back' else 'handed over' end;
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
alter table public.staff           enable row level security;
alter table public.bookings        enable row level security;
alter table public.teacher_changes enable row level security;
alter table public.ge_decisions    enable row level security;
alter table public.ge_holders      enable row level security;
alter table public.settings        enable row level security;

drop policy if exists read_faculty on public.faculty;
create policy read_faculty on public.faculty for select to authenticated using (public.has_role());
drop policy if exists read_classes on public.classes;
create policy read_classes on public.classes for select to authenticated using (public.has_role());

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

-- Hand-overs and decisions are written only through hand_to_house() and decide_ge().
drop policy if exists read_ge_holders on public.ge_holders;
create policy read_ge_holders on public.ge_holders for select to authenticated using (public.has_role());
drop policy if exists read_ge_decisions on public.ge_decisions;
create policy read_ge_decisions on public.ge_decisions for select to authenticated using (public.has_role());

drop policy if exists read_settings on public.settings;
create policy read_settings on public.settings for select to authenticated using (public.has_role());
drop policy if exists admin_settings on public.settings;
create policy admin_settings on public.settings for update to authenticated using (public.is_admin()) with check (public.is_admin());

grant usage on schema public to authenticated;
grant select on public.faculty, public.classes, public.ge_decisions, public.ge_holders to authenticated;
grant select, insert, update, delete on public.staff, public.bookings, public.teacher_changes to authenticated;
grant select, update on public.settings to authenticated;
-- Every helper the access rules call must be runnable by signed-in users (some projects do not grant this by default).
grant execute on function public.my_staff(), public.is_admin(), public.has_role(), public.class_teacher(text),
  public.class_schedule(text), public.class_kind(text), public.can_edit_class(text), public.can_assign(text, text),
  public.needs_approval(text), public.can_decide(text), public.decide_ge(text, text, text, text),
  public.holder_dept_of(text), public.holder_college_of(text), public.hand_to_house(text, boolean),
  public.publish_schedule(), public.stamp_row() to authenticated;
revoke all on all tables in schema public from anon;

-- ---------- live updates ----------
alter table public.bookings replica identity full;
alter table public.teacher_changes replica identity full;
alter table public.ge_decisions replica identity full;
alter table public.ge_holders replica identity full;
do $$ begin
  begin alter publication supabase_realtime add table public.bookings; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.teacher_changes; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.ge_decisions; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.ge_holders; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.settings; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.staff; exception when duplicate_object then null; end;
end $$;
