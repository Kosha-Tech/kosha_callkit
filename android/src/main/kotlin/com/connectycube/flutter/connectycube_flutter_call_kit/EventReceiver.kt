package com.connectycube.flutter.connectycube_flutter_call_kit

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.text.TextUtils
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import com.connectycube.flutter.connectycube_flutter_call_kit.background_isolates.ConnectycubeFlutterBgPerformingService
import com.connectycube.flutter.connectycube_flutter_call_kit.utils.isApplicationForeground
import org.json.JSONObject


// Returns true when the userInfo JSON carries a non-empty "action" field,
// meaning the click came from a custom action button (e.g. "mark_done"/"snooze")
// rather than the main Accept/Decline buttons.
private fun hasCustomAction(userInfo: String?): Boolean {
    if (userInfo.isNullOrBlank()) return false
    return try {
        JSONObject(userInfo).optString("action", "").isNotBlank()
    } catch (e: Exception) {
        false
    }
}

class EventReceiver : BroadcastReceiver() {
    private val TAG = "EventReceiver"

    override fun onReceive(context: Context, intent: Intent?) {

        if (intent == null || TextUtils.isEmpty(intent.action)) return

        Log.d(TAG, "NotificationReceiver onReceive action: ${intent.action}")

        when (intent.action) {
            ACTION_CALL_REJECT -> {
                val extras = intent.extras
                val callId = extras?.getString(EXTRA_CALL_ID)
                val callType = extras?.getInt(EXTRA_CALL_TYPE)
                val callInitiatorId = extras?.getInt(EXTRA_CALL_INITIATOR_ID)
                val callInitiatorName = extras?.getString(EXTRA_CALL_INITIATOR_NAME)
                val callOpponents = extras?.getIntegerArrayList(EXTRA_CALL_OPPONENTS)
                val callPhoto = extras?.getString(EXTRA_CALL_PHOTO)
                val userInfo = extras?.getString(EXTRA_CALL_USER_INFO)
                Log.i(TAG, "NotificationReceiver onReceive Call REJECT, callId: $callId")

                val broadcastIntent = Intent(ACTION_CALL_REJECT)
                val bundle = Bundle()
                bundle.putString(EXTRA_CALL_ID, callId)
                bundle.putInt(EXTRA_CALL_TYPE, callType!!)
                bundle.putInt(EXTRA_CALL_INITIATOR_ID, callInitiatorId!!)
                bundle.putString(EXTRA_CALL_INITIATOR_NAME, callInitiatorName)
                bundle.putIntegerArrayList(EXTRA_CALL_OPPONENTS, callOpponents)
                bundle.putString(EXTRA_CALL_PHOTO, callPhoto)
                bundle.putString(EXTRA_CALL_USER_INFO, userInfo)
                broadcastIntent.putExtras(bundle)

                LocalBroadcastManager.getInstance(context.applicationContext)
                    .sendBroadcast(broadcastIntent)

                NotificationManagerCompat.from(context).cancel(callId.hashCode())

                processCallEnded(context, callId!!)

                if (!isApplicationForeground(context)) {
                    broadcastIntent.putExtra("userCallbackHandleName", REJECTED_IN_BACKGROUND)
                    ConnectycubeFlutterBgPerformingService.enqueueMessageProcessing(
                        context,
                        broadcastIntent
                    )
                }
            }

            ACTION_CALL_ACCEPT -> {
                val extras = intent.extras
                val callId = extras?.getString(EXTRA_CALL_ID)
                val callType = extras?.getInt(EXTRA_CALL_TYPE)
                val callInitiatorId = extras?.getInt(EXTRA_CALL_INITIATOR_ID)
                val callInitiatorName = extras?.getString(EXTRA_CALL_INITIATOR_NAME)
                val callOpponents = extras?.getIntegerArrayList(EXTRA_CALL_OPPONENTS)
                val callPhoto = extras?.getString(EXTRA_CALL_PHOTO)
                val userInfo = extras?.getString(EXTRA_CALL_USER_INFO)
                Log.i(TAG, "NotificationReceiver onReceive Call ACCEPT, callId: $callId")

                val broadcastIntent = Intent(ACTION_CALL_ACCEPT)
                val bundle = Bundle()
                bundle.putString(EXTRA_CALL_ID, callId)
                bundle.putInt(EXTRA_CALL_TYPE, callType!!)
                bundle.putInt(EXTRA_CALL_INITIATOR_ID, callInitiatorId!!)
                bundle.putString(EXTRA_CALL_INITIATOR_NAME, callInitiatorName)
                bundle.putIntegerArrayList(EXTRA_CALL_OPPONENTS, callOpponents)
                bundle.putString(EXTRA_CALL_PHOTO, callPhoto)
                bundle.putString(EXTRA_CALL_USER_INFO, userInfo)
                broadcastIntent.putExtras(bundle)

                LocalBroadcastManager.getInstance(context.applicationContext)
                    .sendBroadcast(broadcastIntent)

                NotificationManagerCompat.from(context).cancel(callId.hashCode())

                saveCallState(context, callId!!, CALL_STATE_ACCEPTED)

                if (!isApplicationForeground(context)) {
                    broadcastIntent.putExtra("userCallbackHandleName", ACCEPTED_IN_BACKGROUND)
                    ConnectycubeFlutterBgPerformingService.enqueueMessageProcessing(
                        context,
                        broadcastIntent
                    )
                }

                // Skip auto-launching MainActivity if the accept came from a
                // custom action button (e.g. "mark_done") — Dart will decide
                // what to do without bringing the app to the foreground.
                // A normal Accept (no userInfo["action"] set) still launches
                // the app, which is the expected phone-call behaviour.
                if (!hasCustomAction(userInfo)) {
                    val launchIntent = getLaunchIntent(context)
                    launchIntent?.action = ACTION_CALL_ACCEPT
                    context.startActivity(launchIntent)
                }
            }

            ACTION_CALL_NOTIFICATION_CANCELED -> {
                val extras = intent.extras
                val callId = extras?.getString(EXTRA_CALL_ID)
                val callType = extras?.getInt(EXTRA_CALL_TYPE)
                val callInitiatorId = extras?.getInt(EXTRA_CALL_INITIATOR_ID)
                val callInitiatorName = extras?.getString(EXTRA_CALL_INITIATOR_NAME)
                val callPhoto = extras?.getString(EXTRA_CALL_PHOTO)
                val userInfo = extras?.getString(EXTRA_CALL_USER_INFO)
                Log.i(
                    TAG,
                    "NotificationReceiver onReceive Delete Call Notification, callId: $callId"
                )
                LocalBroadcastManager.getInstance(context.applicationContext)
                    .sendBroadcast(
                        Intent(ACTION_CALL_NOTIFICATION_CANCELED).putExtra(
                            EXTRA_CALL_ID,
                            callId
                        )
                    )
            }
        }
    }
}