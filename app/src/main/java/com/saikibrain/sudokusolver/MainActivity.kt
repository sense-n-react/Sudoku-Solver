package com.saikibrain.sudokusolver

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.Settings
import android.util.Log
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.result.contract.ActivityResultContract
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Photo
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.material3.Checkbox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import coil.compose.AsyncImage
import com.saikibrain.sudokusolver.ui.theme.SudokuSolverTheme
import java.io.File

class MainActivity : ComponentActivity() {

    private val termuxPermission = "com.termux.permission.RUN_COMMAND"
    private val resultAction = "com.saikibrain.sudokusolver.TERMUX_RESULT"

    /** Ruby スクリプトと入出力の共有ディレクトリ（Termux も読み書きできる） */
    private val sharedDir: String get() =
        "${Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS)
            .absolutePath}/SudokuSolver"

    private lateinit var vm: SudokuSolverViewModel
    private var resultReceiver: BroadcastReceiver? = null
    private val requestPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { grants ->
            val denied = grants.filterValues { !it }.keys
            if (denied.isNotEmpty()) {
                Toast.makeText(this, "パーミッションが拒否されました: $denied", Toast.LENGTH_LONG).show()
            }
        }

    private val galleryLauncher =
        registerForActivityResult(OpenImageWithInitialUri()) { uri ->
            uri?.let {
                contentResolver.takePersistableUriPermission(it, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                saveLastImageUri(it)
                vm.onImageSelected(it)
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        requestRequiredPermissions()

        // API 30+ では MANAGE_EXTERNAL_STORAGE が必要
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            !Environment.isExternalStorageManager()
        ) {
            Toast.makeText(
                this,
                "設定 → このアプリ → 「すべてのファイルへのアクセスを許可」を有効にしてください",
                Toast.LENGTH_LONG
            ).show()
            val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                data = Uri.parse("package:$packageName")
            }
            startActivity(intent)
        }

        resultReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val result = intent.extras?.getBundle("result")
                Log.d("TermuxResult", "extras: ${result?.keySet()?.joinToString()}")
                val stdout = result?.getString("stdout") ?: ""
                val stderr = result?.getString("stderr") ?: ""
                val exitCode = result?.getInt("exitCode", -1) ?: -1
                vm.onSolveFinished(stdout, stderr, exitCode)
            }
        }
        val filter = IntentFilter(resultAction)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(resultReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(resultReceiver, filter)
        }

        setContent {
            SudokuSolverTheme {
                val viewModel: SudokuSolverViewModel = viewModel()
                vm = viewModel
                var showSettings by remember { mutableStateOf(false) }

                if (showSettings) {
                    SettingsScreen(
                        sharedDir = sharedDir,
                        onBack    = { showSettings = false }
                    )
                } else {
                SudokuSolverScreen(
                    onSettingsClick = { showSettings = true },
                    viewModel = viewModel,
                    onGalleryClick = { initialUri -> galleryLauncher.launch(initialUri) },
                    loadLastImageUri = { loadLastImageUri() },
                    onStepSelected = { step -> viewModel.onStepSelected(step) },
                    onImageCaptured = { file ->
                        val uri = androidx.core.content.FileProvider.getUriForFile(
                            this, "$packageName.fileprovider", file
                        )
                        vm.onImageSelected(uri)
                    },
                    onSolveClick = { scriptPath, retryMode ->
                        if (ContextCompat.checkSelfPermission(this, termuxPermission)
                            != PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissionLauncher.launch(arrayOf(termuxPermission))
                            return@SudokuSolverScreen
                        }
                        // 解析対象の URI を取得（再解析時は元画像、初回は現在の URI）
                        val imgUri = viewModel.getOriginalImageUri()
                            ?: viewModel.imageUri.value
                            ?: return@SudokuSolverScreen
                        val imgPath = copyImageToShared(imgUri)
                        if (imgPath == null) {
                            Toast.makeText(this, "画像のコピーに失敗しました", Toast.LENGTH_SHORT).show()
                            return@SudokuSolverScreen
                        }
                        viewModel.onSolveStarted(sharedDir)   // FileObserver も起動
                        runRubyScript(scriptPath, imgPath, retryMode)
                    }
                )
                } // end if (showSettings) else
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        resultReceiver?.let { unregisterReceiver(it) }
    }

    private fun requestRequiredPermissions() {
        val needed = buildList {
            if (ContextCompat.checkSelfPermission(this@MainActivity, termuxPermission)
                != PackageManager.PERMISSION_GRANTED
            ) add(termuxPermission)
            if (ContextCompat.checkSelfPermission(this@MainActivity, android.Manifest.permission.CAMERA)
                != PackageManager.PERMISSION_GRANTED
            ) add(android.Manifest.permission.CAMERA)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                if (ContextCompat.checkSelfPermission(
                        this@MainActivity, android.Manifest.permission.READ_MEDIA_IMAGES
                    ) != PackageManager.PERMISSION_GRANTED
                ) add(android.Manifest.permission.READ_MEDIA_IMAGES)
            } else {
                if (ContextCompat.checkSelfPermission(
                        this@MainActivity, android.Manifest.permission.READ_EXTERNAL_STORAGE
                    ) != PackageManager.PERMISSION_GRANTED
                ) add(android.Manifest.permission.READ_EXTERNAL_STORAGE)
            }
            if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.Q) {
                if (ContextCompat.checkSelfPermission(
                        this@MainActivity, android.Manifest.permission.WRITE_EXTERNAL_STORAGE
                    ) != PackageManager.PERMISSION_GRANTED
                ) add(android.Manifest.permission.WRITE_EXTERNAL_STORAGE)
            }
        }
        if (needed.isNotEmpty()) {
            requestPermissionLauncher.launch(needed.toTypedArray())
        }
    }

    /**
     * content:// URI または file:// URI の画像を /sdcard/Documents/SudokuSolver/input.jpg にコピーする。
     * Termux から同じパスでアクセスできるようにするための中継ステップ。
     */
    private fun copyImageToShared(uri: Uri): String? {
        return try {
            val dir = java.io.File(sharedDir).also { it.mkdirs() }
            val dest = java.io.File(dir, "input.jpg")
            contentResolver.openInputStream(uri)?.use { input ->
                dest.outputStream().use { output -> input.copyTo(output) }
            }
            Log.d("SudokuSolver", "画像コピー完了: ${dest.absolutePath}")
            dest.absolutePath
        } catch (e: Exception) {
            Log.e("SudokuSolver", "画像コピー失敗: $uri", e)
            null
        }
    }

    private fun saveLastImageUri(uri: Uri) {
        getSharedPreferences("sudoku_prefs", Context.MODE_PRIVATE)
            .edit()
            .putString("last_image_uri", uri.toString())
            .apply()
    }

    private fun loadLastImageUri(): Uri? {
        val raw = getSharedPreferences("sudoku_prefs", Context.MODE_PRIVATE)
            .getString("last_image_uri", null) ?: return null
        return Uri.parse(raw)
    }

    /**
     * Termux で Ruby スクリプトを実行する。
     * @param scriptPath  Termux ホームからの相対パスまたは絶対パス（例: "sudoku_solver.rb"）
     * @param imagePath   解析対象の画像の絶対パス（/sdcard/... 形式）
     */
    private fun runRubyScript(scriptPath: String, imagePath: String, retryMode: Boolean = false) {
        val resultIntent = Intent(resultAction).apply { setPackage(packageName) }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pendingIntent = PendingIntent.getBroadcast(this, 0, resultIntent, flags)

        Log.d("SudokuSolver", "Termux 実行: ruby $scriptPath $imagePath $sharedDir${if (retryMode) " -r" else ""}")

        val args = buildList {
            add(scriptPath)
            add(imagePath)
            add(sharedDir)
            if (retryMode) add("-r")
        }.toTypedArray()

        val intent = Intent().apply {
            setClassName("com.termux", "com.termux.app.RunCommandService")
            action = "com.termux.RUN_COMMAND"
            putExtra("com.termux.RUN_COMMAND_PATH", "/data/data/com.termux/files/usr/bin/ruby")
            putExtra("com.termux.RUN_COMMAND_ARGUMENTS", args)
            putExtra("com.termux.RUN_COMMAND_WORKDIR", "/data/data/com.termux/files/home/SudokuSolver")
            putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
            putExtra("com.termux.RUN_COMMAND_PENDING_INTENT", pendingIntent)
        }
        startService(intent)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SudokuSolverScreen(
    viewModel: SudokuSolverViewModel,
    onGalleryClick: (initialUri: Uri?) -> Unit,
    loadLastImageUri: () -> Uri? = { null },
    onSolveClick: (scriptPath: String, retryMode: Boolean) -> Unit,
    onStepSelected: (ProcessingStep) -> Unit = {},
    onSettingsClick: () -> Unit = {},
    onImageCaptured: (File) -> Unit = {}
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("SudokuSolver") },
                actions = {
                    IconButton(onClick = onSettingsClick) {
                        Icon(Icons.Default.Settings, contentDescription = "設定")
                    }
                }
            )
        }
    ) { innerPadding ->
        SudokuSolverContent(
            viewModel = viewModel,
            onGalleryClick = onGalleryClick,
            loadLastImageUri = loadLastImageUri,
            onSolveClick = onSolveClick,
            onStepSelected = onStepSelected,
            onImageCaptured = onImageCaptured,
            modifier = Modifier.padding(innerPadding)
        )
    }
}

@Composable
private fun SudokuSolverContent(
    viewModel: SudokuSolverViewModel,
    @Suppress("UNUSED_PARAMETER") onGalleryClick: (initialUri: Uri?) -> Unit = {},
    @Suppress("UNUSED_PARAMETER") loadLastImageUri: () -> Uri? = { null },
    onSolveClick: (scriptPath: String, retryMode: Boolean) -> Unit,
    onStepSelected: (ProcessingStep) -> Unit,
    onImageCaptured: (File) -> Unit,
    modifier: Modifier = Modifier
) {
    var showCamera by remember { mutableStateOf(false) }
    val imageUri        by viewModel.imageUri.collectAsStateWithLifecycle()
    val originalImageUri by viewModel.originalImageUri.collectAsStateWithLifecycle()
    val processingSteps by viewModel.processingSteps.collectAsStateWithLifecycle()
    val solverState     by viewModel.solverState.collectAsStateWithLifecycle()
    val statusMessage   by viewModel.statusMessage.collectAsStateWithLifecycle()
    val solverOutput    by viewModel.solverOutput.collectAsStateWithLifecycle()
    val solveProcess    by viewModel.solveProcess.collectAsStateWithLifecycle()
    val scrollState = rememberScrollState()

    var showFileBrowser  by remember { mutableStateOf(false) }
    var retryMode        by remember { mutableStateOf(false) }

    val context = LocalContext.current
    val prefs   = remember { context.getSharedPreferences("sudoku_prefs", Context.MODE_PRIVATE) }
    val defaultFolder = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM)
    var fileBrowserRoot by remember {
        mutableStateOf(
            prefs.getString("browser_last_folder", null)
                ?.let { File(it).takeIf { f -> f.isDirectory } }
                ?: defaultFolder
        )
    }

    if (showFileBrowser) {
        FileBrowserSheet(
            initialFolder = fileBrowserRoot,
            onDismiss = { showFileBrowser = false },
            onFileSelected = { uri ->
                showFileBrowser = false
                uri.path?.let { File(it).parentFile?.takeIf { f -> f.isDirectory } }
                    ?.also { folder ->
                        fileBrowserRoot = folder
                        prefs.edit().putString("browser_last_folder", folder.absolutePath).apply()
                    }
                viewModel.onImageSelected(uri)
            },
        )
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .verticalScroll(scrollState)
    ) {
        // --- 画像プレビュー / カメラプレビュー ---
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(320.dp)
                .background(Color(0xFF1A1A2E))
                .clip(RoundedCornerShape(0.dp)),
            contentAlignment = Alignment.Center
        ) {
            if (showCamera) {
                InlineCameraPreview(
                    onImageCaptured = { file ->
                        showCamera = false
                        onImageCaptured(file)
                    },
                    modifier = Modifier.fillMaxSize()
                )
            } else if (imageUri != null) {
                ZoomableImage(
                    uri = imageUri!!,
                    contentDescription = "数独の問題画像",
                    modifier = Modifier.fillMaxSize()
                )
            } else {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(text = "📷", fontSize = 48.sp)
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = "画像を選択または撮影してください",
                        color = Color(0xFF9E9E9E),
                        fontSize = 14.sp,
                        textAlign = TextAlign.Center
                    )
                }
            }

            // 解析状態オーバーレイ
            if (solverState == SolverState.Processing) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(Color(0x88000000)),
                    contentAlignment = Alignment.Center
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        CircularProgressIndicator(color = MaterialTheme.colorScheme.primary)
                        Spacer(modifier = Modifier.height(8.dp))
                        Text("解析中...", color = Color.White)
                    }
                }
            }
        }

        // --- ボタン行 ---
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            OutlinedButton(
                onClick = { showCamera = !showCamera },
                modifier = Modifier.weight(1f)
            ) {
                Icon(
                    if (showCamera) Icons.Default.Image else Icons.Default.CameraAlt,
                    contentDescription = null
                )
                Spacer(modifier = Modifier.width(6.dp))
                Text(if (showCamera) "キャンセル" else "撮影")
            }
            OutlinedButton(
                onClick = { showFileBrowser = true },
                modifier = Modifier.weight(1f)
            ) {
                Icon(Icons.Default.Image, contentDescription = null)
                Spacer(modifier = Modifier.width(6.dp))
                Text("選択")
            }
        }

        // --- 選択ファイル名 ---
        if (originalImageUri != null) {
            val context = LocalContext.current
            val fileName = remember(originalImageUri) {
                originalImageUri?.let { uri ->
                    if (uri.scheme == "content") {
                        context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                            val idx = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                            if (cursor.moveToFirst() && idx >= 0) cursor.getString(idx) else null
                        }
                    } else {
                        uri.lastPathSegment
                    }
                } ?: ""
            }
            if (fileName.isNotEmpty()) {
                Text(
                    text = fileName,
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 16.dp),
                    maxLines = 1,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
                )
                Spacer(modifier = Modifier.height(4.dp))
            }
        }

        // --- 処理ステップ表示 ---
        if (processingSteps.isNotEmpty()) {
            val stepsListState = rememberLazyListState()
            // ステップが追加されるたびに末尾へスクロール
            LaunchedEffect(processingSteps.size) {
                if (processingSteps.isNotEmpty()) {
                    stepsListState.animateScrollToItem(processingSteps.lastIndex)
                }
            }
            Text(
                text = "処理ステップ",
                style = MaterialTheme.typography.titleSmall,
                modifier = Modifier.padding(horizontal = 16.dp)
            )
            Spacer(modifier = Modifier.height(8.dp))
            LazyRow(
                state = stepsListState,
                contentPadding = PaddingValues(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                items(processingSteps) { step ->
                    ProcessingStepCard(
                        step = step,
                        onClick = { onStepSelected(step) }
                    )
                }
            }
            Spacer(modifier = Modifier.height(12.dp))
        } else if (imageUri != null) {
            // まだステップがない場合はプレースホルダー行を表示
            Text(
                text = "処理ステップ",
                style = MaterialTheme.typography.titleSmall,
                modifier = Modifier.padding(horizontal = 16.dp)
            )
            Spacer(modifier = Modifier.height(8.dp))
            LazyRow(
                contentPadding = PaddingValues(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                items(
                    listOf("コーナー検出", "グリッド検出", "数字認識", "解答")
                ) { label ->
                    ProcessingStepPlaceholder(label = label)
                }
            }
            Spacer(modifier = Modifier.height(12.dp))
        }

        // --- リトライモード ---
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Checkbox(
                checked = retryMode,
                onCheckedChange = { retryMode = it }
            )
            Text("enable Retry", fontSize = 14.sp)
        }

        // --- 解析ボタン ---
        Button(
            onClick = { onSolveClick("sudoku.rb", retryMode) },
            enabled = imageUri != null && solverState != SolverState.Processing,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .height(52.dp)
        ) {
            Text(
                text = when (solverState) {
                    SolverState.Processing -> "解析中..."
                    SolverState.Solved -> "再解析"
                    else -> "解析開始"
                },
                fontSize = 16.sp
            )
        }

        // --- ステータス・出力 ---
        if (statusMessage.isNotEmpty()) {
            Spacer(modifier = Modifier.height(12.dp))
            StatusBar(state = solverState, message = statusMessage)
        }

        if (solverOutput.isNotEmpty()) {
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = "出力",
                style = MaterialTheme.typography.titleSmall,
                modifier = Modifier.padding(horizontal = 16.dp)
            )
            Spacer(modifier = Modifier.height(4.dp))
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .padding(12.dp)
            ) {
                Text(
                    text = solverOutput,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 13.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }

        // --- 解探索過程 ---
        if (solveProcess.isNotEmpty()) {
            Spacer(modifier = Modifier.height(8.dp))
            SolveProcessSection(text = solveProcess)
        }

        Spacer(modifier = Modifier.height(24.dp))
    }
}

/**
 * 解探索過程テキストの折りたたみ表示。
 * ヘッダーをタップで展開／折りたたみ。
 */
@Composable
fun SolveProcessSection(text: String) {
    var expanded by remember { mutableStateOf(false) }
    Column(modifier = Modifier.padding(horizontal = 16.dp)) {
        // ヘッダー（タップで展開切り替え）
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable { expanded = !expanded }
                .padding(vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text("解探索過程", style = MaterialTheme.typography.titleSmall)
            Text(
                if (expanded) "▲ 閉じる" else "▼ 表示",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.primary
            )
        }
        if (expanded) {
            val vScroll = rememberScrollState()
            val hScroll = rememberScrollState()
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 400.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .padding(12.dp)
                    .verticalScroll(vScroll)
                    .horizontalScroll(hScroll)
            ) {
                Text(
                    text = text,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 11.sp,
                    lineHeight = 15.sp,
                    softWrap = false,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

/**
 * ピンチイン/アウト・パンに対応した画像表示。
 * ダブルタップでズームリセット。
 */
@Composable
fun ZoomableImage(
    uri: Uri,
    contentDescription: String,
    modifier: Modifier = Modifier
) {
    var scale  by remember(uri) { mutableFloatStateOf(1f) }
    var offset by remember(uri) { mutableStateOf(Offset.Zero) }

    Box(
        modifier = modifier
            .pointerInput(uri) {
                detectTransformGestures { _, pan, zoom, _ ->
                    val newScale = (scale * zoom).coerceIn(1f, 6f)
                    // スケールが 1 のときはオフセット不要
                    offset = if (newScale == 1f) Offset.Zero else offset + pan
                    scale = newScale
                }
            },
        contentAlignment = Alignment.Center
    ) {
        AsyncImage(
            model = uri,
            contentDescription = contentDescription,
            contentScale = ContentScale.Fit,
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer(
                    scaleX = scale,
                    scaleY = scale,
                    translationX = offset.x,
                    translationY = offset.y
                )
        )
    }
}

@Composable
fun ProcessingStepCard(step: ProcessingStep, onClick: () -> Unit = {}) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            modifier = Modifier
                .size(120.dp)
                .clip(RoundedCornerShape(8.dp))
                .border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(8.dp))
                .clickable { onClick() }
        ) {
            AsyncImage(
                model = step.uri,
                contentDescription = step.label,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize()
            )
        }
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = step.label,
            fontSize = 11.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.widthIn(max = 120.dp)
        )
    }
}

@Composable
fun ProcessingStepPlaceholder(label: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            modifier = Modifier
                .size(120.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant)
                .border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(8.dp)),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = "待機中",
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                fontSize = 12.sp
            )
        }
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = label,
            fontSize = 11.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.widthIn(max = 120.dp)
        )
    }
}

@Composable
fun StatusBar(state: SolverState, message: String) {
    val (bgColor, textColor) = when (state) {
        SolverState.Solved -> Pair(
            MaterialTheme.colorScheme.primaryContainer,
            MaterialTheme.colorScheme.onPrimaryContainer
        )
        SolverState.Error -> Pair(
            MaterialTheme.colorScheme.errorContainer,
            MaterialTheme.colorScheme.onErrorContainer
        )
        else -> Pair(
            MaterialTheme.colorScheme.secondaryContainer,
            MaterialTheme.colorScheme.onSecondaryContainer
        )
    }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(bgColor)
            .padding(horizontal = 16.dp, vertical = 10.dp)
    ) {
        Text(text = message, color = textColor, fontSize = 14.sp)
    }
}

// ── Folder picker bottom sheet ────────────────────────────────────────────────

data class FolderEntry(
    val label: String,
    val icon: ImageVector,
    val uri: Uri?
)

/** 外部ストレージの既知フォルダ URI を構築する（ExternalStorage DocumentsProvider） */
private fun externalFolderUri(path: String): Uri =
    DocumentsContract.buildDocumentUri(
        "com.android.externalstorage.documents",
        "primary:$path"
    )

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FolderPickerSheet(
    lastImageUri: Uri?,
    onDismiss: () -> Unit,
    onFolderSelected: (Uri?) -> Unit
) {
    val folders = remember(lastImageUri) {
        buildList {
            if (lastImageUri != null && lastImageUri != Uri.EMPTY) {
                add(FolderEntry("前回のフォルダ", Icons.Default.History, lastImageUri))
            }
            add(FolderEntry("カメラ (DCIM)", Icons.Default.Photo, externalFolderUri("DCIM")))
            add(FolderEntry("ピクチャ", Icons.Default.PhotoLibrary, externalFolderUri("Pictures")))
            add(FolderEntry("ダウンロード", Icons.Default.Download, externalFolderUri("Download")))
            add(FolderEntry("ドキュメント", Icons.Default.FolderOpen, externalFolderUri("Documents")))
            add(FolderEntry("すべての場所から選択", Icons.Default.Image, null))
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Text(
            text = "フォルダを選択",
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp)
        )
        HorizontalDivider()
        folders.forEach { entry ->
            ListItem(
                leadingContent = {
                    Icon(entry.icon, contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary)
                },
                headlineContent = { Text(entry.label) },
                modifier = Modifier.clickable { onFolderSelected(entry.uri) }
            )
        }
        Spacer(modifier = Modifier.height(16.dp))
    }
}

// ── Gallery contract ─────────────────────────────────────────────────────────

/**
 * ACTION_OPEN_DOCUMENT ベースの画像ピッカー。
 * 前回選択した画像の URI を渡すと、同じフォルダから開く。
 */
class OpenImageWithInitialUri : ActivityResultContract<Uri?, Uri?>() {
    override fun createIntent(context: Context, input: Uri?): Intent =
        Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "image/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            if (input != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, input)
            }
        }

    override fun parseResult(resultCode: Int, intent: Intent?): Uri? {
        if (resultCode != android.app.Activity.RESULT_OK) return null
        return intent?.data
    }
}

// ── Previews ─────────────────────────────────────────────────────────────────

@Preview(showBackground = true, showSystemUi = true, name = "初期状態（画像未選択）")
@Composable
private fun PreviewIdle() {
    SudokuSolverTheme {
        SudokuSolverScreen(
            viewModel = SudokuSolverViewModel(),
            onGalleryClick = { _ -> },
            onSolveClick = { _, _ -> }
        )
    }
}

@Preview(showBackground = true, showSystemUi = true, name = "画像選択後（解析前）")
@Composable
private fun PreviewImageSelected() {
    SudokuSolverTheme {
        val vm = SudokuSolverViewModel().also {
            // Uri.EMPTY でプレースホルダーステップ行を表示するために非nullにする
            it.onImageSelected(android.net.Uri.EMPTY)
        }
        SudokuSolverScreen(
            viewModel = vm,
            onGalleryClick = { _ -> },
            onSolveClick = { _, _ -> }
        )
    }
}

@Preview(showBackground = true, showSystemUi = true, name = "解析中")
@Composable
private fun PreviewProcessing() {
    SudokuSolverTheme {
        val vm = SudokuSolverViewModel().also {
            it.onImageSelected(android.net.Uri.EMPTY)
            it.onSolveStarted()
        }
        SudokuSolverScreen(
            viewModel = vm,
            onGalleryClick = { _ -> },
            onSolveClick = { _, _ -> }
        )
    }
}

@Preview(showBackground = true, showSystemUi = true, name = "解析完了")
@Composable
private fun PreviewSolved() {
    SudokuSolverTheme {
        val solvedBoard = """
            5 3 4 6 7 8 9 1 2
            6 7 2 1 9 5 3 4 8
            1 9 8 3 4 2 5 6 7
            8 5 9 7 6 1 4 2 3
            4 2 6 8 5 3 7 9 1
            7 1 3 9 2 4 8 5 6
            9 6 1 5 3 7 2 8 4
            2 8 7 4 1 9 6 3 5
            3 4 5 2 8 6 1 7 9
        """.trimIndent()
        val vm = SudokuSolverViewModel().also {
            it.onImageSelected(android.net.Uri.EMPTY)
            it.onSolveFinished(solvedBoard, "", 0)
        }
        SudokuSolverScreen(
            viewModel = vm,
            onGalleryClick = { _ -> },
            onSolveClick = { _, _ -> }
        )
    }
}

@Preview(showBackground = true, showSystemUi = true, name = "エラー")
@Composable
private fun PreviewError() {
    SudokuSolverTheme {
        val vm = SudokuSolverViewModel().also {
            it.onImageSelected(android.net.Uri.EMPTY)
            it.onSolveFinished("", "sudoku_solver.rb: No such file or directory", 1)
        }
        SudokuSolverScreen(
            viewModel = vm,
            onGalleryClick = { _ -> },
            onSolveClick = { _, _ -> }
        )
    }
}

@Preview(
    showBackground = true, showSystemUi = true, name = "解析完了（ダークモード）",
    uiMode = android.content.res.Configuration.UI_MODE_NIGHT_YES
)
@Composable
private fun PreviewSolvedDark() {
    SudokuSolverTheme {
        val vm = SudokuSolverViewModel().also {
            it.onImageSelected(android.net.Uri.EMPTY)
            it.onSolveFinished("5 3 4 6 7 8 9 1 2\n6 7 2 1 9 5 3 4 8", "", 0)
        }
        SudokuSolverScreen(
            viewModel = vm,
            onGalleryClick = { _ -> },
            onSolveClick = { _, _ -> }
        )
    }
}
