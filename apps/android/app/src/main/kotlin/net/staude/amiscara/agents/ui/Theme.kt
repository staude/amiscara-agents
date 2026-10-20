package net.staude.amiscara.agents.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import android.os.Build

/** Teal of the app icon, for devices without dynamic colors. */
private val Teal = Color(0xFF14A08C)

/** Material You where the system has it (Android 12+), else the icon's teal. */
@Composable
fun AmiscaraTheme(
    dark: Boolean = isSystemInDarkTheme(),
    dynamicColor: Boolean = true,
    content: @Composable () -> Unit,
) {
    val colors = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val context = LocalContext.current
            if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        }
        dark -> darkColorScheme(primary = Teal)
        else -> lightColorScheme(primary = Teal)
    }
    MaterialTheme(colorScheme = colors, content = content)
}
