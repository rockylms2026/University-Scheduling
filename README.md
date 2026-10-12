# University Class Scheduling

## Scheduling desk (what the registrar uses)

`python -m scheduler planner` writes `output/scheduling_system.html`, the
page published on claude.ai where the registrar schedules every class by
hand: College > Programs (Sections, Teachers, Courses) or Rooms. For each
class it lists every time the University Class Time Frame allows and checks,
as you choose, the section's students (including BSBA major groups and BSP
tracks), the teacher's other classes and daily hours, room bookings,
practicum placement days, lab-room blocks, and teaching loads. It shows which
teachers and rooms are free at that time. Bookings are saved in the page's
shared database, so everyone with access sees the same timetable.

## Automatic draft (optional)

Builds conflict-free weekly timetables for every student section, faculty
member, and room, from the university's planning documents:

- the curricula and faculty loading plans of CSS, CISC, CBE, COE, and CCJPS,
- the GE Department faculty and loading plan,
- the University Class Time Frame (periods, lab blocks, practicum days), and
- the Campus Space Plan (classrooms, laboratories, PE venues).

All of it is transcribed into editable YAML files under `data/`.

## What it guarantees

Hard rules (never broken; re-checked independently after every solve):

- No student group, teacher, or room is in two places at once. BSBA major
  groups (FM, MKT, BAN) and BS Psychology tracks are handled so that a
  student's block classes and major classes never collide.
- Lectures meet MWF in one period (M1–M8) or TTh in one period (T1–T5);
  lab courses meet as two MWF lecture periods plus one 3-hour lab block
  (LA–LG); PE is MWF; UNI 103 is one MWF period; CWTS is Saturday 8–11.
- Lunch (11:30–12:30 MWF, 12:00–1:30 TTh) is always free.
- Students on placement (internship, practicum, field study) have no classes
  on their placement days.
- Each college's classes use that college's classrooms; Lingkod Hall
  overflow rooms only when needed; labs use their own lab rooms; PE venues
  are never over-filled.
- No teacher teaches more than 8 hours in a day.

Preferences (kept when possible): labs in the blocks the time frame assigns
to each lab room, CISC lab days by year level, at most 6 teaching hours a day,
compact student days, and classes in the department's own building.

When the plans make a rule impossible to keep, the solver places the class
anyway using a clearly marked exception and lists it under **Needs approval**.

## Use

```bash
pip install -r requirements.txt
python -m scheduler validate              # check the plans (loads, caps, sections)
python -m scheduler solve                 # both semesters, about 6 minutes each
python -m scheduler export                # Excel workbook + HTML viewer
python -m scheduler diagnose --semester 1 # explain an impossible semester
python -m pytest tests
```

Outputs in `output/`:

- `University_Schedule.xlsx`: timetables by student group, teacher, and
  room; a filterable master list; faculty loads; room use; items needing
  approval; plan notes.
- `schedule_viewer.html`: a single-file interactive viewer (open in any
  browser).
- `schedule_sem1.json`, `schedule_sem2.json`: the solved timetables.

## Changing the data

| To change | Edit |
|---|---|
| Courses, curricula, faculty, teaching loads | `data/colleges/<college>.yaml` |
| GE courses | `data/institutional_core.yaml` |
| Periods, lab blocks, CWTS time, faculty daily limits, unavailable times | `data/time_frame.yaml` |
| Classrooms, labs, PE venues, buildings | `data/campus.yaml` |

Then run `validate`, `solve`, and `export` again.
