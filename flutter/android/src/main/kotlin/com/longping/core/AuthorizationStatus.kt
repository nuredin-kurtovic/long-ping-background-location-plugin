package com.longping.core

/** AuthorizationStatus values shared with JS (DESIGN.md, "Types"). */
object AuthorizationStatus {
    const val NOT_DETERMINED = 0
    const val RESTRICTED = 1
    const val DENIED = 2
    const val ALWAYS = 3
    const val WHEN_IN_USE = 4

    /**
     * Android mapping. [background] must already be true below API 29, where foreground access
     * includes background. DENIED needs both "we asked before" and no rationale: Android returns
     * false from shouldShowRequestPermissionRationale both before the first request and after
     * "don't ask again", and only the stored flag tells those apart.
     */
    fun android(foreground: Boolean, background: Boolean, askedBefore: Boolean, shouldShowRationale: Boolean): Int = when {
        foreground && background -> ALWAYS
        foreground -> WHEN_IN_USE
        askedBefore && !shouldShowRationale -> DENIED
        else -> NOT_DETERMINED
    }
}
