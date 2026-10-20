package net.staude.amiscara.agents.ui

import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
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

/** A space as a screen of its own, on a narrow screen. */
@Serializable
data class SpaceRoute(val hostId: String, val workspaceId: String, val paneId: String? = null)

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
                    val route: Any = link.workspaceId?.let { SpaceRoute(link.hostId, it, link.paneId) } ?: HostRoute(link.hostId)
                    nav.navigate(route) { popUpTo(HostsRoute) }
                } else {
                    Toast.makeText(context, R.string.open_unknown_host, Toast.LENGTH_LONG).show()
                }
            }
            app.openedLink.value = null
        }
    }

    NavHost(nav, startDestination = HostsRoute) {
        composable<HostsRoute> {
            var selection by rememberSaveable(stateSaver = SelectionSaver) { mutableStateOf<SpaceSelection?>(null) }
            BoxWithConstraints {
                // Side by side from about a small tablet or a phone in landscape.
                val wide = maxWidth >= 700.dp
                val sidebar = @Composable { modifier: Modifier ->
                    Sidebar(
                        app = app,
                        selected = selection.takeIf { wide },
                        openHost = { nav.navigate(HostRoute(it)) },
                        openSpace = {
                            if (wide) selection = it else nav.navigate(SpaceRoute(it.hostId, it.workspaceId, it.paneId))
                        },
                        addHost = { nav.navigate(EditHostRoute()) },
                        scan = { nav.navigate(ScanRoute) },
                        addLink = {
                            app.trustLink(it)
                            nav.navigate(AddLinkRoute(it))
                        },
                        askLocalNetwork = { askLocalNetwork.launch(AmiscaraApp.LOCAL_NETWORK) },
                        modifier = modifier,
                    )
                }
                if (wide) {
                    Row {
                        sidebar(Modifier.width(340.dp))
                        VerticalDivider()
                        val current = selection
                        if (current == null) {
                            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                                Text(stringResource(R.string.choose_space), Modifier.padding(24.dp))
                            }
                        } else {
                            // A new selection starts the space view over (tab, pane, search).
                            key(current) {
                                WorkspaceScreen(app, current.hostId, current.workspaceId, current.paneId, wide = true, back = null)
                            }
                        }
                    }
                } else {
                    sidebar(Modifier)
                }
            }
        }
        composable<SpaceRoute> { entry ->
            val route = entry.toRoute<SpaceRoute>()
            BoxWithConstraints {
                WorkspaceScreen(app, route.hostId, route.workspaceId, route.paneId, wide = maxWidth >= 700.dp, back = { nav.popBackStack() })
            }
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

/** Keeps the selected space over rotation and process death. */
private val SelectionSaver = listSaver<SpaceSelection?, String?>(
    save = { listOf(it?.hostId, it?.workspaceId, it?.paneId) },
    restore = { (host, workspace, pane) -> if (host != null && workspace != null) SpaceSelection(host, workspace, pane) else null },
)

/** The host's screen right above the list, after adding or editing it. */
private fun NavController.showHost(id: String) {
    navigate(HostRoute(id)) { popUpTo(HostsRoute) }
}
