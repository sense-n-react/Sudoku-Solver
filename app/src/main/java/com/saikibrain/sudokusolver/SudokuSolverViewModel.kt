package com.saikibrain.sudokusolver

import android.net.Uri
import android.os.Build
import android.os.FileObserver
import androidx.lifecycle.ViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject
import java.io.File

data class ProcessingStep(
    val label: String,
    val uri: Uri
)

enum class SolverState {
    Idle,
    Processing,
    Solved,
    Error
}

class SudokuSolverViewModel : ViewModel() {

    private val _imageUri = MutableStateFlow<Uri?>(null)
    val imageUri: StateFlow<Uri?> = _imageUri.asStateFlow()

    /** 元の入力画像 URI（再解析ボタン用・ファイル名表示用） */
    private val _originalImageUri = MutableStateFlow<Uri?>(null)
    val originalImageUri: StateFlow<Uri?> = _originalImageUri.asStateFlow()

    private val _processingSteps = MutableStateFlow<List<ProcessingStep>>(emptyList())
    val processingSteps: StateFlow<List<ProcessingStep>> = _processingSteps.asStateFlow()

    private val _solverState = MutableStateFlow(SolverState.Idle)
    val solverState: StateFlow<SolverState> = _solverState.asStateFlow()

    private val _statusMessage = MutableStateFlow("")
    val statusMessage: StateFlow<String> = _statusMessage.asStateFlow()

    private val _solverOutput = MutableStateFlow("")
    val solverOutput: StateFlow<String> = _solverOutput.asStateFlow()

    private val _solveProcess = MutableStateFlow("")
    val solveProcess: StateFlow<String> = _solveProcess.asStateFlow()

    // ── FileObserver ────────────────────────────────────────────
    private var fileObserver: FileObserver? = null

    /** Ruby の save_step が書き出すファイル名 → ステップ表示ラベルの対応 */
    private val stepLabelMap = mapOf(
        "01_binary.png"               to "二値化",
        "02_frame_candidates.png"     to "外枠候補",
        "02_frame.png"                to "枠線抽出",
        "03_digits_only.png"          to "数字のみ",
        "04_contour.png"     to "最大輪郭",
        "05_corners.png"     to "コーナー検出",
        "06_warped.png"      to "射影補正",
        "07_recognized.png"  to "数字認識",
        "08_result.png"      to "解答",
    )

    // ── 公開 API ────────────────────────────────────────────────

    fun onImageSelected(uri: Uri) {
        _originalImageUri.value = uri
        _imageUri.value = uri
        // 選択画像を最初のステップとして登録
        _processingSteps.value = listOf(ProcessingStep("入力画像", uri))
        _solverState.value = SolverState.Idle
        _statusMessage.value = ""
        _solverOutput.value = ""
        _solveProcess.value = ""
    }

    /**
     * 解析開始。watchDir を渡すと FileObserver を起動してステップ画像をリアルタイム表示する。
     * 再解析時は入力画像ステップを保持してから以降をリセットする。
     */
    fun onSolveStarted(watchDir: String = "") {
        // 先頭の「入力画像」ステップだけ残して他はクリア
        val inputStep = _processingSteps.value.firstOrNull()
        _processingSteps.value = if (inputStep != null) listOf(inputStep) else emptyList()
        // プレビューを入力画像に戻す
        _imageUri.value = _originalImageUri.value
        _solverState.value = SolverState.Processing
        _statusMessage.value = "解析中..."
        if (watchDir.isNotBlank()) startWatchingDir(watchDir)
    }

    /** ステップ画像がタップされたらプレビューに表示 */
    fun onStepSelected(step: ProcessingStep) {
        _imageUri.value = step.uri
    }

    /**
     * Termux からの完了通知。stdout は Ruby が出力した JSON。
     * FileObserver でステップは既に表示済みなので、ここでは状態更新とエラー処理のみ行う。
     */
    fun onSolveFinished(stdout: String, stderr: String, exitCode: Int) {
        stopWatchingDir()

        if (exitCode != 0 || stdout.isBlank()) {
            _solverState.value = SolverState.Error
            _statusMessage.value = "エラー (exit: $exitCode)"
            _solverOutput.value = buildString {
                if (stdout.isNotBlank()) append(stdout)
                if (stderr.isNotBlank()) {
                    if (isNotEmpty()) append("\n")
                    append("[stderr]\n$stderr")
                }
            }
            return
        }

        try {
            val json = JSONObject(stdout)
            if (json.optBoolean("success", false)) {
                // FileObserver が07_result.pngを捕捉できなかった場合のフォールバック
                if (_processingSteps.value.none { it.label == "解答" }) {
                    val stepsJson = json.optJSONArray("steps")
                    if (stepsJson != null) {
                        val inputStep = _processingSteps.value.firstOrNull()
                        val steps = buildList {
                            if (inputStep != null) add(inputStep)
                            for (i in 0 until stepsJson.length()) {
                                val s = stepsJson.getJSONObject(i)
                                val path = s.optString("path", "")
                                if (path.isNotBlank()) {
                                    add(ProcessingStep(s.optString("label", "step$i"),
                                        Uri.fromFile(File(path))))
                                }
                            }
                        }
                        _processingSteps.value = steps
                        steps.lastOrNull()?.let { _imageUri.value = it.uri }
                    }
                }
                _solverState.value = SolverState.Solved
                _statusMessage.value = "解析完了 ✓"
                _solverOutput.value = ""
                _solveProcess.value = json.optString("process", "")

            } else {
                val error = json.optString("error", "不明なエラー")
                val backtrace = json.optJSONArray("backtrace")
                _solverState.value = SolverState.Error
                _statusMessage.value = "解析失敗: $error"
                _solverOutput.value = buildString {
                    append(error)
                    if (backtrace != null && backtrace.length() > 0) {
                        append("\n\n[バックトレース]\n")
                        for (i in 0 until backtrace.length()) append("  ${backtrace.getString(i)}\n")
                    }
                    if (stderr.isNotBlank()) append("\n[stderr]\n$stderr")
                }
            }

        } catch (e: Exception) {
            _solverState.value = SolverState.Error
            _statusMessage.value = "出力の解析に失敗"
            _solverOutput.value = buildString {
                append(stdout)
                if (stderr.isNotBlank()) append("\n[stderr]\n$stderr")
            }
        }
    }

    /** 再解析時に元の入力画像 URI を返す */
    fun getOriginalImageUri(): Uri? = _originalImageUri.value

    override fun onCleared() {
        super.onCleared()
        stopWatchingDir()
    }

    // ── FileObserver 管理（private） ─────────────────────────────

    private fun startWatchingDir(dirPath: String) {
        stopWatchingDir()
        val dir = File(dirPath).also { it.mkdirs() }
        val observer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            object : FileObserver(dir, CLOSE_WRITE) {
                override fun onEvent(event: Int, path: String?) = onFileWritten(dirPath, path)
            }
        } else {
            @Suppress("DEPRECATION")
            object : FileObserver(dirPath, CLOSE_WRITE) {
                override fun onEvent(event: Int, path: String?) = onFileWritten(dirPath, path)
            }
        }
        observer.startWatching()
        fileObserver = observer
    }

    private fun onFileWritten(dirPath: String, filename: String?) {
        val label = stepLabelMap[filename] ?: return
        val file  = File(dirPath, filename!!)
        val step  = ProcessingStep(label, Uri.fromFile(file))

        val current = _processingSteps.value
        if (current.any { it.label == label }) return
        _processingSteps.value = current + step

        // 解答ステップはメインプレビューにも反映
        if (filename == "08_result.png") {
            _imageUri.value = Uri.fromFile(file)
        }
    }

    private fun stopWatchingDir() {
        fileObserver?.stopWatching()
        fileObserver = null
    }
}
