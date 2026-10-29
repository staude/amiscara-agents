package net.staude.amiscara.agents.model

import net.staude.amiscara.agents.core.AgentState
import net.staude.amiscara.agents.core.WorkspaceItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SpacesTest {
    private fun space(id: String, group: String? = null, nested: Boolean = false) = SpaceEntry(
        WorkspaceItem(
            workspaceId = id,
            number = 1u,
            label = group?.let { "$it/$id" } ?: id,
            name = id,
            group = group,
            focused = false,
            agentState = AgentState.IDLE,
            activeTabId = "",
            repoKey = null,
            repoName = null,
            worktreeName = if (nested) id else null,
            branch = null,
            tokens = emptyList(),
            tabs = emptyList(),
        ),
        nested,
    )

    // a, Privat (p1, p2), r with worktrees r1 and r2, b
    private val entries = listOf(
        space("a"),
        space("p1", "Privat"),
        space("p2", "Privat"),
        space("r"),
        space("r1", nested = true),
        space("r2", nested = true),
        space("b"),
    )

    @Test
    fun movesDownBehindTarget() {
        assertEquals(listOf("p1", "p2", "r", "r1", "r2", "b", "a"), moveSpace(entries, "a", "b"))
    }

    @Test
    fun movesUpInFrontOfTarget() {
        assertEquals(listOf("b", "a", "p1", "p2", "r", "r1", "r2"), moveSpace(entries, "b", "a"))
    }

    @Test
    fun movesGroupAsBlock() {
        assertEquals(listOf("a", "r", "r1", "r2", "b", "p1", "p2"), moveSpace(entries, "${GROUP_KEY_PREFIX}Privat", "b"))
        assertEquals(listOf("p1", "p2", "a", "r", "r1", "r2", "b"), moveSpace(entries, "${GROUP_KEY_PREFIX}Privat", "a"))
    }

    @Test
    fun dropsTopSpaceOnGroup() {
        assertEquals(listOf("p1", "p2", "a", "r", "r1", "r2", "b"), moveSpace(entries, "a", "${GROUP_KEY_PREFIX}Privat"))
    }

    @Test
    fun movesSpaceWithinGroup() {
        assertEquals(listOf("a", "p2", "p1", "r", "r1", "r2", "b"), moveSpace(entries, "p1", "p2"))
    }

    @Test
    fun movesRepositoryWithWorktrees() {
        assertEquals(listOf("r", "r1", "r2", "a", "p1", "p2", "b"), moveSpace(entries, "r", "a"))
        assertEquals(listOf("a", "p1", "p2", "b", "r", "r1", "r2"), moveSpace(entries, "r", "b"))
    }

    @Test
    fun movesWorktreeUnderItsRepository() {
        assertEquals(listOf("a", "p1", "p2", "r", "r2", "r1", "b"), moveSpace(entries, "r2", "r1"))
    }

    @Test
    fun refusesOtherLevels() {
        assertNull(moveSpace(entries, "p1", "a"))
        assertNull(moveSpace(entries, "a", "p1"))
        assertNull(moveSpace(entries, "r1", "a"))
        assertNull(moveSpace(entries, "r", "r1"))
        assertNull(moveSpace(entries, "p1", "${GROUP_KEY_PREFIX}Privat"))
    }

    @Test
    fun refusesOtherGroupOrRepository() {
        val more = entries + listOf(space("w1", "Work"), space("s"), space("s1", nested = true))
        assertNull(moveSpace(more, "p1", "w1"))
        assertNull(moveSpace(more, "r1", "s1"))
    }

    @Test
    fun refusesSameOrUnknownKey() {
        assertNull(moveSpace(entries, "a", "a"))
        assertNull(moveSpace(entries, "x", "a"))
        assertNull(moveSpace(entries, "a", "x"))
        assertNull(moveSpace(entries, "${GROUP_KEY_PREFIX}Nope", "a"))
    }

    @Test
    fun linesUpAtTopWhenMovingUp() {
        assertEquals(InsertionLine("a", below = false), insertionLine(entries, "b", "a"))
        assertEquals(InsertionLine("${GROUP_KEY_PREFIX}Privat", below = false), insertionLine(entries, "b", "${GROUP_KEY_PREFIX}Privat"))
    }

    @Test
    fun linesDownBelowLastRowOfTarget() {
        assertEquals(InsertionLine("b", below = true), insertionLine(entries, "a", "b"))
        assertEquals(InsertionLine("r2", below = true), insertionLine(entries, "a", "r"))
        assertEquals(InsertionLine("p2", below = true), insertionLine(entries, "a", "${GROUP_KEY_PREFIX}Privat"))
    }

    @Test
    fun noLineWhereMoveIsRefused() {
        assertNull(insertionLine(entries, "a", "a"))
        assertNull(insertionLine(entries, "p1", "a"))
        assertNull(insertionLine(entries, "x", "a"))
    }
}
