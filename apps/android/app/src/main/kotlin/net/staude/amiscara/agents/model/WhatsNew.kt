package net.staude.amiscara.agents.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject

/** The notes of one version from `apps/whats-new.json` (#382). */
data class WhatsNewEntry(val version: String, val de: List<String>, val en: List<String>) {
    fun notes(german: Boolean): List<String> = if (german) de else en
}

/**
 * "Neuigkeiten" after an update (#382): which versions the dialog shows and
 * when, with the rules of `Model/WhatsNew.swift`. The notes come from
 * `apps/whats-new.json`, which the build bundles as an asset; a release
 * stops without notes for its version (`scripts/whats-new.py`).
 */
object WhatsNew {
    /** The key of this app in the file. */
    const val APP = "android"

    /**
     * The entries of `app`; empty when the file is broken, without the
     * entries it cannot read.
     */
    fun entries(json: String, app: String = APP): List<WhatsNewEntry> {
        val list = runCatching { Json.parseToJsonElement(json).jsonObject[app] as? JsonArray }.getOrNull()
            ?: return emptyList()
        return list.mapNotNull { item ->
            val entry = item as? JsonObject ?: return@mapNotNull null
            val version = (entry["version"] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
                ?: return@mapNotNull null
            val de = strings(entry["de"]) ?: return@mapNotNull null
            val en = strings(entry["en"]) ?: return@mapNotNull null
            WhatsNewEntry(version, de, en)
        }
    }

    private fun strings(element: Any?): List<String>? {
        val array = element as? JsonArray ?: return null
        return array.map { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.contentOrNull ?: return null }
    }

    /** "1.2.3" as three numbers; `null` for anything else. */
    fun parse(version: String): List<Int>? {
        val parts = version.split('.')
        if (parts.size != 3) return null
        val numbers = parts.map { part ->
            if (part.isEmpty() || !part.all { it in '0'..'9' }) return null
            part.toIntOrNull() ?: return null
        }
        return numbers
    }

    /** Whether `a` comes before `b`; 0.9.0 before 0.10.0. */
    fun isOlder(a: List<Int>, b: List<Int>): Boolean {
        for (i in a.indices) if (a[i] != b[i]) return a[i] < b[i]
        return false
    }

    /** The versions after `seen` up to `current`, newest first. */
    fun pending(entries: List<WhatsNewEntry>, seen: String, current: String): List<WhatsNewEntry> {
        val seenNumbers = parse(seen) ?: return emptyList()
        val currentNumbers = parse(current) ?: return emptyList()
        return sorted(entries) { !isOlder(it, seenNumbers) && it != seenNumbers && !isOlder(currentNumbers, it) }
    }

    /** All versions up to `current`, newest first. */
    fun history(entries: List<WhatsNewEntry>, current: String): List<WhatsNewEntry> {
        val currentNumbers = parse(current) ?: return emptyList()
        return sorted(entries) { !isOlder(currentNumbers, it) }
    }

    /**
     * On start: what to show once, given the version noted as seen (`null`
     * on the first start). A fresh install shows nothing, the same version
     * and a downgrade neither. The caller notes `current` as seen.
     */
    fun onLaunch(entries: List<WhatsNewEntry>, seen: String?, current: String): List<WhatsNewEntry> {
        if (seen == null || seen == current) return emptyList()
        return pending(entries, seen, current)
    }

    private fun sorted(entries: List<WhatsNewEntry>, keep: (List<Int>) -> Boolean): List<WhatsNewEntry> =
        entries
            .mapNotNull { entry -> parse(entry.version)?.let { entry to it } }
            .filter { keep(it.second) }
            .sortedWith { x, y -> if (isOlder(x.second, y.second)) 1 else if (isOlder(y.second, x.second)) -1 else 0 }
            .map { it.first }
}
