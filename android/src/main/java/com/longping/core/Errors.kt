package com.longping.core

/** Promise rejection codes (DESIGN.md, "Error codes"). The enum name is the wire value. */
enum class ErrorCode {
    INVALID_CONFIG,
    LICENSE_INVALID,
    PERMISSION_DENIED,
    LOCATION_SERVICES_OFF,
    NOT_ENABLED,
    TIMEOUT,
    NO_ACTIVITY,
    INTERNAL,
}

open class LongPingException(
    val code: ErrorCode,
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)

/** A config (or option) value that failed validation. The message always starts with the key path. */
class ConfigException(val key: String, detail: String) :
    LongPingException(ErrorCode.INVALID_CONFIG, "$key: $detail")
