package com.example.tgwsproxy.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Stores the 16-byte MTProto proxy secret.
 *
 * The secret is encrypted with an AES-GCM key that never leaves Android
 * Keystore. Only the IV+ciphertext blob is written to SharedPreferences, so a
 * backup of app data cannot reveal the proxy link.
 */
class SecretStore(context: Context) {
    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    fun getOrCreate(): String = readStoredSecret() ?: regenerate()

    fun regenerate(): String {
        val bytes = ByteArray(SECRET_BYTES)
        SecureRandom().nextBytes(bytes)
        val secret = bytes.joinToString("") { "%02x".format(it) }
        writeSecret(secret)
        return secret
    }

    private fun readStoredSecret(): String? {
        val blob = prefs.getString(KEY_SECRET, null) ?: return null
        return runCatching {
            val decoded = Base64.decode(blob, Base64.NO_WRAP)
            // Layout: 12-byte GCM IV followed by ciphertext+tag.
            val iv = decoded.copyOfRange(0, GCM_IV_BYTES)
            val ciphertext = decoded.copyOfRange(GCM_IV_BYTES, decoded.size)
            val cipher = Cipher.getInstance(TRANSFORMATION).apply {
                init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(GCM_TAG_BITS, iv))
            }
            cipher.doFinal(ciphertext).decodeToString()
        }.getOrNull()
    }

    private fun writeSecret(secret: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION).apply {
            init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        }
        val encrypted = cipher.doFinal(secret.encodeToByteArray())
        val blob = cipher.iv + encrypted
        prefs.edit().putString(KEY_SECRET, Base64.encodeToString(blob, Base64.NO_WRAP)).apply()
    }

    private fun getOrCreateKey(): SecretKey {
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "tgwsproxy_secret"
        const val PREFS_NAME = "secret_store"
        const val KEY_SECRET = "secret_blob"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val SECRET_BYTES = 16
        const val GCM_IV_BYTES = 12
        const val GCM_TAG_BITS = 128
    }
}
