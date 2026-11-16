// What "Ask pi to review" sends (the Changes tab, Changes.tsx).

export interface ReviewList {
  root: string;
  branch: string;
  default_branch: string;
  ahead: number;
}

// src/ui_changes.odin changes_review_prompt, word for word.
export function reviewPrompt(l: ReviewList): string {
  let t = `Review the uncommitted changes in this checkout (${l.root}): git status and git diff HEAD`;
  if (l.ahead > 0 && l.default_branch) {
    const one = l.ahead === 1;
    t += `, and the ${l.ahead} ${one ? "commit" : "commits"} on ${l.branch || "HEAD"} that ${one ? "is" : "are"} not on ${l.default_branch} (git diff ${l.default_branch}...HEAD)`;
  }
  return t + ". Point out bugs, risks and unfinished work.";
}

