package net.staude.amiscara.agents.model

import net.staude.amiscara.agents.core.SpaceSort
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HostConfigTest {
    private val host = HostConfig(id = "a", name = "w", host = "w.local", user = "frank", socketPath = "/s")

    @Test
    fun sortingPerMode() {
        assertEquals(SpaceSort.Herdr, host.spaceSorting)
        assertEquals(SpaceSort.Herdr, host.copy(spaceSort = SpaceSortMode.HERDR).spaceSorting)
        assertEquals(SpaceSort.NameAscending, host.copy(spaceSort = SpaceSortMode.NAME_ASCENDING).spaceSorting)
        assertEquals(SpaceSort.NameDescending, host.copy(spaceSort = SpaceSortMode.NAME_DESCENDING).spaceSorting)
        assertEquals(SpaceSort.Manual(emptyList()), host.copy(spaceSort = SpaceSortMode.MANUAL).spaceSorting)
        assertEquals(
            SpaceSort.Manual(listOf("w2", "w1")),
            host.copy(spaceSort = SpaceSortMode.MANUAL, spaceOrder = listOf("w2", "w1")).spaceSorting,
        )
    }

    @Test
    fun readsStoredSorting() {
        val base = """"id":"a","name":"w","host":"w.local","user":"frank","socketPath":"/s""""
        val manual = hostJson.decodeFromString<HostConfig>("""{$base,"spaceSort":"manual","spaceOrder":["w2","w1"]}""")
        assertEquals(SpaceSortMode.MANUAL, manual.spaceSort)
        assertEquals(listOf("w2", "w1"), manual.spaceOrder)
        assertEquals(SpaceSortMode.NAME_DESCENDING, hostJson.decodeFromString<HostConfig>("""{$base,"spaceSort":"nameDescending"}""").spaceSort)
        assertNull(hostJson.decodeFromString<HostConfig>("""{$base,"spaceSort":"byColor"}""").spaceSort)
        assertNull(hostJson.decodeFromString<HostConfig>("{$base}").spaceSort)
    }

    @Test
    fun writesDesktopNames() {
        val text = hostJson.encodeToString(host.copy(spaceSort = SpaceSortMode.NAME_ASCENDING))
        assertTrue(text, "\"spaceSort\": \"nameAscending\"" in text)
    }
}
