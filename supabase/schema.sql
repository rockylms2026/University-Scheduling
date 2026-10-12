-- Class Scheduling: database schema, roles, and access rules for Supabase.
--
-- Who can do what (enforced here, in the database, not only in the page):
--   registrar, dean      everything; manage staff; publish; open GE scheduling
--   associate_dean       the classes of their own college's sections; GE classes in
--                        their college's sections (once GE scheduling is open);
--                        approves GE classes taught by their college's faculty
--   chair                the major classes of their own department, with their own
--                        department's faculty; never GE classes; approves GE classes
--                        taught by their department's faculty
--   ge_coordinator       every GE class (once GE scheduling is open)
-- Everyone with a role can read the whole timetable, because conflict checks need it.
--
-- A GE class taught by a member of a college (not the GE Department) is "pending"
-- until both that teacher's department chair and their college's associate dean
-- approve it. Changing its time or teacher afterwards asks again.

-- ---------- reference data (loaded by seed.sql; read-only to users) ----------
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
  college      text not null,        -- the section's college
  department   text not null,        -- the section's program department
  is_ge        boolean not null,
  plan_teacher text references public.faculty(key)
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

-- Approvals of a GE class taught by college faculty, for one teacher and one schedule.
create table if not exists public.ge_approvals (
  class_id    text not null references public.classes(id) on delete cascade,
  teacher     text not null references public.faculty(key),
  schedule    text not null default '',  -- the bookings approved, e.g. "Lec:M1 MWF"
  chair_by    text,
  chair_at    timestamptz,
  adean_by    text,
  adean_at    timestamptz,
  rejected_by text,
  rejected_at timestamptz,
  note        text,
  primary key (class_id, teacher)
);

create table if not exists public.settings (
  id             int primary key default 1 check (id = 1),
  ge_open        boolean not null default false,   -- chairs schedule first; then GE opens
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

-- May the signed-in person book this class (time, room, teacher)?
create or replace function public.can_edit_class(cid text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  me public.staff := public.my_staff();
  c  public.classes;
  ge_is_open boolean;
begin
  if me.email is null then return false; end if;
  if me.role in ('registrar', 'dean') then return true; end if;
  select * into c from public.classes where id = cid;
  if not found then return false; end if;
  if c.is_ge then
    select ge_open into ge_is_open from public.settings where id = 1;
    if not coalesce(ge_is_open, false) then return false; end if;
    return me.role = 'ge_coordinator' or (me.role = 'associate_dean' and c.college = me.college);
  end if;
  if me.role = 'associate_dean' then return c.college = me.college; end if;
  if me.role = 'chair' then return c.department = me.department; end if;
  return false;
end $$;

-- May the signed-in person give this class to this teacher? Chairs use their own faculty.
create or replace function public.can_assign(cid text, t text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare me public.staff := public.my_staff();
begin
  if not public.can_edit_class(cid) then return false; end if;
  if t is null or me.role <> 'chair' then return true; end if;
  return exists (select 1 from public.faculty f where f.key = t and f.department = me.department);
end $$;

-- Does this GE class need the chair's and associate dean's approval?
create or replace function public.needs_approval(cid text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  c public.classes; f public.faculty; scope text; t text := public.class_teacher(cid);
begin
  select * into c from public.classes where id = cid;
  if not found or not c.is_ge or t is null then return false; end if;
  select * into f from public.faculty where key = t;
  if f.college = 'GE' then return false; end if;
  select approval_scope into scope from public.settings where id = 1;
  return scope = 'all' or f.college <> c.college;
end $$;

-- Approve or reject a GE class taught by college faculty. decision: 'approve' | 'reject' | 'reopen'.
create or replace function public.decide_ge(cid text, decision text, note text default null) returns text
language plpgsql volatile security definer set search_path = public as $$
declare
  me public.staff := public.my_staff();
  t text := public.class_teacher(cid);
  f public.faculty;
  sched text := public.class_schedule(cid);
  as_chair boolean; as_adean boolean;
  who text := me.email;
begin
  if me.email is null then raise exception 'Your account has no role yet'; end if;
  if not public.needs_approval(cid) then raise exception 'This class does not need approval'; end if;
  if sched = '' then raise exception 'Book a time for this class first'; end if;
  select * into f from public.faculty where key = t;
  as_chair := me.role in ('registrar', 'dean') or (me.role = 'chair' and me.department = f.department);
  as_adean := me.role in ('registrar', 'dean') or (me.role = 'associate_dean' and me.college = f.college);
  if decision = 'reopen' then
    if not (public.can_edit_class(cid) or as_chair or as_adean) then raise exception 'Not allowed'; end if;
    delete from public.ge_approvals where class_id = cid and teacher = t;
    return 'reopened';
  end if;
  if not (as_chair or as_adean) then raise exception 'Only % chair or the % associate dean can decide this', f.department, f.college; end if;
  insert into public.ge_approvals (class_id, teacher, schedule) values (cid, t, sched)
    on conflict (class_id, teacher) do nothing;
  -- A schedule change since the last decision starts the approval over.
  update public.ge_approvals set schedule = sched, chair_by = null, chair_at = null, adean_by = null, adean_at = null,
         rejected_by = null, rejected_at = null, note = null
   where class_id = cid and teacher = t and schedule <> sched;
  if decision = 'approve' then
    update public.ge_approvals set
      chair_by = case when as_chair then who else chair_by end, chair_at = case when as_chair then now() else chair_at end,
      adean_by = case when as_adean then who else adean_by end, adean_at = case when as_adean then now() else adean_at end,
      rejected_by = null, rejected_at = null, note = coalesce(decide_ge.note, ge_approvals.note)
     where class_id = cid and teacher = t;
    return 'approved';
  elsif decision = 'reject' then
    update public.ge_approvals set rejected_by = who, rejected_at = now(), note = decide_ge.note,
           chair_by = null, chair_at = null, adean_by = null, adean_at = null
     where class_id = cid and teacher = t;
    return 'rejected';
  end if;
  raise exception 'Unknown decision %', decision;
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
alter table public.ge_approvals    enable row level security;
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
  using (public.can_edit_class(class_id)) with check (public.can_assign(class_id, teacher));
drop policy if exists remove_teacher_changes on public.teacher_changes;
create policy remove_teacher_changes on public.teacher_changes for delete to authenticated using (public.can_edit_class(class_id));

-- Approvals are written only through decide_ge().
drop policy if exists read_ge_approvals on public.ge_approvals;
create policy read_ge_approvals on public.ge_approvals for select to authenticated using (public.has_role());

drop policy if exists read_settings on public.settings;
create policy read_settings on public.settings for select to authenticated using (public.has_role());
drop policy if exists admin_settings on public.settings;
create policy admin_settings on public.settings for update to authenticated using (public.is_admin()) with check (public.is_admin());

grant usage on schema public to authenticated;
grant select on public.faculty, public.classes, public.ge_approvals to authenticated;
grant select, insert, update, delete on public.staff, public.bookings, public.teacher_changes to authenticated;
grant select, update on public.settings to authenticated;
grant execute on function public.decide_ge(text, text, text), public.publish_schedule(), public.my_staff(),
  public.can_edit_class(text), public.can_assign(text, text), public.needs_approval(text) to authenticated;
revoke all on all tables in schema public from anon;

-- ---------- live updates ----------
alter table public.bookings replica identity full;
alter table public.teacher_changes replica identity full;
alter table public.ge_approvals replica identity full;
do $$ begin
  begin alter publication supabase_realtime add table public.bookings; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.teacher_changes; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.ge_approvals; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.settings; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.staff; exception when duplicate_object then null; end;
end $$;
