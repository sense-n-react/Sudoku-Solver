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
    def row_has_dark(img):
        """各行に200未満のピクセルがあるか bool リストで返す"""
        return (img < 200).any(axis=1).tolist()

  def corner_min_eigen_val(img, block_size, ksize):
      return cv2.cornerMinEigenVal(img.astype(np.float32), int(block_size), int(ksize))

  def eigen_window_centroid(eigen_map, ey, ex, hw, thresh, max_shift, sq_size):
      """期待位置周辺の最小固有値マップ加重重心を返す。[cy, cx, peak] または None。"""
      y1 = max(0, int(ey) - int(hw)); y2 = min(int(sq_size), int(ey) + int(hw) + 1)
      x1 = max(0, int(ex) - int(hw)); x2 = min(int(sq_size), int(ex) + int(hw) + 1)
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

  def apply_remap(img, pts_y, pts_x, lo, hi, sq_size):
      """pts_y, pts_x は 10x10 のリスト。cv2.remap を適用して返す。"""
      py   = np.array(pts_y, dtype=np.float64)
      px   = np.array(pts_x, dtype=np.float64)
      sq   = int(sq_size); lo = float(lo); hi = float(hi)
      cell = (hi - lo) / 9.0
      exp  = np.array([lo + i * cell for i in range(10)], dtype=np.float64)
      oy_g, ox_g = np.mgrid[0:sq, 0:sq].astype(np.float64)
      i_idx = np.clip(((oy_g - lo) / cell).astype(int), 0, 8)
      j_idx = np.clip(((ox_g - lo) / cell).astype(int), 0, 8)
      t_y   = np.clip((oy_g - exp[i_idx]) / cell, 0.0, 1.0)
      t_x   = np.clip((ox_g - exp[j_idx]) / cell, 0.0, 1.0)
      map_y = ((1-t_y)*((1-t_x)*py[i_idx,   j_idx  ] + t_x*py[i_idx,   j_idx+1]) +
               t_y    *((1-t_x)*py[i_idx+1, j_idx  ] + t_x*py[i_idx+1, j_idx+1])).astype(np.float32)
      map_x = ((1-t_y)*((1-t_x)*px[i_idx,   j_idx  ] + t_x*px[i_idx,   j_idx+1]) +
               t_y    *((1-t_x)*px[i_idx+1, j_idx  ] + t_x*px[i_idx+1, j_idx+1])).astype(np.float32)
      return cv2.remap(img, map_x, map_y, cv2.INTER_LINEAR)

  def array_max(arr):
      return float(arr.max())

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
  # 1回目: ピクセル面積最大の成分を外枠とする
  n, labels, stats, _ = cv2.connectedComponentsWithStats(inv, connectivity: 8).to_a
  return nil if n.to_i <= 1

  outer_label = (1...n.to_i).max_by { |i| stats.item(i, cv2.CC_STAT_AREA).to_i }

  mask_for = ->(lbl, lbs) {
    cv2.compare(lbs, np.full(PY.shape(lbs), lbl, dtype: np.int32), cv2.CMP_EQ)
  }
  frame_mask = mask_for.(outer_label, labels)

  # 外枠内側マスク: 外枠を黒にした画像の隅から flood fill → 背景を塗りつぶす
  h, w = PY.shape(inv).to_a.map(&:to_i)
  interior_base = cv2.bitwise_not(frame_mask)         # 外枠=黒, それ以外=白
  flood_img = interior_base.copy
  CV2.flood_fill(flood_img, nil, 0, 0, 0)             # 隅(0,0)から背景を黒で塗る
  interior_mask = flood_img                           # 残った白 = 外枠の内側

  inner_inv = cv2.bitwise_and(inv, interior_mask)     # 内側の成分のみ

  n2, labels2, _, _ = cv2.connectedComponentsWithStats(inner_inv, connectivity: 8).to_a

  # 外枠凸包面積からセル面積を推定
  outer_hull_area = CV2.label_hull_area(labels, outer_label).to_f
  cell_area = outer_hull_area / 81.0

  canvas = PY.zeros3(h, w)
  PY.apply_mask_color(canvas, frame_mask, 0, 0, 0, 0, w, h, [255, 0, 0])  # 外枠: 青

  (1...n2.to_i).each do |i|
    hull_area = CV2.label_hull_area(labels2, i).to_f
    next if hull_area <= cell_area
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
  clean = inv.copy
  (1...n.to_i).each do |i|
    px_area  = stats.item(i, cv2.CC_STAT_AREA).to_i
    bw       = stats.item(i, cv2.CC_STAT_WIDTH).to_i
    bh       = stats.item(i, cv2.CC_STAT_HEIGHT).to_i
    bbox_area = bw * bh
    garbage = px_area  <= cell_area * 0.01         ||   # 1. pixel 面積が極小
              bw        >  bh * 1.5                ||   # 2. 横長
              ( bw >= bh && bbox_area <= cell_area * 0.10 ) # 3. 縦長でなく小さい
    next unless garbage
    mask = cv2.compare(labels, np.full(PY.shape(labels), i, dtype: np.int32), cv2.CMP_EQ)
    cv2.bitwise_and(clean, cv2.bitwise_not(mask), dst: clean)
  end
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

def correct_curvature( frame_warped, square, sq_size, outer_contour, corners )
  hi, lo, cell = grid_geometry( sq_size )

  hw        = [(cell * 0.40).to_i, 4].max
  hw_fine   = [(cell * 0.25).to_i, 4].max
  max_shift = cell * 0.35
  block     = [(cell * 0.08).to_i, 3].max
  block    += 1 if block.even?

  # 外枠4辺の直線からの最大ズレがセル幅の5%以内なら補正不要
  exp_y = 10.times.map { |i| lo + i * cell }
  exp_x = exp_y.dup
  pts_y = 10.times.map { |i| 10.times.map { |_j| exp_y[i] } }
  pts_x = 10.times.map { |_i| 10.times.map { |j| exp_x[j] } }
  return [square, pts_y, pts_x] if frame_curvature( outer_contour, corners ) < 0.05 / 9

  eigen_map     = CV2.corner_min_eigen_val( frame_warped, block, 3 )
  global_thresh = CV2.array_max( eigen_map ) * 0.01

  # 1パス目: 太線交点（行・列 0,3,6,9）を広い窓で検出し応答中央値を基準値とする
  thick = [0, 3, 6, 9]
  thick_responses = []
  thick.each do |i|
    thick.each do |j|
      r = CV2.eigen_window_centroid( eigen_map, exp_y[i], exp_x[j], hw, global_thresh, max_shift, sq_size )
      next unless r
      ra = r.to_a
      pts_y[i][j] = ra[0].to_f
      pts_x[i][j] = ra[1].to_f
      thick_responses << ra[2].to_f
    end
  end
  debug_puts( "thick_responses: #{thick_responses.map{|t| t.round(1)}}" )

  ref_response = thick_responses.empty? ? CV2.array_max( eigen_map ).to_f
                                        : thick_responses.sort[ thick_responses.size / 2 ]
  fine_thresh  = ref_response * 0.30

  # 2パス目: 16点の双線形補間で期待位置を推定し細線交点を検出
  10.times do |i|
    10.times do |j|
      next if thick.include?(i) && thick.include?(j)

      bi = [i / 3, 2].min * 3
      bj = [j / 3, 2].min * 3
      t  = (i - bi) / 3.0
      s  = (j - bj) / 3.0
      ey = (1-t)*(1-s)*pts_y[bi][bj]   + (1-t)*s*pts_y[bi][bj+3] +
           t    *(1-s)*pts_y[bi+3][bj] + t    *s*pts_y[bi+3][bj+3]
      ex = (1-t)*(1-s)*pts_x[bi][bj]   + (1-t)*s*pts_x[bi][bj+3] +
           t    *(1-s)*pts_x[bi+3][bj] + t    *s*pts_x[bi+3][bj+3]

      r = CV2.eigen_window_centroid( eigen_map, ey, ex, hw_fine, global_thresh, max_shift, sq_size )
      if r && r.to_a[2].to_f >= fine_thresh
        ra = r.to_a
        pts_y[i][j] = ra[0].to_f
        pts_x[i][j] = ra[1].to_f
      else
        pts_y[i][j] = ey
        pts_x[i][j] = ex
      end
    end
  end

  remapped = CV2.apply_remap( square, pts_y, pts_x, lo, hi, sq_size )
  [remapped, pts_y, pts_x]
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

def count_holes(cell_bin, debug_name: nil)
  cell_bin = digit_region(cell_bin)

  # 1px 白パディングを追加して外背景を必ず全周でつなげる。
  # これにより数字が画像端に接していても外背景と孤立した穴が正しく分離される。
  cell_bin = cv2.copyMakeBorder(cell_bin, 1, 1, 1, 1, cv2.BORDER_CONSTANT, value: 255)

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
  9.times do |row|
    9.times do |col|
      v = cells[row][col]
      next unless v > 0
      img = matched_imgs[row][col] || @tmpl_data[:digit_imgs_py][v - 1]
      paste_digit( canvas, img,
                     lo + col * cw + cw * 0.05, lo + row * cw,
                     target_h, [0, 0, 255], align: 'top-right')
    end
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
  9.times do |row|
    9.times do |col|
      next if init_cells[row][col] > 0
      v = answer[row][col]
      next unless v && v > 0
      paste_digit( canvas, @tmpl_data[:digit_imgs_py][v - 1],
                     lo + (col + 0.5) * cw, lo + (row + 0.5) * cw,
                     target_h, [255, 60, 60], align: 'center')
    end
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

  cells       = Array.new(9) { Array.new(9, 0) }
  matched_imgs = Array.new(9) { Array.new(9, nil) }
  (0..8).to_a.product((0..8).to_a).each do |row, col|
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
    row_idx   = [ (min_y / row_h).to_i, @tmpl_data[:num_rows] - 1 ].min

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

    cells[row][col]        = number
    matched_imgs[row][col] = template_digit_img_row( @tmpl_data[:tmpl_gray_py], number, row_idx, @tmpl_data[:num_rows] )
  end
  [cells, matched_imgs]
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
