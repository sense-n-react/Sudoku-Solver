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

  def rectangle(img, x1, y1, x2, y2, b, g, r, thickness):
      cv2.rectangle(img, (int(x1), int(y1)), (int(x2), int(y2)), (b, g, r), int(thickness))

  def line(img, x1, y1, x2, y2, b, g, r, thickness):
      cv2.line(img, (int(x1), int(y1)), (int(x2), int(y2)), (b, g, r), int(thickness))

  def fill_poly(img, pts, val):
      cv2.fillPoly(img, [np.array([[int(x), int(y)] for x, y in pts], dtype=np.int32)], int(val))

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

  def label_hull_area(labels, label):
      pts = np.argwhere(labels == int(label))[:, ::-1].reshape(-1, 1, 2).astype(np.float32)
      return float(cv2.contourArea(cv2.convexHull(pts))) if len(pts) >= 3 else 0.0

  def remove_labels(img, labels, garbage_labels):
      """garbage_labels に含まれるラベルの画素を img から一括除去して返す"""
      mask = np.isin(labels, list(garbage_labels))
      out  = img.copy()
      out[mask] = 0
      return out

  def find_nonzero(img):
      return cv2.findNonZero(img)

  def bounding_rect(coords):
      x, y, w, h = cv2.boundingRect(coords)
      return [x, y, w, h]

  def match_template(tmpl_f, cell_r):
      return cv2.matchTemplate(tmpl_f, cell_r, cv2.TM_SQDIFF_NORMED)

  def invert_matrix(m):
      return np.linalg.inv(np.array(m, dtype=np.float64))

  def blend_masked(result, warped, y1, y2, x1, x2):
      mask = cv2.cvtColor(warped, cv2.COLOR_BGR2GRAY) > 1
      result[int(y1):int(y2), int(x1):int(x2)][mask] = warped[mask]

  def copy_cell(dst, src, r1, r2, c1, c2):
      dst[int(r1):int(r2), int(c1):int(c2)] = src[int(r1):int(r2), int(c1):int(c2)]

  def bgr_to_gray(img):
      return cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)

  def arc_length(contour, closed):
      return float(cv2.arcLength(contour, closed))

  def approx_poly_dp(contour, epsilon, closed):
      return cv2.approxPolyDP(contour, epsilon, closed)

  def corner_min_eigen_val(img, block_size, ksize):
      return cv2.cornerMinEigenVal(img.astype(np.float32), int(block_size), int(ksize))

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
    def row_has_dark(img):
        """各行に200未満のピクセルがあるか bool リストで返す"""
        return (img < 200).any(axis=1).tolist()

    @staticmethod
    def array_max(arr):
        return float(arr.max())

    @staticmethod
    def eigen_window_centroid(eigen_map, ey, ex, hw, thresh, max_shift, img_h, img_w):
        """期待位置周辺の最小固有値マップ加重重心を返す。[cy, cx, peak] または None。"""
        y1 = max(0, int(ey) - int(hw)); y2 = min(int(img_h), int(ey) + int(hw) + 1)
        x1 = max(0, int(ex) - int(hw)); x2 = min(int(img_w), int(ex) + int(hw) + 1)
        local = eigen_map[y1:y2, x1:x2]
        mask  = local > float(thresh)
        if not mask.any():
            return None
        weights = local[mask]
        ys, xs  = np.argwhere(mask).T
        cy = float((weights * (y1 + ys)).sum() / weights.sum())
        cx = float((weights * (x1 + xs)).sum() / weights.sum())
        if abs(cy - float(ey)) < float(max_shift) and abs(cx - float(ex)) < float(max_shift):
            return [cy, cx, float(local.max())]
        return None

PYTHON

#
# PyObject と Ruby型 との変換が必要な pyCall は CV2.xxxx あるいは PY.xxxx で呼び出す。
# OpenCV に関する pyCall は CV2.xxxx、それ以外は PY.xxxx
#
CV2 = PyCall.import_module('__main__')
PY  = CV2._PY

# ── パラメータ（デフォルト値） ────────────────────────────────
WARP_MARGIN     = 0.05   # 射影補正後の余白率（0.05 = 5%）
CELL_CROP_RATIO = 0.45   # セル切り出しサイズ（cell_w の何倍か）

PARAMS = {
  "blur_kernel_divisor"   => 130,    # GaussianBlur カーネルサイズ = 短辺 / この値（奇数に丸め）
  "adaptive_block_divisor"=> 30,     # adaptiveThreshold ブロックサイズ = 短辺 / この値（奇数に丸め）
  "adaptive_c"            => 10,     # adaptiveThreshold の定数 C
  "frame_min_ratio"       => 0.667,  # 外枠として認める最小サイズ（画像短辺に対する比率）
  "blank_dark_ratio"      => 0.06,   # 細長くない成分の面積比閾値（これ以下なら空白と判定）
  "match_score_threshold" => 0.5,    # マッチスコア（min/max）がこれ以上なら棄却
  "match_off_x_min"       => 0.2,    # 数字位置のオフセット下限
  "match_off_x_max"       => 0.8,    # 数字位置のオフセット上限
}

def square_times(n) = (0...n).to_a.product((0...n).to_a)

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

# 9x9 のマス目線を描画（3x3 ブロック境界は太く）
# WARP_MARGIN を考慮し、実際の盤面領域に合わせて描画する
def draw_grid( img, sq_size )
  hi, lo, cell = grid_geometry( sq_size )
  (0..9).each do |i|
    pos = (lo + i * cell).to_i
    thickness = (i % 3 == 0) ? 15 : 5
    CV2.line( img, pos, lo.to_i, pos, hi.to_i, 70, 160, 70, thickness)
    CV2.line( img, lo.to_i, pos, hi.to_i, pos, 70, 160, 70, thickness)
  end
end

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
  cv2.adaptiveThreshold(
    blurred, FIRST_THRESH,
    cv2.ADAPTIVE_THRESH_MEAN_C, cv2.THRESH_BINARY_INV,
    bs, PARAMS["adaptive_c"]
  )
end

# --
# ── 外枠を検出
# --
def detect_frame( gray_inv )
  # 1回目: ピクセル面積最大の成分を外枠とする
  n, labels, stats, _ = cv2.connectedComponentsWithStats( gray_inv, connectivity: 8).to_a
  return nil if n.to_i <= 1

  outer_label = (1...n.to_i).max_by { |i| stats.item(i, cv2.CC_STAT_AREA).to_i }

  mask_for = ->(lbl, lbs) {
    cv2.compare(lbs, np.full(PY.shape(lbs), lbl, dtype: np.int32), cv2.CMP_EQ)
  }
  # 外枠の凸包面積からセル辺長を推定（傾き・曲がりに対応するため bounding box より正確）
  cell_side = Math.sqrt( CV2.label_hull_area(labels, outer_label).to_f / 81.0 )

  frame_mask = mask_for.(outer_label, labels)
  h, w = PY.shape( gray_inv ).to_a.map(&:to_i)

  # 外枠内側マスク: 外枠を黒にした画像の隅から flood fill → 背景を塗りつぶす
  flood_img = cv2.bitwise_not(frame_mask).copy
  CV2.flood_fill(flood_img, nil, 0, 0, 0)
  inner_inv = cv2.bitwise_and( gray_inv, flood_img )

  n2, labels2, stats2, _ = cv2.connectedComponentsWithStats(inner_inv, connectivity: 8).to_a

  # bounding box の長辺がセル辺長を超えるものを中枠線と判定（stats のみで判断）

  canvas = PY.zeros3(h, w)
  PY.apply_mask_color(canvas, frame_mask, 0, 0, 0, 0, w, h, [255, 0, 0])  # 外枠: 青

  inner_labels = (1...n2.to_i).select { |i|
    bw = stats2.item(i, cv2.CC_STAT_WIDTH).to_i
    bh = stats2.item(i, cv2.CC_STAT_HEIGHT).to_i
    [bw, bh].max > cell_side
  }
  inner_labels.each do |i|
    inner_mask = mask_for.(i, labels2)
    PY.apply_mask_color(canvas, inner_mask, 0, 0, 0, 0, w, h, [0, 255, 0])  # 中枠: 緑
    cv2.bitwise_or(frame_mask, inner_mask, dst: frame_mask)
  end
  save_step(canvas, "02_frame_candidates.png", "外枠候補（青=外枠 緑=中枠）")

  frame_mask
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
# digits_bin（白=背景・黒=数字）から以下の条件を満たすゴミ成分を除去して返す
#   1. pixel 面積が cell_area の 1% 以下
#   2. bounding box の幅 > 高さ * 1.5（横長）
#   3. 縦長でない（幅 >= 高さ）かつ bounding box 面積が cell_area の 10% 以下
def remove_small_components( digits_bin, cell_area )
  inv = cv2.bitwise_not( digits_bin )   # 数字=白 に反転して CCS にかける
  n, labels, stats, _ = cv2.connectedComponentsWithStats( inv, connectivity: 8 ).to_a
  garbage_labels = (1...n.to_i).select do |i|
    px_area   = stats.item(i, cv2.CC_STAT_AREA).to_i
    bw        = stats.item(i, cv2.CC_STAT_WIDTH).to_i
    bh        = stats.item(i, cv2.CC_STAT_HEIGHT).to_i
    bbox_area = bw * bh
    px_area  <= cell_area * 0.01              ||   # 1. pixel 面積が極小
    bw        >  bh * 1.5                    ||   # 2. 横長
    ( bw >= bh && bbox_area <= cell_area * 0.10 ) # 3. 縦長でなく小さい
  end
  clean = garbage_labels.empty? ? inv : CV2.remove_labels(inv, labels, garbage_labels)
  cv2.bitwise_not( clean )              # 白=背景・黒=数字 に戻す
end

# -- WARP_MARGIN を考慮した 9x9 グリッドの幾何情報を返す
# -- [盤面遠端座標(px), 盤面近端オフセット(px), 1セルの幅(px)]
def grid_geometry( sq_size )
  hi, lo = sq_size * ( 1.0 - WARP_MARGIN ), sq_size * WARP_MARGIN
  [hi, lo, (hi - lo) / 9.0]
end

# outer_contour の各点から外枠4辺（corners で定義）への最大距離を
# フレーム短辺長で正規化した値を返す（直線なら≈0、曲がるほど大きい）
def frame_curvature( outer_contour, corners )
  pts   = PY.contour_pts( outer_contour ).to_a.map { |p| p.to_a.map(&:to_f) }
  edges = ( corners + [corners.first] ).each_cons(2).to_a
  debug_puts( "edges: #{edges}" )

  frame_size = edges.map { |(x0,y0),(x1,y1)| Math.sqrt((x1-x0)**2+(y1-y0)**2) }.min

  max_dev = pts.map do |px, py|
    edges.map do |(x0,y0),(x1,y1)|
      dx = x1-x0; dy = y1-y0; len2 = dx*dx+dy*dy
      next Float::INFINITY if len2 == 0
      t  = [[dx*(px-x0)+dy*(py-y0), 0].max.fdiv(len2), 1].min
      Math.sqrt( (x0+t*dx-px)**2 + (y0+t*dy-py)**2 )
    end.min
  end.max

  debug_puts( "frame_curvature: max_dev/frame_size = %.1f/%.1f = %.4f" %
              [ max_dev, frame_size, max_dev / frame_size ]
            )
  max_dev / frame_size
end

def normalize_grid( frame_bin, digits_bin, sq_size, outer_contour, corners, persp_m )
  hi, lo, cell = grid_geometry( sq_size )
  inv_persp    = CV2.invert_matrix( persp_m )

  # case 1: 外枠がほぼ直線 → warpPerspective 1回で正規化
  if frame_curvature( outer_contour, corners ) < 0.05 / 9
    square = cv2.warpPerspective( digits_bin, persp_m, [sq_size, sq_size], borderValue: 255 )
    return [square, nil]
  end

  # case 2: 枠が曲がっている → 元画像上で交点検出、per-cell warpPerspective で正規化

  # 元画像の画像サイズ（eigen_window_centroid のクリッピングに使用）
  img_h, img_w = PY.shape( frame_bin ).to_a.map(&:to_i)

  # 均等グリッドを inv_persp で元画像空間に変換して初期推定値とする
  # pts[i][j] = [x, y] （元画像座標）
  m   = inv_persp.tolist.to_a.map { |row| row.to_a.map(&:to_f) }
  pts = square_times(10).each_with_object(Array.new(10) { Array.new(10) }) do |(i, j), acc|
    gx = lo + j * cell;  gy = lo + i * cell
    w  = m[2][0]*gx + m[2][1]*gy + m[2][2]
    acc[i][j] = [(m[0][0]*gx + m[0][1]*gy + m[0][2]) / w,
                 (m[1][0]*gx + m[1][1]*gy + m[1][2]) / w]
  end
  exp = pts.map { |row| row.map(&:dup) }

  # 元画像でのセル平均サイズに基づいて探索窓を設定
  side_lengths = corners.zip( corners.rotate(1) ).map { |(x0,y0),(x1,y1)|
    Math.sqrt( (x1-x0)**2 + (y1-y0)**2 )
  }
  avg_cell_orig = side_lengths.sum / side_lengths.size / 9.0
  hw        = [(avg_cell_orig * 0.40).to_i, 4].max
  hw_fine   = [(avg_cell_orig * 0.25).to_i, 4].max
  max_shift = avg_cell_orig * 0.35
  block     = [(avg_cell_orig * 0.08).to_i, 3].max
  block    += 1 if block.even?

  eigen_map     = CV2.corner_min_eigen_val( frame_bin, block, 3 )
  global_thresh = PY.array_max( eigen_map ) * 0.01

  # 1パス目: 太線交点（行・列 0,3,6,9）を広い窓で検出
  thick = [0, 3, 6, 9]
  thick_responses = []
  thick.each do |i|
    thick.each do |j|
      ex, ey = exp[i][j]
      r = PY.eigen_window_centroid( eigen_map, ey, ex, hw, global_thresh, max_shift, img_h, img_w )
      next unless r
      ra = r.to_a
      pts[i][j] = [ra[1].to_f, ra[0].to_f]
      thick_responses << ra[2].to_f
    end
  end
  debug_puts( "thick_responses: #{thick_responses.map{|t| t.round(1)}}" )

  ref_response = thick_responses.empty? ? PY.array_max( eigen_map ).to_f
                                        : thick_responses.sort[ thick_responses.size / 2 ]
  fine_thresh  = ref_response * 0.30

  # 2パス目: 双線形補間で期待位置を推定し細線交点を検出
  square_times(10).each do |i, j|
      next if thick.include?(i) && thick.include?(j)

      bi = [i / 3, 2].min * 3
      bj = [j / 3, 2].min * 3
      t  = (i - bi) / 3.0
      s  = (j - bj) / 3.0
      ex = (1-t)*(1-s)*pts[bi][bj][0]   + (1-t)*s*pts[bi][bj+3][0] +
           t    *(1-s)*pts[bi+3][bj][0] + t    *s*pts[bi+3][bj+3][0]
      ey = (1-t)*(1-s)*pts[bi][bj][1]   + (1-t)*s*pts[bi][bj+3][1] +
           t    *(1-s)*pts[bi+3][bj][1] + t    *s*pts[bi+3][bj+3][1]

      r = PY.eigen_window_centroid( eigen_map, ey, ex, hw_fine, global_thresh, max_shift, img_h, img_w )
      pts[i][j] = if r && r.to_a[2].to_f >= fine_thresh
        ra = r.to_a; [ra[1].to_f, ra[0].to_f]
      else
        [ex, ey]
      end
  end

  square = build_normalized_square( digits_bin, pts, sq_size, lo, cell )
  [square, pts]
end

def build_normalized_square( digits_bin, pts, sq_size, lo, cell )
  sq = PY.full_gray( sq_size, sq_size, 255 )
  square_times(9).each do |i, j|
    src_pts = np.array( [
      pts[i  ][j  ].map(&:to_f),
      pts[i  ][j+1].map(&:to_f),
      pts[i+1][j+1].map(&:to_f),
      pts[i+1][j  ].map(&:to_f),
    ], dtype: np.float32 )
    dx = lo + j * cell
    dy = lo + i * cell
    dst_pts = np.array( [
      [ dx,        dy       ],
      [ dx + cell, dy       ],
      [ dx + cell, dy + cell],
      [ dx,        dy + cell],
    ], dtype: np.float32 )
    m      = cv2.getPerspectiveTransform( src_pts, dst_pts )
    warped = cv2.warpPerspective( digits_bin, m, [sq_size, sq_size], borderValue: 255 )
    CV2.copy_cell( sq, warped, dy, dy + cell, dx, dx + cell )
  end
  sq
end

# --
# ── 台形画像 <-> 正方形 変換のための射影変換
# --
def get_perspective_transform( corners, sq_size )
  hi, lo, _ = grid_geometry( sq_size )
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
# -- テンプレートの digit n (1-9), row(フォント) row_idx のバウンディングボックス画像を取得
# --
def template_digit_img_row( tmpl_gray, n, row_idx, num_rows )
  th, tw = PY.shape(tmpl_gray).to_a.map(&:to_i)
  cw    = tw / 10
  row_h = (th - cw / 2) / num_rows
  r1, r2 = row_idx * row_h, (row_idx + 1) * row_h

  col    = PY.crop( tmpl_gray, r1, r2, n * cw, (n + 1) * cw)
  bw     = CV2.threshold( col, 128, 255, cv2.THRESH_BINARY_INV )
  coords = CV2.find_nonzero( bw )
  return PY.full_gray(cw, cw, 255) unless coords
  rx, ry, rw, rh = CV2.bounding_rect(coords).to_a.map(&:to_i)
  return PY.full_gray(cw, cw, 255) if rw == 0 || rh == 0
  PY.crop(col, ry, ry + rh, rx, rx + rw)
end

# --
# -- テンプレートから digit n (1-9) の最小バウンディングボックス画像を取得（全行中で最小面積のもの）
# --
def template_digit_img( tmpl_gray, n, num_rows )
  best_img  = nil
  best_area = Float::INFINITY

  num_rows.times.each do |row_idx|
    img = template_digit_img_row( tmpl_gray, n, row_idx, num_rows )
    h, w = PY.shape(img).to_a.map(&:to_i)
    area = w * h
    if area < best_area
      best_img  = img
      best_area = area
    end
  end

  best_img
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
  col1     = PY.crop( tmpl, 0, th, cell_w, cell_w * 2 )
  num_rows = PY.row_has_dark( col1 ).to_a
               .chunk_while { |a, b| a == b }.select { |g| g.first }.count
               .then { |n| [n, 1].max }

  # 5/6/8/9 それぞれをマスク（白で塗り潰し）したテンプレートを事前生成
  masked_tmpls_py = [5, 6, 8, 9].to_h do |n|
    masked = PY.img_copy(tmpl)
    cv2.rectangle(masked, [n * cell_w, 0], [(n + 1) * cell_w, th], 255, cv2.FILLED)
    [n, PY.astype_float32(masked)]
  end

  @tmpl_data = {
    cell_w:          cell_w,
    num_rows:        num_rows,
    tmpl_gray_py:    tmpl,
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

# --
# -- 穴の数と 6/9 判定をまとめて返す
# --
#   cell_bin    : 白背景・黒文字のセル画像
#   min_area    : 有効な穴の最小面積（digit bounding box 面積 × HOLE_MIN_AREA_RATIO）
#   digit_mid_y : 数字本体の縦中心 y（cell 座標系）。穴が1個のとき 6/9 判定に使用
#
#   戻り値: [hole_count, six_or_nine]
#     hole_count  : 有効な穴の数
#     six_or_nine : 穴が1個のとき 6 または 9、それ以外は nil
#
def analyze_digit_holes(cell_bin, min_area, digit_mid_y, debug_name: nil)
  padded = cv2.copyMakeBorder(digit_region(cell_bin), 1, 1, 1, 1, cv2.BORDER_CONSTANT, value: 255)
  h, w   = PY.shape(padded).to_a.map(&:to_i)

  # 白背景・黒数字の画像で白領域を数える
  # label0=黒ストローク, label1=外背景, label2以降=穴（小さいゴミは除外）
  n, labels, stats, _ = cv2.connectedComponentsWithStats(padded, connectivity: 4).to_a
  is_hole = ->(lbl) do
    area = stats.item(lbl, cv2.CC_STAT_AREA).to_i
    bw   = stats.item(lbl, cv2.CC_STAT_WIDTH).to_i
    bh   = stats.item(lbl, cv2.CC_STAT_HEIGHT).to_i
    ls   = [bw, bh].max; ss = [bw, bh].min
    area >= min_area && (ss > 0 ? ls.to_f / ss : Float::INFINITY) <= HOLE_MAX_ASPECT
  end
  hole_labels = (2...n.to_i).select { |lbl| is_hole.(lbl) }

  if ENV['SUDOKU_DEBUG'] == '1' && debug_name
    colors = [[0,0,0], [200,200,200]]
    canvas = PY.zeros3(h, w)
    (0...n.to_i).each do |lbl|
      color = case
              when lbl < 2;       colors[lbl]
              when is_hole.(lbl); [0, 0, 255]   # 有効な穴=赤
              else [0, 165, 255]                # ゴミ=オレンジ
              end
      mask = cv2.compare(labels, np.full(PY.shape(labels), lbl, dtype: np.int32), cv2.CMP_EQ)
      PY.apply_mask_color(canvas, mask, 0, 0, 0, 0, w, h, color)
    end
    # padded は 1px 追加しているので digit_mid_y に +1 オフセット
    CV2.rectangle(canvas, 0, (digit_mid_y + 1).to_i, w, (digit_mid_y + 2).to_i, 200, 200, 200, 1)
    save_step(canvas, "#{debug_name}_holes.png")
  end

  six_nine = if hole_labels.size == 1
    hole_mask  = cv2.compare(labels, np.full(PY.shape(labels), hole_labels[0], dtype: np.int32), cv2.CMP_EQ)
    m          = cv2.moments(hole_mask)
    centroid_y = m['m01'].to_f / m['m00'].to_f
    centroid_y < digit_mid_y + 1 ? 9 : 6
  end

  [hole_labels.size, six_nine]
end

# --
# ── テンプレートマッチング
# --
# float32 テンプレートに対してマッチングし [min_val, max_val, min_x, min_y, result] を返す
def match_template( tmpl_f, cell_r )
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

  x0 = case align
       when 'bottom'    then cx.to_i - nw_out / 2
       when 'top-right' then cx.to_i
       else                  cx.to_i - nw_out / 2
       end
  y0 = case align
       when 'bottom'    then cy.to_i - nh_out
       when 'top-right' then cy.to_i
       else                  cy.to_i - nh_out / 2
       end

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
def build_recognized_overlay( sq_size, cells, matched_imgs )
  canvas     = PY.zeros3(sq_size, sq_size)
  _, lo, cw = grid_geometry( sq_size )
  target_h = (cw * 0.45).to_i
  square_times(9).each do |row, col|
    v = cells[row][col]
    next unless v > 0
    img = matched_imgs[row][col] || @tmpl_data[:digit_imgs_py][v - 1]
    paste_digit( canvas, img,
                   lo + col * cw + cw * 0.05, lo + row * cw,
                   target_h, [0, 0, 255], align: 'top-right')
  end
  canvas
end

# --
# ── 解答オーバーレイ（セル中央、緑色）
# --
def build_answer_overlay( sq_size, init_cells, answer )
  canvas    = PY.zeros3( sq_size, sq_size )
  _, lo, cw = grid_geometry( sq_size )
  target_h = sq_size / 15
  square_times(9).each do |row, col|
    next if init_cells[row][col] > 0
    v = answer[row][col]
    next unless v && v > 0
    paste_digit( canvas, @tmpl_data[:digit_imgs_py][v - 1],
                   lo + (col + 0.5) * cw, lo + (row + 0.5) * cw,
                   target_h, [255, 60, 60], align: 'center')
  end
  canvas
end

# --
# ── 9x9 cell の数字認識
# --
def extract_numbers( square )
  sq_size        = PY.shape(square).to_a.map(&:to_i).min
  _, lo, cell_w  = grid_geometry( sq_size )
  cell_h         = cell_w
  tmpl_cell_w    = @tmpl_data[:cell_w].to_f

  # 全セルで crop サイズは同一なので、ループ前に一度だけ計算
  crop_px   = (cell_w * CELL_CROP_RATIO * 2).to_i
  cell_area = crop_px * crop_px

  # テンプレートをセルサイズ基準で3スケールにリサイズ（セルのリサイズ不要）
  tmpl_orig = @tmpl_data[:tmpl_f_py]
  th_orig, tw_orig = PY.shape(tmpl_orig).to_a.map(&:to_i)
  # テンプレートをネイティブサイズ基準で3スケール事前生成（小さいまま）
  # セルは tmpl_cell_w に1回縮小してマッチング
  scaled_tmpls = [0.93, 1.00, 1.07].map { |s|
    tw_s = [(tw_orig * s).to_i, 1].max
    th_s = [(th_orig * s).to_i, 1].max
    [PY.astype_float32( CV2.resize(tmpl_orig, tw_s, th_s) ), tmpl_cell_w * s]
  }

  cells        = Array.new(9) { Array.new(9, 0) }
  matched_imgs = Array.new(9) { Array.new(9, nil) }
  digit_bboxes = []
  square_times(9).each do |row, col|
    # ( cx, cy ) : cell 中央の座標
    cx, cy = lo + (col + 0.5) * cell_w, lo + (row + 0.5) * cell_h
    cell   = PY.crop( square,
                      (cy - cell_h * CELL_CROP_RATIO).to_i,
                      (cy + cell_h * CELL_CROP_RATIO).to_i,
                      (cx - cell_w * CELL_CROP_RATIO).to_i,
                      (cx + cell_w * CELL_CROP_RATIO).to_i )
    if ENV['SUDOKU_DEBUG'] == '1'
      save_step( cell, "cell#{row}#{col}.png"  )
    end


    # 連結成分からゴミ（枠線残滓）を除いて数字候補を選ぶ
    # bbox_ratio >= max_bbox_ratio のものは枠線残滓としてスキップし、次の候補を試す
    cell_inv = cv2.bitwise_not(cell)
    nc, _lc, sc, _ = cv2.connectedComponentsWithStats(cell_inv, connectivity: 8).to_a
    next if nc.to_i < 2
    max_bbox = PARAMS.fetch("max_bbox_ratio", 0.7)
    dl = (1...nc.to_i)
           .sort_by { |lbl| -sc.item(lbl, cv2.CC_STAT_AREA).to_i }
           .find do |lbl|
             bw_ = sc.item(lbl, cv2.CC_STAT_WIDTH).to_i
             bh_ = sc.item(lbl, cv2.CC_STAT_HEIGHT).to_i
             (bw_ * bh_).to_f / cell_area < max_bbox
           end
    next unless dl
    bw   = sc.item(dl, cv2.CC_STAT_WIDTH).to_i
    bh   = sc.item(dl, cv2.CC_STAT_HEIGHT).to_i
    area = sc.item(dl, cv2.CC_STAT_AREA).to_i
    bx   = sc.item(dl, cv2.CC_STAT_LEFT).to_i
    by   = sc.item(dl, cv2.CC_STAT_TOP).to_i
    x0_sq = (cx - cell_w * CELL_CROP_RATIO).to_i
    y0_sq = (cy - cell_h * CELL_CROP_RATIO).to_i
    digit_bboxes << [x0_sq + bx, y0_sq + by, x0_sq + bx + bw, y0_sq + by + bh]
    aspect     = bh > 0 ? bw.to_f / bh : 1.0
    bbox_ratio = (bw * bh).to_f / cell_area

    debug_puts "cell[#{row}][#{col}] cc_area_ratio=#{(area.to_f/cell_area).round(4)} aspect=#{aspect.round(3)} bbox_ratio=#{bbox_ratio.round(3)}"

    # 細長くない成分（幅/高さ >= 0.5）は面積閾値を高くする
    # 細長い場合（「1」など）は面積が小さいので低い閾値のまま
    min_ratio = aspect < 0.5 ? PARAMS.fetch("blank_dark_ratio_thin", 0.02)
                              : PARAMS["blank_dark_ratio"]
    next if area.to_f / cell_area < min_ratio

    cell_for_match = cell

    # セルを tmpl_cell_w にリサイズ（テンプレートはネイティブサイズ基準で小さいまま）
    tw = tmpl_cell_w.to_i
    cell_r = PY.astype_float32( CV2.resize(cell, tw, tw) )
    min_val, max_val, min_x, min_y, match_result, matched_digit_w =
      scaled_tmpls.map { |tmpl, digit_w|
        [*match_template( tmpl, cell_r ), digit_w]
      }.min_by { |v, *| v }

    r_h, r_w  = PY.shape( match_result ).to_a.map(&:to_i)
    row_h     = r_h.to_f / @tmpl_data[:num_rows]
    y_r       = ( min_y % row_h ) / row_h   # 各行内での相対位置 0.0 ～ 1.0
    row_idx   = [ (min_y / row_h).to_i, @tmpl_data[:num_rows] - 1 ].min

    min_by_max = max_val > 0 ? min_val.to_f / max_val.to_f : 1.0

    debug_puts "  min_val: #{min_val.round(3)}, max_val: #{max_val.round(3)}, min/max: #{min_by_max.round(2)}"
    debug_puts "  min_x: #{min_x}, min_y: #{min_y}"
    debug_puts "  result(h,w)=(#{r_h},#{r_w}), y_r: #{y_r.round(2)}"

    if y_r < 0.2 || y_r > 0.8
      next
    end

    number_f   = (min_x + tw / 2.0) / matched_digit_w
    number     = number_f.to_i
    off_x      = number_f - number
    debug_puts "  number_f: #{number_f.round(2)}, off_x:#{off_x.round(3)}"

    # 誤認識補正: 穴判定
    # 3→0, 5→0, 6→1(下), 9→1(上), 8→2 という特徴で補正する
    # 3 は穴が0個なら元の判定を維持、1個以上なら9に補正
    if [3, 5, 6, 8, 9].include?(number)
      x1, y1, x2, y2 = digit_bboxes[-1]
      min_area    = (x2 - x1) * (y2 - y1) * HOLE_MIN_AREA_RATIO
      digit_mid_y = by + bh / 2.0
      holes, classified = analyze_digit_holes(cell, min_area, digit_mid_y, debug_name: "cell#{row}#{col}")
      debug_puts "  holes= #{holes}"
      corrected = if number == 3
                    holes >= 1 ? classified : nil
                  else
                    case holes
                    when 0; 5
                    when 1; classified
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

    cells[row][col]        = number
    matched_imgs[row][col] = template_digit_img_row( @tmpl_data[:tmpl_gray_py], number, row_idx, @tmpl_data[:num_rows] )
  end
  [cells, matched_imgs, digit_bboxes]
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
def overlay_answer( original, init_cells, answer, sq_size, persp_m, pts )
  hi, lo, cw  = grid_geometry( sq_size )
  cell_size   = cw.to_i
  target_h    = sq_size / 15
  result      = original.copy
  inv_persp   = CV2.invert_matrix( persp_m )
  img_h, img_w = PY.shape( original ).to_a.map(&:to_i)

  if pts.nil?
    # case 1: 正方形キャンバスに全数字を描いて warpPerspective 1回で元画像に戻す
    sq_canvas = PY.zeros3( sq_size, sq_size )
    square_times(9).each do |row, col|
      next if init_cells[row][col] > 0
      v = answer[row][col]
      next unless v && v > 0
      paste_digit( sq_canvas, @tmpl_data[:digit_imgs_py][v - 1],
                   lo + (col + 0.5) * cw, lo + (row + 0.5) * cw,
                   target_h, [255, 60, 60], align: 'center' )
    end
    warped_back = cv2.warpPerspective( sq_canvas, inv_persp, [img_w, img_h] )
    mask = CV2.threshold( CV2.bgr_to_gray( warped_back ), 1, 255, cv2.THRESH_BINARY )
    PY.copy_where( result, warped_back, mask )
  else
    # case 2: 元画像空間の交点座標を使いセル毎に warpPerspective
    square_times(9).each do |row, col|
      next if init_cells[row][col] > 0
      v = answer[row][col]
      next unless v && v > 0

      cell_img = PY.zeros3( cell_size, cell_size )
      paste_digit( cell_img, @tmpl_data[:digit_imgs_py][v - 1],
                   cell_size / 2.0, cell_size / 2.0,
                   target_h, [255, 60, 60], align: 'center' )

      orig_corners = [ pts[row][col], pts[row][col+1],
                       pts[row+1][col+1], pts[row+1][col] ]
      xs = orig_corners.map(&:first);  ys = orig_corners.map(&:last)
      x1 = [xs.min.floor, 0].max;     x2 = [xs.max.ceil, img_w].min
      y1 = [ys.min.floor, 0].max;     y2 = [ys.max.ceil, img_h].min
      next if x1 >= x2 || y1 >= y2

      s       = (cell_size - 1).to_f
      src_pts = np.array( [[0,0],[s,0],[s,s],[0,s]], dtype: np.float32 )
      dst_pts = np.array( orig_corners.map { |x, y| [x - x1, y - y1] }, dtype: np.float32 )
      m       = cv2.getPerspectiveTransform( src_pts, dst_pts )
      warped  = cv2.warpPerspective( cell_img, m, [x2 - x1, y2 - y1] )
      CV2.blend_masked( result, warped, y1, y2, x1, x2 )
    end
  end
  result
end
