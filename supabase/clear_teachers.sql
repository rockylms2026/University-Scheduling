-- Start every class with no teacher. Paste into the Supabase SQL Editor and run it once.
-- Removes the teachers from the loading plans and every teacher chosen so far.
-- Borrowed GE classes booked together with an instructor of another department keep that
-- instructor, since the request and its approval depend on it.
delete from public.teacher_changes tc
where not exists (select 1 from public.ge_requests r where r.class_id = tc.class_id);
update public.classes set plan_teacher = null where plan_teacher is not null;
