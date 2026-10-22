package net.staude.amiscara.agents

import android.annotation.SuppressLint
import android.content.Intent
import android.os.Bundle
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import net.staude.amiscara.agents.model.Demo
import net.staude.amiscara.agents.ui.AmiscaraTheme
import net.staude.amiscara.agents.ui.AppNavigation

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val app = application as AmiscaraApp
        val demo = Demo.read(intent.extras, app.hosts)
        dropExtras(intent)
        if (savedInstanceState == null) handle(intent)
        demo?.let { app.openedLink.value = it }
        setContent {
            AmiscaraTheme {
                AppNavigation(app)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // The user may have allowed the local network in the settings.
        (application as AmiscaraApp).refreshLocalNetwork()
    }

    // Activity.dispatchKeyEvent is public API; androidx.core only marks its
    // own override restricted. Shortcuts must come before the focused view.
    @SuppressLint("RestrictedApi")
    override fun dispatchKeyEvent(event: KeyEvent): Boolean =
        (application as AmiscaraApp).shortcuts.dispatch(event) || super.dispatchKeyEvent(event)

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val demo = Demo.read(intent.extras, (application as AmiscaraApp).hosts)
        dropExtras(intent)
        handle(intent)
        demo?.let { (application as AmiscaraApp).openedLink.value = it }
    }

    /**
     * The activity is exported, and Navigation follows deep link extras in
     * its intent to any screen with any arguments. The app reads only the
     * link (`data`), so every extra goes.
     */
    private fun dropExtras(intent: Intent) {
        intent.replaceExtras(Bundle())
        setIntent(intent)
    }

    private fun handle(intent: Intent) {
        if (intent.action == Intent.ACTION_VIEW) intent.data?.let { (application as AmiscaraApp).open(it) }
    }
}
