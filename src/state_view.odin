package main

import "core"

// The window's State (docs/plans/background-core.md §10.2, "Qualified names, no alias file"):
// the core's own today, so the window keeps writing state.x; M3 points it at the window's
// replica. Written by scripts/core-move.py.
state: ^core.State = &core.state
