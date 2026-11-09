package core

// From src/ui_files.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

// Steps of the row menu that are not commands.
Files_Step :: enum u8 {
	None,
	New_File,
	New_Folder,
	Rename,
	Copy_Path,
	Copy_Relative,
}
