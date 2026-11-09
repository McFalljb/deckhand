package core

// From src/ui_job_sheet.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

Job_Sheet :: struct {
	open:        bool,
	job:         string, // a job's id: edit it ("" = a new job)
	for_project: string, // a new job's owner, preselected
}
