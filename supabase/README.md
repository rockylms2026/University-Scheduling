# Hosted version with logins (Supabase)

The scheduling page in `web/index.html` signs people in with Supabase and limits what each role can do. The limits are enforced by the database (row level security in `schema.sql`), not only by the page.

| Role | Can schedule | Approves |
|---|---|---|
| Registrar, Dean | everything; manage people; open GE Department scheduling; publish | anything |
| Department Chair | their department's major classes, with their own faculty; GE courses their department holds, for their own sections; GE courses another department holds, for their own sections (time and room only) | borrowed GE classes from their department, when the borrowing department is in the same college (and they pick the teacher) |
| Associate Dean | the classes of their college's sections | borrowed GE classes from their college, when the borrowing department is in another college (and they pick the teacher) |
| GE Coordinator | GE Department courses (PE, CWTS, PHIL 190, PHIL 220, ARTS 101, ENGL 302), last, once opened | none |

The department holding a GE class is the one the loading plan gives it to: Social Work, say, for the PSYC 160 and GAD 171 classes its faculty teach. A class with no teacher in the plan goes to the house department in `housed_by` (`data/institutional_core.yaml`; UNI 103 is held by each program's own department). A department teaching a GE course for its own sections needs no approval. A GE class a department books from another department stays *Waiting* until the holding department approves it and picks the teacher from its own faculty. A holding department without an available instructor can hand the class to the house department (and take it back). A new time asks again.

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
