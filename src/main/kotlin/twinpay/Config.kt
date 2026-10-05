// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Ahmad Parr

package twinpay

/** Runtime configuration. Environment overrides use TWINPAY_ prefix. */
object Config {
    val tokenSymbol: String = "TWIN"
    val tokenScale: Int = 100 // minor units per whole TWIN

    val plaidMode: String = System.getenv("TWINPAY_PLAID_MODE") ?: "enforce" // enforce|permissive|mock
    val plaidCmd: String = System.getenv("TWINPAY_PLAID_CMD") ?: "plaid"
    val plaidTimeoutMs: Long = System.getenv("TWINPAY_PLAID_TIMEOUT_MS")?.toLongOrNull() ?: 10_000L

    val treasuryIssuers: List<String> =
        (System.getenv("TWINPAY_TREASURY_ISSUERS") ?: "treasury").split(",")
    val treasuryKey: String = System.getenv("TWINPAY_TREASURY_KEY") ?: "change-me"

    val httpPort: Int = System.getenv("TWINPAY_HTTP_PORT")?.toIntOrNull() ?: 8080
    val httpBind: String = System.getenv("TWINPAY_HTTP_BIND") ?: "127.0.0.1"

    /** Business policy: fiat cents per whole TWIN on redemption. */
    val redemptionCentsPerToken: Int =
        System.getenv("TWINPAY_REDEMPTION_CENTS")?.toIntOrNull() ?: 100

    val wormFile: String = System.getenv("TWINPAY_WORM_FILE") ?: "priv/worm-kotlin.dat"
    val companyName: String = "TWINPAY"
    val companyId: String = "TWINPAY01"
}
