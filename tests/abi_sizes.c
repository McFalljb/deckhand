// Prints sizeof/offsetof for the libghostty-vt structs bound in
// src/ghostty/ghostty.odin. tests/ghostty_test.odin compares these.
#include <stddef.h>
#include <stdio.h>
#define GHOSTTY_STATIC
#include <ghostty/vt.h>

#define S(name, type) printf("%s size %zu\n", name, sizeof(type))
#define O(name, type, field) printf("%s.%s offset %zu\n", name, #field, offsetof(type, field))

int main(void) {
  S("Style", GhosttyStyle);
  O("Style", GhosttyStyle, bold);
  O("Style", GhosttyStyle, underline);
  S("Style_Color", GhosttyStyleColor);
  S("Point", GhosttyPoint);
  S("Grid_Ref", GhosttyGridRef);
  S("Selection", GhosttySelection);
  O("Selection", GhosttySelection, rectangle);
  S("Selection_Format_Options", GhosttyTerminalSelectionFormatOptions);
  O("Selection_Format_Options", GhosttyTerminalSelectionFormatOptions, selection);
  S("Scroll_Viewport", GhosttyTerminalScrollViewport);
  S("Scrollbar", GhosttyTerminalScrollbar);
  S("Mode_Config", GhosttyTerminalModeConfig);
  S("Render_Cursor", GhosttyRenderStateCursor);
  O("Render_Cursor", GhosttyRenderStateCursor, visual_style);
  S("Render_Colors", GhosttyRenderStateColors);
  O("Render_Colors", GhosttyRenderStateColors, palette);
  S("Row_Selection", GhosttyRenderStateRowSelection);
  S("Mouse_Encoder_Size", GhosttyMouseEncoderSize);
  S("Mouse_Position", GhosttyMousePosition);
  printf("Key.F25 value %d\n", (int)GHOSTTY_KEY_F25);
  printf("Key.Escape value %d\n", (int)GHOSTTY_KEY_ESCAPE);
  printf("Terminal_Option.Color_Palette value %d\n", (int)GHOSTTY_TERMINAL_OPT_COLOR_PALETTE);
  printf("Terminal_Option.Color_Scheme value %d\n", (int)GHOSTTY_TERMINAL_OPT_COLOR_SCHEME);
  printf("Color_Scheme.Dark value %d\n", (int)GHOSTTY_COLOR_SCHEME_DARK);
  printf("Terminal_Data.Color_Background_Default value %d\n", (int)GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND_DEFAULT);
  printf("Terminal_Data.Kitty_Keyboard_Flags value %d\n", (int)GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS);
  printf("Cell_Data.Has_Hyperlink value %d\n", (int)GHOSTTY_CELL_DATA_HAS_HYPERLINK);
  printf("Grid_Row_Data.Wrap value %d\n", (int)GHOSTTY_ROW_DATA_WRAP);
  printf("Grid_Row_Data.Hyperlink value %d\n", (int)GHOSTTY_ROW_DATA_HYPERLINK);
  S("Program_Status", GhosttyTerminalProgramStatus);
  O("Program_Status", GhosttyTerminalProgramStatus, progress);
  O("Program_Status", GhosttyTerminalProgramStatus, id);
  O("Program_Status", GhosttyTerminalProgramStatus, message);
  S("Semantic_Prompt", GhosttyTerminalSemanticPrompt);
  O("Semantic_Prompt", GhosttyTerminalSemanticPrompt, exit_code);
  O("Semantic_Prompt", GhosttyTerminalSemanticPrompt, error);
  printf("Terminal_Option.Program_Status value %d\n", (int)GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS);
  printf("Terminal_Option.Semantic_Prompt value %d\n", (int)GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT);
  printf("Program_Status_State.Clear value %d\n", (int)GHOSTTY_PROGRAM_STATUS_STATE_CLEAR);
  printf("Program_Status_Kind.Auth value %d\n", (int)GHOSTTY_PROGRAM_STATUS_KIND_AUTH);
  printf("Semantic_Prompt_Kind.Prompt_Start value %d\n", (int)GHOSTTY_SEMANTIC_PROMPT_PROMPT_START);
  printf("Grid_Row size %zu\n", sizeof(GhosttyRow));
  printf("Point_Coordinate size %zu\n", sizeof(GhosttyPointCoordinate));
  S("Writer", GhosttyWriter);
  S("Reader", GhosttyReader);
  S("Formatter_Screen_Extra", GhosttyFormatterScreenExtra);
  O("Formatter_Screen_Extra", GhosttyFormatterScreenExtra, charsets);
  S("Formatter_Terminal_Extra", GhosttyFormatterTerminalExtra);
  O("Formatter_Terminal_Extra", GhosttyFormatterTerminalExtra, keyboard);
  O("Formatter_Terminal_Extra", GhosttyFormatterTerminalExtra, screen);
  S("Formatter_Terminal_Options", GhosttyFormatterTerminalOptions);
  O("Formatter_Terminal_Options", GhosttyFormatterTerminalOptions, extra);
  O("Formatter_Terminal_Options", GhosttyFormatterTerminalOptions, selection);
  printf("Formatter_Format.VT value %d\n", (int)GHOSTTY_FORMATTER_FORMAT_VT);
  printf("Terminal_Option.Continuation_Max_Bytes value %d\n", (int)GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES);
  printf("Terminal_Option.Scrollback_Max_Lines value %d\n", (int)GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES);
  printf("Terminal_Data.Cursor_X value %d\n", (int)GHOSTTY_TERMINAL_DATA_CURSOR_X);
  printf("Terminal_Data.Cursor_Pending_Wrap value %d\n", (int)GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP);
  printf("Terminal_Data.Cursor_Visible value %d\n", (int)GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE);
  printf("Terminal_Data.Cursor_Style value %d\n", (int)GHOSTTY_TERMINAL_DATA_CURSOR_STYLE);
  printf("Terminal_Data.Pwd value %d\n", (int)GHOSTTY_TERMINAL_DATA_PWD);
  printf("Terminal_Data.Total_Rows value %d\n", (int)GHOSTTY_TERMINAL_DATA_TOTAL_ROWS);
  printf("Terminal_Data.Scrollback_Rows value %d\n", (int)GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS);
  printf("Terminal_Data.Color_Foreground value %d\n", (int)GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND);
  printf("Terminal_Data.Color_Palette value %d\n", (int)GHOSTTY_TERMINAL_DATA_COLOR_PALETTE);
  printf("Terminal_Data.Scrollback_Max_Bytes value %d\n", (int)GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_BYTES);
  printf("Terminal_Data.Continuation_Max_Bytes value %d\n", (int)GHOSTTY_TERMINAL_DATA_CONTINUATION_MAX_BYTES);
  printf("Terminal_Data.Vt_Ground value %d\n", (int)GHOSTTY_TERMINAL_DATA_VT_GROUND);
  printf("Cell_Data.Protected value %d\n", (int)GHOSTTY_CELL_DATA_PROTECTED);
  printf("Cell_Data.Semantic_Content value %d\n", (int)GHOSTTY_CELL_DATA_SEMANTIC_CONTENT);
  printf("Grid_Row_Data.Semantic_Prompt value %d\n", (int)GHOSTTY_ROW_DATA_SEMANTIC_PROMPT);
  printf("Snapshot_Decoder_Option.Retain_Continuation value %d\n", (int)GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION);
  printf("Snapshot_Decoder_Option.Compress_History value %d\n", (int)GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY);
  printf("Snapshot_Decoder_Data.Source_Offset value %d\n", (int)GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET);
  return 0;
}
