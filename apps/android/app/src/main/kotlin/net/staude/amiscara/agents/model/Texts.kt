package net.staude.amiscara.agents.model

import android.content.Context
import android.content.res.Resources
import androidx.annotation.StringRes

/**
 * Localized strings for model code without a `Context` at hand, such as
 * error messages built for the screens (#207). Set once by `AmiscaraApp`;
 * the application's resources follow the system and per-app language.
 */
object Texts {
    private lateinit var resources: () -> Resources

    fun init(context: Context) {
        val app = context.applicationContext
        resources = { app.resources }
    }

    fun get(@StringRes id: Int, vararg args: Any): String = resources().getString(id, *args)
}
