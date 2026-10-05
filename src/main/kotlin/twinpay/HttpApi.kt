// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Ahmad Parr

package twinpay

import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.util.concurrent.Executors

/**
 * HTTP/JSON API for agents. JDK built-in HttpServer, zero dependencies.
 * Routes mirror the Erlang twinpay so agents can switch implementations.
 */
class HttpApi(
    private val registry: AgentRegistry,
    private val service: PaymentService,
    private val ledger: Ledger,
    private val treasury: Treasury,
    private val payments: Payments,
    private val worm: Worm,
    private val rtp: Rtp,
    private val bind: String = Config.httpBind,
    private val port: Int = Config.httpPort
) {
    private var server: HttpServer? = null

    fun start() {
        val s = HttpServer.create(InetSocketAddress(bind, port), 0)
        s.executor = Executors.newCachedThreadPool()
        s.createContext("/") { ex -> route(ex) }
        s.start()
        server = s
        println("twinpay-kotlin listening on $bind:$port")
    }

    fun stop() = server?.stop(0)

    private fun route(ex: HttpExchange) {
        try {
            val method = ex.requestMethod
            val path = ex.requestURI.path
            when {
                method == "POST" && path == "/v1/agents" -> registerAgent(ex)
                method == "POST" && path == "/v1/gifts" -> gift(ex)
                method == "POST" && path == "/v1/transfers" -> transfer(ex)
                method == "GET" && path.startsWith("/v1/transfers/") -> getTransfer(ex)
                method == "POST" && Regex("^/v1/transfers/[^/]+/reversal$").matches(path) -> reversal(ex)
                method == "POST" && path == "/v1/redemptions" -> redeem(ex)
                method == "GET" && Regex("^/v1/agents/[^/]+/balance$").matches(path) -> balance(ex)
                method == "GET" && Regex("^/v1/agents/[^/]+/feed$").matches(path) -> feed(ex)
                method == "GET" && path == "/v1/supply" -> supply(ex)
                method == "GET" && path == "/v1/conservation" -> conservation(ex)
                method == "GET" && path == "/v1/health" -> health(ex)
                else -> reply(ex, 404, jobj("error" to JVal.Str("not_found")))
            }
        } catch (e: Exception) {
            reply(ex, 500, jobj("error" to JVal.Str("internal"), "detail" to JVal.Str(e.message ?: "?")))
        }
    }

    private fun readBody(ex: HttpExchange): JVal {
        val bytes = ex.requestBody.readBytes()
        if (bytes.isEmpty()) return jobj()
        return Json.parse(String(bytes, Charsets.UTF_8))
    }

    private fun reply(ex: HttpExchange, code: Int, v: JVal) {
        val body = Json.stringify(v).toByteArray(Charsets.UTF_8)
        ex.responseHeaders.add("Content-Type", "application/json")
        ex.sendResponseHeaders(code, body.size.toLong())
        ex.responseBody.use { it.write(body) }
    }

    private fun bad(ex: HttpExchange, reason: String, code: Int = 400) =
        reply(ex, code, jobj("ok" to JVal.False, "error" to JVal.Str(reason)))

    private fun registerAgent(ex: HttpExchange) {
        val b = readBody(ex)
        val handle = b.str("handle") ?: return bad(ex, "missing_handle")
        val agent = registry.register(handle)
        reply(ex, 200, jobj(
            "ok" to JVal.True,
            "id" to JVal.Str(agent.id),
            "handle" to JVal.Str(agent.handle)
        ))
    }

    private fun gift(ex: HttpExchange) {
        val b = readBody(ex)
        val issuer = b.str("issuer") ?: return bad(ex, "missing_issuer")
        val key = b.str("key") ?: return bad(ex, "missing_treasury_key")
        if (key != Config.treasuryKey) return bad(ex, "unauthorized_issuer", 403)
        val to = b.str("to") ?: return bad(ex, "missing_to")
        val amount = b.long("amount") ?: return bad(ex, "missing_amount")
        val reason = b.str("reason") ?: "treasury gift"
        val agent = registry.lookup(to) ?: return bad(ex, "unknown_agent")
        when (val r = treasury.gift(agent.id, amount, reason, issuer, null)) {
            is Treasury.GiftResult.Ok -> reply(ex, 200, jobj(
                "ok" to JVal.True, "id" to JVal.Str(r.paymentId),
                "to" to JVal.Str(agent.handle), "amount" to JVal.Num(amount),
                "worm_index" to JVal.Num(r.wormIndex), "worm_hash" to JVal.Str(r.wormHash)
            ))
            is Treasury.GiftResult.Err -> bad(ex, r.reason, if (r.reason == "unauthorized_issuer") 403 else 400)
        }
    }

    private fun transfer(ex: HttpExchange) {
        val b = readBody(ex)
        val from = b.str("from") ?: return bad(ex, "missing_from")
        val to = b.str("to") ?: return bad(ex, "missing_to")
        val amount = b.long("amount") ?: return bad(ex, "missing_amount")
        val memo = b.str("memo") ?: ""
        val key = b.str("key") ?: return bad(ex, "missing_key")
        val rail = b.str("rail") ?: "internal"
        when (val r = service.send(from, to, amount, memo, key, rail)) {
            is PaymentService.SendResult.Ok -> reply(ex, 200, jobj(
                "ok" to JVal.True, "id" to JVal.Str(r.paymentId),
                "worm_index" to JVal.Num(r.wormIndex), "worm_hash" to JVal.Str(r.wormHash)
            ))
            is PaymentService.SendResult.Duplicate -> reply(ex, 200, jobj(
                "ok" to JVal.True, "id" to JVal.Str(r.paymentId),
                "status" to JVal.Str("already_processed")
            ))
            is PaymentService.SendResult.Err ->
                bad(ex, r.reason, if (r.reason == "insufficient_funds") 402 else 400)
        }
    }

    private fun getTransfer(ex: HttpExchange) {
        val id = ex.requestURI.path.removePrefix("/v1/transfers/")
        val p = payments.lookup(id) ?: return bad(ex, "unknown_payment", 404)
        reply(ex, 200, paymentJson(p))
    }

    private fun reversal(ex: HttpExchange) {
        val id = ex.requestURI.path.removePrefix("/v1/transfers/").removeSuffix("/reversal")
        val b = readBody(ex)
        val reason = b.str("reason") ?: return bad(ex, "missing_reason")
        val actor = b.str("actor") ?: return bad(ex, "missing_actor")
        when (val r = service.reverse(id, reason, actor)) {
            is PaymentService.ReverseResult.Ok -> reply(ex, 200, jobj(
                "ok" to JVal.True, "reversal_id" to JVal.Str(r.reversalId),
                "worm_index" to JVal.Num(r.wormIndex), "worm_hash" to JVal.Str(r.wormHash)
            ))
            is PaymentService.ReverseResult.Err ->
                bad(ex, r.reason, if (r.reason == "already_reversed") 409 else 400)
        }
    }

    private fun redeem(ex: HttpExchange) {
        val b = readBody(ex)
        val agent = b.str("agent") ?: return bad(ex, "missing_agent")
        val amount = b.long("amount") ?: return bad(ex, "missing_amount")
        val routing = b.str("routing") ?: return bad(ex, "missing_routing")
        val account = b.str("account") ?: return bad(ex, "missing_account")
        val key = b.str("key") ?: return bad(ex, "missing_key")
        when (val r = service.redeem(agent, amount, routing, account, key)) {
            is PaymentService.RedeemResult.Ok -> reply(ex, 200, jobj(
                "ok" to JVal.True, "id" to JVal.Str(r.paymentId),
                "worm_index" to JVal.Num(r.wormIndex), "worm_hash" to JVal.Str(r.wormHash),
                "nacha_lines" to JVal.Num(r.nachaLines),
                "ach_preview" to JVal.Str(r.achPreview)
            ))
            is PaymentService.RedeemResult.Err ->
                bad(ex, r.reason, if (r.reason == "plaid_not_connected") 424 else 400)
        }
    }

    private fun balance(ex: HttpExchange) {
        val handle = ex.requestURI.path.removePrefix("/v1/agents/").removeSuffix("/balance")
        val agent = registry.lookup(handle) ?: return bad(ex, "unknown_agent", 404)
        reply(ex, 200, jobj(
            "ok" to JVal.True, "handle" to JVal.Str(agent.handle),
            "balance" to JVal.Num(ledger.balance(agent.id)),
            "token" to JVal.Str(Config.tokenSymbol)
        ))
    }

    private fun feed(ex: HttpExchange) {
        val handle = ex.requestURI.path.removePrefix("/v1/agents/").removeSuffix("/feed")
        val agent = registry.lookup(handle) ?: return bad(ex, "unknown_agent", 404)
        val limit = ex.requestURI.query
            ?.split("&")?.firstOrNull { it.startsWith("limit=") }
            ?.removePrefix("limit=")?.toIntOrNull()?.coerceIn(1, 100) ?: 20
        val items = payments.forAccount(agent.id, limit).map { paymentJson(it) }
        reply(ex, 200, jobj("ok" to JVal.True, "feed" to JVal.Arr(items)))
    }

    private fun supply(ex: HttpExchange) {
        reply(ex, 200, jobj(
            "ok" to JVal.True, "supply" to JVal.Num(treasury.supply()),
            "token" to JVal.Str(Config.tokenSymbol)
        ))
    }

    private fun conservation(ex: HttpExchange) {
        reply(ex, 200, jobj("ok" to JVal.True, "conservation" to
            JVal.Str(if (ledger.conservationCheck()) "ok" else "broken")))
    }

    private fun health(ex: HttpExchange) {
        val wormCount = try { worm.verify() } catch (_: Exception) { -1L }
        reply(ex, 200, jobj(
            "ok" to JVal.True, "service" to JVal.Str("twinpay-kotlin"),
            "token" to JVal.Str(Config.tokenSymbol),
            "worm_blocks" to JVal.Num(wormCount),
            "rtp_outbox" to JVal.Num(rtp.outboxSize().toLong())
        ))
    }

    private fun paymentJson(p: Payment): JVal = jobj(
        "ok" to JVal.True,
        "id" to JVal.Str(p.id),
        "kind" to JVal.Str(p.kind.name.lowercase()),
        "from" to JVal.Str(p.from),
        "to" to JVal.Str(p.to),
        "amount" to JVal.Num(p.amount),
        "memo" to JVal.Str(p.memo),
        "rail" to JVal.Str(p.rail),
        "status" to JVal.Str(p.status.name.lowercase()),
        "worm_index" to (p.wormIndex?.let { JVal.Num(it) } ?: JVal.Null),
        "worm_hash" to (p.wormHash?.let { JVal.Str(it) } ?: JVal.Null)
    )
}
