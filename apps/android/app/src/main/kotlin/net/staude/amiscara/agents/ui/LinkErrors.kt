package net.staude.amiscara.agents.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import net.staude.amiscara.agents.R
import net.staude.amiscara.agents.core.AddHostLinkException

/** Why a scanned or opened "add host" link was refused, in the user's language. */
@Composable
fun linkErrorMessage(error: Throwable): String = when (error) {
    is AddHostLinkException.TooLong -> stringResource(R.string.link_error_too_long)
    is AddHostLinkException.NotALink -> stringResource(R.string.link_error_not_a_link)
    is AddHostLinkException.Damaged -> stringResource(R.string.link_error_damaged)
    is AddHostLinkException.UnknownField -> stringResource(R.string.link_error_unknown_field, error.field)
    is AddHostLinkException.DuplicateField -> stringResource(R.string.link_error_duplicate_field, error.field)
    is AddHostLinkException.MissingVersion -> stringResource(R.string.link_error_missing_version)
    is AddHostLinkException.BadVersion -> stringResource(R.string.link_error_bad_version)
    is AddHostLinkException.NewerVersion -> stringResource(R.string.link_error_newer_version)
    is AddHostLinkException.MissingHost -> stringResource(R.string.link_error_missing_host)
    is AddHostLinkException.BadHost -> stringResource(R.string.link_error_bad_host, error.host)
    is AddHostLinkException.BadPort -> stringResource(R.string.link_error_bad_port)
    is AddHostLinkException.MissingUser -> stringResource(R.string.link_error_missing_user)
    is AddHostLinkException.BadUser -> stringResource(R.string.link_error_bad_user, error.user)
    is AddHostLinkException.BadSocket -> stringResource(R.string.link_error_bad_socket)
    is AddHostLinkException.MissingKey -> stringResource(R.string.link_error_missing_key)
    is AddHostLinkException.KeyNotOneLine -> stringResource(R.string.link_error_key_not_one_line)
    is AddHostLinkException.KeyTooLong -> stringResource(R.string.link_error_key_too_long)
    is AddHostLinkException.BadKey -> stringResource(R.string.link_error_bad_key)
    is AddHostLinkException.BadName -> stringResource(R.string.link_error_bad_name)
    else -> error.message ?: error.toString()
}
