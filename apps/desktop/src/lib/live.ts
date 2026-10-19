// Live mode of the input bar: slash commands typed straight into Claude
// Code, so it shows its own suggestions in the pane (LiveTyping.swift).

/**
 * What to send so an agent's input line goes from `typed` to `target`:
 * backspaces for everything after the common start, then the new rest.
 * Counts code points, as the terminal deletes characters.
 */
export function liveEdit(typed: string, target: string): { erase: number; insert: string } {
  const from = [...typed];
  const to = [...target];
  let common = 0;
  while (common < from.length && common < to.length && from[common] === to[common]) common++;
  return { erase: from.length - common, insert: to.slice(common).join("") };
}
