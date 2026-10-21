package net.staude.amiscara.agents.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import net.staude.amiscara.agents.core.StyledLine
import net.staude.amiscara.agents.core.StyledSpan
import net.staude.amiscara.agents.core.TermColor
import net.staude.amiscara.agents.model.TerminalScheme

// Terminal colors for styled spans; the same schemes and contrast rule as
// `TerminalTheme.swift` and `apps/desktop/src/lib/term.ts`.

data class Rgb(val r: Double, val g: Double, val b: Double) {
    val color: Color get() = Color(r.toFloat(), g.toFloat(), b.toFloat())

    fun mixed(other: Rgb, t: Double) = Rgb(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)

    /** Relative luminance after WCAG 2. */
    val luminance: Double
        get() {
            fun channel(c: Double) = if (c <= 0.04045) c / 12.92 else ((c + 0.055) / 1.055).pow(2.4)
            return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
        }

    fun contrast(other: Rgb): Double {
        val (a, b) = luminance to other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    companion object {
        fun hex(value: Int) = Rgb((value shr 16 and 0xff) / 255.0, (value shr 8 and 0xff) / 255.0, (value and 0xff) / 255.0)
        fun bytes(r: UByte, g: UByte, b: UByte) = Rgb(r.toInt() / 255.0, g.toInt() / 255.0, b.toInt() / 255.0)
        val White = Rgb(1.0, 1.0, 1.0)
        val Black = Rgb(0.0, 0.0, 0.0)
    }
}

/** The resolved colors a pane is drawn with. */
data class TerminalTheme(
    val background: Rgb,
    val foreground: Rgb,
    val base: List<Rgb>,
    val dark: Boolean,
    val minContrast: Boolean,
) {
    /** `fg` on `bg`, lightened or darkened until readable when `minContrast` is on. */
    fun readable(fg: Rgb, bg: Rgb): Rgb {
        if (!minContrast || fg.contrast(bg) >= CONTRAST_TARGET) return fg
        val target = if (Rgb.White.contrast(bg) >= Rgb.Black.contrast(bg)) Rgb.White else Rgb.Black
        // The least change that reaches the target.
        var low = 0.0
        var high = 1.0
        repeat(12) {
            val mid = (low + high) / 2
            if (fg.mixed(target, mid).contrast(bg) < CONTRAST_TARGET) low = mid else high = mid
        }
        return fg.mixed(target, high)
    }

    private fun indexed(index: Int): Rgb = when {
        index < 16 -> base[index]
        index < 232 -> {
            val n = index - 16
            fun step(v: Int) = (if (v == 0) 0 else 55 + v * 40) / 255.0
            Rgb(step(n / 36), step(n / 6 % 6), step(n % 6))
        }
        else -> (8 + (index - 232) * 10).let { Rgb(it / 255.0, it / 255.0, it / 255.0) }
    }

    private fun resolve(color: TermColor): Rgb? = when (color) {
        TermColor.Default -> null
        is TermColor.Indexed -> indexed(color.index.toInt())
        is TermColor.Rgb -> Rgb.bytes(color.r, color.g, color.b)
    }

    fun style(span: StyledSpan): SpanStyle {
        var fg = resolve(span.fg)
        var bg = resolve(span.bg)
        if (span.inverse) {
            val swapped = (bg ?: background) to (fg ?: foreground)
            fg = swapped.first
            bg = swapped.second
        }
        if (minContrast && (fg != null || bg != null)) fg = readable(fg ?: foreground, bg ?: background)
        val decorations = listOfNotNull(
            TextDecoration.Underline.takeIf { span.underline },
            TextDecoration.LineThrough.takeIf { span.strikethrough },
        )
        return SpanStyle(
            color = when {
                span.hidden -> Color.Transparent
                else -> (fg ?: foreground).color.let { if (span.dim) it.copy(alpha = 0.55f) else it }
            },
            background = bg?.color ?: Color.Unspecified,
            fontWeight = if (span.bold) FontWeight.Bold else null,
            fontStyle = if (span.italic) FontStyle.Italic else null,
            textDecoration = if (decorations.isEmpty()) null else TextDecoration.combine(decorations),
        )
    }

    /** One terminal line with search hits marked: character ranges and their color. */
    fun line(line: StyledLine, marks: List<Pair<IntRange, Color>> = emptyList()): AnnotatedString =
        buildAnnotatedString {
            for (span in line.spans) {
                // A web address in the output opens in the browser (#186).
                val link = span.link
                if (link == null) {
                    withStyle(style(span)) { append(span.text) }
                } else {
                    withLink(LinkAnnotation.Url(link, LINK)) { withStyle(style(span)) { append(span.text) } }
                }
            }
            for ((range, color) in marks) addStyle(SpanStyle(background = color, color = Color.Black), range.first, range.last + 1)
        }

    companion object {
        private val LINK = TextLinkStyles(SpanStyle(textDecoration = TextDecoration.Underline))

        /** Contrast ratio text gets at least with `minContrast` (WCAG AA). */
        const val CONTRAST_TARGET = 4.5

        fun of(scheme: TerminalScheme, dark: Boolean, minContrast: Boolean): TerminalTheme {
            val (light, darkColors, base) = when (scheme) {
                TerminalScheme.STANDARD -> Triple(0xffffff to 0x1b1f20, 0x1c1c1f to 0xe0e0e0, STANDARD)
                TerminalScheme.SOLARIZED -> Triple(0xfdf6e3 to 0x657b83, 0x002b36 to 0x839496, SOLARIZED)
                TerminalScheme.APPLE -> Triple(0xffffff to 0x000000, 0x1e1e1e to 0xf2f2f2, APPLE)
            }
            val (bg, fg) = if (dark) darkColors else light
            return TerminalTheme(Rgb.hex(bg), Rgb.hex(fg), base, dark, minContrast)
        }

        private val STANDARD = listOf(
            0x000000, 0xcc3d3d, 0x5cb85c, 0xccad3d, 0x4275d6, 0xb05cc7, 0x3dadbd, 0xcccccc,
            0x757575, 0xf56666, 0x85e085, 0xf5db66, 0x75a3fa, 0xdb85f5, 0x6bdbeb, 0xffffff,
        ).map(Rgb::hex)

        private val SOLARIZED = listOf(
            0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
            0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3,
        ).map(Rgb::hex)

        private val APPLE = listOf(
            0x000000, 0x990000, 0x00a600, 0x999900, 0x0000b2, 0xb200b2, 0x00a6b2, 0xbfbfbf,
            0x666666, 0xe50000, 0x00d900, 0xe5e500, 0x0000ff, 0xe500e5, 0x00e5e5, 0xe5e5e5,
        ).map(Rgb::hex)
    }
}
