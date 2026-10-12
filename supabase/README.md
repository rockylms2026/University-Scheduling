# Hosted version with logins (Supabase)

The scheduling page in `web/index.html` signs people in with Supabase and limits what each role can do. The limits are enforced by the database (row level security in `schema.sql`), not only by the page.

| Role | Can schedule | Approves |
|---|---|---|
| Registrar, Dean | everything; manage people; open GE scheduling; publish | anything |
| Associate Dean | their college's classes, and GE classes in their college's sections (once GE is open) | GE classes taught by their college's faculty |
| Department Chair | their department's major classes, with their own department's faculty; never GE | GE classes taught by their department's faculty |
| GE Coordinator | every GE class (once GE is open) | none |

A GE class taught by a member of a college (not the GE Department) stays *Waiting* until that teacher's chair approves it. If the teacher's department does not hold the course, their college's associate dean must approve too. For example, Psychology holds Understanding the Self, so a Psychology teacher needs only the chair. A new time or a new teacher asks again. In Settings, the Registrar can limit this to teachers serving another college.

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
