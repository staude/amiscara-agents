package net.staude.amiscara.agents.model

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.io.FileNotFoundException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The private SSH keys, one per host, sealed with an AES key that never
 * leaves the Android Keystore. They lie in `noBackupFilesDir`: a backup
 * could not be opened on another device anyway.
 */
class KeyVault(context: Context) {
    private val dir = File(context.noBackupFilesDir, "keys")

    fun store(hostId: String, privateOpenssh: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val sealed = cipher.doFinal(privateOpenssh.toByteArray())
        dir.mkdirs()
        val file = AtomicFile(file(hostId))
        val out = file.startWrite()
        try {
            out.write(cipher.iv.size)
            out.write(cipher.iv)
            out.write(sealed)
            file.finishWrite(out)
        } catch (e: Exception) {
            file.failWrite(out)
            throw e
        }
    }

    /** The key in OpenSSH text form, or `null` when the host has none. */
    fun load(hostId: String): String? {
        val data = try {
            AtomicFile(file(hostId)).readFully()
        } catch (_: FileNotFoundException) {
            return null
        }
        val ivSize = data[0].toInt()
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, data, 1, ivSize))
        return String(cipher.doFinal(data, 1 + ivSize, data.size - 1 - ivSize))
    }

    fun delete(hostId: String) {
        AtomicFile(file(hostId)).delete()
    }

    private fun file(hostId: String): File {
        require(hostId.matches(Regex("[A-Za-z0-9-]+"))) { "invalid host id" }
        return File(dir, "$hostId.key")
    }

    private fun secretKey(): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
            .apply { init(spec) }
            .generateKey()
    }

    private companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "net.staude.amiscara.agents.ssh-key"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}
