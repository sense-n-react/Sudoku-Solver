#!/usr/bin/env ruby
# -*- coding:utf-8 -*-


# 数独を解く
# back-tracking ではなくロジックで解く
# --retry オプションで、back-trackin を行う
# stdin ：盤面データ
# stdout：途中経過、結果の盤面
#

require 'stringio'

$OPT_f = []
$O ||= {}

# 配列 a のチェーン
# [a,b,c] と [c,b,a] は同一とみなす
# [a,b,c] => [ [a],[a,b],[a,c],[a,b,c],[a,c,b], [b], [b,c], [b,a,c], [c] ]
#
def chains( a, top = true )
  if a.size == 1
    yield a
  else
    a.each do |m|
      next  if ! top && !( yield [m] )
      chains( a - [m], false ) do |ans|
        yield [m] + ans   if !top || m.xy_s < ans[-1].xy_s
      end
    end
  end
end

#
#
class Cell
  attr_reader   :x, :y
  attr_accessor :val

  def initialize( x, y, v )
    @x, @y = x, y
    @val = (v == 0)? [1,2,3,4,5,6,7,8,9] : [v]
  end

  def fixed?
    val.size <= 1
  end

  # 座標配列 [0,0] - [8,8]
  def pos
    [ @x, @y ]
  end

  # 可能性のある数字
  # " 123 567 9 "
  def to_s
    (1..10).map{ |v| @val.include?(v) ? v.to_s : ' ' }.join
  end

  # 座標文字列 (1,1) - (9,9)
  # "(3,4)"
  def xy_s
    "(%d,%d)" % [@x + 1, @y + 1]
  end

end  # class

#
# 盤面
# 9x9 の Cell の配列
#
class Board
  # Board#each, Board#select を使えるようにする
  include Enumerable

  def initialize( initval, escape:  )
    vals = initval.split
    @table = Array.new(9) do |y|
      Array.new(9) do |x|
        Cell.new( x, y, vals.shift.to_i )
      end
    end
    @opt = { escape: escape }
  end

  def to_a
    @table.map{ |cells| cells.map{ |c| c.val[0] || 0 } }
  end

  def each;        @table.flatten.each {|c| yield c }; end
  def at( x, y );  @table[y][x];   end

  def scan_unfixed_cell
    select {|c| !c.fixed? }.each { |cell|
      @prev = cell.val[0 .. -1]
      yield cell
    }
  end

  def done?;      @table.flatten.all? { |cell| cell.val.size == 1 }; end

  def copy(from);  each { |c| c.val = from.at( c.x, c.y ).val[ 0 .. -1] }; end


  # 同じ行の cell を列挙する
  def m_hline( cell, all = false )
    cells = (0..8).map {|x| at( x, cell.y ) }.select{ |c| all || c != cell }
    if block_given?
      cells.each { |c|  yield c }
    else
      cells
    end
  end

  # 同じ列の cell を列挙する
  def m_vline( cell, all = false )
    cells = (0..8).map {|y| at( cell.x, y ) }.select{ |c| all || c != cell }
    if block_given?
      cells.each { |c|  yield c }
    else
      cells
    end
  end

  # 同じブロックの cell を列挙する
  def m_box( cell, all = false )
    x0, y0 = (cell.x / 3) * 3,  (cell.y / 3) * 3
    cells = (y0.. y0+2 ).to_a.product( (x0.. x0+2 ).to_a ).
              map { |y, x| at( x, y ) }.
              select { |c| all || c != cell }

    if block_given?
      cells.each { |c|  yield c }
    else
      cells
    end
  end

  def m_box_of( x, y )
    m_box( at( (x + 9)% 9, (y + 9) % 9 ), true ) { |c| yield c }
  end

  # 同じ列／行／ボックス にあるか？
  def is_peer?( c1, c2 )
    c1.x == c2.x || c1.y == c2.y ||
      ( c1.x / 3 == c2.x / 3 && c1.y / 3 == c2.y / 3 )
  end

  # 同じ列（or行orボックス）で val があるのは c1, c2 のみ
  def is_pair?( c1, c2, v )
    sym =  ( c1.x == c2.x ) ? :m_vline :
           ( c1.y == c2.y ) ? :m_hline :
                              :m_box
    method(sym).( c1, true ).select{|c| c.val.include?( v ) }.size == 2
  end

  # cell の属する 列／行／ボックスの全てのセル
  def all_peers( cell, all = false )
    [ :m_hline, :m_vline, :m_box ]
      .flat_map{ |sym| method(sym).( cell, all ).to_a }.uniq
  end

  # c1, c2 に共通の列／行／ボックスに属するセル
  def common_cells ( c1, c2 )
    all_peers( c1 ) & all_peers( c2 )
  end

  #
  # Boardの表示
  #
  # +-----+-----+-----+-----+-----+-----+-----+-----+-----+
  # |     :     : 2   |     :   4 :     |  3  :1    :    5|
  # |  8  : 7 9 :     |67   :     :6  9 |     :     :     |
  # |- - -+- - -+- - -+- - -+- - -+- - -+- - -+- - -+- - -|
  # |  3  :     :1    | 2   :     :    5|     :     :   4 |
  # |     :6    :     |     :  8  :     | 7   :   9 :     |
  # |- - -+- - -+- - -+- - -+- - -+- - -+- - -+- - -+- - -|
  # |     :    5:   4 |1 3  :1 3  :  3  |     : 2   :     |
  # | 7 9 :     :     | 7   : 7 9 :   9 |  8  :     :6    |
  # +-----+-----+-----+-----+-----+-----+-----+-----+-----+
  # |    5:1    :  3 5|  3 5:     : 23  |    5:   4 : 2   |
  # | 7 9 :     : 789 | 7   :6    :  8  |   9 :     :   9 |
  # |- - -+- - -+- - -+- - -+- - -+- - -+- - -+- - -+- - -|
  # | 2   :   4 :    5|   45:    5:1    |     :  3  :     |
  # |     : 7 9 : 7 9 | 7   : 7   :     |6    :     :  8  |
  # |- - -+- - -+- - -+- - -+- - -+- - -+- - -+- - -+- - -|
  # |     :  34 :  3 5|     :  3 5: 234 |1   5:     :12   |
  # |6    :     :  8  |   9 :     :  8  |     : 7   :     |
  # +-----+-----+-----+-----+-----+-----+-----+-----+-----+
  # |1   5: 2   :     |1 345:1 3 5:  34 |1  4 :     :1 3  |
  # | 7 9 :     :6    |     :   9 :   9 |   9 :  8  : 7 9 |
  # |- - -+- - -+- - -+- - -+- - -+- - -+- - -+- - -+- - -|
  # |   4 :  3  :  3 5|     :1 3 5:     | 2   :     :1 3  |
  # |     :   9 :   9 |  8  :   9 : 7   |     :6    :   9 |
  # |- - -+- - -+- - -+- - -+- - -+- - -+- - -+- - -+- - -|
  # |1    :     :  3  |1 34 : 2   :  34 |1  4 :    5:1 3  |
  # | 7 9 :  8  : 7 9 |6    :     :6  9 |   9 :     : 7 9 |
  # +-----+-----+-----+-----+-----+-----+-----+-----+-----+
  # +-----------------------------+
  # | 8     2 |    4    | 3  1  5 |
  # | 3  6  1 | 2  8  5 | 7  9  4 |
  # |    5  4 |         | 8  2  6 |
  # |--------- --------- ---------|
  # |    1    |    6    |    4    |
  # | 2       |       1 |[6] 3  8 |
  # | 6       | 9       |    7    |
  # |--------- --------- ---------|
  # |    2  6 |         |    8    |
  # | 4       | 8     7 | 2  6    |
  # |    8    |    2    |    5    |
  # +-----------------------------+
  #
  def render( big = false, cell = nil )

    def esc( s ); @opt[:escape] ? "\033[7m#{s}\033[0m" :  s; end

    if $O[:debug] || big
      @table.each_with_index { |cells, y|
        puts (y % 3 == 0) ?
               '+-----+-----+-----+-----+-----+-----+-----+-----+-----+' :
               '|- - -+- - -+- - -+- - -+- - -+- - -+- - -+- - -+- - -|'

        [ 0, 5 ].each { |idx|
          puts "|%s:%s:%s|%s:%s:%s|%s:%s:%s|\n" %
               cells.map{ |c| c.to_s[idx,5].then{ c == cell ? esc(it) : it } }
        }
      }
      puts '+-----+-----+-----+-----+-----+-----+-----+-----+-----+'
    end

    puts '+-----------------------------+'
    @table.each_with_index { |cells, y|
      puts '|--------- --------- ---------|'  if y == 3 || y == 6
      puts "|%s%s%s|%s%s%s|%s%s%s|\n" %
           cells.map { |c|
        (c.fixed? ? c.val[0]: ' ').then{ (c == cell)?  "[#{it}]": " #{it} " }
      }
    }
    puts '+-----------------------------+'
  end

  def conflict?
    select {|c| c.fixed? }.any? do |cell|
      [ :m_hline, :m_vline, :m_box ].any? do |sym|
        method(sym).(cell).any? do |c|
          ( c.fixed? && c.val[0] == cell.val[0] ).tap do
            if it
              puts "conflict  #{c.xy_s} #{cell.xy_s} : #{c.val[0]}"
              render true, cell
            end
          end
        end
      end
    end
  end


  #
  # 確定している数を排除
  #
  def strategy_1
    scan_unfixed_cell{ |cell|
      [ :m_hline, :m_vline, :m_box ].each { |sym|
        method(sym).(cell).each { |c|
          if c.fixed? && cell.val.include?( c.val[0] )
            cell.val -= c.val
            @updated = true
            if cell.fixed?  || $O[:debug]
              yield [cell, "! Naked Single #{sym}  #{c.val[0]} at #{c.xy_s}"]
              return
            end
          end
        }
      }
    }
  end

  # その cell にしか含まれていない数
  def strategy_2
    scan_unfixed_cell{ |cell|
      [ :m_hline, :m_vline, :m_box ].each { |sym|
        v = cell.val - method(sym).(cell).inject([]){ |vals,c| vals + c.val }
        if  v.size > 0 &&  v.size < cell.val.size
          cell.val = v
          @updated = true
          if  cell.fixed? || $O[:debug]
            yield  [cell, "* Hidden Single in #{sym}" ]
            return
          end
        end
      }
    }
  end


  #    L  M  N
  #    v  .  .      cell.x = L のとき
  #    v  .  .      隣接ブロックで、「L列にしかない v 」があれば
  #    .  .  .      cell は v ではない
  #
  #   !v  .  .
  #
  OFFSETS = { BELOW: [0,3], ABOVE: [0,6], RIGHT: [3,0], LEFT: [6,0] }
  def strategy_3
    scan_unfixed_cell{ |cell|
      OFFSETS.each {|dir, (ox,oy)|
        v, w = m_box( at( (cell.x + ox)% 9, (cell.y + oy) % 9 ), true ).
          each_with_object( [[],[]]) { |c, (v_,w_) |
          if  c.pos  == cell.pos
            v_ |= c.val
          else
            w_ |= c.val
          end
        }
        if (cell.val & ( v - w )).size > 0
          cell.val -= (v - w)
          @updated = true
          if cell.fixed?  || $O[:debug]
            yield  [cell, "!! Locked Candidates  #{dir} block has [#{(v-w).join(',')}]" ]
            return
          end
        end
      }
    }
  end


  #  他の２ブロックの異なる列に v がなければ
  #  そのcellに v はない
  #
  #  L  !v .  .   .  .  .   .  .  .
  #  M  .  .  .   !v !v !v  !v !v !v
  #  N  .  .  .   .  .  .   .  .  .
  #
  def strategy_5
    def other_6cells( cell, xy, d )
      ii, jj = (xy == :X)? [cell.x, cell.y] : [cell.y, cell.x]
      i0 = ( ii / 3 ) * 3
      j  = ( jj / 3 ) * 3 + ( jj + d ) % 3
      (i0+3).upto(i0+8).map { |i|  (xy == :X)? at(i%9, j) : at(j, i%9) }
    end

    scan_unfixed_cell{ |cell|
      [ [:X, 1], [:X, 2], [:Y, 1], [:Y, 2] ].each { |xy,d|
        v = [1,2,3,4,5,6,7,8,9] - other_6cells( cell, xy, d )
                                    .inject([]) {|vals,c| vals + c.val }
        if ( cell.val & v ).size > 0
          @updated = true
          cell.val -= v
          yield [cell, "!!! Locked Candidates #{xy}#{d}" ]
          return
        end
      }
    }
  end

  # あるブロック／列で、特定のＮ個の数 n1,n2..nN を含むセルが
  # Ｎ個しかないなら、そのＮ個のセルには n1,n2..nN 以外 はあり得ない。
  # そして、残りのセルには n1,n2..nN は含まれない。
  #
  #  L  a,b,c  .  .    .   .   a,b,c        . .  a,b,c      .....
  #
  S6_TABLE =
    [
     [:m_hline, (0..8).map { |y| [0,y] } ],
     [:m_vline, (0..8).map { |x| [x,0] } ],
     [:m_box,   [0,3,6].product( [0,3,6] ) ],
    ]
  def strategy_6
    def each_m
      # 未確定の数の組み合わせ（２つ以上）
      2.upto(5) {|n|
        # block/line
        S6_TABLE.each {|sym, m|
          # method
          m.each {|xy|
            yield [ n, sym, xy]
          }
        }
      }
    end

    each_m {|n, sym, xy|
      cell = at( xy[0],xy[1] )
      # 未確定の数
      unfixed_num = []
      method(sym).(cell,true) { |c|
        unfixed_num |= c.val  unless c.fixed?
      }
      unfixed_num.combination( n ).each { |nums|
        rem = unfixed_num - nums
        cells_all   = []        # [n1,n2, X,Y], [n2,n3, Y], [n1,n2],,
        cells_exact = []        # [n1,n2,n3]
        cells_include = []      # [n1,n2],[n2],,,,
        # nums = [n1,n2,..nn] を含むセル
        method(sym).(cell,true) { |c|
          if (c.val & nums).size() > 0
            cells_all << c                # ひとつでも含む
            if (c.val - nums).size == 0
              cells_include << c          # nums 以外を含まない
              if c.val.size == n
                cells_exact << c          # nums と同じ
              end
            end
          end
        }
        # nums以外を含むセルが全然ない
        next  if cells_all.size == cells_include.size

        # numsを含むセルがN個しかない => nums 以外の数を排除
        if cells_all.size() == n
          (cells_all - cells_include).each { |c|
            @updated = true
            @prev = c.val[0 .. -1]
            c.val -= (@prev - nums)
            yield [c, "strategy6: Naked Pair #{nums} in #{sym}:#{cell.xy_s}" ]
          }
          return
        end

        # nums を含むセルがN+α個あって、nums と同じセルが N個ある
        # => ＋αから nums を削除
        if  cells_exact.size() == n
          (cells_all - cells_exact).each { |c|
            @updated = true
            @prev = c.val[0 .. -1]
            c.val -= nums
            yield [c, "strategy6: Hidden Pair #{nums} in #{sym}:#{cell.xy_s}" ]
          }
          return
        end

      } #combination
    } # for_m
  end

  #
  # X-Wing
  #
  def strategy_xwing
    # 1 - 9 までの数字
    1.upto(9) {|n|
      scan_unfixed_cell{ |cell|
        # cell とは異なるbox の未決セルをスキャンする

        0.upto(8).to_a.product( 0.upto(8).to_a ).each { |xy|
          diag = at(*xy)
          next   if  diag.y/3 == cell.y/3
          next   if  diag.x/3 == cell.x/3
          next   if  diag.fixed?

          # X-WING の４つの頂点が n を含むか
          next unless [ diag, cell, at(diag.x, cell.y), at(cell.x, diag.y) ]
                        .all? {|cc| cc.val.include?(n) }

          # X-WING の各辺に含まれる n の数
          h_n1 = m_hline( cell, true ).select{ it.val.include?(n) }.size
          h_n2 = m_hline( diag, true ).select{ it.val.include?(n) }.size
          v_n1 = m_vline( cell, true ).select{ it.val.include?(n) }.size
          v_n2 = m_vline( diag, true ).select{ it.val.include?(n) }.size
          #p [ :n, n,  [x, y], [cell.x, cell.y], h_n1, h_n2, v_n1, v_n2 ]

          c = nil
          # 縦ライン
          if  ( h_n1 + h_n2 == 4 ) && ( v_n1 + v_n2 > 4 )
            [[cell, diag], [diag, cell]].each {|c1, c2|
              m_vline( c1 ) { |cc|
                if  cc.y != c2.y && cc.val.include?(n)
                  c = cc
                  break
                end
              }
            }
          end
          # 横ライン
          if  ( h_n1 + h_n2 > 4 ) && ( v_n1 + v_n2  == 4 )
            [[cell, diag], [diag, cell]].each {|c1, c2|
              m_hline( c1 ) { |cc|
                if  cc.x != c2.x && cc.val.include?(n)
                  c = cc
                  break
                end
              }
            }
          end

          if c
            @updated = true
            @prev = c.val[0 .. -1]
            c.val -= [ n ]
            yield [c, "strategy_X-WING: #{n}:#{cell.xy_s}-#{diag.xy_s}" ]
            return
          end
        }
      }
    }

  end

  #
  # XY-Chain
  #
  # ２候補しかないセルのチェインをたどる
  #
  def strategy_chain
    commons = []
    # ２候補の内、どちらを選ぶか
    [0,1].each {|idx|
      # ２候補しかないセルの順列を数え上げる
      chains( select{ |c| c.val.size == 2 } ) {|chain|
        block_ret = true
        prev_c    = chain[0]
        v_start, val  = prev_c.val[idx], prev_c.val[1-idx]
        chain[1..-1].each {|c|
          # 値がchain していて、同じ列／行／ブロックにあるか
          if c.val.include?( val ) &&
              is_peer?( prev_c, c ) &&
              is_pair?( prev_c, c, val )

            val  = (c.val - [val])[0]
            prev_c  = c
          else
            # chain しない順列はそれ以上数え上げない
            block_ret = false
            break
          end
        }
        # ３個以上のチェインで、始まりと終わりが同じ値を持ち、
        # 始まりと終わりが同じ列／行／ブロックにないものを抽出する
        if block_ret && chain.size >= 3 &&
            v_start == val &&
            ! is_peer?( chain[0], chain[-1] )

          # 二つのセルに共通の 列／行／ブロックに存在するcell で
          # v_start を含むもの
          common = common_cells( chain[0], chain[-1] ).
                       select{|c| c.val.include?( v_start ) }

          if common.size > 0
            p [ v_start, chain.map{|c| c.xy_s}.join('=>') ]
            p [ 'common', common.map{ |c| "#{c.xy_s}[#{c}]" } ]
            commons <<
              [ v_start,
                chain,
                common.min{|a,b| a.val.size <=> b.val.size } #候補数が最少のセル
              ]
          end
        end
        block_ret
      } # chains
    } # [0,1]

    if commons.size > 0
      # 最小手数で終わらせたいので
      # 候補の少ないセルでチェインが短いものを選ぶ
      commons.sort!{ |a,b|
        v_start_a, chain_a, cell_a = a
        v_start_b, chain_b, cell_b = b
        if  cell_a.val.size != cell_b.val.size
          # 候補数の少ないもの
          cell_a.val.size  <=> cell_b.val.size
        else
          # 候補数が同じならチェインの短いセル
          chain_a.size <=> chain_b.size
        end
      }
      v_start, chain, c = commons[0]
      @updated = true
      @prev = c.val[0 .. -1]
      c.val -= [v_start]
      yield [c, "strategy_chain: #{chain.map{|c| c.xy_s}.join('->')}: #{v_start} " ]
    end
  end

  #
  # 指定した座標に値をセットする
  #
  def strategy_force
    return unless $OPT_f.size > 0

    x,y, v = $OPT_f.shift.match( /(\d),(\d)=(-?\d)/ ).to_a[1,3].map{|s| s.to_i }
    c = at( x-1, y-1 )
    unless c.fixed?
      @updated = true
      @prev = c.val[0 .. -1]
      if v > 0
        c.val = [v]
      else
        c.val -= [-v]
      end
      yield [c, "strategy_force: force #{v}" ]
    end
  end

  # 解けるまで strategy_1, strategy_2, ,,, を適用する
  def solve
    @updated = true
    while @updated
      [ 1, 2, 3, 5, 6, :xwing, :chain, :force ].each { |s|
        @updated = false
        self.send( "strategy_#{s}" ) { |cell, msg|
          if $O[:interactive]
            print ">"
            $stdin.gets
          end
          return false  if conflict?()       # 矛盾が発生

          next if  $O[:suppress]
          printf( "%s %s | %s %s\n",
                  cell.xy_s, msg, @prev,
                  ( msg[0] == '*' )? "-> #{cell.val}" : "- #{@prev - cell.val}" )
          render $O[:verbose], cell
        }
        break  if @updated
      }
    end
    return done?  if done? || !$O[:retry]

    #
    # 解けなかった場合、適当な数字を選んで retry する
    #
    # 現在の盤面を保存
    save = Board.new( '', escape: @opt[:escape] )
    save.copy( self )

    # 未確定セルの中で最も候補の数が少ないセル
    cell = select{ |c| !c.fixed? }.sort{ |a,b| a.val.size <=> b.val.size }[0]

    # 可能性を試す
    cell.val.each { |maybe_val|
      p [ 'try++ @', maybe_val, cell ]

      render  true, cell
      # 可能性のある数をとりあえず入れて解く
      cell.val = [maybe_val]
      render  false, cell

      # 解けたら retun
      return true   if solve()
      if solve()
        puts( "====================== SOLVED =======================" )
      end
      # ダメだったら次の候補を試す
      copy( save )
      p [ 'try-- @', cell]
    }
    return false
  end

  #
  # solver 呼び出し
  # number: 空白区切りの 81個の数字
  # swap_stdout: solver 内の puts を StringIO に書く
  # escape: render 時に escape シーケンスを使う
  #
  def self.solve( numbers, swap_stdout: true, escape: false )

    org_stdout = $stdout
    output     = StringIO.new
    $stdout     = output  if swap_stdout

    table = Board.new( numbers, escape: escape )
    table.render( true )   unless $O[:suppress]
    done = table.solve
    table.render( true )   unless $O[:suppress]
    puts( done ? "done": "not solved" )

    $stdout = org_stdout  if swap_stdout
    output.rewind

    # 結果：[盤面の文字列、途中経過の文字列]
    [ (done ? table.to_a : nil), output.gets(nil) ]
  end

end

#####################################################################

if __FILE__ == $0
  require 'optparse'
  exit unless ARGV.options {|opt|
    opt.on( '-d', '--debug' )
    opt.on( '-i', '--interactive' )
    opt.on( '-v', '--verbose'     )
    opt.on( '-r', '--retry', 'enable retry' )
    opt.on( '-n', '--suppress')
    opt.on( '-t', '--trans AXIS', 'X,Y:mirror inversion, R: 45deg rotation' )
    opt.on( '-f', '--force XYV', 'force set XYV : "x,y=val"') { |v|
      $OPT_f << v
    }
    opt.parse!( into: $O )
  }

  sample = "
. . .  1 . 2  . . .
. 4 .  . . .  . 9 .
. . 2  . 8 .  4 . .

. . 9  . 3 .  6 . .
5 . .  . . .  . . 7
. 8 .  . . .  . 1 .

. . .  3 . 5  . . .
7 . .  . . .  . . 1
. 3 4  2 . 6  8 5 .
"
  nums_9x9 = ( ARGV[0] ? gets(nil) : sample ).split.each_slice(9).to_a

  # 鏡像、回転
  $O[:trans].to_s.chars.each do |t|
    nums_9x9 = case t
           when /X/i; nums_9x9.map { |line| line.reverse }
           when /Y/i; nums_9x9.reverse
           when /R/i; nums_9x9.transpose
           else nums_9x9
           end
  end

  p Board.solve( nums_9x9.join(' ' ), swap_stdout: false, escape: true )
end
