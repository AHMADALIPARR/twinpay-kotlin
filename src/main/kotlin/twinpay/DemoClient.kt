// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Ahmad Parr

package twinpay

import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse

/**
 * Kotlin demo client: drives the twinpay-kotlin HTTP API through the
 * full agent commerce flow and prints each step. Needs a running server:
 *
 *   ./demo/demo-server.sh &   (or: java -jar out/twinpay.jar)
 *   java -cp out/twinpay.jar twinpay.DemoClient
 */
object DemoClient {
    private val http = HttpClient.newHttpClient()
    private var base = "http://127.0.0.1:8080"

    private fun post(path: String, body: String): String {
        val req = HttpRequest.newBuilder(URI("$base$path"))
            .header("Content-Type", "application/json")
            .POST(HttpRequest.BodyPublishers.ofString(body))
            .build()
        return http.send(req, HttpResponse.BodyHandlers.ofString()).body()
    }

    private fun get(path: String): String {
        val req = HttpRequest.newBuilder(URI("$base$path")).GET().build()
        return http.send(req, HttpResponse.BodyHandlers.ofString()).body()
    }

    private fun step(name: String, body: () -> String) {
        println("\n== $name")
        println(body())
    }

    private fun idOf(json: String): String =
        Regex(""""id":"([^"]+)"""").find(json)?.groupValues?.get(1) ?: "?"

    @JvmStatic
    fun main(args: Array<String>) {
        if (args.isNotEmpty()) base = args[0]
        println("twinpay-kotlin demo client -> $base")

        step("register @alice and @bob") {
            post("/v1/agents", """{"handle":"@alice"}""") + "\n" +
                post("/v1/agents", """{"handle":"@bob"}""")
        }
        step("treasury gifts @alice 10000 minor units") {
            post("/v1/gifts",
                """{"issuer":"treasury","key":"change-me","to":"@alice","amount":10000,"reason":"demo seed"}""")
        }
        step("@alice sends @bob 2500 (key kpay-1)") {
            post("/v1/transfers",
                """{"from":"@alice","to":"@bob","amount":2500,"memo":"demo coffee","key":"kpay-1"}""")
        }
        step("resend same key -> already_processed") {
            post("/v1/transfers",
                """{"from":"@alice","to":"@bob","amount":2500,"memo":"demo coffee","key":"kpay-1"}""")
        }
        step("balances") {
            get("/v1/agents/@alice/balance") + "\n" + get("/v1/agents/@bob/balance")
        }
        val probe = post("/v1/transfers",
            """{"from":"@alice","to":"@bob","amount":100,"memo":"probe","key":"kpay-2"}""")
        val pid = idOf(probe)
        step("reverse $pid") {
            post("/v1/transfers/$pid/reversal", """{"reason":"demo reversal","actor":"@alice"}""")
        }
        step("reverse again -> already_reversed") {
            post("/v1/transfers/$pid/reversal", """{"reason":"demo reversal","actor":"@alice"}""")
        }
        step("conservation + health") {
            get("/v1/conservation") + "\n" + get("/v1/health")
        }
        println("\ndemo complete")
    }
}
