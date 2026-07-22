package com.saikibrain.sudokusolver

import android.content.Context
import android.net.Uri
import android.os.Environment
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.ArrowDropUp
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import java.io.File
import java.text.SimpleDateFormat
import java.util.Locale

private val IMAGE_EXTENSIONS = setOf("jpg", "jpeg", "png", "webp", "heic", "heif", "bmp")

enum class SortKey { DATE, NAME }
enum class SortOrder { ASC, DESC }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FileBrowserSheet(
    initialFolder: File,
    onDismiss: () -> Unit,
    onFileSelected: (Uri) -> Unit,
) {
    val context = LocalContext.current
    val prefs   = remember { context.getSharedPreferences("sudoku_prefs", Context.MODE_PRIVATE) }

    var currentDir by remember { mutableStateOf(initialFolder) }
    var sortKey    by remember {
        mutableStateOf(SortKey.valueOf(prefs.getString("browser_sort_key", SortKey.DATE.name)!!))
    }
    var sortOrder  by remember {
        mutableStateOf(SortOrder.valueOf(prefs.getString("browser_sort_order", SortOrder.DESC.name)!!))
    }

    val entries = remember(currentDir, sortKey, sortOrder) {
        val files = currentDir.listFiles { f ->
            f.isDirectory || f.extension.lowercase() in IMAGE_EXTENSIONS
        } ?: emptyArray()

        val comparator: Comparator<File> = when (sortKey) {
            SortKey.DATE -> compareBy { it.lastModified() }
            SortKey.NAME -> compareBy { it.name.lowercase() }
        }
        val sorted = files.sortedWith(comparator)
        if (sortOrder == SortOrder.DESC) sorted.reversed() else sorted
    }

    val rootDir = remember {
        Environment.getExternalStorageDirectory()
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        modifier = Modifier.fillMaxHeight(0.92f),
    ) {
        // ── ヘッダー ─────────────────────────────────────────────
        Column(modifier = Modifier.padding(horizontal = 16.dp)) {
            Text(
                text = currentDir.absolutePath
                    .removePrefix(rootDir.absolutePath)
                    .ifEmpty { "/" },
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(4.dp))

            // ── ソートバー ───────────────────────────────────────
            Row(verticalAlignment = Alignment.CenterVertically) {
                fun saveSort(key: SortKey, order: SortOrder) {
                    prefs.edit()
                        .putString("browser_sort_key", key.name)
                        .putString("browser_sort_order", order.name)
                        .apply()
                }
                SortChip(
                    label = "日付",
                    selected = sortKey == SortKey.DATE,
                    order = sortOrder,
                    onClick = {
                        val newOrder = if (sortKey == SortKey.DATE) sortOrder.toggle() else SortOrder.DESC
                        sortKey = SortKey.DATE; sortOrder = newOrder
                        saveSort(sortKey, sortOrder)
                    }
                )
                Spacer(Modifier.width(8.dp))
                SortChip(
                    label = "名前",
                    selected = sortKey == SortKey.NAME,
                    order = sortOrder,
                    onClick = {
                        val newOrder = if (sortKey == SortKey.NAME) sortOrder.toggle() else SortOrder.ASC
                        sortKey = SortKey.NAME; sortOrder = newOrder
                        saveSort(sortKey, sortOrder)
                    }
                )

                Spacer(Modifier.weight(1f))

                if (currentDir != rootDir) {
                    TextButton(onClick = { currentDir = currentDir.parentFile ?: rootDir }) {
                        Text("上へ")
                    }
                }
            }
        }

        HorizontalDivider()

        // ── ファイルグリッド ──────────────────────────────────────
        LazyVerticalGrid(
            columns = GridCells.Adaptive(minSize = 100.dp),
            contentPadding = PaddingValues(8.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            items(entries, key = { it.absolutePath }) { file ->
                if (file.isDirectory) {
                    FolderCell(file) { currentDir = file }
                } else {
                    ImageCell(file) { onFileSelected(Uri.fromFile(file)); onDismiss() }
                }
            }
        }
    }
}

@Composable
private fun SortChip(
    label: String,
    selected: Boolean,
    order: SortOrder,
    onClick: () -> Unit,
) {
    val icon = if (order == SortOrder.ASC) Icons.Default.ArrowDropUp
               else Icons.Default.ArrowDropDown
    FilterChip(
        selected = selected,
        onClick = onClick,
        label = { Text(label) },
        trailingIcon = if (selected) ({ Icon(icon, contentDescription = null, modifier = Modifier.size(16.dp)) }) else null,
    )
}

@Composable
private fun FolderCell(dir: File, onClick: () -> Unit) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .clickable(onClick = onClick)
            .padding(4.dp),
    ) {
        Icon(
            Icons.Default.FolderOpen,
            contentDescription = dir.name,
            modifier = Modifier.size(64.dp),
            tint = MaterialTheme.colorScheme.primary,
        )
        Text(
            text = dir.name,
            fontSize = 11.sp,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun ImageCell(file: File, onClick: () -> Unit) {
    val fmt = remember { SimpleDateFormat("MM/dd HH:mm", Locale.getDefault()) }
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .clickable(onClick = onClick)
            .padding(4.dp),
    ) {
        AsyncImage(
            model = file,
            contentDescription = file.name,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .size(90.dp)
                .aspectRatio(1f),
        )
        Spacer(Modifier.height(2.dp))
        Text(
            text = file.name,
            fontSize = 10.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            text = fmt.format(file.lastModified()),
            fontSize = 9.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

private fun SortOrder.toggle() = if (this == SortOrder.ASC) SortOrder.DESC else SortOrder.ASC
