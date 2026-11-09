package core

// From src/editor_file.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

import "core:time"

EDITOR_MAX_BYTES :: 20 * 1024 * 1024

EDITOR_POLL :: 2 * time.Second

CREDENTIALS_NOT_OPENED :: "Credentials file: managed by pi (/login), not opened"
