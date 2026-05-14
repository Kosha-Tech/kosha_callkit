package com.connectycube.flutter.connectycube_flutter_call_kit

import android.app.Activity
import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.TextUtils
import android.util.Log
import android.view.View
import android.view.WindowManager
import android.widget.ImageView
import android.widget.TextView
import androidx.annotation.Nullable
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import com.bumptech.glide.Glide
import com.connectycube.flutter.connectycube_flutter_call_kit.utils.getPhotoPlaceholderResId
import com.google.android.material.imageview.ShapeableImageView
import com.skyfishjy.library.RippleBackground
import org.json.JSONObject


fun createStartIncomingScreenIntent(
    context: Context, callId: String, callType: Int, callInitiatorId: Int,
    callInitiatorName: String, opponents: ArrayList<Int>, callPhoto: String?, userInfo: String
): Intent {
    val intent = Intent(context, IncomingCallActivity::class.java)
    intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
    intent.putExtra(EXTRA_CALL_ID, callId)
    intent.putExtra(EXTRA_CALL_TYPE, callType)
    intent.putExtra(EXTRA_CALL_INITIATOR_ID, callInitiatorId)
    intent.putExtra(EXTRA_CALL_INITIATOR_NAME, callInitiatorName)
    intent.putIntegerArrayListExtra(EXTRA_CALL_OPPONENTS, opponents)
    intent.putExtra(EXTRA_CALL_PHOTO, callPhoto)
    intent.putExtra(EXTRA_CALL_USER_INFO, userInfo)
    return intent
}

class IncomingCallActivity : Activity() {
    private lateinit var callStateReceiver: BroadcastReceiver
    private lateinit var localBroadcastManager: LocalBroadcastManager

    private var callId: String? = null
    private var callType = -1
    private var callInitiatorId = -1
    private var callInitiatorName: String? = null
    private var callOpponents: ArrayList<Int>? = ArrayList()
    private var callPhoto: String? = null
    private var callUserInfo: String? = null


    override fun onCreate(@Nullable savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(resources.getIdentifier("activity_incoming_call", "layout", packageName))

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            setInheritShowWhenLocked(true)
        }

        with(getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                requestDismissKeyguard(this@IncomingCallActivity, object :
                    KeyguardManager.KeyguardDismissCallback() {
                    override fun onDismissError() {
                        Log.d("IncomingCallActivity", "[KeyguardDismissCallback.onDismissError]")
                    }

                    override fun onDismissSucceeded() {
                        Log.d(
                            "IncomingCallActivity",
                            "[KeyguardDismissCallback.onDismissSucceeded]"
                        )
                    }

                    override fun onDismissCancelled() {
                        Log.d(
                            "IncomingCallActivity",
                            "[KeyguardDismissCallback.onDismissCancelled]"
                        )
                    }
                })
            }
        }

        processIncomingData(intent)
        initUi()
        initCallStateReceiver()
        registerCallStateReceiver()
    }

    private fun initCallStateReceiver() {
        localBroadcastManager = LocalBroadcastManager.getInstance(this)
        callStateReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent == null || TextUtils.isEmpty(intent.action)) return
                val action: String? = intent.action

                val callIdToProcess: String? = intent.getStringExtra(EXTRA_CALL_ID)
                if (TextUtils.isEmpty(callIdToProcess) || callIdToProcess != callId) {
                    return
                }
                when (action) {
                    ACTION_CALL_NOTIFICATION_CANCELED, ACTION_CALL_REJECT, ACTION_CALL_ENDED -> {
                        finishAndRemoveTask()
                    }

                    ACTION_CALL_ACCEPT -> finishDelayed()
                }
            }
        }
    }

    private fun finishDelayed() {
        Handler(Looper.getMainLooper()).postDelayed({
            finishAndRemoveTask()
        }, 1000)
    }

    private fun registerCallStateReceiver() {
        val intentFilter = IntentFilter()
        intentFilter.addAction(ACTION_CALL_NOTIFICATION_CANCELED)
        intentFilter.addAction(ACTION_CALL_REJECT)
        intentFilter.addAction(ACTION_CALL_ACCEPT)
        intentFilter.addAction(ACTION_CALL_ENDED)
        localBroadcastManager.registerReceiver(callStateReceiver, intentFilter)
    }

    private fun unRegisterCallStateReceiver() {
        localBroadcastManager.unregisterReceiver(callStateReceiver)
    }

    override fun onDestroy() {
        super.onDestroy()
        unRegisterCallStateReceiver()
    }

    private fun processIncomingData(intent: Intent) {
        callId = intent.getStringExtra(EXTRA_CALL_ID)
        callType = intent.getIntExtra(EXTRA_CALL_TYPE, -1)
        callInitiatorId = intent.getIntExtra(EXTRA_CALL_INITIATOR_ID, -1)
        callInitiatorName = intent.getStringExtra(EXTRA_CALL_INITIATOR_NAME)
        callOpponents = intent.getIntegerArrayListExtra(EXTRA_CALL_OPPONENTS)
        callPhoto = intent.getStringExtra(EXTRA_CALL_PHOTO)
        callUserInfo = intent.getStringExtra(EXTRA_CALL_USER_INFO)
    }

    private fun initUi() {
        // Optional user-supplied UI overrides — apps can pass these as fields
        // inside the call's userInfo JSON to customise the screen without
        // modifying the plugin.
        //
        //   userInfo["headerText"]    -> overrides the "Incoming Call" header
        //   userInfo["subtitleText"]  -> overrides the "Incoming Audio call" subtitle
        //   userInfo["hiddenViews"]   -> comma-separated view IDs to hide
        //                                (e.g. "quick_actions_row,location_pill")
        //   userInfo["viewTexts"]     -> JSON map { "<view_id>": "<text>" } that
        //                                lets the caller set the text of any
        //                                TextView in the layout by its ID.
        //                                Empty/missing values are ignored.
        val customHeader = readUserInfoField(callUserInfo, "headerText")
        val customSubtitle = readUserInfoField(callUserInfo, "subtitleText")
        val hiddenViews = readUserInfoField(callUserInfo, "hiddenViews")
        val viewTexts = readUserInfoField(callUserInfo, "viewTexts")

        // Header title — only present on app-overridden layouts.
        val headerTitleId = resources.getIdentifier("header_title_txt", "id", packageName)
        if (headerTitleId != 0 && !customHeader.isNullOrBlank()) {
            findViewById<TextView>(headerTitleId)?.text = customHeader
        }

        val callTitleTxt: TextView =
            findViewById(resources.getIdentifier("user_name_txt", "id", packageName))
        callTitleTxt.text = callInitiatorName

        val callSubTitleTxt: TextView =
            findViewById(resources.getIdentifier("call_type_txt", "id", packageName))
        callSubTitleTxt.text = if (!customSubtitle.isNullOrBlank()) {
            customSubtitle
        } else {
            String.format(CALL_TYPE_PLACEHOLDER, if (callType == 1) "Video" else "Audio")
        }

        // Hide any views the caller asked us to hide.
        if (!hiddenViews.isNullOrBlank()) {
            hiddenViews.split(",").forEach { rawName ->
                val name = rawName.trim()
                if (name.isEmpty()) return@forEach
                val viewId = resources.getIdentifier(name, "id", packageName)
                if (viewId != 0) findViewById<View>(viewId)?.visibility = View.GONE
            }
        }

        // Apply arbitrary TextView overrides — { "<view_id>": "<text>" }.
        // Lets the caller drive every label on the screen (pill captions,
        // location text, description, etc.) from the FCM payload.
        if (!viewTexts.isNullOrBlank()) {
            try {
                val map = JSONObject(viewTexts)
                val keys = map.keys()
                while (keys.hasNext()) {
                    val viewName = keys.next()
                    val text = map.optString(viewName, "")
                    if (text.isBlank()) continue
                    val viewId = resources.getIdentifier(viewName, "id", packageName)
                    if (viewId == 0) continue
                    val view = findViewById<View>(viewId) ?: continue
                    when (view) {
                        is TextView -> view.text = text
                        // Quietly ignore non-text views — caller misconfigured.
                    }
                }
            } catch (e: Exception) {
                Log.w("IncomingCallActivity", "viewTexts is not valid JSON: ${e.message}")
            }
        }

        val callAcceptButton: ImageView =
            findViewById(resources.getIdentifier("start_call_btn", "id", packageName))
        // If the host layout supplied its own static src (e.g. for a reminder UI), don't
        // overwrite it. Only swap to the call-type icon when the layout still expects it
        // (the bundled drawable resources exist in the host).
        val acceptButtonIconName = if (callType == 1) "ic_video_call_start" else "ic_call_start"
        val iconResId = resources.getIdentifier(acceptButtonIconName, "drawable", packageName)
        if (iconResId != 0 && customSubtitle.isNullOrBlank() && customHeader.isNullOrBlank()) {
            callAcceptButton.setImageResource(iconResId)
        }

        val avatarImg: ShapeableImageView =
            findViewById(resources.getIdentifier("avatar_img", "id", packageName))

        val defaultPhotoResId = getPhotoPlaceholderResId(applicationContext)

        if (!TextUtils.isEmpty(callPhoto)) {
            Glide.with(applicationContext)
                .load(callPhoto)
                .error(defaultPhotoResId)
                .placeholder(defaultPhotoResId)
                .into(avatarImg)
        } else {
            avatarImg.setImageResource(defaultPhotoResId)
        }

        val acceptButtonAnimation: RippleBackground =
            findViewById(resources.getIdentifier("accept_button_animation", "id", packageName))
        acceptButtonAnimation.startRippleAnimation()

        val rejectButtonAnimation: RippleBackground =
            findViewById(resources.getIdentifier("reject_button_animation", "id", packageName))
        rejectButtonAnimation.startRippleAnimation()
    }

    // Main reject button — referenced from layout as android:onClick="onEndCall".
    fun onEndCall(view: View?) {
        dispatchEvent(ACTION_CALL_REJECT, null)
    }

    // Main accept button — referenced from layout as android:onClick="onStartCall".
    fun onStartCall(view: View?) {
        dispatchEvent(ACTION_CALL_ACCEPT, null)
    }

    // Generic handler for ANY extra/custom action button (snooze, mark_done, etc.).
    // The view's android:tag controls the dispatch:
    //
    //   tag="accept:<action>"  → broadcast ACCEPT, userInfo["action"] = <action>
    //   tag="reject:<action>"  → broadcast REJECT, userInfo["action"] = <action>
    //
    // Dart receives the regular onCallAccepted / onCallRejected callback and reads
    // event.userInfo["action"] to dispatch to the right handler.
    //
    // Example (host layout):
    //   <View android:onClick="onClick" android:tag="reject:snooze" />
    //   <View android:onClick="onClick" android:tag="accept:mark_done" />
    fun onClick(view: View?) {
        val tag = view?.tag as? String
        if (tag.isNullOrBlank()) {
            Log.w("IncomingCallActivity", "onClick fired but view has no tag — ignoring")
            return
        }

        val parts = tag.split(":", limit = 2)
        if (parts.size != 2 || parts[1].isBlank()) {
            Log.w(
                "IncomingCallActivity",
                "onClick tag '$tag' must be 'accept:<action>' or 'reject:<action>'"
            )
            return
        }

        val kind = parts[0].lowercase()
        val action = parts[1].trim()

        val broadcastAction = when (kind) {
            "accept" -> ACTION_CALL_ACCEPT
            "reject" -> ACTION_CALL_REJECT
            else -> {
                Log.w("IncomingCallActivity", "onClick tag '$tag' kind must be 'accept' or 'reject'")
                return
            }
        }

        dispatchEvent(broadcastAction, action)
    }

    private fun dispatchEvent(broadcastAction: String, action: String?) {
        val outboundUserInfo =
            if (action.isNullOrBlank()) callUserInfo
            else injectActionField(callUserInfo, action)

        val bundle = Bundle()
        bundle.putString(EXTRA_CALL_ID, callId)
        bundle.putInt(EXTRA_CALL_TYPE, callType)
        bundle.putInt(EXTRA_CALL_INITIATOR_ID, callInitiatorId)
        bundle.putString(EXTRA_CALL_INITIATOR_NAME, callInitiatorName)
        bundle.putIntegerArrayList(EXTRA_CALL_OPPONENTS, callOpponents)
        bundle.putString(EXTRA_CALL_PHOTO, callPhoto)
        bundle.putString(EXTRA_CALL_USER_INFO, outboundUserInfo)

        val intent = Intent(this, EventReceiver::class.java)
        intent.action = broadcastAction
        intent.putExtras(bundle)
        applicationContext.sendBroadcast(intent)
    }

    private fun readUserInfoField(userInfo: String?, key: String): String? {
        if (userInfo.isNullOrBlank()) return null
        return try {
            JSONObject(userInfo).optString(key, "").ifBlank { null }
        } catch (e: Exception) {
            Log.w("IncomingCallActivity", "userInfo is not JSON, can't read $key: ${e.message}")
            null
        }
    }

    private fun injectActionField(userInfo: String?, action: String): String {
        return try {
            val json = if (userInfo.isNullOrBlank()) JSONObject() else JSONObject(userInfo)
            json.put("action", action)
            json.toString()
        } catch (e: Exception) {
            "{\"action\":\"$action\"}"
        }
    }
}
