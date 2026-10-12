# Hosted version with logins (Supabase)

The scheduling page in `web/index.html` signs people in with Supabase and limits what each role can do. The limits are enforced by the database (row level security in `schema.sql`), not only by the page.

| Role | Can schedule | Answers requests |
|---|---|---|
| Registrar, Dean | everything; manage people and the GE teaching lists; open GE Department scheduling; publish | any |
| Department Chair | their department's major classes, with their own faculty; GE courses their department may teach, for their own sections, with their own faculty; other GE classes of their own sections (time and room, then ask a department) | requests to their department from a department of the same college (and they pick the teacher) |
| Associate Dean | the classes of their college's sections | requests to a department of their college from another college (and they pick the teacher) |
| GE Coordinator | GE Department courses (PE, CWTS, PHIL 190, PHIL 220, ARTS 101, ENGL 302), last, once opened | none |

**Who may teach each GE course** is a list on the Settings page, started from the loading plans: for example Psychology, Social Work, and Elementary Education for PSYC 160. A department on the list books that course for its own sections with its own instructors, with no approval.

**Submitting.** A chair submits when the department's own part is done: every class of its sections has a time (and a room where needed), and every class the department teaches has a teacher. Borrowed GE classes need only their time, because their instructors are asked from other departments after those departments submit. GE Department courses are not counted. If anything is missing, a pop-up lists it and the submission is refused. The Submissions page and the bell show who has submitted, and a department is *fully complete* once its borrowed GE classes have approved instructors.

**Asking for a GE instructor.** A section whose department is not on the list books the time and names an instructor of a listed department that has submitted, free then and with room in their load; the GE Availability page shows them all. When nobody is available, it can request an instructor from a department instead. The asked department answers (its chair in the same college, its college's associate dean otherwise) and may give the class to another of its instructors; if it says no, the section asks someone else.

## One-time setup

1. **Database.** In Supabase, open **SQL Editor → New query**, paste all of `supabase/setup.sql`, and click **Run**. This creates the tables and rules, loads the faculty and classes, gives the Registrar's email full access, and copies the 49 bookings and 3 teacher changes made in the claude.ai version. It is safe to run again.
2. **Your login.** Open **Authentication → Users → Add user → Create new user**. Enter the Registrar's email and a password, and tick **Auto Confirm User**.
3. **Close public sign-up** (recommended). Open **Authentication → Sign In / Providers** and turn off **Allow new users to sign up**. Accounts are then created only by you. An account with no role can sign in but sees nothing either way.
4. **Host the page.** On [Vercel](https://vercel.com), choose **Add New → Project**, import `rockylms2026/university-scheduling`, and click **Deploy**. Leave **Root Directory** empty and the framework as **Other**: `vercel.json` tells Vercel to serve the `web` folder as it is, with nothing to install or build.
5. **Tell Supabase the address.** In **Authentication → URL Configuration**, set **Site URL** to the Vercel address (for example `https://university-scheduling.vercel.app`) and add the same address under **Redirect URLs**. Password-reset emails link there.

## Adding people

1. In Supabase: **Authentication → Users → Add user**, with their email, a temporary password, and **Auto Confirm User** ticked.
2. In the scheduling page: **Settings → People and roles**. Enter the same email, their name, role, college (for associate deans and chairs), and department (for chairs).
3. Give them the address and the temporary password. They can change it under **Settings → Your account**.

Supabase's free plan sends only a few emails an hour, so password resets by email may be slow. Setting a new temporary password from **Authentication → Users** always works.

## Updating

When the data files change, run `python -m scheduler web`, then run the new `supabase/seed.sql` in the SQL Editor and redeploy (Vercel redeploys on every push).

## Checking the rules

`tests/rls_check.py` runs 38 checks against a local Postgres loaded with `setup.sql` (with a small stand-in for Supabase's `auth` schema). Examples: a chair cannot book another department's class or a GE class, and an approval cannot be written except through `decide_ge()`.
