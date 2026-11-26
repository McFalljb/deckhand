// A phone's bar while the Files tree's clipboard holds something: "3 items copied · Paste here ·
// Clear". Paste here goes where Paste goes (the selected folder, the selected file's folder, else
// the root: fileclip.ts pasteTarget), named on the button's title.

import { clearClip, clipText, paste, type Tree } from "./fileops.ts";
import { folderLabel } from "./filetree.ts";

export function ClipBar({ t, target }: { t: Tree; target: string }) {
  return (
    <div class="files-pick files-clip" role="toolbar" aria-label="Files to paste">
      <span class="files-pick-n">{clipText()}</span>
      <span class="spacer" />
      <button type="button" class="btn small primary" title={"Paste in " + folderLabel(t.root, target)} onClick={() => void paste(t, target)}>Paste here</button>
      <button type="button" class="btn small" onClick={() => clearClip(t)}>Clear</button>
    </div>
  );
}
