package net.staude.amiscara.agents.ui

import android.view.KeyEvent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import net.staude.amiscara.agents.AmiscaraApp
import net.staude.amiscara.agents.model.Shortcuts

/** Handles Ctrl shortcuts while this composable is on screen (see [Shortcuts]). */
@Composable
fun KeyShortcuts(app: AmiscaraApp, handle: (KeyEvent) -> Boolean) {
    val current by rememberUpdatedState(handle)
    DisposableEffect(app) {
        val handler = Shortcuts.Handler { current(it) }
        app.shortcuts.add(handler)
        onDispose { app.shortcuts.remove(handler) }
    }
}

/** 1 for the 1 key (top row or keypad), else `null`. */
fun KeyEvent.digit(): Int? = when (keyCode) {
    in KeyEvent.KEYCODE_1..KeyEvent.KEYCODE_9 -> keyCode - KeyEvent.KEYCODE_0
    in KeyEvent.KEYCODE_NUMPAD_1..KeyEvent.KEYCODE_NUMPAD_9 -> keyCode - KeyEvent.KEYCODE_NUMPAD_0
    else -> null
}
