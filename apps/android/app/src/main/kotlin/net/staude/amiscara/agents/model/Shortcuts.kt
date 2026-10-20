package net.staude.amiscara.agents.model

import android.view.KeyEvent

/**
 * Hardware keyboard shortcuts, like the other apps (Ctrl where the Mac
 * uses ⌘). The activity hands every key press with Ctrl here before the
 * focused view sees it; the screens on display register their handlers,
 * the newest first, so they work wherever the focus is.
 */
class Shortcuts {
    fun interface Handler {
        /** True when the key press was used. */
        fun handle(event: KeyEvent): Boolean
    }

    private val handlers = mutableListOf<Handler>()

    fun add(handler: Handler) {
        handlers += handler
    }

    fun remove(handler: Handler) {
        handlers -= handler
    }

    fun dispatch(event: KeyEvent): Boolean {
        if (event.action != KeyEvent.ACTION_DOWN || !event.isCtrlPressed) return false
        // Ctrl+Alt from AltGr types characters on many layouts.
        if (event.metaState and KeyEvent.META_ALT_RIGHT_ON != 0) return false
        return handlers.asReversed().any { it.handle(event) }
    }
}
