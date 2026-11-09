package net.staude.amiscara.agents.model

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The rules of "Neuigkeiten" (#382), the same cases as `Tests/WhatsNew/main.swift`. */
class WhatsNewTest {
    private fun entry(version: String) = WhatsNewEntry(version, listOf("de $version"), listOf("en $version"))

    private fun versions(entries: List<WhatsNewEntry>) = entries.map { it.version }

    private val all = listOf("0.1.0", "0.3.0", "0.2.0", "0.10.0", "kaputt").map(::entry)

    @Test
    fun ordersByNumbersNotText() {
        assertTrue(WhatsNew.isOlder(WhatsNew.parse("0.9.0")!!, WhatsNew.parse("0.10.0")!!))
        assertFalse(WhatsNew.isOlder(WhatsNew.parse("1.0.0")!!, WhatsNew.parse("0.10.0")!!))
    }

    @Test
    fun parsesOnlyThreeNumbers() {
        assertNull(WhatsNew.parse("1.2"))
        assertNull(WhatsNew.parse("1.2.x"))
        assertNull(WhatsNew.parse("1.2.+3"))
        assertNull(WhatsNew.parse("1..3"))
        assertEquals(listOf(1, 2, 3), WhatsNew.parse("1.2.3"))
    }

    @Test
    fun pendingIsAfterSeenUpToCurrentNewestFirst() {
        assertEquals(listOf("0.3.0"), versions(WhatsNew.pending(all, "0.2.0", "0.3.0")))
        assertEquals(listOf("0.10.0", "0.3.0", "0.2.0"), versions(WhatsNew.pending(all, "0.1.0", "0.10.0")))
        assertTrue(WhatsNew.pending(all, "0.3.0", "0.3.0").isEmpty())
        assertTrue(WhatsNew.pending(all, "0.3.0", "0.2.0").isEmpty())
        assertTrue(WhatsNew.pending(all, "?", "0.3.0").isEmpty())
        assertTrue(WhatsNew.pending(all, "0.3.0", "0.4.0").isEmpty())
    }

    @Test
    fun historyIsEverythingUpToCurrent() {
        assertEquals(listOf("0.3.0", "0.2.0", "0.1.0"), versions(WhatsNew.history(all, "0.3.0")))
        assertTrue(WhatsNew.history(all, "x").isEmpty())
    }

    @Test
    fun firstStartShowsNothing() {
        assertTrue(WhatsNew.onLaunch(all, null, "0.2.0").isEmpty())
    }

    @Test
    fun updateShowsTheNewVersionOnce() {
        assertEquals(listOf("0.3.0"), versions(WhatsNew.onLaunch(all, "0.2.0", "0.3.0")))
        assertTrue(WhatsNew.onLaunch(all, "0.3.0", "0.3.0").isEmpty())
    }

    @Test
    fun downgradeShowsNothing() {
        assertTrue(WhatsNew.onLaunch(all, "0.3.0", "0.2.0").isEmpty())
    }

    @Test
    fun skipsUnreadableEntries() {
        val json = """{"android": [{"version": "0.2.0", "de": ["a"]}, {"version": "0.1.0", "de": ["b"], "en": ["c"]}, 7]}"""
        assertEquals(listOf("0.1.0"), versions(WhatsNew.entries(json)))
    }

    @Test
    fun brokenFileHasNoEntries() {
        assertTrue(WhatsNew.entries("{").isEmpty())
        assertTrue(WhatsNew.entries("""{"mac": []}""").isEmpty())
    }

    // Gradle runs unit tests in apps/android/app.
    @Test
    fun bundledFileHasCompleteAndroidEntries() {
        val entries = WhatsNew.entries(File("../../whats-new.json").readText())
        assertTrue(entries.isNotEmpty())
        assertTrue(entries.all { WhatsNew.parse(it.version) != null && it.de.isNotEmpty() && it.en.isNotEmpty() })
    }
}
