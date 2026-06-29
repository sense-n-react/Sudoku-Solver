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

begin
  raise ArgumentError, "画像パスを指定してください" unless image_path
  raise ArgumentError, "ファイルが存在しません: #{image_path}" unless File.exist?(image_path)

  img = cv2.imread(image_path)
  raise "画像を読み込めませんでした: #{image_path}" if img.nil? || img.size.to_i == 0

  #
  # (1) 前処理
  #
  _gray, inv = preprocess( img )
  save_step( inv, "01_binary.png", "二値化" )

  #
  # (2) 外枠・数字の分離
  #
  frame_bin = detect_frame(inv)
  raise "外枠を検出できませんでした" unless frame_bin
  save_step( frame_bin, "02_frame.png",  "枠線抽出" )

  # frame_bin 以外を digits_bin とする。
  # digits_bin は 0/255 の二値画像（数字=黒・背景=白）
  digits_mask  = cv2.bitwise_and( inv, cv2.bitwise_not( frame_bin ) )
  digits_bin   = CV2.threshold( digits_mask, 0, 255, cv2.THRESH_BINARY_INV )
  save_step( digits_bin, "03_digits_only.png", "数字のみ" )

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
  save_step(contour_img, "04_contour.png", "最大輪郭" )

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
  save_step( corners_img, "05_corners.png", "コーナー検出" )

  #
  # (5) 射影補正
  #
  sq_size = PY.shape(inv).to_a.map(&:to_i).min
  persp_m = get_perspective_transform( corners, sq_size )

  square = cv2.warpPerspective( digits_bin, persp_m, [sq_size, sq_size] )
  save_step( square, "06_warped.png", "射影補正" )

  #
  # (6) 数字認識
  #
  load_digit_template()
  cells = extract_numbers( square )

  recognized_img = cv2.cvtColor( square, cv2.COLOR_GRAY2BGR )
  overlay = build_recognized_overlay( sq_size, cells)
  mask    = CV2.threshold( CV2.bgr_to_gray(overlay), 1, 255, cv2.THRESH_BINARY )
  PY.copy_where( recognized_img, overlay, mask )
  save_step( recognized_img, "07_recognized.png", "数字認識" )

  raise "認識結果に矛盾があります（同じ行/列/ブロックに重複数字）" unless board_consistent?(cells)

  #
  # (7) 数独を解く
  #
  answer, process = Board::solve( cells.join( ' ' ) )

  raise "数独を解けませんでした（認識ミスの可能性があります）" unless answer

  #
  # (8) 答えを重ね合わせ
  #
  result_img = overlay_answer( img, cells, answer, sq_size, persp_m )
  save_step( result_img, "08_result.png", "解答" )

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
