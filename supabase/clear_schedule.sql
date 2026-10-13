-- Clean start for the 1st semester schedule. Paste into the Supabase SQL Editor and run it once.
-- Removes every booking (times and rooms), every teacher chosen so far, all requests and
-- answers for borrowed GE classes, instructor requests, and department submissions, since a
-- submission describes a schedule that no longer exists. Faculty, classes, staff accounts,
-- the GE teaching lists and specializations stay.
delete from public.ge_decisions;
delete from public.ge_requests;
delete from public.instructor_requests;
delete from public.bookings;
delete from public.teacher_changes;
delete from public.submissions;
update public.classes set plan_teacher = null where plan_teacher is not null;
update public.settings set published_at = null, published_by = null;
