package net.staude.amiscara.agents

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import net.staude.amiscara.agents.ui.AmiscaraTheme
import net.staude.amiscara.agents.ui.ProbeScreen

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            AmiscaraTheme {
                ProbeScreen()
            }
        }
    }
}
