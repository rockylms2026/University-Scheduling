-- Clean start for teachers. Paste into the Supabase SQL Editor and run it once.
-- 1. Borrowed GE classes lose their bookings, so each one is booked again later together
--    with a free instructor of a department that teaches the course.
-- 2. All requests, answers and instructor requests for borrowed GE classes are removed.
-- 3. Every teacher chosen so far is removed, and no class keeps a loading-plan teacher.
-- Times and rooms of all other classes stay as they are.
delete from public.bookings where public.class_kind(class_id) = 'borrowed';
delete from public.ge_decisions;
delete from public.ge_requests;
delete from public.instructor_requests;
delete from public.teacher_changes;
update public.classes set plan_teacher = null where plan_teacher is not null;
