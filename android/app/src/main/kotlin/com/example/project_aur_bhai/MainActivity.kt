package com.example.project_aur_bhai

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.view.KeyEvent
import androidx.media.session.MediaButtonReceiver
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// FlutterFragmentActivity is required by local_auth for biometric / screen-lock prompts.
class MainActivity : FlutterFragmentActivity() {
    private var mediaSession: MediaSessionCompat? = null
    private var headsetChannel: MethodChannel? = null
    private var captureEnabled = false
    private var downAtMs = 0L
    private var longFired = false
    private var lastEmitAtMs = 0L
    private var audioFocusRequest: AudioFocusRequest? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val longPressRunnable =
        Runnable {
            if (!longFired && downAtMs != 0L) {
                longFired = true
                emit("longStart", "timer")
            }
        }
    private val longPressMs = 400L
    private val focusChangeListener =
        AudioManager.OnAudioFocusChangeListener { /* claim focus only */ }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "aur_bhai/call_state",
        ).setMethodCallHandler { call, result ->
            if (call.method == "getCallBusy") {
                val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                val busy =
                    am.mode == AudioManager.MODE_IN_CALL ||
                        am.mode == AudioManager.MODE_IN_COMMUNICATION ||
                        am.mode == AudioManager.MODE_RINGTONE
                result.success(if (busy) "busy" else "idle")
            } else {
                result.notImplemented()
            }
        }

        headsetChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                "aur_bhai/headset",
            )
        headsetChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "setCaptureEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") == true
                    setHeadsetCaptureEnabled(enabled)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        ensureMediaSession()
    }

    private fun ensureMediaSession() {
        if (mediaSession != null) return
        val session = MediaSessionCompat(this, "aur_bhai_headset")
        session.setFlags(
            MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or
                MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS,
        )
        val mbrIntent = Intent(Intent.ACTION_MEDIA_BUTTON)
        mbrIntent.setClass(this, MediaButtonReceiver::class.java)
        val mbrPending =
            PendingIntent.getBroadcast(
                this,
                0,
                mbrIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        session.setMediaButtonReceiver(mbrPending)
        session.setCallback(
            object : MediaSessionCompat.Callback() {
                override fun onPlay() {
                    emitShort("onPlay")
                }

                override fun onPause() {
                    emitShort("onPause")
                }

                override fun onSkipToNext() {
                    // OnePlus/HeyMelody often maps double-tap → Next, not Play/Pause.
                    emitShort("onSkipToNext")
                }

                override fun onSkipToPrevious() {
                    emitShort("onSkipToPrevious")
                }

                override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                    @Suppress("DEPRECATION")
                    val ke =
                        mediaButtonIntent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT)
                            ?: return super.onMediaButtonEvent(mediaButtonIntent)
                    return handleMediaKey(ke) || super.onMediaButtonEvent(mediaButtonIntent)
                }
            },
            mainHandler,
        )
        applyPlaybackState(session, playing = false)
        mediaSession = session
    }

    private fun transportActions(): Long {
        return PlaybackStateCompat.ACTION_PLAY or
            PlaybackStateCompat.ACTION_PAUSE or
            PlaybackStateCompat.ACTION_PLAY_PAUSE or
            PlaybackStateCompat.ACTION_STOP or
            PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
            PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS
    }

    private fun applyPlaybackState(session: MediaSessionCompat, playing: Boolean) {
        val state =
            if (playing) {
                PlaybackStateCompat.STATE_PLAYING
            } else {
                PlaybackStateCompat.STATE_PAUSED
            }
        session.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(transportActions())
                .setState(state, 0L, if (playing) 1f else 0f)
                .build(),
        )
    }

    private fun setHeadsetCaptureEnabled(enabled: Boolean) {
        captureEnabled = enabled
        ensureMediaSession()
        val session = mediaSession ?: return
        session.isActive = enabled
        if (enabled) {
            applyPlaybackState(session, playing = true)
            claimMediaButtonPriority()
        } else {
            applyPlaybackState(session, playing = false)
            abandonClaimFocus()
        }
    }

    /**
     * Samsung/OnePlus keep routing AVRCP to the last real media player (often YT Music).
     * A brief silent MEDIA track + transient focus makes us the active session.
     */
    private fun claimMediaButtonPriority() {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val req =
                    AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                        .setAudioAttributes(
                            AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_MEDIA)
                                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                                .build(),
                        )
                        .setOnAudioFocusChangeListener(focusChangeListener)
                        .build()
                audioFocusRequest = req
                am.requestAudioFocus(req)
            } else {
                @Suppress("DEPRECATION")
                am.requestAudioFocus(
                    focusChangeListener,
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK,
                )
            }
        } catch (_: Exception) {
        }

        try {
            val sampleRate = 44100
            val frames = sampleRate / 20 // ~50ms silence
            val bytes = frames * 2
            val track =
                AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build(),
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(sampleRate)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                            .build(),
                    )
                    .setBufferSizeInBytes(bytes)
                    .setTransferMode(AudioTrack.MODE_STATIC)
                    .build()
            track.write(ShortArray(frames), 0, frames)
            track.play()
            mainHandler.postDelayed({
                try {
                    track.stop()
                    track.release()
                } catch (_: Exception) {
                }
                abandonClaimFocus()
                mediaSession?.let { applyPlaybackState(it, playing = captureEnabled) }
            }, 120)
        } catch (_: Exception) {
        }
    }

    private fun abandonClaimFocus() {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audioFocusRequest?.let { am.abandonAudioFocusRequest(it) }
            } else {
                @Suppress("DEPRECATION")
                am.abandonAudioFocus(focusChangeListener)
            }
        } catch (_: Exception) {
        }
        audioFocusRequest = null
    }

    private fun handleMediaKey(ke: KeyEvent): Boolean {
        if (!captureEnabled) return false
        val code = ke.keyCode
        // Next/Previous: OnePlus double-tap often lands here (not Play/Pause).
        if (code == KeyEvent.KEYCODE_MEDIA_NEXT ||
            code == KeyEvent.KEYCODE_MEDIA_PREVIOUS
        ) {
            if (ke.action == KeyEvent.ACTION_UP) {
                emitShort(if (code == KeyEvent.KEYCODE_MEDIA_NEXT) "keyNext" else "keyPrev")
            }
            return true
        }

        val isHeadset =
            code == KeyEvent.KEYCODE_HEADSETHOOK ||
                code == KeyEvent.KEYCODE_MEDIA_PLAY ||
                code == KeyEvent.KEYCODE_MEDIA_PAUSE ||
                code == KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
        if (!isHeadset) return false

        when (ke.action) {
            KeyEvent.ACTION_DOWN -> {
                if (ke.repeatCount == 0) {
                    downAtMs = SystemClock.uptimeMillis()
                    longFired = false
                    mainHandler.removeCallbacks(longPressRunnable)
                    mainHandler.postDelayed(longPressRunnable, longPressMs)
                }
                return true
            }
            KeyEvent.ACTION_UP -> {
                mainHandler.removeCallbacks(longPressRunnable)
                if (longFired) {
                    emit("longEnd", "up")
                } else {
                    emitShort("up")
                }
                downAtMs = 0L
                longFired = false
                return true
            }
        }
        return false
    }

    private fun emitShort(source: String) {
        emit("short", source)
    }

    private fun emit(event: String, source: String) {
        if (!captureEnabled) return
        val now = SystemClock.uptimeMillis()
        if (event == "short" && now - lastEmitAtMs < 350L) return
        if (event == "short") lastEmitAtMs = now
        mainHandler.post {
            headsetChannel?.invokeMethod(
                "headsetEvent",
                mapOf("event" to event, "source" to source),
            )
        }
    }

    override fun onResume() {
        super.onResume()
        if (captureEnabled) {
            setHeadsetCaptureEnabled(true)
        }
    }

    override fun onDestroy() {
        abandonClaimFocus()
        mediaSession?.isActive = false
        mediaSession?.release()
        mediaSession = null
        super.onDestroy()
    }
}
