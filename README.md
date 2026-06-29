# SudokuSolver

> このドキュメントは [Claude Code](https://claude.ai/code)（Anthropic）を使用して生成しました。

カメラで撮影した数独の画像を解析し、答えを重ねて表示する Android アプリです。
画像処理・数字認識・解探索は Termux 上の Ruby スクリプトが行い、Android GUI と連携します。

---

## アーキテクチャ

```
Android アプリ (Kotlin / Jetpack Compose)
  │  画像を /sdcard/Download/SudokuSolver/input.jpg にコピー
  │  Termux RUN_COMMAND で sudoku.rb を起動
  ▼
Termux (Ruby + PyCall + OpenCV)
  ├── sudoku.rb       … エントリポイント・JSON 出力
  ├── sudoku_ocr.rb   … 画像処理・数字認識（OCR）
  └── sudoku_solver.rb … 数独ソルバー（ロジック解法 + バックトラック）
  │  処理ステップ画像を /sdcard/Download/SudokuSolver/sudoku_work/ に書き出し
  │  解析結果を JSON で stdout に出力
  ▼
Android アプリ
  FileObserver でステップ画像をリアルタイム表示
  JSON をパースして解答を元画像に重ねて表示
```

---

## Ruby スクリプト構成

| ファイル | 役割 |
|---|---|
| `sudoku.rb` | エントリポイント。引数解析・画像読み込み・各モジュールの呼び出し・JSON 出力 |
| `sudoku_ocr.rb` | 画像前処理・外枠検出・射影補正・テンプレートマッチングによる数字認識 |
| `sudoku_solver.rb` | 数独ソルバー。候補絞り込みロジック + バックトラック（`-r` オプション） |

### 起動方法

```bash
ruby sudoku.rb <画像パス> [出力ディレクトリ] [-r]
```

| オプション | 説明 |
|---|---|
| `-r` / `--retry` | ロジックで解けない場合にバックトラックを使って解く（リトライモード） |

---

## Kotlin ファイル構成

| ファイル | 役割 |
|---|---|
| `MainActivity.kt` | メイン画面・インラインカメラ・Termux 連携 |
| `SudokuSolverViewModel.kt` | 状態管理・FileObserver によるステップ画像の監視 |
| `SettingsScreen.kt` | 解析パラメータの表示・編集・保存 |
| `CameraPreview.kt` | CameraX を使ったインラインカメラプレビュー |

---

## 必要環境

### Android 端末

- Android 8.0 以上
- [Termux](https://f-droid.org/packages/com.termux/)（F-Droid 版を推奨）
- [Termux:API](https://f-droid.org/packages/com.termux.api/)（RUN_COMMAND に必要）

### Termux 内

```bash
pkg install ruby python
pip install opencv-python numpy
gem install pycall
```

---

## セットアップ

### 1. Termux に sshd をインストール

PC から `scp` でファイルを転送するために OpenSSH を導入します。

```bash
pkg install openssh
# パスワードを設定（scp 接続時に使用）
passwd
# sshd を起動（ポート 8022）
sshd
```

Android 端末の IP アドレスを確認しておきます。

```bash
ip addr show wlan0
```

### 2. Termux の作業ディレクトリを作成

```bash
mkdir -p ~/SudokuSolver
```

### 3. スクリプト・テンプレートをデプロイ

`scripts/` フォルダの全ファイル を Termux の `~/SudokuSolver/` にコピーします。

```bash
# PC 側で実行（<IP> は手順 1 で確認した Android 端末の IP アドレス）
scp -P 8022 scripts/* sudoku_template.png <IP>:~/SudokuSolver/
```

`~/SudokuSolver/` に以下が揃っていれば完了です。

```
~/SudokuSolver/
├── sudoku.rb
├── sudoku_ocr.rb
├── sudoku_solver.rb
├── sudoku_params.json
└── sudoku_template.png
```

### 4. 解析パラメータを配置（任意）

`scripts/sudoku_params.json` はデフォルト値のサンプルです。
カスタマイズする場合は以下にコピーしてください。

```bash
cp scripts/sudoku_params.json /sdcard/Download/SudokuSolver/sudoku_params.json
```

アプリ内の「設定」画面からも編集・保存できます。

### 5. アプリのパーミッション設定

初回起動時に以下を許可してください。

- **すべてのファイルへのアクセス**（Android 11 以上）
  設定 → アプリ → SudokuSolver → 権限 → ファイルとメディア
- **Termux:RUN_COMMAND**
  アプリ起動時にダイアログが表示されます

---

## ファイル構成

```
SudokuSolver/
├── app/                        Android アプリ本体
│   └── src/main/java/.../
│       ├── MainActivity.kt         メイン画面・インラインカメラ・Termux 連携
│       ├── SudokuSolverViewModel.kt 状態管理・FileObserver
│       ├── SettingsScreen.kt        パラメータ設定画面
│       └── CameraPreview.kt         CameraX インラインプレビュー
└── scripts/                    Termux にデプロイする Ruby スクリプト
    ├── sudoku.rb               エントリポイント
    ├── sudoku_ocr.rb           画像処理・数字認識
    ├── sudoku_solver.rb        数独ソルバー
    └── sudoku_params.json      解析パラメータのデフォルト値サンプル
```

---

## 共有ディレクトリ

Android ↔ Termux 間のファイルやり取りは `/sdcard/Download/SudokuSolver/` を使います。

| ファイル | 内容 |
|---|---|
| `input.jpg` | アプリが書き出す解析対象画像 |
| `sudoku_work/01_binary.png` 〜 `08_result.png` | 処理ステップ画像 |
| `sudoku_params.json` | 解析パラメータ（アプリの設定画面で編集可） |

---

## 数独盤面の画像処理アルゴリズム

撮影画像から数独の盤面を認識するまでの処理を 8 ステップで行います。
各ステップの中間画像は `sudoku_work/` に保存され、アプリ上で確認できます。

### ① 二値化（`01_binary.png`）

```
カラー画像
  → グレースケール変換
  → GaussianBlur（カーネルサイズ = 短辺 ÷ blur_kernel_divisor）
  → adaptiveThreshold（ADAPTIVE_THRESH_MEAN_C）
  → 二値化画像（白=線・数字、黒=背景）
```

照明ムラに強い適応的二値化を使うことで、撮影環境に依存しにくくしています。

### ② 外枠抽出（`02_frame_candidates.png` / `02_frame.png`）・数字のみ（`03_digits_only.png`）

```
二値化画像
  → connectedComponentsWithStats で連結成分を取得
  → 面積上位候補を色分けして可視化（02_frame_candidates.png）
  → 最大面積かつ十分なサイズ（短辺の frame_min_ratio 以上）の領域を外枠と判定
  → 外枠を除去 → 数字のみの画像（03_digits_only.png）
  → 外枠のみの画像（02_frame.png）
```

### ③ 最大輪郭の可視化（`04_contour.png`）

```
外枠画像
  → findContours で外側輪郭をすべて取得
  → 最大面積の輪郭を選択
  → 輪郭上の全点を赤い小丸でプロット
```

コーナー検出前に輪郭の形状・欠けを目視確認するためのステップです。

### ④ コーナー検出（`05_corners.png`）

```
外枠画像（最大輪郭）
  → approxPolyDP（Ramer-Douglas-Peucker）で 4 点に近似
      ε = 輪郭周長 × 2%〜12% を段階的に試して 4 点になった時点で採用
  → 重心を基準に時計回りにソート
```

ε を段階的に広げることで、輪郭に多少の欠けがあっても安定して 4 点に収束します。
デバッグ画像には二値化画像の上にコーナー位置のサークルと番号を重ねて表示します。

### ⑤ 射影補正（`06_warped.png`）

```
4 コーナー座標
  → getPerspectiveTransform で変換行列を計算
  → warpPerspective で正方形に変換（余白 warp_margin = 5%）
```

台形歪みや傾きを補正し、以降の処理を正方形グリッド前提で行えるようにします。

### ⑥ 数字認識（`07_recognized.png`）

```
補正済み画像を 10×10 の仮想グリッドに分割（セル中心は 1〜9 番目の交点）
各セルについて：
  1. セル中心を cell_crop_ratio 倍の範囲で切り出し
  2. 暗い画素の割合 < blank_dark_ratio → 空白セルとして skip
  3. テンプレートに合わせてリサイズして float32 に変換
  4. matchTemplate（TM_SQDIFF_NORMED）でテンプレートの上段・下段それぞれとマッチング
  5. スコアが低い（match_score_threshold 未満）かつ
     オフセットが有効範囲（match_off_x_min 〜 match_off_x_max）内なら数字として採用
  6. 穴の数・縦方向の重心で 6/9 を判別
```

テンプレート画像は 1〜9 の数字を上下 2 段（フォント違い）で並べた 1 枚の PNG です。

### ⑦ 解探索

```
認識結果（9×9 配列）
  → 候補絞り込みロジック（naked single / hidden single / X-Wing / XY-Chain 等）
  → 解けない場合は -r オプション指定時のみバックトラックを適用
```

解探索の過程はアプリの「解探索過程」セクションで確認できます。

### ⑧ 解答の重ね合わせ（`08_result.png`）

```
解答数字をオーバーレイ画像（透明背景）に描画
  → warpPerspective の逆変換で元画像座標系に戻す
  → マスクを使って元画像に合成
```

射影変換の逆行列を使うことで、補正済み座標で描いた解答を元の撮影画像に正確に重ねます。

---

## 解析パラメータ

| キー | デフォルト | 説明 |
|---|---|---|
| `blur_kernel_divisor` | 130 | GaussianBlur カーネルサイズ = 短辺 ÷ この値 |
| `adaptive_block_divisor` | 30 | adaptiveThreshold ブロックサイズ = 短辺 ÷ この値 |
| `adaptive_c` | 10 | adaptiveThreshold の定数 C |
| `frame_min_ratio` | 0.667 | 外枠として認める最小サイズ（画像短辺に対する比率） |
| `warp_margin` | 0.05 | 射影補正後の余白率 |
| `blank_dark_ratio` | 0.02 | 空白セル判定しきい値 |
| `cell_crop_ratio` | 0.45 | セル切り出し比率 |
| `match_score_threshold` | 0.5 | マッチスコアしきい値 |
| `match_off_x_min` | 0.2 | 数字位置オフセット下限 |
| `match_off_x_max` | 0.8 | 数字位置オフセット上限 |

---
