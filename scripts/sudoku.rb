#!/usr/bin/env ruby
# sudoku.rb
#
# 使い方: ruby sudoku.rb <画像パス> [出力ディレクトリ]
# 標準出力: JSON { success, cells, answer, steps:[{label,path},...], error }
#
# 依存: pycall gem + Python opencv-python

require 'json'
require 'optparse'
require_relative 'sudoku_ocr'
require_relative 'sudoku_solver'

$O ||= {}
exit unless ARGV.options {|opt|
  opt.on( '-r', '--retry', 'enable retry' )
  opt.parse!( into: $O )
}

image_path  = ARGV[0]
@output_dir = ARGV[1] || File.join( __dir__, "sudoku_work")

load_params()
@out = { success: false, steps: [], cells: nil, answer: nil, error: nil }

t_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
t0 = t_start
lap = ->(label) {
  now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  @out[:time] ||= {}
  @out[:time][label] = ((now - t0) * 1000).round(1)
  t0 = now
}

begin
  raise ArgumentError, "画像パスを指定してください" unless image_path
  raise ArgumentError, "ファイルが存在しません: #{image_path}" unless File.exist?(image_path)

  input_img = cv2.imread(image_path)
  raise "画像を読み込めませんでした: #{image_path}" if input_img.nil? || input_img.size.to_i == 0
  lap.("00_load")

  #
  # (1) 前処理
  #
  gray_inv = preprocess( input_img )
  save_step( gray_inv, "01_binary.png", "二値化" )
  lap.("01_preprocess")

  #
  # (2) 外枠・数字の分離
  #
  frame_bin = detect_frame( gray_inv )
  raise "外枠を検出できませんでした" unless frame_bin
  save_step( frame_bin, "02_frame.png",  "枠線抽出" )
  lap.("02_detect_frame")

  #
  # (3) 最大輪郭の可視化
  #
  contours, _ = cv2.findContours( frame_bin.copy,
                                  cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE )
  outer_contour = contours.to_a.max_by { |c| CV2.contour_area(c).to_f }

  contour_img = cv2.cvtColor( frame_bin, cv2.COLOR_GRAY2BGR )
  PY.contour_pts( outer_contour).to_a.each do |p|
    CV2.circle( contour_img, p[0], p[1], 6, 0, 0, 255, -1 )
  end
  save_step(contour_img, "03_contour.png", "最大輪郭" )
  lap.("03_contour")

  #
  # (4) コーナー検出
  #
  corners = detect_corners( outer_contour )
  raise "外枠のコーナーを検出できませんでした" unless corners

  corners_img = cv2.cvtColor( frame_bin, cv2.COLOR_GRAY2BGR)
  corners.each_with_index do |c, i|
    CV2.circle( corners_img, c[0], c[1], 30, 0, 255, 0, 6)
    CV2.put_text( corners_img, i, c[0] + 20, c[1] + 0, cv2.FONT_HERSHEY_SIMPLEX, 4.0, 0, 0, 255, 8)
  end
  save_step( corners_img, "04_corners.png", "コーナー検出" )
  lap.("04_corners")

  #
  # (5) 枠内の数字だけの画像をできるだけ抽出する
  #
  # frame_bin 以外を digits_bin とする。
  # digits_bin は 0/255 の二値画像（数字=黒・背景=白）
  digits_mask = cv2.bitwise_and( gray_inv, cv2.bitwise_not( frame_bin ) )
  digits_bin  = CV2.threshold( digits_mask, 0, 255, cv2.THRESH_BINARY_INV )

  # さらに検出した4コーナーで囲まれた四角形の外側を digits_bin からマスクして除去
  h_, w_ = PY.shape( gray_inv ).to_a.map(&:to_i)
  quad_mask  = PY.full_gray(h_, w_, 0)
  CV2.fill_poly(quad_mask, corners, 255)
  digits_bin = cv2.bitwise_and(digits_bin, quad_mask)

  cell_area  = CV2.contour_area(outer_contour).to_f / 81.0
  digits_bin = remove_small_components( digits_bin, cell_area )

  save_step( digits_bin, "05_digits_only.png", "数字のみ" )
  lap.("05_digits")

  #
  # (6) 射影補正
  #
  sq_size = PY.shape( gray_inv ).to_a.map(&:to_i).min
  persp_m = get_perspective_transform( corners, sq_size )

  square, pts = normalize_grid( frame_bin, digits_bin, sq_size, outer_contour, corners, persp_m )
  lap.("06_warp_curvature")

  if pts
    # case 2: 元画像上の交点を元画像にプロット
    dbg = cv2.cvtColor( frame_bin, cv2.COLOR_GRAY2BGR )
    pts.each do |row|
      row.each do |x, y|
        CV2.circle( dbg, x, y, 8, 0, 0, 255, -1 )
      end
    end
  else
    # case 1: warpPerspective した枠線画像を表示
    warped_frame = cv2.warpPerspective( frame_bin, persp_m, [sq_size, sq_size] )
    dbg = cv2.cvtColor( warped_frame, cv2.COLOR_GRAY2BGR )
  end
  save_step( dbg, "06b_remap_debug.png", "曲げ補正交点" )

  warped_img = cv2.cvtColor( square, cv2.COLOR_GRAY2BGR )
  draw_grid( warped_img, sq_size )
  save_step( warped_img, "06_warped.png", "射影補正" )

  #
  # (7) 数字認識
  #
  load_digit_template()
  cells, matched_imgs, digit_bboxes = extract_numbers( square )

  recognized_img = cv2.cvtColor( square, cv2.COLOR_GRAY2BGR )
  draw_grid( recognized_img, sq_size )
  digit_bboxes.each do |x1, y1, x2, y2|
    cv2.rectangle( recognized_img, [x1.to_i, y1.to_i], [x2.to_i, y2.to_i], [255, 255, 0], 5 )
  end
  overlay = build_recognized_overlay( sq_size, cells, matched_imgs )
  mask    = CV2.threshold( CV2.bgr_to_gray(overlay), 1, 255, cv2.THRESH_BINARY )
  PY.copy_where( recognized_img, overlay, mask )
  save_step( recognized_img, "07_recognized.png", "数字認識" )
  lap.("07_ocr")

  raise "認識結果に矛盾があります（同じ行/列/ブロックに重複数字）" unless board_consistent?(cells)

  #
  # (8) 数独を解く
  #
  answer, process = Board::solve( cells.join( ' ' ) )
  raise "数独を解けませんでした（認識ミスの可能性があります）" unless answer
  lap.("08_solve")

  #
  # (9) 答えを重ね合わせ
  #
  result_img = overlay_answer( input_img, cells, answer, sq_size, persp_m, pts )
  save_step( result_img, "08_result.jpg", "解答" )
  lap.("09_overlay")

  @out[:time] ||= {}
  @out[:time]["total"] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_start) * 1000).round(1)

  @out.merge!( { success: true,
                 cells:   cells,
                 answer:  answer,
                 process: process,
                 steps:   @steps } )

rescue => e
  @out[:error]     = e.message
  @out[:backtrace] = e.backtrace&.first(5)
end

puts @out.to_json
