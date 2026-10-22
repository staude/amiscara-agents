package net.staude.amiscara.agents.model

import android.content.Context
import androidx.core.content.edit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.Json
import net.staude.amiscara.agents.R

/** Light or dark terminal: as the app (default) or fixed. */
enum class TerminalAppearance { APP, LIGHT, DARK }

/** Same schemes as the other apps (`TerminalTheme.swift`, `term.ts`). */
enum class TerminalScheme { STANDARD, SOLARIZED, APPLE }

/** The terminal look the user chose; edited in the settings (#176). */
data class TerminalPrefs(
    val appearance: TerminalAppearance = TerminalAppearance.APP,
    val scheme: TerminalScheme = TerminalScheme.STANDARD,
    val minContrast: Boolean = true,
    val fontSize: Float = DEFAULT_FONT_SIZE,
    /** Long lines wrap at the view width instead of scrolling sideways (#191). */
    val wrapLines: Boolean = false,
    /** Offer the steps through full-screen agents, which move the host's view too (#187). */
    val fullscreenScroll: Boolean = false,
) {
    companion object {
        const val DEFAULT_FONT_SIZE = 12f
        val FONT_RANGE = 8f..28f
    }
}

/**
 * Per-device settings in shared preferences: the terminal look, the quick
 * replies of the input bar (same defaults as the other apps) and the
 * standby.
 */
class Settings(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
    /** Shown until the user changes the list, as in the other apps. */
    private val defaultReplies = context.resources.getStringArray(R.array.default_quick_replies).toList()
    private val json = Json

    private val terminalState = MutableStateFlow(loadTerminal())
    val terminal: StateFlow<TerminalPrefs> = terminalState.asStateFlow()

    private val repliesState = MutableStateFlow(loadReplies())
    val quickReplies: StateFlow<List<String>> = repliesState.asStateFlow()

    private val standbyState = MutableStateFlow(prefs.getBoolean("standby", false))
    /** Whether the standby service keeps the sessions open in the background. */
    val standby: StateFlow<Boolean> = standbyState.asStateFlow()

    private val standbyOnBootState = MutableStateFlow(prefs.getBoolean("standbyOnBoot", true))
    /** Whether the standby comes back after the device starts. */
    val standbyOnBoot: StateFlow<Boolean> = standbyOnBootState.asStateFlow()

    fun setStandby(on: Boolean) {
        prefs.edit { putBoolean("standby", on) }
        standbyState.value = on
    }

    fun setStandbyOnBoot(on: Boolean) {
        prefs.edit { putBoolean("standbyOnBoot", on) }
        standbyOnBootState.value = on
    }

    fun setTerminal(value: TerminalPrefs) {
        val clamped = value.copy(fontSize = value.fontSize.coerceIn(TerminalPrefs.FONT_RANGE))
        prefs.edit {
            putString("terminalAppearance", clamped.appearance.name)
            putString("terminalScheme", clamped.scheme.name)
            putBoolean("terminalMinContrast", clamped.minContrast)
            putFloat("terminalFontSize", clamped.fontSize)
            putBoolean("terminalWrapLines", clamped.wrapLines)
            putBoolean("scrollFullscreenAgents", clamped.fullscreenScroll)
        }
        terminalState.value = clamped
    }

    /** Keeps the entries that are not blank, trimmed. */
    fun setQuickReplies(replies: List<String>) {
        val list = replies.map { it.trim() }.filter { it.isNotEmpty() }
        prefs.edit { putString("quickReplies", json.encodeToString(list)) }
        repliesState.value = list
    }

    /** The agent a dialog last started (`key` per dialog); `null` for a plain shell. */
    fun agentKind(key: String): String? = prefs.getString("agentKind.$key", null)

    fun setAgentKind(key: String, kind: String?) {
        prefs.edit { if (kind == null) remove("agentKind.$key") else putString("agentKind.$key", kind) }
    }

    private fun loadTerminal() = TerminalPrefs(
        appearance = enumOr(prefs.getString("terminalAppearance", null), TerminalAppearance.APP),
        scheme = enumOr(prefs.getString("terminalScheme", null), TerminalScheme.STANDARD),
        minContrast = prefs.getBoolean("terminalMinContrast", true),
        fontSize = prefs.getFloat("terminalFontSize", TerminalPrefs.DEFAULT_FONT_SIZE),
        wrapLines = prefs.getBoolean("terminalWrapLines", false),
        fullscreenScroll = prefs.getBoolean("scrollFullscreenAgents", false),
    )

    private fun loadReplies(): List<String> =
        prefs.getString("quickReplies", null)?.let { runCatching { json.decodeFromString<List<String>>(it) }.getOrNull() }
            ?: defaultReplies

    private inline fun <reified T : Enum<T>> enumOr(name: String?, default: T): T =
        enumValues<T>().firstOrNull { it.name == name } ?: default

}
