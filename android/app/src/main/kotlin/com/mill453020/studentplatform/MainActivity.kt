package com.mill453020.studentplatform

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import android.os.Build
import android.provider.Settings
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import androidx.core.view.inputmethod.EditorInfoCompat
import androidx.core.view.inputmethod.InputConnectionCompat
import androidx.core.view.inputmethod.InputConnectionCompat.OnCommitContentListener
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.dart.DartExecutor
import android.os.Handler
import android.os.Looper
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.Executors
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.CountDownLatch
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val startupOrigin = SystemClock.elapsedRealtime()
    private val fixtureIoDelegate = lazy { Executors.newSingleThreadExecutor() }
    private val fixtureIo by fixtureIoDelegate
    private val authorityIoDelegate = lazy { ThreadPoolExecutor(1,1,0,TimeUnit.MILLISECONDS,ArrayBlockingQueue<Runnable>(32)) }
    private val authorityIo by authorityIoDelegate
    private val fixtureAuthorityHold=CountDownLatch(1)
    private val fixtureAuthorityHeld=AtomicBoolean(false)

    private fun startupTrace(stage: String) {
        if (intent?.getBooleanExtra("startupTrace", false) == true) {
            Log.i("StartupTrace", "$stage elapsed=${SystemClock.elapsedRealtime() - startupOrigin}ms uptime=${SystemClock.elapsedRealtime()}ms")
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        startupTrace("activity-onCreate-start")
        super.onCreate(savedInstanceState)
        startupTrace("activity-onCreate-end")
    }
    override fun onDestroy() {
        if (fixtureIoDelegate.isInitialized()) fixtureIo.shutdown()
        if (authorityIoDelegate.isInitialized()) authorityIo.shutdown()
        super.onDestroy()
    }

    override fun onFlutterUiDisplayed() {
        super.onFlutterUiDisplayed()
        startupTrace("flutter-ui-displayed")
    }


    private lateinit var channel: MethodChannel
    private var captureView: CommitEditText? = null
    private var heldQaLeaseEngine: FlutterEngine? = null
    private var heldAuthorityFixtureEngine: FlutterEngine? = null

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        if (packageName == "com.mill453020.studentplatform.authorityqa" || packageName == "com.mill453020.studentplatform.authorityfixture" || packageName == "com.mill453020.studentplatform.authorityrecoverfixture" || packageName == "com.mill453020.studentplatform.authorityrecoverdenyfixture" || packageName == "com.mill453020.studentplatform.authorityrecoverrevokedfixture" || packageName == "com.mill453020.studentplatform.authorityrecoverdiagnosticfixture" || packageName == "com.mill453020.studentplatform.authoritysourcefixture" || packageName == "com.mill453020.studentplatform.authoritysourcediagnosticv6" || packageName == "com.mill453020.studentplatform.authoritygatefixture" || packageName == "com.mill453020.studentplatform.authoritydispatchfixturev4" || packageName == "com.mill453020.studentplatform.authoritycoldlaunchfixture") {
            SourceDocumentAuthorityQa.unregisterOffMain(this,flutterEngine)
            heldAuthorityFixtureEngine?.let { SourceDocumentAuthorityQa.unregisterOffMain(this,it); it.destroy() }
            heldAuthorityFixtureEngine = null
        }
        if (packageName == "com.mill453020.studentplatform.attachfixture") {
            SourceDocumentNativeQa.unregister(flutterEngine)
            SourceEngineLeaseQa.close(this,flutterEngine)
            heldQaLeaseEngine?.let { if (SourceEngineLeaseQa.close(this,it)) { SourceDocumentNativeQa.unregister(it); it.destroy(); heldQaLeaseEngine = null } }
        }
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        startupTrace("plugins-start")
        super.configureFlutterEngine(flutterEngine)
        startupTrace("plugins-end")
        if (packageName == "com.mill453020.studentplatform.authorityqa") {
            SourceDocumentAuthorityQa.register(flutterEngine)
            installAuthorityChannel(flutterEngine)
        }
        if (packageName == "com.mill453020.studentplatform.authorityrecoverfixture" || packageName == "com.mill453020.studentplatform.authorityrecoverdenyfixture" || packageName == "com.mill453020.studentplatform.authorityrecoverrevokedfixture" || packageName == "com.mill453020.studentplatform.authorityrecoverdiagnosticfixture" || packageName == "com.mill453020.studentplatform.authoritysourcefixture" || packageName == "com.mill453020.studentplatform.authoritysourcediagnosticv6" || packageName == "com.mill453020.studentplatform.authoritygatefixture" || packageName == "com.mill453020.studentplatform.authoritydispatchfixturev4" || packageName == "com.mill453020.studentplatform.authoritycoldlaunchfixture") {
            SourceDocumentAuthorityQa.register(flutterEngine)
            installAuthorityChannel(flutterEngine)
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger,"student_platform/authority_recovery_fixture").setMethodCallHandler { call,result ->
                when(call.method) {
                    "startOwner" -> { startService(Intent(this,SourceAuthorityRecoveryFixtureService::class.java)); result.success(true) }
                    "setLockMode" -> {
                        val mode=call.argument<String>("mode")
                        if(mode !in setOf("guardOnly","docOnly","both")) result.success(false)
                        else { startService(Intent(this,SourceAuthorityRecoveryFixtureService::class.java).putExtra("fixtureLockMode",mode)); result.success(true) }
                    }
                    "testProviderOpen" -> fixtureIo.execute {
                        val request=call.argument<String>("request")
                        val opened=try {
                            if(packageName !in setOf("com.mill453020.studentplatform.authoritydispatchfixturev4","com.mill453020.studentplatform.authoritycoldlaunchfixture") || request==null || !Regex("^[A-Za-z0-9_-]{16,80}$").matches(request)) false
                            else contentResolver.openFileDescriptor(Uri.parse("content://$packageName.authority_document_qa/document/$request"),"r")?.use { true } ?: false
                        } catch (_:Exception) { false }
                        runOnUiThread { result.success(opened) }
                    }
                    "ownerDead" -> fixtureIo.execute {
                        val dead=try {
                            val file=File(filesDir.canonicalFile,"pinned_media_guard_ordinary_v1.db")
                            val db=android.database.sqlite.SQLiteDatabase.openDatabase(file.path,null,android.database.sqlite.SQLiteDatabase.OPEN_READONLY)
                            val pid=try { db.rawQuery("SELECT pid FROM qa_recovery_fixture",null).use { if (!it.moveToFirst()) -1 else it.getInt(0) } } finally { db.close() }
                            pid>0 && !File("/proc/$pid").exists()
                        } catch (_:Exception) { false }
                        runOnUiThread { result.success(dead) }
                    }
                    "killOwner" -> fixtureIo.execute {
                        val ok=try {
                            val file=File(filesDir.canonicalFile,"pinned_media_guard_ordinary_v1.db")
                            val db=android.database.sqlite.SQLiteDatabase.openDatabase(file.path,null,android.database.sqlite.SQLiteDatabase.OPEN_READONLY)
                            val pid=try { db.rawQuery("SELECT pid FROM qa_recovery_fixture",null).use { if (!it.moveToFirst()) -1 else it.getInt(0) } } finally { db.close() }
                            val cmd=if (pid>0 && pid!=android.os.Process.myPid()) File("/proc/$pid/cmdline").readText().substringBefore('\u0000') else ""
                            if (cmd=="$packageName:qa_recovery_owner") { android.os.Process.killProcess(pid); true } else false
                        } catch (_:Exception) { false }
                        runOnUiThread { result.success(ok) }
                    }
                    else -> result.notImplemented()
                }
            }
        }
        if (packageName == "com.mill453020.studentplatform.authorityfixture") {
            // Main engine A intentionally has no native owner registration.
            installAuthorityChannel(flutterEngine)
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger,"student_platform/authority_fixture_control").setMethodCallHandler { call, result ->
                when(call.method) {
                    "startOwnerB" -> startAuthorityFixtureOwner(result)
                    "closeOwnerB" -> {
                        val other=heldAuthorityFixtureEngine
                        if (other==null) result.success(false) else {
                            MethodChannel(other.dartExecutor.binaryMessenger,"student_platform/authority_fixture_child").invokeMethod("close",null,object:MethodChannel.Result {
                                override fun success(value:Any?) {
                                    if (value == true) { SourceDocumentAuthorityQa.unregister(this@MainActivity,other); other.destroy(); heldAuthorityFixtureEngine=null }
                                    result.success(value == true)
                                }
                                override fun error(code:String,message:String?,details:Any?) { result.success(false) }
                                override fun notImplemented() { result.success(false) }
                            })
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
        if (packageName == "com.mill453020.studentplatform.attachfixture") {
            SourceDocumentNativeQa.register(flutterEngine, primary = true)
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
                "student_platform/source_document_qa_guard").setMethodCallHandler { call, result ->
                val args = call.arguments as? Map<*, *>
                when (call.method) {
                    "dispatchSynthetic" -> result.success(args != null && SourceDocumentQaGuard.dispatch(this, args))
                    "verifyRealSchemaSynthetic" -> Thread {
                        val value = args != null && SourceDocumentProofQa.verifyFixture(this, args)
                        runOnUiThread { result.success(value) }
                    }.start()
                    "claimNativeOwnerSynthetic" -> result.success(args != null && SourceDocumentNativeQa.claim(this, flutterEngine, args))
                    "createNativeLeaseSynthetic" -> result.success(SourceEngineLeaseQa.create(this,flutterEngine))
                    "admitNativeLeaseSynthetic" -> result.success(SourceEngineLeaseQa.admit(this,flutterEngine))
                    "validateNativeLeaseSynthetic" -> result.success((args?.get("token") as? String)?.let { SourceEngineLeaseQa.validate(this,flutterEngine,it) } ?: false)
                    "verifyHeldLeaseSynthetic" -> result.success((args?.get("token") as? String)?.let { token -> heldQaLeaseEngine?.let { SourceEngineLeaseQa.validate(this,it,token) } } ?: false)
                    "admitHeldLeaseSynthetic" -> result.success(heldQaLeaseEngine?.let { SourceEngineLeaseQa.admit(this,it) } ?: false)
                    "closeHeldLeaseSynthetic" -> {
                        val held = heldQaLeaseEngine
                        val closed = held != null && SourceEngineLeaseQa.close(this,held)
                        if (closed && held != null) { SourceDocumentNativeQa.unregister(held); held.destroy(); heldQaLeaseEngine = null }
                        result.success(closed)
                    }
                    "revokeNativeOwnerSynthetic" -> Thread {
                        val value = SourceDocumentNativeQa.revoke(this, flutterEngine)
                        runOnUiThread { result.success(value) }
                    }.start()
                    "revokeOtherEngineSynthetic" -> {
                        val other = FlutterEngine(applicationContext)
                        SourceDocumentNativeQa.register(other, primary = false)
                        Thread {
                            val value = SourceDocumentNativeQa.revoke(this,other)
                            runOnUiThread { SourceDocumentNativeQa.unregister(other); other.destroy(); result.success(value) }
                        }.start()
                    }
                    "dispatchRealSchemaSynthetic" -> Thread {
                        val value = if (args == null) "blocked" else SourceDocumentNativeQa.dispatch(this, flutterEngine, args)
                        runOnUiThread { result.success(value) }
                    }.start()
                    "readPreparedSynthetic" -> Thread {
                        val request = args?.get("request") as? String
                        val value = try {
                            if (request == null || !Regex("^[A-Za-z0-9_-]{16,80}$").matches(request)) null else {
                                val uri = Uri.parse("content://${packageName}.source_document_qa/content/$request")
                                contentResolver.openInputStream(uri)?.use { input ->
                                    val digest = java.security.MessageDigest.getInstance("SHA-256")
                                    val buffer = ByteArray(64*1024)
                                    var total = 0
                                    while (true) {
                                        val n = input.read(buffer)
                                        if (n < 0) break
                                        total += n
                                        if (total > 8*1024*1024) throw IllegalStateException()
                                        digest.update(buffer,0,n)
                                    }
                                    digest.digest().joinToString("") { "%02x".format(it) }
                                }
                            }
                        } catch (_: Exception) { null }
                        runOnUiThread { result.success(value) }
                    }.start()
                    "holdPreparedSynthetic" -> Thread {
                        val request = args?.get("request") as? String
                        val value = try {
                            if (request == null || !Regex("^[A-Za-z0-9_-]{16,80}$").matches(request)) false else {
                                val uri = Uri.parse("content://${packageName}.source_document_qa/content/$request")
                                val opened = mutableListOf<android.os.ParcelFileDescriptor>()
                                try {
                                    val first = contentResolver.openFileDescriptor(uri,"r")?.also { opened.add(it) }
                                    val second = contentResolver.openFileDescriptor(uri,"r")?.also { opened.add(it) }
                                    val third = try { contentResolver.openFileDescriptor(uri,"r")?.also { opened.add(it) } } catch (_: Exception) { null }
                                    if (first == null || second == null || third != null) false else {
                                        Thread.sleep(8500)
                                        val oldError = try {
                                            val byte = ByteArray(1)
                                            android.system.Os.read(first.fileDescriptor,byte,0,1)
                                            false
                                        } catch (e: android.system.ErrnoException) { e.errno == android.system.OsConstants.EIO }
                                        var afterClose: android.os.ParcelFileDescriptor? = null
                                        for (i in 0 until 100) {
                                            afterClose = try { contentResolver.openFileDescriptor(uri,"r")?.also { opened.add(it) } } catch (_: Exception) { null }
                                            if (afterClose != null) break
                                            Thread.sleep(20)
                                        }
                                        oldError && afterClose != null
                                    }
                                } finally { opened.forEach { try { it.close() } catch (_: Exception) {} } }
                            }
                        } catch (_: Exception) { false }
                        runOnUiThread { result.success(value) }
                    }.start()
                    "seekPreparedSynthetic" -> Thread {
                        val request = args?.get("request") as? String
                        val value = try {
                            if (request == null || !Regex("^[A-Za-z0-9_-]{16,80}$").matches(request)) false else {
                                val uri = Uri.parse("content://${packageName}.source_document_qa/content/$request")
                                contentResolver.openFileDescriptor(uri,"r")?.use { fd ->
                                    Thread.sleep(5500) // an idle/slow reader must not be truncated
                                    val size = 3L*1024*1024
                                    val at = size-1
                                    android.system.Os.lseek(fd.fileDescriptor,at,android.system.OsConstants.SEEK_SET)
                                    val one = ByteArray(1)
                                    android.system.Os.read(fd.fileDescriptor,one,0,1) == 1 && (one[0].toInt() and 0xff) == (at % 251).toInt()
                                } ?: false
                            }
                        } catch (_: Exception) { false }
                        runOnUiThread { result.success(value) }
                    }.start()
                    "dispatchOtherEngineSynthetic" -> {
                        val other = FlutterEngine(applicationContext)
                        SourceDocumentNativeQa.register(other, primary = false)
                        Thread {
                            val value = if (args == null) "blocked" else SourceDocumentNativeQa.dispatch(this, other, args)
                            runOnUiThread { SourceDocumentNativeQa.unregister(other); other.destroy(); result.success(value) }
                        }.start()
                    }
                    "claimOtherEngineSynthetic" -> {
                        val other = FlutterEngine(applicationContext)
                        SourceDocumentNativeQa.register(other, primary = false)
                        try { result.success(args != null && SourceDocumentNativeQa.claim(this, other, args)) }
                        finally { SourceDocumentNativeQa.unregister(other); other.destroy() }
                    }
                    "claimPrimaryContenderSynthetic" -> {
                        val other = FlutterEngine(applicationContext)
                        SourceDocumentNativeQa.register(other, primary = true)
                        try { result.success(args != null && SourceDocumentNativeQa.claim(this, other, args)) }
                        finally { SourceDocumentNativeQa.unregister(other); other.destroy() }
                    }
                    "restartNativeOwnerSynthetic" -> {
                        SourceDocumentNativeQa.unregister(flutterEngine)
                        val next = FlutterEngine(applicationContext)
                        SourceDocumentNativeQa.register(next, primary = true)
                        try { result.success(args != null && SourceDocumentNativeQa.claim(this, next, args)) }
                        finally { SourceDocumentNativeQa.unregister(next); next.destroy(); SourceDocumentNativeQa.register(flutterEngine, primary = true) }
                    }
                    "runDartSecondarySynthetic" -> {
                        if (args == null) result.success(null) else runSecondaryQa(args,result)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "student_platform/storage_space").setMethodCallHandler { call, result ->
            if (call.method == "availableSupportBytes") {
                try {
                    val bytes = filesDir.usableSpace
                    result.success(if (bytes > 0) bytes else null)
                } catch (_: Exception) { result.success(null) }
            } else result.notImplemented()
        }
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "keyboard_image_channel"
        )

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "focus" -> {
                    ensureCaptureView()
                    showKeyboard()
                    result.success(null)
                }
                "dispose" -> {
                    removeCaptureView()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "student_platform/notifications"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "clearNotifications" -> {
                    (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancelAll()
                    result.success(null)
                }
                "openNotificationSettings" -> {
                    openNotificationSettings()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "student_platform/topic_ocr"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isAvailable" -> {
                    Thread {
                        try {
                            val ok = TopicOcrRecognizer.isAvailable(applicationContext)
                            runOnUiThread { result.success(ok) }
                        } catch (_: Exception) {
                            runOnUiThread { result.success(false) }
                        }
                    }.start()
                }
                "recognize" -> {
                    val args = call.arguments as? Map<*, *>
                    val path = args?.get("path") as? String
                    val languages = (args?.get("languages") as? String) ?: "rus+eng"
                    if (path.isNullOrBlank()) {
                        result.error("bad_args", "Путь к изображению не передан.", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            val text = TopicOcrRecognizer.recognize(
                                context = applicationContext,
                                imagePath = path,
                                languages = languages,
                            )
                            runOnUiThread { result.success(text) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error(
                                    "ocr_error",
                                    e.message ?: "Не удалось распознать текст.",
                                    null,
                                )
                            }
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun installAuthorityChannel(engine:FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger,"student_platform/document_authority_qa").setMethodCallHandler { call, result ->
            if (call.method=="workerHeldForTest" && packageName=="com.mill453020.studentplatform.authoritygatefixture") {
                result.success(fixtureAuthorityHeld.get()); return@setMethodCallHandler
            }
            if (call.method=="releaseWorkerForTest" && packageName=="com.mill453020.studentplatform.authoritygatefixture") {
                fixtureAuthorityHold.countDown(); result.success(true); return@setMethodCallHandler
            }
            if (call.method=="closeGateForTest" && packageName=="com.mill453020.studentplatform.authoritygatefixture") {
                SourceDocumentAuthorityQa.unregisterOffMain(this,engine)
                result.success(true)
                return@setMethodCallHandler
            }
            val args=call.arguments as? Map<*,*>
            // Shorter than the Dart visible timeout; a queued request must not
            // begin a new OS handoff after that caller has already timed out.
            val arrivalDeadline=SystemClock.elapsedRealtime()+10000L
            val requestedDeadline=(args?.get("deadline") as? Number)?.toLong() ?: 0L
            val dispatchDeadline=minOf(arrivalDeadline,requestedDeadline)
            try { authorityIo.execute {
                val value:Any? = try { when(call.method) {
                    "createGuard" -> SourceDocumentAuthorityQa.createGuard(this,engine)?.let {
                        mapOf("guard" to it,"path" to File(filesDir.canonicalFile,"pinned_media_guard_ordinary_v1.db").canonicalPath)
                    }
                    "releaseGuard" -> (args?.get("guard") as? String)?.let { SourceDocumentAuthorityQa.releaseGuard(this,engine,it) } ?: false
                    "captureClosed" -> if(args==null) null else SourceDocumentAuthorityQa.capture(this,engine,args)
                    "recoverClosed" -> if(args==null) null else SourceDocumentAuthorityQa.recover(this,engine,args)
                    "verifySource" -> if(args==null) null else SourceDocumentAuthorityQa.verifySource(this,engine,args)
                    "elapsedRealtime" -> SystemClock.elapsedRealtime()
                    "holdWorkerForTest" -> if(packageName=="com.mill453020.studentplatform.authoritygatefixture") { fixtureAuthorityHeld.set(true); fixtureAuthorityHold.await(5,TimeUnit.SECONDS) } else false
                    "reserveDispatch" -> if(args==null) "blocked" else SourceDocumentAuthorityQa.reserveDispatch(this,engine,args)
                    "dispatchSource" -> if(args==null) "blocked" else SourceDocumentAuthorityQa.dispatchSource(this,engine,args,dispatchDeadline)
                    "dispatchExpiredForTest" -> if(args==null || packageName!="com.mill453020.studentplatform.authoritygatefixture") "blocked" else SourceDocumentAuthorityQa.dispatchSource(this,engine,args,0L)
                    "dispatchSlowProofForTest" -> if(args==null || packageName!="com.mill453020.studentplatform.authoritygatefixture") "blocked" else SourceDocumentAuthorityQa.dispatchSource(this,engine,args,SystemClock.elapsedRealtime()+200L)
                    "slowProofReachedForTest" -> packageName=="com.mill453020.studentplatform.authoritygatefixture" && SourceDocumentAuthorityQa.testSlowProofReached
                    "ackDispatch" -> (args?.get("request") as? String)?.let { SourceDocumentAuthorityQa.acknowledgeDispatch(this,engine,it) } ?: false
                    "admit" -> {
                        val ticket=args?.get("ticket") as? String
                        val instance=args?.get("instance") as? String
                        val revision=(args?.get("revision") as? Number)?.toLong()
                        ticket!=null && instance!=null && revision!=null && SourceDocumentAuthorityQa.admit(this,engine,ticket,instance,revision)
                    }
                    "close" -> SourceDocumentAuthorityQa.close(this,engine,args?.get("ticket") as? String)
                    else -> null
                } } catch (_:Exception) { null }
                runOnUiThread { result.success(value) }
            } } catch (_:RejectedExecutionException) { result.success(null) }
        }
    }

    private fun startAuthorityFixtureOwner(parentResult:MethodChannel.Result) {
        if (heldAuthorityFixtureEngine!=null) { parentResult.success(false); return }
        val engine=FlutterEngine(applicationContext)
        SourceDocumentAuthorityQa.register(engine)
        installAuthorityChannel(engine)
        val done=AtomicBoolean(false)
        val handler=Handler(Looper.getMainLooper())
        lateinit var timeout:Runnable
        fun finish(ok:Boolean) {
            if (!done.compareAndSet(false,true)) return
            handler.removeCallbacks(timeout)
            if (ok) heldAuthorityFixtureEngine=engine else { SourceDocumentAuthorityQa.unregister(this,engine); engine.destroy() }
            parentResult.success(ok)
        }
        timeout=Runnable { finish(false) }
        MethodChannel(engine.dartExecutor.binaryMessenger,"student_platform/authority_fixture_control").setMethodCallHandler { call,result ->
            if (call.method=="reportReady") { result.success(null); finish(call.arguments == true) }
            else result.notImplemented()
        }
        handler.postDelayed(timeout,20000)
        try {
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(
                FlutterInjector.instance().flutterLoader().findAppBundlePath(),"secondaryAuthorityMain"))
        } catch (_:Exception) { finish(false) }
    }

    private fun runSecondaryQa(input: Map<*, *>, parentResult: MethodChannel.Result) {
        val other = FlutterEngine(applicationContext)
        SourceDocumentNativeQa.register(other, primary = false)
        val main = Handler(Looper.getMainLooper())
        val finished = AtomicBoolean(false)
        lateinit var timeout: Runnable
        fun finish(value: Any?) {
            if (!finished.compareAndSet(false,true)) return
            main.removeCallbacks(timeout)
            val keep = input["keepLease"] == true && (value as? Map<*, *>)?.get("lease") == true && heldQaLeaseEngine == null
            if (keep) heldQaLeaseEngine = other else {
                SourceEngineLeaseQa.close(this,other)
                SourceDocumentNativeQa.unregister(other)
                other.destroy()
            }
            parentResult.success(value)
        }
        timeout = Runnable { finish(null) }
        MethodChannel(other.dartExecutor.binaryMessenger,"student_platform/source_document_qa_guard").setMethodCallHandler { call, result ->
            val args = call.arguments as? Map<*, *>
            when (call.method) {
                "createNativeLeaseSynthetic" -> result.success(SourceEngineLeaseQa.create(this,other))
                "admitNativeLeaseSynthetic" -> result.success(SourceEngineLeaseQa.admit(this,other))
                "validateNativeLeaseSynthetic" -> result.success((args?.get("token") as? String)?.let { SourceEngineLeaseQa.validate(this,other,it) } ?: false)
                "claimNativeOwnerSynthetic" -> result.success(args != null && SourceDocumentNativeQa.claim(this,other,args))
                "dispatchRealSchemaSynthetic" -> Thread {
                    val value = if (args == null) "blocked" else SourceDocumentNativeQa.dispatch(this,other,args)
                    runOnUiThread { result.success(value) }
                }.start()
                else -> result.notImplemented()
            }
        }
        MethodChannel(other.dartExecutor.binaryMessenger,"student_platform/source_document_qa_secondary").setMethodCallHandler { call, result ->
            when (call.method) {
                "getInput" -> result.success(input)
                "report" -> { result.success(null); finish(call.arguments) }
                else -> result.notImplemented()
            }
        }
        main.postDelayed(timeout,15000)
        try {
            other.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(
                FlutterInjector.instance().flutterLoader().findAppBundlePath(),"secondaryEngineMain"))
        } catch (_: Exception) { finish(null) }
    }

    private fun openNotificationSettings() {
        val intent = Intent().apply {
            when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O -> {
                    action = Settings.ACTION_APP_NOTIFICATION_SETTINGS
                    putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                }
                else -> {
                    action = Settings.ACTION_APPLICATION_DETAILS_SETTINGS
                    data = Uri.fromParts("package", packageName, null)
                }
            }
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    private fun ensureCaptureView() {
        if (captureView != null) return

        val v = CommitEditText(this).apply {
            // «невидимый» едитекст внизу экрана
            setSingleLine(true)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 1f)
            setPadding(0, 0, 0, 0)
            background = null
            alpha = 0f
            isFocusable = true
            isFocusableInTouchMode = true
            imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_ACTION_NONE
            inputType = InputType.TYPE_CLASS_TEXT
            layoutParams = FrameLayout.LayoutParams(
                1, 1, Gravity.BOTTOM or Gravity.START
            )
        }

        addContentView(v, v.layoutParams)
        captureView = v
    }

    private fun showKeyboard() {
        val v = captureView ?: return
        v.requestFocus()
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        imm.showSoftInput(v, InputMethodManager.SHOW_IMPLICIT)
    }

    private fun removeCaptureView() {
        val v = captureView ?: return
        (v.parent as? ViewGroup)?.removeView(v)
        captureView = null
    }

    /** EditText, который принимает контент из клавиатуры (GIF/WEBP/PNG/JPEG) */
    inner class CommitEditText(ctx: Context) : EditText(ctx) {
        override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
            val ic = super.onCreateInputConnection(outAttrs)

            // Разрешаем типы, которые умеет отдавать клавиатура
            EditorInfoCompat.setContentMimeTypes(
                outAttrs,
                arrayOf(
                    "image/gif",
                    "image/webp",
                    "image/png",
                    "image/jpeg",
                    "image/*"
                )
            )

            val callback = OnCommitContentListener { info, flags, _ ->
                if (Build.VERSION.SDK_INT >= 25 &&
                    (flags and InputConnectionCompat.INPUT_CONTENT_GRANT_READ_URI_PERMISSION) != 0
                ) {
                    try { info.requestPermission() } catch (_: Exception) {}
                }

                try {
                    val uri = info.contentUri
                    val mime = contentResolver.getType(uri) ?: ""
                    val ext = when {
                        mime.contains("gif") -> "gif"
                        mime.contains("webp") -> "webp"
                        mime.contains("png") -> "png"
                        else -> "jpg"
                    }
                    val file = File(cacheDir, "kb_${System.currentTimeMillis()}.$ext")
                    contentResolver.openInputStream(uri)?.use { input ->
                        FileOutputStream(file).use { output -> input.copyTo(output) }
                    }
                    // отправляем путь в Dart
                    channel.invokeMethod("onPicked", file.absolutePath)
                } catch (_: Exception) {
                } finally {
                    if (Build.VERSION.SDK_INT >= 25) {
                        try { info.releasePermission() } catch (_: Exception) {}
                    }
                }
                true
            }

            return InputConnectionCompat.createWrapper(ic, outAttrs, callback)
        }
    }
}
