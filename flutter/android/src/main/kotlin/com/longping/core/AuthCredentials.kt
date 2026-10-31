package com.longping.core

import org.json.JSONObject

/**
 * Upload credentials from setAuthorization(). Stored encrypted, never part of config.
 * [refreshPayloadJson] / [refreshHeaders] are kept exactly as given.
 */
data class AuthCredentials(
    val accessToken: String,
    val refreshToken: String? = null,
    val refreshUrl: String? = null,
    val refreshPayloadJson: String? = null,
    val refreshHeaders: Map<String, String> = emptyMap(),
) {
    val canRefresh: Boolean get() = !refreshUrl.isNullOrEmpty()

    fun toJson(): JSONObject = JSONObject().apply {
        put("accessToken", accessToken)
        put("refreshToken", refreshToken ?: JSONObject.NULL)
        put("refreshUrl", refreshUrl ?: JSONObject.NULL)
        put("refreshPayload", refreshPayloadJson?.let { JSONObject(it) } ?: JSONObject.NULL)
        put("refreshHeaders", JSONObject().also { h -> refreshHeaders.forEach { (k, v) -> h.put(k, v) } })
    }

    /** Refresh body: refreshPayload (default `{"refresh_token":"{{refreshToken}}"}`) with the token filled in. */
    fun refreshBody(): String {
        val payload = refreshPayloadJson?.let { JSONObject(it) } ?: JSONObject().put("refresh_token", REFRESH_TOKEN_TOKEN)
        val out = JSONObject()
        for (key in Json.keys(payload)) {
            val v = payload.opt(key)
            out.put(key, if (v is String) v.replace(REFRESH_TOKEN_TOKEN, refreshToken ?: "") else v)
        }
        return out.toString()
    }

    fun withTokens(access: String, refresh: String?): AuthCredentials =
        copy(accessToken = access, refreshToken = refresh ?: refreshToken)

    companion object {
        const val REFRESH_TOKEN_TOKEN = "{{refreshToken}}"

        /** Validates setAuthorization() input. */
        fun fromJson(obj: JSONObject): AuthCredentials {
            val access = Json.value(obj, "accessToken") as? String
            if (access.isNullOrEmpty()) throw ConfigException("accessToken", "must be a non-empty string")
            val refreshUrl = optionalString(obj, "refreshUrl")?.takeIf { it.isNotEmpty() }
            if (refreshUrl != null && !refreshUrl.startsWith("http://") && !refreshUrl.startsWith("https://")) {
                throw ConfigException("refreshUrl", "must start with http:// or https://")
            }
            val payload = Json.value(obj, "refreshPayload")
            if (payload != null && payload !is JSONObject) throw ConfigException("refreshPayload", "must be an object")
            val headers = LinkedHashMap<String, String>()
            when (val h = Json.value(obj, "refreshHeaders")) {
                null -> Unit
                is JSONObject -> for (name in Json.keys(h)) {
                    headers[name] = Json.value(h, name) as? String
                        ?: throw ConfigException("refreshHeaders.$name", "must be a string")
                }
                else -> throw ConfigException("refreshHeaders", "must be an object")
            }
            return AuthCredentials(
                accessToken = access,
                refreshToken = optionalString(obj, "refreshToken")?.takeIf { it.isNotEmpty() },
                refreshUrl = refreshUrl,
                refreshPayloadJson = (payload as JSONObject?)?.toString(),
                refreshHeaders = headers,
            )
        }

        /** Restores the stored form; null if it is unreadable. */
        fun restore(text: String?): AuthCredentials? = try {
            text?.let { fromJson(JSONObject(it)) }
        } catch (e: Exception) {
            null
        }

        /** `access_token`|`accessToken` (required) and `refresh_token`|`refreshToken` from a refresh reply. */
        fun parseRefreshResponse(body: String?): Pair<String, String?>? {
            val obj = try {
                JSONObject(body?.trim() ?: return null)
            } catch (e: Exception) {
                return null
            }
            val access = (Json.value(obj, "access_token") ?: Json.value(obj, "accessToken")) as? String
            if (access.isNullOrEmpty()) return null
            val refresh = (Json.value(obj, "refresh_token") ?: Json.value(obj, "refreshToken")) as? String
            return access to refresh?.takeIf { it.isNotEmpty() }
        }

        private fun optionalString(obj: JSONObject, key: String): String? {
            val v = Json.value(obj, key) ?: return null
            return v as? String ?: throw ConfigException(key, "must be a string")
        }
    }
}
