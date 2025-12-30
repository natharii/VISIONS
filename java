package com.visions.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.telephony.SmsMessage
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject

class SmsReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "SmsReceiver"
        private val JSON = "application/json; charset=utf-8".toMediaType()
        private val client = OkHttpClient()
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "android.provider.Telephony.SMS_RECEIVED") return

        val pendingResult = goAsync()
        val bundle: Bundle? = intent.extras
        if (bundle == null) {
            pendingResult.finish()
            return
        }

        CoroutineScope(Dispatchers.IO).launch {
            try {
                val pdus = bundle["pdus"] as? Array<*>
                if (pdus == null) {
                    Log.w(TAG, "No PDUs in bundle")
                    return@launch
                }
                val format = bundle.getString("format")
                for (pdu in pdus) {
                    val bytes = pdu as ByteArray
                    val msg = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                        SmsMessage.createFromPdu(bytes, format)
                    } else {
                        SmsMessage.createFromPdu(bytes)
                    }
                    val from = msg.originatingAddress ?: "unknown"
                    val body = msg.messageBody ?: ""
                    Log.i(TAG, "SMS from $from : $body")

                    // Read preferences to decide whether to forward
                    val prefs = context.getSharedPreferences("visions_prefs", Context.MODE_PRIVATE)
                    val enabled = prefs.getBoolean("forward_enabled", true)
                    val piUrl = prefs.getString("pi_url", null)
                    val token = prefs.getString("auth_token", null)

                    if (enabled && !piUrl.isNullOrEmpty() && !token.isNullOrEmpty()) {
                        // POST to Pi /incoming_sms
                        val json = JSONObject()
                        json.put("from", from)
                        json.put("body", body)
                        val bodyReq = json.toString().toRequestBody(JSON)
                        val req = Request.Builder()
                            .url(piUrl.trimEnd('/') + "/incoming_sms")
                            .addHeader("Content-Type", "application/json")
                            .addHeader("X-VISIONS-AUTH", token)
                            .post(bodyReq)
                            .build()
                        try {
                            client.newCall(req).execute().use { resp ->
                                Log.i(TAG, "Posted to Pi - code: ${resp.code}; body: ${resp.body?.string()}")
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to POST to Pi", e)
                        }
                    } else {
                        Log.i(TAG, "Forwarding disabled or config missing (piUrl/token)")
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error handling SMS", e)
            } finally {
                pendingResult.finish()
            }
        }
    }
}
