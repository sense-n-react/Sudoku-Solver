# sudoku_ocr.rb
#
# 数独画像から数字を認識する OCR モジュール
# 依存: pycall gem + Python opencv-python

require 'pycall/import'
require 'fileutils'
require 'json'

include PyCall::Import
pyimport :cv2
pyimport :numpy, as: :np

# ── Python ヘルパー ───────────────────────────────────────────
PyCall.exec(<<~PYTHON)
  import cv2, numpy as np

  # ── CV2.xxx : cv2 API ラッパー ───────────────────────────────
  def put_text(img, text, x, y, font, scale, b, g, r, thickness):
      cv2.putText(img, str(text), (int(x), int(y)), font, scale, (b, g, r), int(thickness))

  def circle(img, x, y, radius, b, g, r, thickness):
      cv2.circle(img, (int(x), int(y)), int(radius), (b, g, r), int(thickness))

  def rectangle(img, x1, y1, x2, y2, val, thickness):
      cv2.rectangle(img, (int(x1), int(y1)), (int(x2), int(y2)), val, int(thickness))

  def threshold(img, thresh, maxval, typ):
      _, result = cv2.threshold(img, thresh, maxval, typ)
      return result

  def flood_fill(img, mask, x, y, new_val):
      area, _, _, rect = cv2.floodFill(
          img, mask, (int(x), int(y)), new_val,
          loDiff=0, upDiff=0, flags=cv2.FLOODFILL_FIXED_RANGE)
      return [int(area), list(rect)]

  def resize(img, w, h):
      return cv2.resize(img, (int(w), int(h)), interpolation=cv2.INTER_AREA)

  def contour_area(contour):
      return float(cv2.contourArea(contour))

  def find_nonzero(img):
      return cv2.findNonZero(img)

  def bounding_rect(coords):
      x, y, w, h = cv2.boundingRect(coords)
      return [x, y, w, h]

  def match_template(tmpl_f, cell_r):
      return cv2.matchTemplate(tmpl_f, cell_r, cv2.TM_SQDIFF_NORMED)

  def bgr_to_gray(img):
      return cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)

  def arc_length(contour, closed):
      return float(cv2.arcLength(contour, closed))

  def approx_poly_dp(contour, epsilon, closed):
      return cv2.approxPolyDP(contour, epsilon, closed)

  # ── PY.xxx : numpy 操作 ──────────────────────────────────────
  class _PY:
    @staticmethod
    def crop(img, y1, y2, x1, x2):
        return img[int(y1):int(y2), int(x1):int(x2)].copy()

    @staticmethod
    def zeros3(h, w):
        return np.zeros((int(h), int(w), 3), dtype=np.uint8)

    @staticmethod
    def full_gray(h, w, val):
        return np.full((int(h), int(w)), int(val), dtype=np.uint8)

    @staticmethod
    def shape(img):
        return list(img.shape)

    @staticmethod
    def count_dark( img, thr=100 ):
        return int( np.sum( img < thr ) )

    @staticmethod
    def astype_float32(img):
        return img.astype(np.float32)

    @staticmethod
    def img_copy(img):
        return img.copy()

    @staticmethod
    def contour_pts(contour):
        return contour.reshape(-1, 2).tolist()

    @staticmethod
    def normalize_u8(img):
        out = np.zeros(img.shape, dtype=np.uint8)
        cv2.normalize(img, out, 0, 255, cv2.NORM_MINMAX, cv2.CV_8U)
        return out

    @staticmethod
    def apply_mask_color(canvas, mask, dx, dy, sx, sy, w, h, color):
        roi = canvas[dy:dy+h, dx:dx+w]
        m   = mask[sy:sy+h, sx:sx+w]
        roi[m > 0] = color

    @staticmethod
    def copy_where(dst, src, mask):
        dst[mask > 0] = src[mask > 0]

    @staticmethod
    def count_template_rows(tmpl, cell_w):
        # 列1（数字"1"）を縦スキャンして暗ピクセルがある行を検出し、連続する塊を数える
        cw = int(cell_w)
        col1 = tmpl[:, cw:cw*2]
        has_dark = np.any(col1 < 200, axis=1)
        # 連続する True の塊の数 = 行数
        count = 0
        in_block = False
        for v in has_dark:
            if v and not in_block:
                count += 1
                in_block = True
            elif not v:
                in_block = False
        return max(count, 1)

PYTHON

#
# PyObject と Ruby型 との変換が必要な pyCall は CV2.xxxx あるいは PY.xxxx で呼び出す。
# OpenCV に関する pyCall は CV2.xxxx、それ以外は PY.xxxx
#
CV2 = PyCall.import_module('__main__')
PY  = CV2._PY

# ── パラメータ（デフォルト値） ────────────────────────────────
PARAMS = {
  "blur_kernel_divisor"   => 130,    # GaussianBlur カーネルサイズ = 短辺 / この値（奇数に丸め）
  "adaptive_block_divisor"=> 30,     # adaptiveThreshold ブロックサイズ = 短辺 / この値（奇数に丸め）
  "adaptive_c"            => 10,     # adaptiveThreshold の定数 C
  "frame_min_ratio"       => 0.667,  # 外枠として認める最小サイズ（画像短辺に対する比率）
  "warp_margin"           => 0.05,   # 射影補正後の余白率（0.05 = 5%）
  "blank_dark_ratio"      => 0.06,   # 細長くない成分の面積比閾値（これ以下なら空白と判定）
  "cell_crop_ratio"       => 0.45,   # セル切り出しサイズ（cell_w の何倍か）
  "match_score_threshold" => 0.5,    # マッチスコア（min/max）がこれ以上なら棄却
  "match_off_x_min"       => 0.2,    # 数字位置のオフセット下限
  "match_off_x_max"       => 0.8,    # 数字位置のオフセット上限
}

# PARAMS を sudoku_params.json で上書きする
def load_params
  path = File.join( @output_dir, "sudoku_params.json")
  user = File.exist?(path) ? JSON.parse(File.read(path)) : {}
  debug_puts "#{user}"
  PARAMS.merge!(user)
rescue JSON::ParserError
  PARAMS
end

# ── 定数 ──────────────────────────────────────────────────────
FIRST_THRESH = 128
HOLE_MAX_ASPECT = 3.0  # 穴の長辺/短辺がこれを超えたらゴミとして除外

# 画像をファイルに保存
def save_step( img, name, label = nil )
  path = File.join( @output_dir, name )
  cv2.imwrite( path, img )
  if label.to_s != ''
    @steps ||= []
    @steps << { label: label, path: path }
  end
end

# デバッグ文
def debug_puts msg
  $stderr.puts msg  if ENV['SUDOKU_DEBUG'] == '1'
end

# --
# ── 前処理
# --
#    ニ値化して 背景：黒、 数字・枠：グレー にする
def preprocess( img )
  gray = cv2.cvtColor( img, cv2.COLOR_BGR2GRAY )  # grayスケールに変換
  h, w = PY.shape(gray).to_a.map(&:to_i)
  k = [[w, h].min / PARAMS["blur_kernel_divisor"], 3].max
  k += 1 if k.even?
  blurred = cv2.GaussianBlur(gray, [k, k], 0)
  bs = [[w, h].min / PARAMS["adaptive_block_divisor"], 7].max
  bs += 1 if bs.even?
  inv = cv2.adaptiveThreshold(
    blurred, FIRST_THRESH,
    cv2.ADAPTIVE_THRESH_MEAN_C, cv2.THRESH_BINARY_INV,
    bs, PARAMS["adaptive_c"]
  )
  [gray, inv]
end

# --
# ── 外枠を検出
# --
def detect_frame( inv )
  n, labels, stats, _ = cv2.connectedComponentsWithStats(inv, connectivity: 8).to_a
  return nil if n.to_i <= 1

  # 面積上位3候補を取得
  top3 = (1...n.to_i)
           .sort_by { |i| -stats.item(i, cv2.CC_STAT_AREA).to_i }
           .first(3)

  mask_for = ->(label) {
    cv2.compare(labels, np.full(PY.shape(labels), label, dtype: np.int32), cv2.CMP_EQ)
  }

  # 上位3候補を色分けして1枚に重ねて保存（青=1位, 緑=2位, 赤=3位）
  h, w = PY.shape(inv).to_a.map(&:to_i)
  canvas = PY.zeros3(h, w)
  [[255,0,0],[0,255,0],[0,0,255]].each_with_index do |color, idx|
    break if idx >= top3.size
    PY.apply_mask_color(canvas, mask_for.(top3[idx]), 0, 0, 0, 0, w, h, color)
  end
  save_step(canvas, "02_frame_candidates.png", "外枠候補（青=1位 緑=2位 赤=3位）")

  mask_for.(top3.first)
end

# --
# ── 外枠の4コーナーを検出
# --
def detect_corners( outer)
  # approxPolyDP で4点に近似（ε を段階的に広げながら試みる）
  peri    = CV2.arc_length(outer, true)
  corners = [ 0.02, 0.03, 0.04, 0.05, 0.06, 0.08, 0.10, 0.12 ].
    each_with_object(nil) do |eps_ratio|
      approx = CV2.approx_poly_dp(outer, eps_ratio * peri, true)
      pts    = PY.contour_pts(approx).to_a.map { |p| p.to_a.map(&:to_f) }
      break pts  if pts.size == 4
    end
  return nil unless corners

  # 重心からの角度で時計回りにソート（getPerspectiveTransform の src/dst 対応を合わせるため）
  cx, cy = corners.transpose.map { |coords| coords.sum.fdiv(coords.size) }
  corners.sort_by { |x, y| Math.atan2(y - cy, x - cx) % (2 * Math::PI) }
end

# --
# ── 台形画像 <-> 正方形 変換のための射影変換
# --
def get_perspective_transform( corners, sq_size )
  margin   = PARAMS["warp_margin"].to_f
  hi, lo = sq_size * ( 1.0 - margin ), sq_size * margin
  src = np.array( corners.map { |p| p.map(&:to_f) },     dtype: np.float32 )
  dst = np.array( [[ hi,hi], [lo,hi], [lo,lo], [hi,lo]], dtype: np.float32 )
  cv2.getPerspectiveTransform( src, dst )
end

# 数字認識の方法
#
# 数字のテンプレート画像を用意する
# +------------------------------+
# | 0  1  2  3  4  5  6  7  8  9 |
# | 0  1  2  3  4  5  6  7  8  9 |  <- 異なるフォント
# +------------------------------+
#
# １セルの画像がテンプレート上で最もマッチした位置のX座標で数値を判定する
# 5,6,8,9 の誤認識対策
#   穴の数： 0 -> 5, 2 -> 8、 1 -> 6 or 9
#   穴位置：穴の重心位置が数字画像の中心より上 -> 9、 下 -> 6 ので判定する

@tmpl_data = {}

# --
# -- テンプレートから digit n (1-9) の最小バウンディングボックス画像を取得
# --
def template_digit_img( tmpl_gray, n, num_rows )
  th, tw = PY.shape(tmpl_gray).to_a.map(&:to_i)
  cw    = tw / 10
  row_h = (th - cw / 2) / num_rows

  best_img  = nil
  best_area = Float::INFINITY

  num_rows.times.map { |i| [i * row_h, (i + 1) * row_h] }.each do |r1, r2|
    col    = PY.crop( tmpl_gray, r1, r2, n * cw, (n + 1) * cw)
    bw     = CV2.threshold( col, 128, 255, cv2.THRESH_BINARY_INV )
    coords = CV2.find_nonzero( bw )
    next unless coords
    rx, ry, rw, rh = CV2.bounding_rect(coords).to_a.map(&:to_i)
    next if rw == 0 || rh == 0
    area = rw * rh
    if area < best_area
      best_img  = PY.crop(col, ry, ry + rh, rx, rx + rw)
      best_area = area
    end
  end

  best_img || PY.full_gray(cw, cw, 255)
end

# --
# -- 数字テンプレートのロード
# --
def load_digit_template
  path = File.join(__dir__, "sudoku_template.png")
  raise "テンプレート画像:#{path} が見つかりません。 " unless File.exist?(path)

  tmpl          = cv2.imread( path, cv2.IMREAD_GRAYSCALE )
  raise "テンプレート画像を読み込めませんでした: #{path}" unless tmpl

  th, tw = PY.shape(tmpl).to_a.map(&:to_i)
  cell_w   = tw / 10
  num_rows = PY.count_template_rows(tmpl, cell_w).to_i

  # 5/6/8/9 それぞれをマスク（白で塗り潰し）したテンプレートを事前生成
  masked_tmpls_py = [5, 6, 8, 9].to_h do |n|
    masked = PY.img_copy(tmpl)
    cv2.rectangle(masked, [n * cell_w, 0], [(n + 1) * cell_w, th], 255, cv2.FILLED)
    [n, PY.astype_float32(masked)]
  end

  @tmpl_data = {
    cell_w:          cell_w,
    num_rows:        num_rows,
    tmpl_f_py:       PY.astype_float32( tmpl ),
    digit_imgs_py:   (1..9).map { |n| template_digit_img( tmpl, n, num_rows ) },
    masked_tmpls_py: masked_tmpls_py,
  }
end

HOLE_MIN_AREA_RATIO = 0.01  # 画像面積に対する穴の最小面積比率

# --
# -- 数字の穴の数
# --
#  白背景・黒文字のセル画像から穴（閉じた白領域）の数を返す
#
# セル中央部分（上下左右 margin 割合を除いた領域）を返す。
# 枠線残滓（縦線・四角・L字・U字）は端に偏るためこの操作で除外できる。
# バウンディングボックス切り出しはしない（切り出すと曲線部とboxコーナーで
# 偽の穴ができるため）。
def digit_region(cell_bin, margin: 0.00)
  h, w = PY.shape(cell_bin).to_a.map(&:to_i)
  dy = (h * margin).to_i
  dx = (w * margin).to_i
  PY.crop(cell_bin, dy, h - dy, dx, w - dx)
end

def count_holes(cell_bin, debug_name: nil)
  save_step(cell_bin, "#{debug_name}_cell_bin_before.png")

  cell_bin = digit_region(cell_bin)

  save_step(cell_bin, "#{debug_name}_cell_bin_digit.png")
  # 1px 白パディングを追加して外背景を必ず全周でつなげる。
  # これにより数字が画像端に接していても外背景と孤立した穴が正しく分離される。
  cell_bin = cv2.copyMakeBorder(cell_bin, 1, 1, 1, 1, cv2.BORDER_CONSTANT, value: 255)
    save_step(cell_bin, "#{debug_name}_cell_bin_after.png")

  # 白背景・黒数字の画像で白領域を数える
  # label0=黒ストローク, label1=外背景, label2以降=穴（小さいゴミは除外）
  h, w = PY.shape(cell_bin).to_a.map(&:to_i)
  min_area = h * w * HOLE_MIN_AREA_RATIO
  n, labels, stats, _ = cv2.connectedComponentsWithStats(cell_bin, connectivity: 4).to_a
  holes = (2...n.to_i).count do |lbl|
    area = stats.item(lbl, cv2.CC_STAT_AREA).to_i
    bw   = stats.item(lbl, cv2.CC_STAT_WIDTH).to_i
    bh   = stats.item(lbl, cv2.CC_STAT_HEIGHT).to_i
    long_side  = [bw, bh].max
    short_side = [bw, bh].min
    aspect = short_side > 0 ? long_side.to_f / short_side : Float::INFINITY
    area >= min_area && aspect <= HOLE_MAX_ASPECT
  end

  if ENV['SUDOKU_DEBUG'] == '1' && debug_name
    colors = [[0,0,0], [200,200,200], [0,0,255], [0,255,0], [255,0,0]]
    canvas = PY.zeros3(h, w)
    (0...n.to_i).each do |lbl|
      area  = stats.item(lbl, cv2.CC_STAT_AREA).to_i
      bw2 = stats.item(lbl, cv2.CC_STAT_WIDTH).to_i
      bh2 = stats.item(lbl, cv2.CC_STAT_HEIGHT).to_i
      ls  = [bw2, bh2].max; ss = [bw2, bh2].min
      asp = ss > 0 ? ls.to_f / ss : Float::INFINITY
      color = if lbl < 2 then colors[lbl]
              elsif area >= min_area && asp <= HOLE_MAX_ASPECT then [0, 0, 255]   # 有効な穴=赤
              else [0, 165, 255]                                                   # ゴミ=オレンジ
              end
      mask  = cv2.compare(labels, np.full(PY.shape(labels), lbl, dtype: np.int32), cv2.CMP_EQ)
      PY.apply_mask_color(canvas, mask, 0, 0, 0, 0, w, h, color)
    end
    save_step(canvas, "#{debug_name}_count_holes.png")
  end

  holes
end

# --
# -- 6/9 の判定
# --
#   穴が1個のとき 6 か 9 かを穴の位置で判定
#   穴の重心位置が数字画像の中心より上 -> 9、 下 -> 6
#
def six_or_nine( cell_bin, debug_name: nil )
  inner = digit_region(cell_bin)
  h, w  = PY.shape(inner).to_a.map(&:to_i)

  # 数字本体の縦中心を最大CCのバウンディングボックスから求める
  nc, _lc, sc_cc, _ = cv2.connectedComponentsWithStats(cv2.bitwise_not(inner), connectivity: 8).to_a
  digit_mid_y = if nc.to_i >= 2
    dl  = (1...nc.to_i).max_by { |lbl| sc_cc.item(lbl, cv2.CC_STAT_AREA).to_i }
    by2 = sc_cc.item(dl, cv2.CC_STAT_TOP).to_i
    bh2 = sc_cc.item(dl, cv2.CC_STAT_HEIGHT).to_i
    by2 + bh2 / 2.0
  else
    h / 2.0
  end

  padded = cv2.copyMakeBorder(inner, 1, 1, 1, 1, cv2.BORDER_CONSTANT, value: 255)
  ph, pw = PY.shape(padded).to_a.map(&:to_i)
  min_area = ph * pw * HOLE_MIN_AREA_RATIO
  n, labels, stats, _ = cv2.connectedComponentsWithStats(padded, connectivity: 4).to_a
  hole_label = (2...n.to_i).find do |lbl|
    area = stats.item(lbl, cv2.CC_STAT_AREA).to_i
    bw   = stats.item(lbl, cv2.CC_STAT_WIDTH).to_i
    bh   = stats.item(lbl, cv2.CC_STAT_HEIGHT).to_i
    long_side  = [bw, bh].max
    short_side = [bw, bh].min
    aspect = short_side > 0 ? long_side.to_f / short_side : Float::INFINITY
    area >= min_area && aspect <= HOLE_MAX_ASPECT
  end
  return nil unless hole_label

  if ENV['SUDOKU_DEBUG'] == '1' && debug_name
    colors = [[0,0,0], [200,200,200], [0,0,255], [0,255,0], [255,0,0]]
    canvas = PY.zeros3(ph, pw)
    (0...n.to_i).each do |lbl|
      area  = stats.item(lbl, cv2.CC_STAT_AREA).to_i
      color = if lbl < 2 then colors[lbl]
              elsif area >= min_area then [0, 0, 255]   # 有効な穴=赤
              else [0, 165, 255]                        # ゴミ=オレンジ
              end
      mask  = cv2.compare(labels, np.full(PY.shape(labels), lbl, dtype: np.int32), cv2.CMP_EQ)
      PY.apply_mask_color(canvas, mask, 0, 0, 0, 0, pw, ph, color)
    end
    CV2.rectangle(canvas, 0, (digit_mid_y + 1).to_i, pw, (digit_mid_y + 2).to_i, 200, 1)
    save_step(canvas, "#{debug_name}_holes.png")
  end

  # 穴の重心 y と数字本体の縦中心を比較（上 → 9、下 → 6）
  # padded は inner に 1px 追加しているので digit_mid_y に +1 のオフセット
  hole_mask = cv2.compare(labels, np.full(PY.shape(labels), hole_label, dtype: np.int32), cv2.CMP_EQ)
  m = cv2.moments(hole_mask)
  centroid_y = m['m01'].to_f / m['m00'].to_f
  centroid_y < digit_mid_y + 1 ? 9 : 6
end

# --
# ── テンプレートマッチング
# --
# float32 テンプレートに対してマッチングし [min_val, max_val, min_x, min_y, result] を返す
def match_template( cell_r )
  tmpl_f = @tmpl_data[:tmpl_f_py]

  th, tw = PY.shape(tmpl_f).to_a.map(&:to_i)
  ch, cw = PY.shape(cell_r).to_a.map(&:to_i)
  return [1.0, 1.0, 0, 0, nil] if th < ch || tw < cw
  result = CV2.match_template(tmpl_f, cell_r)
  min_val, max_val, min_loc, _ = cv2.minMaxLoc(result).to_a
  min_x, min_y = min_loc.to_a.map(&:to_i)
  [min_val.to_f, max_val.to_f, min_x, min_y, result]
end

# --
# ── digit_gray を canvas の (cx,cy) 基準に target_h 高さで貼り付け
# --
def paste_digit( canvas, digit_gray, cx, cy, target_h, color, align: 'bottom' )
  dh, dw = PY.shape(digit_gray).to_a.map(&:to_i)
  return if dh == 0 || dw == 0

  scale   = target_h.to_f / dh
  nw_out  = [(dw * scale).to_i, 1].max
  nh_out  = [(dh * scale).to_i, 1].max
  resized = CV2.resize( digit_gray, nw_out, nh_out )
  mask    = CV2.threshold( resized, 128, 255, cv2.THRESH_BINARY_INV )

  x0 = cx.to_i - nw_out / 2
  y0 = align == 'bottom' ? cy.to_i - nh_out : cy.to_i - nh_out / 2

  ch, cw_c = PY.shape(canvas).to_a.map(&:to_i)
  sx = [0, -x0].max;  sy = [0, -y0].max
  ex = [nw_out, cw_c - x0].min
  ey = [nh_out, ch   - y0].min
  return if ex <= sx || ey <= sy

  PY.apply_mask_color( canvas, mask, [x0, 0].max, [y0, 0].max, sx, sy, ex - sx, ey - sy, color)
end

# --
# ── 認識結果オーバーレイ（セル左寄り・下端揃え、赤色）
# --
def build_recognized_overlay( sq_size, cells )
  canvas   = PY.zeros3(sq_size, sq_size)
  cw       = sq_size / 10
  target_h = (cw * 0.5).to_i
  9.times do |row|
    9.times do |col|
      v = cells[row][col]
      next unless v > 0
      paste_digit( canvas, @tmpl_data[:digit_imgs_py][v - 1],
                     col * cw + cw / 2, (row + 1) * cw,
                     target_h, [0, 0, 255], align: 'bottom')
    end
  end
  canvas
end

# --
# ── 解答オーバーレイ（セル中央、緑色）
# --
def build_answer_overlay( sq_size, init_cells, answer )
  canvas   = PY.zeros3( sq_size, sq_size )
  cw       = sq_size / 10
  target_h = sq_size / 15
  9.times do |row|
    9.times do |col|
      next if init_cells[row][col] > 0
      v = answer[row][col]
      next unless v && v > 0
      paste_digit( canvas, @tmpl_data[:digit_imgs_py][v - 1],
                     (col + 1) * cw, (row + 1) * cw,
                     target_h, [255, 60, 60], align: 'center')
    end
  end
  canvas
end

# --
# ── 9x9 cell の数字認識
# --
def extract_numbers( square )
  cell_h, cell_w = PY.shape(square).to_a.map { it.to_i / 10 }
  tmpl_cell_w    = @tmpl_data[:cell_w].to_f
  crop_r         = PARAMS["cell_crop_ratio"]

  cells = Array.new(9) { Array.new(9, 0) }
  (0..8).to_a.product((0..8).to_a).each do |row, col|
    cx, cy = (col + 1) * cell_w, (row + 1) * cell_h
    cell   = PY.crop(square, (cy - cell_h * crop_r).to_i, (cy + cell_h * crop_r).to_i,
                              (cx - cell_w * crop_r).to_i, (cx + cell_w * crop_r).to_i)
    if ENV['SUDOKU_DEBUG'] == '1'
      save_step( cell, "cell#{row}#{col}.png"  )
    end

    cell_sh  = PY.shape(cell).to_a.map(&:to_i)
    cell_area = cell_sh[0] * cell_sh[1]

    # 連結成分からゴミ（枠線残滓）を除いて数字候補を選ぶ
    # bbox_ratio >= max_bbox_ratio のものは枠線残滓としてスキップし、次の候補を試す
    cell_inv2 = cv2.bitwise_not(cell)
    nc2, _lc2, sc2, _ = cv2.connectedComponentsWithStats(cell_inv2, connectivity: 8).to_a
    next if nc2.to_i < 2
    max_bbox = PARAMS.fetch("max_bbox_ratio", 0.7)
    dl2 = (1...nc2.to_i)
            .sort_by { |lbl| -sc2.item(lbl, cv2.CC_STAT_AREA).to_i }
            .find do |lbl|
              bw_ = sc2.item(lbl, cv2.CC_STAT_WIDTH).to_i
              bh_ = sc2.item(lbl, cv2.CC_STAT_HEIGHT).to_i
              (bw_ * bh_).to_f / cell_area < max_bbox
            end
    next unless dl2
    bw2   = sc2.item(dl2, cv2.CC_STAT_WIDTH).to_i
    bh2   = sc2.item(dl2, cv2.CC_STAT_HEIGHT).to_i
    area2 = sc2.item(dl2, cv2.CC_STAT_AREA).to_i
    aspect     = bh2 > 0 ? bw2.to_f / bh2 : 1.0
    bbox_ratio = (bw2 * bh2).to_f / cell_area

    debug_puts "cell[#{row}][#{col}] cc_area_ratio=#{(area2.to_f/cell_area).round(4)} aspect=#{aspect.round(3)} bbox_ratio=#{bbox_ratio.round(3)}"

    # 細長くない成分（幅/高さ >= 0.5）は面積閾値を高くする
    # 細長い場合（「1」など）は面積が小さいので低い閾値のまま
    min_ratio = aspect < 0.5 ? PARAMS.fetch("blank_dark_ratio_thin", 0.02)
                              : PARAMS["blank_dark_ratio"]
    next if area2.to_f / cell_area < min_ratio

    cell_for_match = cell

    rw = tmpl_cell_w / cell_sh[1]
    nw = [(cell_sh[1] * rw).to_i, 1].max
    nh = [(cell_sh[0] * rw).to_i, 1].max

    # フォントサイズの±10% 変化に対応するため複数スケールで試して最良を採用
    min_val, max_val, min_x, min_y, match_result = [0.90, 0.95, 1.00, 1.05, 1.10].map do |scale|
      snw = [(nw * scale).to_i, 1].max
      snh = [(nh * scale).to_i, 1].max
      match_template( PY.astype_float32(cv2.resize(cell, [snw, snh])) )
    end.min_by { |v, *| v }

    r_h, r_w  = PY.shape( match_result ).to_a.map(&:to_i)
    row_h     = r_h.to_f / @tmpl_data[:num_rows]
    y_r       = ( min_y % row_h ) / row_h   # 各行内での相対位置 0.0 ～ 1.0

    min_by_max = max_val > 0 ? min_val.to_f / max_val.to_f : 1.0

    debug_puts "  min_val: #{min_val.round(3)}, max_val: #{max_val.round(3)}, min/max: #{min_by_max.round(2)}"
    debug_puts "  min_x: #{min_x}, min_y: #{min_y}"
    debug_puts "  result(h,w)=(#{r_h},#{r_w}), y_r: #{y_r.round(2)}"

    if y_r < 0.2 || y_r > 0.8
      next
    end

    number_f   = (min_x + nw / 2.0) / tmpl_cell_w
    number     = number_f.to_i
    off_x      = number_f - number
    debug_puts "  number_f: #{number_f.round(2)}, off_x:#{off_x.round(3)}"

    # 誤認識補正: 穴判定
    # 3→0, 5→0, 6→1(下), 9→1(上), 8→2 という特徴で補正する
    # 3 は穴が0個なら元の判定を維持、1個以上なら9に補正
    if [3, 5, 6, 8, 9].include?(number)
      holes = count_holes(cell, debug_name: "cell#{row}#{col}")
      debug_puts "  holes= #{holes}"
      corrected = if number == 3
                    holes >= 1 ? six_or_nine(cell, debug_name: "cell#{row}#{col}") : nil
                  else
                    case holes
                    when 0; 5
                    when 1; six_or_nine(cell, debug_name: "cell#{row}#{col}")
                    when 2; 8
                    end
                  end
      if corrected && corrected != number
        debug_puts "  -> hole correction: #{number} -> #{corrected} (holes=#{holes})"
        number = corrected
      end
    end

    debug_puts "  => num= #{number}"

    if ENV['SUDOKU_DEBUG'] == '1'
      vis = cv2.cvtColor(PY.normalize_u8(match_result), cv2.COLOR_GRAY2BGR)
      CV2.circle(vis, min_x.to_i, min_y, 5, 0, 0, 255, 2)
      save_step(vis, "match_#{row}#{col}-#{number}.png" )
    end

    if min_by_max >= PARAMS["match_score_threshold"]
      debug_puts "  match_score_threshold: #{min_by_max} >= #{PARAMS["match_score_threshold"]}"
      next
    end
    if off_x < PARAMS["match_off_x_min"] || off_x > PARAMS["match_off_x_max"]
      debug_puts "  off_x: #{off_x}, off_x_min: #{PARAMS["match_off_x_min"]} off_x_max: #{PARAMS["match_off_x_max"]}"
      next
    end
    next if number < 1 || number > 9

    cells[row][col] = number
  end
  cells
end

# --
# -- 行、列、ブロック内に重複した数字が無いことを確認
# --
def board_consistent?( cells )
  transposed = cells.transpose
  row = ->i { cells[i] }
  col = ->i { transposed[i] }
  box = ->i do
    x_y    = [0,1,2].product([0,1,2])
    y0, x0 = x_y[i].map { it * 3 }
    x_y.map { |y, x| cells[y0 + y][x0 + x] }
  end

  [row, col, box].all? do |m|
    (0..8).all? { |i| m.(i).select{ it > 0 }.then{ it == it.uniq } }
  end
end

# --
# -- 答えを元の画像に重ね合わせ
# --
def overlay_answer( original, init_cells, answer, sq_size, persp_m  )
  h_, w_  = PY.shape(original).to_a.map(&:to_i)
  ans_img = build_answer_overlay( sq_size, init_cells, answer )
  warped  = cv2.warpPerspective( ans_img, persp_m, [ w_, h_ ],
                                  flags: cv2.INTER_LINEAR | cv2.WARP_INVERSE_MAP
                                )
  gray_mask = cv2.cvtColor( warped, cv2.COLOR_BGR2GRAY )
  mask      = CV2.threshold( gray_mask, 1, 255, cv2.THRESH_BINARY)
  mask_inv  = cv2.bitwise_not( mask)
  bg = cv2.bitwise_and( original, original, mask: mask_inv )
  fg = cv2.bitwise_and( warped,   warped,   mask: mask )
  cv2.add( bg, fg )
end
