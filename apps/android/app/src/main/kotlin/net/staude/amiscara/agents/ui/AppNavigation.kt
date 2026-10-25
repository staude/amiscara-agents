package net.staude.amiscara.agents.ui

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.view.KeyEvent
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
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
import androidx.compose.ui.text.font.FontFamily
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.toRoute
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import net.staude.amiscara.agents.AmiscaraApp
import net.staude.amiscara.agents.R
import net.staude.amiscara.agents.model.AppLink
import net.staude.amiscara.agents.model.Demo
import net.staude.amiscara.agents.model.SpaceSelection

@Serializable
object HostsRoute

/** A space as a screen of its own, on a narrow screen. */
@Serializable
data class SpaceRoute(val hostId: String, val workspaceId: String, val paneId: String? = null)

@Serializable
data class HostRoute(val id: String)

/** `sessionOf` with `socket`: a new host for another herdr session on that host's machine. */
@Serializable
data class EditHostRoute(val id: String? = null, val sessionOf: String? = null, val socket: String? = null)

@Serializable
data class AddLinkRoute(val text: String)

@Serializable
object ScanRoute

@Serializable
object SettingsRoute

@Serializable
data class ConversationRoute(val hostId: String, val paneId: String)

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

    val askFirstStart = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        app.refreshLocalNetwork()
    }

    // Asked once there is a host to reach, not on the empty first start:
    // the local network and, from Android 13, notifications.
    LaunchedEffect(hosts.isNotEmpty(), localNetwork) {
        if (hosts.isEmpty() || app.permissionsAsked) return@LaunchedEffect
        app.permissionsAsked = true
        val missing = buildList {
            if (!localNetwork) add(AmiscaraApp.LOCAL_NETWORK)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
            ) {
                add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
        if (missing.isNotEmpty()) askFirstStart.launch(missing.toTypedArray())
    }

    var switcher by remember { mutableStateOf(false) }

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
                is AppLink.Demo -> {
                    link.paneId?.let {
                        nav.navigate(SpaceRoute(Demo.HOST_ID, it.substringBefore(':'), it)) { popUpTo(HostsRoute) }
                    }
                    when (link.view) {
                        "settings" -> nav.navigate(SettingsRoute)
                        "conversation" -> link.paneId?.let { nav.navigate(ConversationRoute(Demo.HOST_ID, it)) }
                        "switcher" -> switcher = true
                        "addHost" -> nav.navigate(EditHostRoute())
                    }
                }
            }
            app.openedLink.value = null
        }
    }

    // The space beside the sidebar on a wide screen; a narrow one opens it
    // as a screen of its own.
    var selection by rememberSaveable(stateSaver = SelectionSaver) { mutableStateOf<SpaceSelection?>(null) }
    var dialog by remember { mutableStateOf<ManageDialog?>(null) }

    KeyShortcuts(app) { event ->
        if (event.keyCode == KeyEvent.KEYCODE_K && !event.isAltPressed && hosts.isNotEmpty()) {
            switcher = true
            true
        } else {
            false
        }
    }

    BoxWithConstraints {
        // Side by side from about a small tablet or a phone in landscape.
        val wide = maxWidth >= 700.dp
        val openSpace: (SpaceSelection) -> Unit = { target ->
            if (wide) {
                selection = target
                nav.popBackStack(HostsRoute, inclusive = false)
            } else {
                nav.navigate(SpaceRoute(target.hostId, target.workspaceId, target.paneId)) { popUpTo(HostsRoute) }
            }
        }
        val manage = { value: ManageDialog -> dialog = value }
        val openConversation = { hostId: String, paneId: String -> nav.navigate(ConversationRoute(hostId, paneId)) }

        NavHost(nav, startDestination = HostsRoute) {
            composable<HostsRoute> {
                val sidebar = @Composable { modifier: Modifier ->
                    Sidebar(
                        app = app,
                        selected = selection.takeIf { wide },
                        openHost = { nav.navigate(HostRoute(it)) },
                        addSession = { hostId, socket -> nav.navigate(EditHostRoute(sessionOf = hostId, socket = socket)) },
                        openSpace = openSpace,
                        addHost = { nav.navigate(EditHostRoute()) },
                        scan = { nav.navigate(ScanRoute) },
                        addLink = {
                            app.trustLink(it)
                            nav.navigate(AddLinkRoute(it))
                        },
                        askLocalNetwork = { askLocalNetwork.launch(AmiscaraApp.LOCAL_NETWORK) },
                        openSwitcher = { switcher = true },
                        openSettings = { nav.navigate(SettingsRoute) },
                        manage = manage,
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
                                WorkspaceScreen(
                                    app, current.hostId, current.workspaceId, current.paneId, wide = true, back = null,
                                    open = openSpace, manage = manage, openConversation = { openConversation(current.hostId, it) },
                                    gone = { selection = null },
                                )
                            }
                        }
                    }
                } else {
                    sidebar(Modifier)
                }
            }
            composable<SpaceRoute> { entry ->
                val route = entry.toRoute<SpaceRoute>()
                WorkspaceScreen(
                    app, route.hostId, route.workspaceId, route.paneId, wide = wide, back = { nav.popBackStack() },
                    open = openSpace, manage = manage, openConversation = { openConversation(route.hostId, it) },
                    gone = { nav.popBackStack() },
                )
            }
            composable<HostRoute> { entry ->
                val id = entry.toRoute<HostRoute>().id
                HostDetailScreen(app, id, back = { nav.popBackStack() }, edit = { nav.navigate(EditHostRoute(id)) })
            }
            composable<EditHostRoute> { entry ->
                val route = entry.toRoute<EditHostRoute>()
                HostEditorScreen(
                    app, route.id, back = { nav.popBackStack() }, saved = { nav.showHost(it) },
                    sessionOf = route.sessionOf, sessionSocket = route.socket,
                )
            }
            composable<AddLinkRoute> { entry ->
                val text = entry.toRoute<AddLinkRoute>().text
                // Decided once per screen, from memory only (see AmiscaraApp.trustLink).
                val trusted = rememberSaveable(text) { app.takeTrust(text) }
                AddLinkScreen(app, text, trusted, back = { nav.popBackStack() }, added = { nav.showHost(it) })
            }
            composable<SettingsRoute> {
                SettingsScreen(app, back = { nav.popBackStack() })
            }
            composable<ConversationRoute> { entry ->
                val route = entry.toRoute<ConversationRoute>()
                ConversationScreen(app, route.hostId, route.paneId, back = { nav.popBackStack() })
            }
            composable<ScanRoute> {
                ScannerScreen(back = { nav.popBackStack() }, scanned = {
                    app.trustLink(it)
                    nav.navigate(AddLinkRoute(it)) { popUpTo(HostsRoute) }
                })
            }
        }

        dialog?.let { ManageDialogView(app, it, dismiss = { dialog = null }, created = openSpace) }
        OpenRequestDialog(app)
        if (switcher) {
            QuickSwitcher(app, dismiss = { switcher = false }) {
                switcher = false
                openSpace(it)
            }
        }
    }
}

/**
 * Pages agents on the hosts want opened (#247), the first one at a time.
 * Opening forwards a page on the host's localhost, hands it to the browser
 * and takes the request back on the host, so other devices drop it too;
 * ignoring hides it on this device only.
 */
@Composable
private fun OpenRequestDialog(app: AmiscaraApp) {
    val requests by app.connections.openRequests.collectAsStateWithLifecycle()
    val pending = requests.firstOrNull() ?: return
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var error by remember(pending.key) { mutableStateOf<String?>(null) }
    var opening by remember(pending.key) { mutableStateOf(false) }
    val request = pending.request
    AlertDialog(
        onDismissRequest = { app.connections.ignore(pending) },
        title = { Text(stringResource(R.string.open_request_title, request.workspaceLabel.ifEmpty { pending.hostName })) },
        text = {
            Column {
                Text(request.url, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            TextButton(enabled = !opening, onClick = {
                opening = true
                scope.launch {
                    app.connections.openAddress(pending).fold(
                        onSuccess = { address ->
                            try {
                                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(address)))
                                app.connections.dismiss(pending)
                            } catch (e: ActivityNotFoundException) {
                                error = e.message
                            }
                        },
                        onFailure = { error = it.message },
                    )
                    opening = false
                }
            }) { Text(stringResource(R.string.open_request_open)) }
        },
        dismissButton = {
            TextButton(onClick = { app.connections.ignore(pending) }) { Text(stringResource(R.string.open_request_ignore)) }
        },
    )
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
