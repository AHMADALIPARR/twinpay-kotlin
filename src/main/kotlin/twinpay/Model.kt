// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Ahmad Parr

package twinpay

/** Core domain model. Amounts are integer minor units of TWIN — never floats. */

enum class Kind { TRANSFER, GIFT, BURN, REVERSAL }
enum class PayStatus { PROCESSING, SETTLED, FAILED, REVERSED }
enum class LegKind { TRANSFER, ISSUE, BURN, REVERSAL }

data class Posting(
    val seq: Long,
    val paymentId: String,
    val account: String,
    /** Signed minor units. Debits negative, credits positive. */
    val amount: Long,
    val kind: LegKind,
    val memo: String
)

data class Payment(
    val id: String,
    val kind: Kind,
    val from: String,
    val to: String,
    val amount: Long,
    val memo: String,
    val rail: String = "internal",
    var status: PayStatus = PayStatus.PROCESSING,
    var wormIndex: Long? = null,
    var wormHash: String? = null,
    val createdAt: Long = System.currentTimeMillis(),
    var reversalOf: String? = null,
    var reversedBy: String? = null,
    var reason: String? = null,
    var actor: String? = null
)

data class Agent(val id: String, val handle: String, val createdAt: Long)

data class Claim(val paymentId: String?, val status: String) // status: claimed|settled|failed
