package net.staude.amiscara.agents.model

/**
 * Live mode of the input bar: slash commands typed straight into Claude
 * Code, so it shows its own suggestions in the pane (`LiveTyping.swift`,
 * `live.ts`). What to send so the agent's input line goes from `typed` to
 * `target`: backspaces for everything after the common start, then the
 * new rest. Counts code points, as the terminal deletes characters.
 */
fun liveEdit(typed: String, target: String): Pair<Int, String> {
    val from = typed.codePoints().toArray()
    val to = target.codePoints().toArray()
    var common = 0
    while (common < from.size && common < to.size && from[common] == to[common]) common++
    return (from.size - common) to String(to, common, to.size - common)
}

/** A path as one shell word: in single quotes, with `'` escaped. */
fun shellQuoted(path: String): String = "'" + path.replace("'", "'\\''") + "'"
