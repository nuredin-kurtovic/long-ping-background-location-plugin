package com.longping.engine

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Base64
import com.longping.core.AuthCredentials
import java.security.KeyStore
import java.security.UnrecoverableKeyException
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Upload credentials, AES-GCM encrypted with a non-exportable AndroidKeyStore key (alias
 * `longping_auth`); only the ciphertext is stored in SharedPreferences `longping`.
 *
 * A blob that can never be decrypted (restored from a backup onto another device, key wiped by an
 * OEM keystore reset) is deleted and the app has to call setAuthorization() again. Other keystore
 * errors are treated as transient: the blob is kept and the next read tries again.
 */
internal class AuthStore(private val prefs: EnginePrefs, private val log: Logger) {
    private var loaded = false
    private var cached: AuthCredentials? = null

    private class Unrecoverable(message: String, cause: Throwable? = null) : Exception(message, cause)

    @Synchronized
    fun get(): AuthCredentials? {
        if (loaded) return cached
        val blob = prefs.authBlob
        if (blob == null) {
            loaded = true
            return null
        }
        try {
            cached = decrypt(blob)
            loaded = true
        } catch (e: Unrecoverable) {
            log.error(TAG, "stored credentials cannot be decrypted and were removed; call setAuthorization() again", e.cause ?: e)
            prefs.saveAuthBlob(null)
            cached = null
            loaded = true
        } catch (e: Exception) {
            log.warn(TAG, "keystore unavailable; credentials will be read again on the next upload", e)
            return null
        }
        return cached
    }

    @Synchronized
    fun set(credentials: AuthCredentials) {
        cached = credentials
        loaded = true
        try {
            prefs.saveAuthBlob(encrypt(credentials.toJson().toString()))
        } catch (e: Exception) {
            // Keep the credentials for this process so uploads work; they just won't survive a restart.
            log.error(TAG, "could not encrypt credentials; kept in memory only", e)
        }
    }

    /**
     * Stores [next] only if [expected] is still current. A token refresh that finishes after the
     * app called setAuthorization() / clearAuthorization() must not bring the old user back.
     */
    @Synchronized
    fun replaceIf(expected: AuthCredentials, next: AuthCredentials): Boolean {
        if (get() != expected) return false
        set(next)
        return true
    }

    @Synchronized
    fun clear() {
        cached = null
        loaded = true
        prefs.saveAuthBlob(null)
    }

    private fun decrypt(blob: String): AuthCredentials {
        val parts = blob.split(':')
        if (parts.size != 3 || parts[0] != FORMAT) throw Unrecoverable("unknown format")
        val key = existingKey() ?: throw Unrecoverable("encryption key is gone")
        val plain = try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, Base64.decode(parts[1], Base64.NO_WRAP)))
            String(cipher.doFinal(Base64.decode(parts[2], Base64.NO_WRAP)), Charsets.UTF_8)
        } catch (e: AEADBadTagException) {
            throw Unrecoverable("ciphertext does not match the key", e)
        } catch (e: KeyPermanentlyInvalidatedException) {
            throw Unrecoverable("key invalidated", e)
        } catch (e: IllegalArgumentException) {
            throw Unrecoverable("corrupt blob", e)
        }
        return AuthCredentials.restore(plain) ?: throw Unrecoverable("unreadable credentials")
    }

    private fun encrypt(plain: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        val key = try {
            existingKey()
        } catch (e: Unrecoverable) {
            KeyStore.getInstance(KEYSTORE).apply { load(null) }.deleteEntry(ALIAS)
            null
        }
        cipher.init(Cipher.ENCRYPT_MODE, key ?: newKey())
        val ct = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        return "$FORMAT:${Base64.encodeToString(cipher.iv, Base64.NO_WRAP)}:${Base64.encodeToString(ct, Base64.NO_WRAP)}"
    }

    private fun existingKey(): SecretKey? {
        val ks = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        return try {
            ks.getKey(ALIAS, null) as? SecretKey
        } catch (e: UnrecoverableKeyException) {
            throw Unrecoverable("key unrecoverable", e)
        }
    }

    private fun newKey(): SecretKey {
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val TAG = "auth"
        const val KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "longping_auth"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val FORMAT = "v1"
    }
}
