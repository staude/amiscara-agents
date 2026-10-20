package net.staude.amiscara.agents.ui

import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.toRoute
import kotlinx.serialization.Serializable
import net.staude.amiscara.agents.AmiscaraApp
import net.staude.amiscara.agents.R
import net.staude.amiscara.agents.model.AppLink

@Serializable
object HostsRoute

@Serializable
data class HostRoute(val id: String)

@Serializable
data class EditHostRoute(val id: String? = null)

@Serializable
data class AddLinkRoute(val text: String)

@Serializable
object ScanRoute

/** The screens of the app and the links opened from outside. */
@Composable
fun AppNavigation(app: AmiscaraApp) {
    val nav = rememberNavController()
    val context = LocalContext.current
    val hosts by app.hosts.hosts.collectAsStateWithLifecycle()
    val localNetwork by app.localNetworkAllowed.collectAsStateWithLifecycle()
    val askLocalNetwork = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        app.refreshLocalNetwork()
    }

    // Asked once there is a host to reach, not on the empty first start.
    LaunchedEffect(hosts.isNotEmpty(), localNetwork) {
        if (hosts.isNotEmpty() && !localNetwork && !app.localNetworkAsked) {
            app.localNetworkAsked = true
            askLocalNetwork.launch(AmiscaraApp.LOCAL_NETWORK)
        }
    }

    LaunchedEffect(Unit) {
        app.openedLink.collect { link ->
            when (link) {
                null -> return@collect
                is AppLink.AddHost -> nav.navigate(AddLinkRoute(link.text))
                is AppLink.Open -> if (app.hosts.get(link.hostId) != null) {
                    nav.navigate(HostRoute(link.hostId)) { popUpTo(HostsRoute) }
                } else {
                    Toast.makeText(context, R.string.open_unknown_host, Toast.LENGTH_LONG).show()
                }
            }
            app.openedLink.value = null
        }
    }

    NavHost(nav, startDestination = HostsRoute) {
        composable<HostsRoute> {
            HostListScreen(
                app = app,
                openHost = { nav.navigate(HostRoute(it)) },
                addHost = { nav.navigate(EditHostRoute()) },
                scan = { nav.navigate(ScanRoute) },
                addLink = {
                    app.trustLink(it)
                    nav.navigate(AddLinkRoute(it))
                },
                askLocalNetwork = { askLocalNetwork.launch(AmiscaraApp.LOCAL_NETWORK) },
            )
        }
        composable<HostRoute> { entry ->
            val id = entry.toRoute<HostRoute>().id
            HostDetailScreen(app, id, back = { nav.popBackStack() }, edit = { nav.navigate(EditHostRoute(id)) })
        }
        composable<EditHostRoute> { entry ->
            HostEditorScreen(app, entry.toRoute<EditHostRoute>().id, back = { nav.popBackStack() }, saved = { nav.showHost(it) })
        }
        composable<AddLinkRoute> { entry ->
            val text = entry.toRoute<AddLinkRoute>().text
            // Decided once per screen, from memory only (see AmiscaraApp.trustLink).
            val trusted = rememberSaveable(text) { app.takeTrust(text) }
            AddLinkScreen(app, text, trusted, back = { nav.popBackStack() }, added = { nav.showHost(it) })
        }
        composable<ScanRoute> {
            ScannerScreen(back = { nav.popBackStack() }, scanned = {
                app.trustLink(it)
                nav.navigate(AddLinkRoute(it)) { popUpTo(HostsRoute) }
            })
        }
    }
}

/** The host's screen right above the list, after adding or editing it. */
private fun NavController.showHost(id: String) {
    navigate(HostRoute(id)) { popUpTo(HostsRoute) }
}
