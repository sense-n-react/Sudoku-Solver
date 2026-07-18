package com.saikibrain.sudokusolver

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import org.json.JSONObject
import java.io.File

// ── パラメータ定義 ────────────────────────────────────────────
data class ParamDef(
    val key: String,
    val label: String,
    val description: String,
    val defaultValue: Double,
    val min: Double,
    val max: Double,
    val isInt: Boolean = false
)

val PARAM_DEFS = listOf(
    ParamDef("blur_kernel_divisor",    "ぼかし強度（除数）",     "GaussianBlur カーネルサイズ = 短辺 ÷ この値",    130.0, 50.0,  300.0, isInt = true),
    ParamDef("adaptive_block_divisor", "二値化ブロック（除数）", "adaptiveThreshold ブロックサイズ = 短辺 ÷ この値", 30.0,  10.0,  100.0, isInt = true),
    ParamDef("adaptive_c",             "二値化定数 C",           "adaptiveThreshold の定数 C（大きいほど暗い画素を除去）", 10.0, 1.0, 30.0, isInt = true),
    ParamDef("frame_min_ratio",        "外枠最小サイズ比",       "外枠として認める最小サイズ（画像短辺に対する比率）", 0.667, 0.3, 0.95),
    ParamDef("blank_dark_ratio",       "空白セル判定しきい値",   "暗い画素の割合がこれ以下なら空白セルと判定",       0.02,  0.0,  0.2),
    ParamDef("match_score_threshold",  "マッチスコアしきい値",   "min/max がこれ以上なら認識失敗と判定",             0.5,   0.1,  0.9),
    ParamDef("match_off_x_min",        "オフセット下限",         "数字位置オフセットの下限（これ以下は棄却）",       0.2,   0.0,  0.4),
    ParamDef("match_off_x_max",        "オフセット上限",         "数字位置オフセットの上限（これ以上は棄却）",       0.8,   0.6,  1.0),
)

// ── 設定画面 ─────────────────────────────────────────────────
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    sharedDir: String,
    onBack: () -> Unit
) {
    // 表示用の入力文字列 Map（キー → 入力中テキスト）
    val textValues = remember { mutableStateMapOf<String, String>() }
    var loadError  by remember { mutableStateOf<String?>(null) }
    var saveResult by remember { mutableStateOf<String?>(null) }

    // 画面表示時に JSON を読み込む
    LaunchedEffect(Unit) {
        val json = loadParamsJson(sharedDir)
        PARAM_DEFS.forEach { def ->
            val v = if (json.has(def.key)) json.getDouble(def.key) else def.defaultValue
            textValues[def.key] = if (def.isInt) v.toInt().toString() else v.toString()
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("解析パラメータ設定") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "戻る")
                    }
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            loadError?.let {
                Text(it, color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.padding(vertical = 8.dp))
            }

            PARAM_DEFS.forEach { def ->
                ParamRow(
                    def        = def,
                    text       = textValues[def.key] ?: def.defaultValue.toString(),
                    onTextChange = { textValues[def.key] = it }
                )
            }

            Spacer(modifier = Modifier.height(16.dp))

            // 保存ボタン
            Button(
                onClick = {
                    saveResult = saveParamsJson(sharedDir, textValues)
                },
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("保存")
            }

            // リセットボタン
            OutlinedButton(
                onClick = {
                    PARAM_DEFS.forEach { def ->
                        textValues[def.key] = if (def.isInt)
                            def.defaultValue.toInt().toString()
                        else
                            def.defaultValue.toString()
                    }
                    saveResult = "デフォルト値に戻しました（未保存）"
                },
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("デフォルトに戻す")
            }

            saveResult?.let {
                Text(it,
                    color = if (it.startsWith("保存")) MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.secondary,
                    modifier = Modifier.padding(vertical = 8.dp))
            }

            Spacer(modifier = Modifier.height(32.dp))
        }
    }
}

// ── 1パラメータ行 ────────────────────────────────────────────
@Composable
fun ParamRow(def: ParamDef, text: String, onTextChange: (String) -> Unit) {
    val numVal  = text.toDoubleOrNull()
    val isError = numVal == null || numVal < def.min || numVal > def.max

    Column(modifier = Modifier.padding(vertical = 4.dp)) {
        OutlinedTextField(
            value         = text,
            onValueChange = onTextChange,
            label         = { Text(def.label) },
            supportingText = {
                Text(
                    if (isError) "範囲: ${fmtNum(def.min, def.isInt)} 〜 ${fmtNum(def.max, def.isInt)}"
                    else         def.description,
                    color = if (isError) MaterialTheme.colorScheme.error
                            else        MaterialTheme.colorScheme.onSurfaceVariant
                )
            },
            isError       = isError,
            keyboardOptions = KeyboardOptions(keyboardType =
                if (def.isInt) KeyboardType.Number else KeyboardType.Decimal),
            modifier      = Modifier.fillMaxWidth(),
            singleLine    = true
        )
    }
}

private fun fmtNum(v: Double, isInt: Boolean) = if (isInt) v.toInt().toString() else v.toString()

// ── JSON 読み書き ────────────────────────────────────────────
private fun loadParamsJson(sharedDir: String): JSONObject {
    val file = File(sharedDir, "sudoku_params.json")
    return if (file.exists()) {
        try { JSONObject(file.readText()) } catch (e: Exception) { JSONObject() }
    } else {
        JSONObject()
    }
}

private fun saveParamsJson(sharedDir: String, values: Map<String, String>): String {
    return try {
        val json = JSONObject()
        PARAM_DEFS.forEach { def ->
            val text = values[def.key] ?: return@forEach
            val num  = text.toDoubleOrNull() ?: return@forEach
            if (def.isInt) json.put(def.key, num.toInt())
            else           json.put(def.key, num)
        }
        val file = File(sharedDir, "sudoku_params.json")
        file.parentFile?.mkdirs()
        file.writeText(json.toString(2))
        "保存しました"
    } catch (e: Exception) {
        "保存失敗: ${e.message}"
    }
}
