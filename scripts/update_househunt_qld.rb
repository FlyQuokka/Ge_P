# 找房页面（第三页）昆州（QLD）部分的数据更新脚本
# 放置位置：仓库里的 scripts/update_househunt_qld.rb（共用的小工具在 scripts/househunt_lib.rb）
#
# 生成的文件（都在 data/househunt/qld/ 里）：
#   suburbs.json          昆州所有区（locality）：名称、邮编、范围                         —— 昆州政府 QSpatial、澳洲统计局（邮编区）
#   schools.json          昆州学校：公立（含 3 所 Queensland Academies）和非公立              —— 昆州政府 QSpatial（教育部、NSSAB）
#   catchments/*.json     公立学校学区（catchment）的边界，切成小块，网页只下载用得到的那一块   —— 昆州教育部
#   crime.json            每个区所在警务分区（police division）最近 12 个月的罪案数和每千人比率 —— 昆州警察局 QPS
#
# 房子本身的隐藏信息（community titles scheme、洪水、山火、遗产等）不在这里下载：网页查地址时直接去政府地图服务查。
# 每一项单独处理；某一项失败时保留它原来的文件，其他照常更新，最后报告哪些失败了。

require_relative "househunt_lib"

QLD_DIR   = "#{DIR}/qld"
QLD_CATCH = "#{QLD_DIR}/catchments"
[QLD_DIR, QLD_CATCH].each { |d| Dir.mkdir(d) unless Dir.exist?(d) }
QSPATIAL = "https://spatial-gis.information.qld.gov.au/arcgis/rest/services"
QLD_POA  = "https://geo.abs.gov.au/arcgis/rest/services/ASGS2021/POA/MapServer/0"
SCHOOLS_SVC = "#{QSPATIAL}/Society/SchoolsAndSchoolCatchments/MapServer"

# 多边形里取一些点（格子上的点，在多边形里面的才要），用来判断一个区"大部分"在哪个邮编、哪个警务分区
def sample_points(rings, bbox, n = 7)
  pts = []
  n.times do |i|
    n.times do |j|
      p = [bbox[0] + (bbox[2] - bbox[0]) * (i + 0.5) / n, bbox[1] + (bbox[3] - bbox[1]) * (j + 0.5) / n]
      pts << p if point_in_rings?(p, rings)
    end
  end
  pts.empty? ? [interior_point(rings)] : pts
end

# 一组点大多落在哪个多边形（list 里每项有 rings、bbox）
def majority(pts, list, key)
  votes = Hash.new(0)
  pts.each { |p| hit = locate(p, list); votes[hit[key]] += 1 if hit }
  votes.max_by { |_, n| n }&.first
end

# ---------- 1. 昆州所有区（locality）：名称、邮编、范围 ----------
# 昆州的地址库没有邮编，所以用澳洲统计局的邮编区（POA）：区里面取一些点，看大多数落在哪个邮编
QLD_SUBURBS = []
step("昆州区域名单") do
  poas = arc_all(QLD_POA, where: "poa_code_2021 LIKE '4%'", outFields: "poa_code_2021", returnGeometry: true, outSR: 4326,
                 maxAllowableOffset: 0.001, orderByFields: "objectid")
           .select { |f| f["geometry"] }.map { |f| with_bbox({ "p" => f["attributes"]["poa_code_2021"].to_s }, f["geometry"]["rings"]) }
  raise "邮编区太少（#{poas.size}）" if poas.size < 400
  feats = arc_all("#{QSPATIAL}/PlanningCadastre/LandParcelPropertyFramework/MapServer/19", where: "1=1", outFields: "locality,lga",
                  returnGeometry: true, outSR: 4326, maxAllowableOffset: 0.001, orderByFields: "objectid")
  feats.each do |f|
    rings = (f["geometry"] || {})["rings"] or next
    s = with_bbox({ "n" => f["attributes"]["locality"].to_s.strip, "lga" => f["attributes"]["lga"].to_s }, rings)
    s["samples"] = sample_points(rings, s["bbox"])
    s["p"] = majority(s["samples"], poas, "p").to_s
    QLD_SUBURBS << s
  end
  list = QLD_SUBURBS.uniq { |s| [s["n"], s["p"]] }.sort_by { |s| [s["n"], s["p"]] }
  raise "区太少（#{list.size}）" if list.size < 3000
  File.write("#{QLD_DIR}/suburbs.json", "[\n" + list.map { |s| { "n" => s["n"], "p" => s["p"], "bbox" => s["bbox"].map { |v| v.round(4) } }.to_json }.join(",\n") + "\n]\n")
  puts "昆州区域名单：#{list.size} 个（#{QLD_SUBURBS.count { |s| s["p"].empty? }} 个查不到邮编）"
end

# ---------- 2. 学校 ----------
# 公立学校分在几个图层：小学、初中（7–9 年级）、高中（10–12 年级）、其他中学（含 3 所 Queensland Academies）、特殊学校
QLD_ACADEMIES = %w[5684 5685 5727]   # Queensland Academies：10–12 年级按申请和考核录取，没有学区（类似精英中学）

def qld_points(layer, fields)
  arc_all("#{SCHOOLS_SVC}/#{layer}", where: "1=1", outFields: fields, returnGeometry: true, outSR: 4326, orderByFields: "objectid")
end

def qld_town(pt)
  s = locate(pt, QLD_SUBURBS)
  s && s["n"]
end

step("昆州学校") do
  publics = {}
  { 4 => "P", 5 => "S", 6 => "S", 7 => "M", 8 => "X" }.each do |layer, kind|
    qld_points(layer, "centre_name,centre_code").each do |f|
      a, g = f["attributes"], f["geometry"]
      next unless g && g["x"]
      code = a["centre_code"].to_s.strip
      s = publics[code] ||= { "c" => code, "n" => a["centre_name"].to_s.gsub(/\s+/, " ").strip, "g" => 1, "kinds" => [],
                              "lat" => g["y"].round(5), "lon" => g["x"].round(5) }
      s["kinds"] << kind
    end
  end
  publics.each_value do |s|
    k = s.delete("kinds").uniq
    s["k"] = if QLD_ACADEMIES.include?(s["c"]) then "S"
             elsif k.include?("P") && k.include?("S") then "K12"
             elsif k.include?("P") then "P"
             elsif k.include?("S") then "S"
             else "X"
             end
    s["sel"] = "F" if QLD_ACADEMIES.include?(s["c"])
    s["sx"] = s["n"] =~ /\bGirls\b/i ? "G" : s["n"] =~ /\bBoys\b/i ? "B" : nil
    s["t"] = qld_town([s["lon"], s["lat"]])
  end
  raise "公立学校太少（#{publics.size}）" if publics.size < 1100
  privates = qld_points(9, "name,centre_code,location,type_of_education,school_status,latitude,longitude").map do |f|
    a = f["attributes"]
    next unless a["school_status"].to_s =~ /open/i
    lat, lon = a["latitude"].to_f, a["longitude"].to_f
    next if lat.zero? || lon.zero?
    kind = { "Primary" => "P", "Secondary" => "S", "Primary and secondary" => "K12" }[a["type_of_education"].to_s.strip] || "X"
    { "c" => "n" + a["centre_code"].to_s, "n" => a["name"].to_s.strip, "g" => 0, "k" => kind, "lat" => lat.round(5), "lon" => lon.round(5),
      "t" => a["location"].to_s.strip }
  end.compact.uniq { |s| s["n"] }
  schools = (publics.values + privates).map { |s| s.reject { |_, v| v.nil? || v == "" } }.sort_by { |s| s["n"] }
  sel = schools.select { |s| s["sel"] }
  raise "Queensland Academies 对不上（#{sel.map { |s| s["n"] }.join("、")}）" unless sel.size == QLD_ACADEMIES.size
  meta = { "source" => "Queensland Government (QSpatial): Schools and school catchments; non-state schools from the Non-State Schools Accreditation Board",
           "updated" => Time.now.utc.iso8601,
           "kinds" => { "P" => "小学", "S" => "中学", "K12" => "小学到中学", "X" => "特殊学校等" },
           "selective" => { "F" => "Queensland Academies（10–12 年级申请入学，没有学区）" } }
  write_json_rows("qld/schools.json", meta, "schools", schools)
  puts "昆州学校：公立 #{publics.size} 所（Queensland Academies #{sel.size} 所），非公立 #{privates.size} 所"
end

# ---------- 3. 公立学校学区（catchment） ----------
# 小学、初中（7–9 年级）、高中（10–12 年级）各一个图层。大多数中学的初中和高中学区一样，网页上会合并
QLD_ZONE_LAYERS = { 1 => ["P", "P"], 2 => ["S", "Y7"], 3 => ["S", "SR"] }

step("昆州学区") do
  # 数据日期 + 数量没变就不用重新计算
  stamps = QLD_ZONE_LAYERS.keys.map do |l|
    j = get_json("#{SCHOOLS_SVC}/#{l}/query?" + URI.encode_www_form(where: "1=1", outFields: "data_currency", returnDistinctValues: true,
                                                                   returnGeometry: false, f: "json"))
    n = get_json("#{SCHOOLS_SVC}/#{l}/query?" + URI.encode_www_form(where: "1=1", returnCountOnly: true, f: "json"))["count"]
    "#{l}:#{(j["features"] || []).map { |f| f["attributes"]["data_currency"] }.sort.join("/")}:#{n}"
  end
  stamp = stamps.join(" ")
  old = (JSON.parse(File.read("#{QLD_CATCH}/index.json")) rescue nil)
  if old && old["source_modified"] == stamp
    puts "昆州学区：教育部没有更新学区（#{stamp}），不用重新计算"
    next
  end
  feats = []
  QLD_ZONE_LAYERS.each do |layer, (t, ct)|
    arc_all("#{SCHOOLS_SVC}/#{layer}", where: "1=1", outFields: "centre_code", returnGeometry: true, outSR: 4326,
            maxAllowableOffset: 0.00002, orderByFields: "objectid").each do |f|
      rings = ((f["geometry"] || {})["rings"] || []).map { |r| simplify(r, 0.00002) }.select { |r| r.size >= 4 }
      feats << { id: f["attributes"]["centre_code"].to_s.strip, t: t, ct: ct, rings: rings } unless rings.empty?
    end
  end
  # 同一所中学的高中学区和初中学区一模一样时，只留初中的（大多数中学都是这样，可以省一半空间）
  junior = feats.select { |f| f[:ct] == "Y7" }.map { |f| [f[:id], f[:rings]] }.to_h
  before = feats.size
  feats.reject! { |f| f[:ct] == "SR" && junior[f[:id]] == f[:rings] }
  puts "昆州学区：#{before - feats.size} 个高中学区和初中学区相同，已合并"
  raise "学区太少（#{feats.size}）" if feats.size < 1400
  all = feats.flat_map { |f| f[:rings] }.flatten(1)
  root = [all.map(&:first).min - 0.001, all.map(&:last).min - 0.001, all.map(&:first).max + 0.001, all.map(&:last).max + 0.001]
  Dir["#{QLD_CATCH}/t*.json"].each { |f| File.delete(f) }
  tiles = []
  build_tiles(QLD_CATCH, root, feats, 0, tiles)
  index = { "source" => "Queensland Department of Education, state school catchments (QSpatial)", "source_modified" => stamp,
            "enrolment_year" => Time.now.year, "updated" => Time.now.utc.iso8601,
            "types" => { "P" => "小学", "Y7" => "初中（7–9 年级）", "SR" => "高中（10–12 年级）" }, "tiles" => tiles }
  File.write("#{QLD_CATCH}/index.json", JSON.generate(index) + "\n")
  sizes = Dir["#{QLD_CATCH}/t*.json"].map { |f| File.size(f) }
  puts "昆州学区：#{feats.size} 个学区，切成 #{tiles.size} 块，最大 #{sizes.max / 1024} KB，合计 #{sizes.sum / 1024} KB"
end

# ---------- 4. 犯罪统计（QPS：每个警务分区每月、每种罪名的数量；每月更新） ----------
QPS = "https://open-crime-data.s3-ap-southeast-2.amazonaws.com"
QPS_NUM   = "#{QPS}/Crime%20Statistics/division_Reported_Offences_Number.csv"
QPS_RATE  = "#{QPS}/Crime%20Statistics/division_Reported_Offences_Rates.csv"
QPS_DIVS  = "#{QPS}/document/QPS_DIVISIONS.zip"
QLD_CRIME_FILE = "#{QLD_DIR}/crime.json"
# 全部罪案 = 三个大类加起来
QLD_TOTAL_COLS = ["Offences Against the Person", "Offences Against Property", "Other Offences"]
# key → [中文名, QPS 的栏目]。key 和其他州一样，网页可以共用（昆州没有单独的家暴攻击，用"违反家暴保护令"）
QLD_CRIME_CATS = {
  "burglary_dwelling" => ["入室盗窃",         ["Unlawful Entry With Intent - Dwelling"]],
  "stealing_mv"       => ["偷车",             ["Unlawful Use of Motor Vehicle"]],
  "stealing_from_mv"  => ["车内财物被偷",     ["Vehicles (steal from/enter with intent)"]],
  "property_damage"   => ["财物损坏",         ["Other Property Damage", "Arson"]],
  "assault"           => ["人身攻击",         ["Assault"]],
  "family_violence"   => ["违反家暴保护令",   ["Breach Domestic Violence Protection Order"]],
  "robbery"           => ["抢劫",             ["Robbery"]],
  "drugs"             => ["毒品",             ["Drug Offences"]]
}
QLD_CRIME_KEYS = ["total"] + QLD_CRIME_CATS.keys
MON = %w[JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC]

# "OCT26" → 2026-10
def qps_month(s)
  m = MON.index(s[0, 3]) or return nil
  format("%04d-%02d", 2000 + s[3, 2].to_i, m + 1)
end

# 读 QPS 的大 CSV：每个分区每个月一行。返回 { 分区 => { "2026-10" => [每个 key 的数] } }
def read_qps(path, cols_of)
  out = Hash.new { |h, k| h[k] = {} }
  File.open(path, encoding: "UTF-8") do |io|
    head = csv_cells(io.gets.to_s.strip.delete_prefix([0xFEFF].pack("U")))
    idx = cols_of.transform_values { |names| names.map { |n| head.index(n) or raise "犯罪统计表头变了（没有 #{n}）" } }
    raise "犯罪统计格式变了" unless head[0] == "Division" && head[1] == "Month Year"
    io.each_line do |line|
      c = csv_cells(line.strip)
      ym = qps_month(c[1].to_s) or next
      out[c[0].strip][ym] = idx.map { |_, is| is.sum { |i| c[i].to_f } }
    end
  end
  out
end

step("昆州犯罪统计") do
  raise "区域名单没有准备好" if QLD_SUBURBS.empty?
  stamp = [last_modified(QPS_NUM), last_modified(QPS_RATE), last_modified(QPS_DIVS)]
  old = (JSON.parse(File.read(QLD_CRIME_FILE)) rescue nil)
  if old && stamp.include?(nil)
    puts "昆州犯罪统计：暂时查不到 QPS 有没有发布新数据，先用现有数据，明天再查"
    next
  end
  if old && old["inputs"] == { "crime" => stamp }
    puts "昆州犯罪统计：QPS 还没有发布新数据，不用重新计算"
    next
  end
  cols = { "total" => QLD_TOTAL_COLS }.merge(QLD_CRIME_CATS.transform_values(&:last))
  nums = rates = divs = nil
  Dir.mktmpdir do |tmp|
    File.binwrite("#{tmp}/num.csv", download(QPS_NUM, binary: true) || raise("下载犯罪统计失败"))
    File.binwrite("#{tmp}/rate.csv", download(QPS_RATE, binary: true) || raise("下载犯罪比率失败"))
    File.binwrite("#{tmp}/d.zip", download(QPS_DIVS, binary: true) || raise("下载警务分区边界失败"))
    nums = read_qps("#{tmp}/num.csv", cols)
    rates = read_qps("#{tmp}/rate.csv", { "total" => QLD_TOTAL_COLS })
    Dir.mkdir("#{tmp}/d")
    system("unzip", "-o", "-q", "#{tmp}/d.zip", "QPS_DIVISIONS.shp", "QPS_DIVISIONS.dbf", "-d", "#{tmp}/d") or raise "解压警务分区边界失败"
    divs = read_shapefile("#{tmp}/d").select { |_, r| r.any? }.map { |a, r| with_bbox({ "d" => a["DIVISION"].to_s.strip.upcase }, r) }
  end
  raise "犯罪统计分区太少（#{nums.size}）" if nums.size < 300
  raise "警务分区边界太少（#{divs.size}）" if divs.size < 300
  latest = nums.values.flat_map(&:keys).max
  last12 = (0..11).map { |i| month_add(latest, -i) }
  prev12 = (12..23).map { |i| month_add(latest, -i) }

  # 每个分区：最近 12 个月的罪案数、前 12 个月的总数、人口（= 罪案数 ÷ 每 10 万人比率）
  per_div = {}
  nums.each do |name, by_month|
    c = QLD_CRIME_KEYS.each_index.map { |i| last12.sum { |m| (by_month[m] || [])[i].to_f }.round }
    prev = prev12.sum { |m| (by_month[m] || [0])[0].to_f }.round
    r = last12.sum { |m| ((rates[name] || {})[m] || [0])[0].to_f }
    pop = r > 0 && c[0] > 0 ? (c[0] / r * 100_000).round : nil
    per_div[name.upcase] = { "k" => title_case(name), "pop" => pop, "c" => c, "p" => prev }.compact
  end
  with_pop = per_div.values.select { |v| v["pop"].to_i > 0 }
  state_pop = with_pop.sum { |v| v["pop"] }
  per = ->(n, p) { p.to_i > 0 ? (n * 1000.0 / p).round(2) : nil }
  state = QLD_CRIME_KEYS.each_with_index.map { |k, i| [k, per.(with_pop.sum { |v| v["c"][i] }, state_pop)] }.to_h

  # 每个区 → 大部分面积所在的警务分区
  suburbs = {}
  QLD_SUBURBS.each do |s|
    d = majority(s["samples"], divs, "d") or next
    row = per_div[d] or next
    suburbs["#{s["n"].upcase}|#{s["p"]}"] ||= row
  end
  meta = {
    "source" => "Queensland Police Service, reported offences by police division (monthly); population implied by QPS offence rates",
    "inputs" => { "crime" => stamp }, "updated" => Time.now.utc.iso8601, "latest_month" => latest, "unit" => "division",
    "period" => { "from" => last12.last, "to" => latest }, "prev_period" => { "from" => prev12.last, "to" => prev12.first },
    "population_year" => latest[0, 4].to_i, "keys" => QLD_CRIME_KEYS,
    "categories" => { "total" => "全部罪案" }.merge(QLD_CRIME_CATS.transform_values(&:first)),
    "state" => { "population" => state_pop, "rate" => state }, "small_population" => 1000
  }
  write_json_rows("qld/crime.json", meta, "suburbs", suburbs.sort.to_h)
  puts "昆州犯罪统计：#{meta["period"]["from"]} 至 #{latest}，#{per_div.size} 个警务分区（#{with_pop.size} 个有人口，合计 #{state_pop}），" \
       "全州每千人 #{state["total"]} 起/年（入室盗窃 #{state["burglary_dwelling"]}）；#{suburbs.size} / #{QLD_SUBURBS.size} 个区对上了警务分区"
  %w[TARINGA INDOOROOPILLY TOOWONG SUNNYBANK SOUTHPORT INALA].each do |n|
    k, r = suburbs.find { |key, _| key.start_with?(n + "|") }
    puts "   #{k}: #{r ? "#{r["k"]} 分区，人口 #{r["pop"]}，每千人 #{per.(r["c"][0], r["pop"])}，入室盗窃 #{per.(r["c"][1], r["pop"])}" : "没有"}"
  end
end

abort "这些项目下载失败，已保留旧数据：#{FAILED.join('、')}" unless FAILED.empty?
