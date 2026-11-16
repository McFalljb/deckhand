package main

// The job sheet's form and the note it writes live in the core (core/jobs_form.odin), so a
// browser's job sheet (job_form, web/src/app/JobSheet.tsx) writes the same note with the same
// messages. The window's names for them:

import "core"

Job_Form :: core.Job_Form
Sched_Preset :: core.Sched_Preset
SCHED_PRESET_LABELS := core.SCHED_PRESET_LABELS
EVERY_HOURS_MAX :: core.EVERY_HOURS_MAX

job_form_from_note :: core.job_form_from_note
job_form_check :: core.job_form_check
job_note_apply_form :: core.job_note_apply_form
job_form_new_note :: core.job_form_new_note
sched_preset_text :: core.sched_preset_text
sched_preset_detect :: core.sched_preset_detect
sched_next_text :: core.sched_next_text
