# 找房数据脚本共用的小工具（下载、读 shapefile、多边形计算、写 JSON 等）
# 放置位置：仓库里的 scripts/househunt_lib.rb
# 由 scripts/update_househunt.rb（西澳）、update_househunt_nsw.rb（新州）、update_househunt_vic.rb（维州）调用，自己不单独运行。

require "net/http"
require "json"
require "uri"
require "time"
require "date"
require "tmpdir"

DIR    = "data/househunt"
FAILED = []
Dir.mkdir(DIR) unless Dir.exist?(DIR)

def download(url, binary: false)
  uri = URI(url)
  3.times do
    begin
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 30, read_timeout: 300) do |http|
        http.get(uri.request_uri, "User-Agent" => "Mozilla/5.0")
      end
      if res.is_a?(Net::HTTPRedirection)
        uri = URI.join(uri.to_s, res["location"])
        next
      end
      return binary ? res.body : res.body.force_encoding("UTF-8") if res.is_a?(Net::HTTPSuccess)
    rescue StandardError => e
      warn "  下载出错 #{e.class}：#{url}"
    end
    sleep 5
  end
  nil
end

# 只问服务器"文件什么时候改过"，不下载文件本身
def last_modified(url)
  uri = URI(url)
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 30, read_timeout: 60) do |http|
    http.head(uri.request_uri, "User-Agent" => "Mozilla/5.0")
  end
  res["last-modified"]
rescue StandardError
  nil
end

def get_json(url)
  text = download(url) or raise "下载失败：#{url}"
  j = JSON.parse(text)
  raise j["error"]["message"].to_s if j.is_a?(Hash) && j["error"]
  j
end

# 查询 ArcGIS 图层的全部结果（一次最多 2000 条，自动翻页）
def arc_all(layer_url, params)
  out = []
  loop do
    q = { f: "json", resultOffset: out.size, resultRecordCount: 1000 }.merge(params)
    j = get_json("#{layer_url}/query?" + URI.encode_www_form(q))
    feats = j["features"] || []
    out.concat(feats)
    break if feats.empty? || !j["exceededTransferLimit"]
  end
  out
end

# 区名比较用：大写、去掉多余空格
def key_name(s)
  s.to_s.upcase.gsub(/\s+/, " ").strip
end

# 尝试做一件事；出错就记下来，保留旧文件
def step(name)
  yield
rescue StandardError => e
  warn "#{name} 失败：#{e.message}"
  FAILED << name
end

# "SOUTH PERTH" → "South Perth"，"O'CONNOR" → "O'Connor"，"ST COLUMBA'S" → "St Columba's"
def title_case(name)
  name.downcase.split(" ").map { |w| w.split("'").map(&:capitalize).join("'").sub(/'S\z/, "'s") }.join(" ")
end

def write_json(file, obj)
  File.write("#{DIR}/#{file}", JSON.pretty_generate(obj) + "\n")
end

# ---------- 小工具：多边形 ----------
def ring_area(r)
  s = 0.0
  r.each_cons(2) { |(x0, y0), (x1, y1)| s += x0 * y1 - x1 * y0 }
  s / 2
end

def point_in_rings?((x, y), rings)
  inside = false
  rings.each do |ring|
    j = ring.size - 1
    ring.each_with_index do |(xi, yi), i|
      xj, yj = ring[j]
      inside = !inside if (yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi
      j = i
    end
  end
  inside
end

# 多边形里面的一个点：先试面积中心，不在里面就横着找最宽的一段取中点
def interior_point(rings)
  ring = rings.max_by { |r| ring_area(r).abs }
  a = ring_area(ring)
  return ring[0] if a.abs < 1e-14
  cx = cy = 0.0
  ring.each_cons(2) { |(x0, y0), (x1, y1)| f = x0 * y1 - x1 * y0; cx += (x0 + x1) * f; cy += (y0 + y1) * f }
  cx /= 6 * a
  cy /= 6 * a
  return [cx, cy] if point_in_rings?([cx, cy], [ring])
  xs = []
  ring.each_cons(2) { |(x0, y0), (x1, y1)| xs << x0 + (cy - y0) * (x1 - x0) / (y1 - y0) if (y0 > cy) != (y1 > cy) }
  xs.sort!
  best, width = ring[0], -1
  xs.each_slice(2) { |p, q| next unless q; (best, width = [(p + q) / 2, cy], q - p) if q - p > width }
  best
end

# 边界线点太多时简化：去掉偏离不到 tol 度的点（0.0001 度约 10 米），形状基本不变，相邻两块之间也不会出现缝
def simplify(points, tol)
  return points if points.size < 4
  keep = Array.new(points.size, false)
  keep[0] = keep[-1] = true
  stack = [[0, points.size - 1]]
  until stack.empty?
    s, e = stack.pop
    next if e <= s + 1
    (ax, ay), (bx, by) = points[s], points[e]
    dx, dy = bx - ax, by - ay
    len2 = dx * dx + dy * dy
    far, idx = -1.0, nil
    (s + 1...e).each do |i|
      px, py = points[i]
      t = len2.zero? ? 0.0 : (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0)
      d = (px - ax - t * dx)**2 + (py - ay - t * dy)**2
      far, idx = d, i if d > far
    end
    next unless far > tol * tol
    keep[idx] = true
    stack << [s, idx] << [idx, e]
  end
  points.each_index.select { |i| keep[i] }.map { |i| points[i] }
end

# 写 JSON：说明信息在前，长长的名单每条一行（文件小，用眼睛也容易看）
def write_json_rows(file, meta, key, rows)
  lines = rows.is_a?(Hash) ? rows.map { |k, v| "    #{k.to_json}: #{v.to_json}" } : rows.map { |r| "    #{r.to_json}" }
  open_br, close_br = rows.is_a?(Hash) ? ["{", "}"] : ["[", "]"]
  parts = meta.map { |k, v| "  #{k.to_json}: #{JSON.generate(v)}" }
  parts << "  #{key.to_json}: #{open_br}\n#{lines.join(",\n")}\n  #{close_br}"
  File.write("#{DIR}/#{file}", "{\n#{parts.join(",\n")}\n}\n")
end

def read_shapefile(dir)
  shp = File.binread(Dir["#{dir}/*.shp"].first)
  dbf = File.binread(Dir["#{dir}/*.dbf"].first)
  # .dbf：每条记录的属性
  n, hlen, rlen = dbf[4, 4].unpack1("V"), dbf[8, 2].unpack1("v"), dbf[10, 2].unpack1("v")
  fields, off = [], 32
  while dbf.getbyte(off) != 0x0D
    fields << [dbf[off, 11].delete("\x00"), dbf.getbyte(off + 16)]
    off += 32
  end
  attrs = Array.new(n) do |i|
    rec, pos = dbf[hlen + i * rlen + 1, rlen - 1], 0
    fields.map { |name, len| v = rec[pos, len].force_encoding("UTF-8").strip; pos += len; [name, v] }.to_h
  end
  # .shp：每条记录的多边形（可能有好几块，含海岛）
  shapes, pos = [], 100
  while pos + 8 <= shp.bytesize
    len = shp[pos + 4, 4].unpack1("N") * 2
    c = shp[pos + 8, len]
    if [5, 15, 25].include?(c[0, 4].unpack1("l<"))
      nparts, npts = c[36, 8].unpack("l<l<")
      parts = c[44, 4 * nparts].unpack("l<*")
      pts = c[44 + 4 * nparts, 16 * npts].unpack("E*").each_slice(2).to_a
      shapes << parts.each_with_index.map { |s, i| pts[s...(parts[i + 1] || npts)] }
    else
      shapes << []
    end
    pos += 8 + len
  end
  attrs.zip(shapes)
end

# 简单的 CSV 拆分（有的格子带引号、里面有逗号）
def csv_cells(line)
  line.scan(/(?:\A|,)("(?:[^"]|"")*"|[^,]*)/).flatten.map { |v| v.start_with?('"') ? v[1..-2].gsub('""', '"') : v }
end

def csv_table(text)
  rows = text.split(/\r?\n/).reject(&:empty?)
  head = csv_cells(rows.shift)
  [head, rows.map { |l| csv_cells(l) }]
end

def with_bbox(h, rings)
  pts = rings.flatten(1)
  xs = pts.map(&:first)
  ys = pts.map(&:last)
  h.merge("rings" => rings, "bbox" => [xs.min, ys.min, xs.max, ys.max])
end

# 在一组多边形里找包含这个点的那一个
def locate(pt, list)
  list.find { |x| b = x["bbox"]; pt[0].between?(b[0], b[2]) && pt[1].between?(b[1], b[3]) && point_in_rings?(pt, x["rings"]) }
end

def month_add(ym, n)
  (Date.strptime(ym + "-01", "%Y-%m-%d") >> n).strftime("%Y-%m")
end

# ---------- 学区边界切块（新州、维州用） ----------
# 一个州的学区边界有好几 MB，网页不可能一次下载。所以切成大小不同的方块（学校密的地方切得小），
# 每块一个文件（t0.json、t1.json…），网页查某个地址时只下载那个地址所在的一块。
TILE_MAX_BYTES = 150_000

# 把一个多边形切到长方形里面（Sutherland–Hodgman 方法；只用来判断"点在不在里面"，切边多出来的线不影响）
def clip_ring(ring, x0, y0, x1, y1)
  pts = ring
  [[0, x0, 1], [0, x1, -1], [1, y0, 1], [1, y1, -1]].each do |axis, v, dir|
    inside = ->(p) { (p[axis] - v) * dir >= 0 }
    cut = lambda do |a, b|
      t = (v - a[axis]) / (b[axis] - a[axis])
      q = [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]
      q[axis] = v
      q
    end
    out = []
    pts.each_with_index do |cur, i|
      prev = pts[i - 1]
      if inside.(cur)
        out << cut.(prev, cur) unless inside.(prev)
        out << cur
      elsif inside.(prev)
        out << cut.(prev, cur)
      end
    end
    pts = out
    return nil if pts.size < 3
  end
  pts
end

def ring_box(r)
  xs = r.map(&:first)
  ys = r.map(&:last)
  [xs.min, ys.min, xs.max, ys.max]
end

# 一块方块：里面的学区（已经切好）太大就再分成 4 块
def build_tiles(dir, box, feats, depth, tiles)
  x0, y0, x1, y1 = box
  inside = feats.map do |f|
    rings = f[:rings].map do |r|
      b = ring_box(r)
      next nil if b[2] < x0 || b[0] > x1 || b[3] < y0 || b[1] > y1
      b[0] >= x0 && b[2] <= x1 && b[1] >= y0 && b[3] <= y1 ? r : clip_ring(r, x0, y0, x1, y1)
    end.compact
    rings.empty? ? nil : f.merge(rings: rings)
  end.compact
  return if inside.empty?
  body = inside.map { |f| [f[:id], f[:t], f[:ct], f[:rings].map { |r| r.map { |p| p.map { |v| v.round(5) } } }] }
  size = JSON.generate(body).bytesize
  if size > TILE_MAX_BYTES && depth < 12
    xm, ym = (x0 + x1) / 2.0, (y0 + y1) / 2.0
    [[x0, y0, xm, ym], [xm, y0, x1, ym], [x0, ym, xm, y1], [xm, ym, x1, y1]].each { |b| build_tiles(dir, b, inside, depth + 1, tiles) }
  else
    name = "t#{tiles.size}.json"
    File.write("#{dir}/#{name}", JSON.generate({ "b" => box.map { |v| v.round(6) }, "f" => body }) + "\n")
    tiles << box.map { |v| v.round(6) } + [name]
  end
end
