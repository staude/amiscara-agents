package net.staude.amiscara.agents

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import net.staude.amiscara.agents.ui.AmiscaraTheme
import net.staude.amiscara.agents.ui.AppNavigation

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val app = application as AmiscaraApp
        dropExtras(intent)
        if (savedInstanceState == null) handle(intent)
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

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        dropExtras(intent)
        handle(intent)
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
