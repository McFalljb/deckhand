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
  printf("Grid_Row size %zu\n", sizeof(GhosttyRow));
  printf("Point_Coordinate size %zu\n", sizeof(GhosttyPointCoordinate));
  return 0;
}
