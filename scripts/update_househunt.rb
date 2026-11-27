# 找房页面（第三页）用的数据更新脚本
# 放置位置：仓库里的 scripts/update_househunt.rb
#
# 生成的文件（都在 data/househunt/ 里）：
#   suburbs.json               珀斯和皮尔地区的区域名单：名称、邮编、范围            —— 西澳 Landgate 区域边界（SLIP 公开服务）
#   rates.json                 澳洲平均房贷利率（自住、新贷款）和现金利率            —— 澳洲储备银行 RBA 统计表 F6、F1.1
#   schools_wa.json            珀斯和皮尔地区所有学校（公立 + 私立）：位置、年级、人数 —— 西澳教育部（SLIP 公开服务，每年一份）
#   wa_police_districts.json   西澳每个区（suburb）属于哪个警区、各警区人口          —— 西澳警察局警区边界 + 澳洲统计局估计人口（每年）和 2021 年人口普查
#   wa_police_districts.geojson 珀斯 8 个警区的简化边界（地图上画犯罪率用）
#   crime_wa.json              各警区最近 12 个月的犯罪数量和每千人犯罪率            —— 西澳警察局犯罪统计（每季度更新）
#
# 房子的隐藏信息（strata、洪水、山火等）不在这里下载：网页会在你查某个地址时，直接去政府地图服务查询。
# 每一项单独下载；某一项失败时保留它原来的文件，其他照常更新，最后报告哪些失败了。
# 不需要安装任何东西：GitHub Actions 自带 Ruby 和 unzip。

require_relative "househunt_lib"

SLIP   = "https://public-services.slip.wa.gov.au/public/rest/services/SLIP_Public_Services"

# 查询西澳政府公开地图服务（SLIP）的一个图层
def slip_query(path, params)
  get_json("#{SLIP}/#{path}/query?" + URI.encode_www_form({ f: "json" }.merge(params)))["features"]
end

# ---------- 1. 区域名单（珀斯和皮尔地区，用于输入区域名时的提示和地图定位） ----------
step("区域名单") do
  feats = slip_query("Boundaries/MapServer/16",
    geometry: "115.45,-32.90,116.45,-31.30", geometryType: "esriGeometryEnvelope", inSR: 4326,
    spatialRel: "esriSpatialRelIntersects", outFields: "name,postcode", returnGeometry: true,
    outSR: 4326, maxAllowableOffset: 0.001)
  list = feats.map do |f|
    a = f["attributes"]
    pts = f["geometry"]["rings"].flatten(1)
    xs = pts.map(&:first)
    ys = pts.map(&:last)
    { "n" => title_case(a["name"]), "p" => a["postcode"].to_s,
      "bbox" => [xs.min, ys.min, xs.max, ys.max].map { |v| v.round(4) } }
  end
  list = list.uniq { |s| [s["n"], s["p"]] }.sort_by { |s| s["n"] }
  raise "区域太少（#{list.size}）" if list.size < 200
  File.write("#{DIR}/suburbs.json", "[\n" + list.map(&:to_json).join(",\n") + "\n]\n")
  puts "区域名单：#{list.size} 个"
end

# ---------- 2. 平均房贷利率（RBA 表 F6）和现金利率（RBA 表 F1.1） ----------
# 用最简单的方式读 CSV：找到 "Series ID" 那一行确定列，再取最后一个有数字的月份
def rba_latest(table, series_id)
  csv = download("https://www.rba.gov.au/statistics/tables/csv/#{table}-data.csv") or raise "下载 RBA #{table} 失败"
  lines = csv.delete_prefix([0xFEFF].pack("U")).split(/\r?\n/)
  ids = (lines.find { |l| l.start_with?("Series ID,") } or raise "RBA #{table} 格式变了").split(",")
  i = ids.index(series_id) or raise "RBA #{table} 找不到 #{series_id}"
  row = lines.reverse.map { |l| l.split(",") }.find { |c| c[0] =~ %r{\A\d{2}/\d{2}/\d{4}\z} && c[i].to_s =~ /\d/ }
  raise "RBA #{table} 没有数据" unless row
  d, m, y = row[0].split("/")
  { "value" => row[i].to_f, "date" => "#{y}-#{m}-#{d}" }
end

step("房贷利率") do
  variable = rba_latest("f6", "FLRHOFVA")   # 新贷款、自住、浮动利率、所有银行的平均
  fixed    = rba_latest("f6", "FLRHOFFA")   # 新贷款、自住、固定 3 年以内
  cash     = rba_latest("f1.1", "FIRMMCRT") # 现金利率目标
  raise "利率不合理：#{variable["value"]}" unless variable["value"].between?(1, 20)
  out = {
    "mortgage_variable_new" => variable.merge("label" => "新贷款 · 自住 · 浮动利率（所有银行平均）"),
    "mortgage_fixed_new"    => fixed.merge("label" => "新贷款 · 自住 · 固定 3 年以内（平均）"),
    "cash_rate"             => cash.merge("label" => "澳洲储备银行现金利率"),
    "source"                => "Reserve Bank of Australia, Statistical Tables F6 and F1.1",
    "updated"               => Time.now.utc.iso8601
  }
  write_json("rates.json", out)
  puts "房贷利率：浮动 #{variable["value"]}%（#{variable["date"]}），现金利率 #{cash["value"]}%（#{cash["date"]}）"
end

# ---------- 3. 学校（西澳教育部，每年第一学期的学校名单，公立和私立都有） ----------
YEAR_ORDER = %w[PKG KIN PRP Y01 Y02 Y03 Y04 Y05 Y06 Y07 Y08 Y09 Y10 Y11 Y12]
def yi(y)
  YEAR_ORDER.index(y.to_s.strip) || -1
end

# 不算普通学校的：特殊教育、语言发展中心、远程教育、行为支持等
SPECIAL_SCHOOL = /EDUCATION SUPPORT|SPECIAL EDUCATIONAL|DEAF|ISOLATED AND DISTANCE|LANGUAGE DEVELOPMENT|LEARNING CENTRE|ALTERNATIVE|HOSPITAL|INTENSIVE ENGLISH|SENSORY|BEHAVIOUR|KINDERGARTEN/
SELECTIVE_SCHOOLS = ["PERTH MODERN SCHOOL"]   # 全部考试入学、没有学区的公立学校

# P = 小学，S = 中学，K12 = 小学到中学都有，X = 特殊学校、只有高年级的学院、幼儿园等（不算普通学区学校）
def school_kind(a)
  name = a["schoolname"].to_s
  lo, hi = yi(a["lowyear"]), yi(a["highyear"])
  return "S" if SELECTIVE_SCHOOLS.include?(name)
  return "X" if name =~ SPECIAL_SCHOOL || lo < 0 || hi < yi("Y01") || lo >= yi("Y10")
  # 公立特殊学校的名字通常只有 "XXX SCHOOL"，没有 PRIMARY / HIGH / COLLEGE 这些字
  return "X" if a["sector"] == "GOVERNMENT" && name !~ /PRIMARY|HIGH|COLLEGE|COMMUNITY SCHOOL|REMOTE/
  has_p = lo <= yi("Y01") && hi >= yi("Y02")
  has_s = (lo >= yi("Y07") && lo <= yi("Y09")) || (lo <= yi("Y06") && hi >= yi("Y09"))
  has_p && has_s ? "K12" : has_p ? "P" : has_s ? "S" : "X"
end

step("西澳学校") do
  layers = get_json("#{SLIP}/Education/MapServer?f=json")["layers"]
  layer = layers.select { |l| l["name"] =~ /Current Active Schools Semester 1 \d{4}/ }.max_by { |l| l["name"][/\d{4}/].to_i } or raise "找不到学校图层"
  feats = slip_query("Education/MapServer/#{layer["id"]}", where: "1=1", returnGeometry: false,
    outFields: "code,schoolname,sector,lowyear,highyear,totalschoo,latitude,longitude,physicalto")
  schools = feats.map { |f| f["attributes"] }
                 .select { |a| a["latitude"].to_f.between?(-33.2, -31.0) && a["longitude"].to_f.between?(115.2, 116.8) }
                 .map do |a|
    { "c" => a["code"].to_s, "n" => title_case(a["schoolname"].to_s), "g" => a["sector"] == "GOVERNMENT" ? 1 : 0,
      "k" => school_kind(a), "sel" => SELECTIVE_SCHOOLS.include?(a["schoolname"].to_s) ? 1 : nil,
      "lo" => a["lowyear"], "hi" => a["highyear"], "e" => a["totalschoo"].to_i,
      "lat" => a["latitude"].to_f.round(5), "lon" => a["longitude"].to_f.round(5), "t" => title_case(a["physicalto"].to_s) }.compact
  end.sort_by { |s| s["n"] }
  raise "学校太少（#{schools.size}）" if schools.size < 300
  meta = { "year" => layer["name"][/\d{4}/].to_i, "source" => "WA Department of Education, #{layer["name"]} (SLIP)",
           "updated" => Time.now.utc.iso8601,
           "kinds" => { "P" => "小学", "S" => "中学", "K12" => "小学到中学", "X" => "特殊学校 / 高年级学院 / 幼儿园" } }
  write_json_rows("schools_wa.json", meta, "schools", schools)
  gov = schools.select { |s| s["g"] == 1 }
  puts "西澳学校：#{schools.size} 所（#{layer["name"]}），公立小学 #{gov.count { |s| %w[P K12].include?(s["k"]) }}、公立中学 #{gov.count { |s| %w[S K12].include?(s["k"]) }}"
end

# ---------- 4. 警区：每个区属于哪个警区、各警区现在的人口 ----------
# 西澳警察局只公布到警区（珀斯 8 个），所以先算出每个区（suburb）在哪个警区，再算每个警区的人口。
# 人口：澳洲统计局每年公布的 SA2 统计区估计人口（最新一年），按 2021 年人口普查里各区的人口比例分到警区。
# 边界和人口都很少变，所以只有在警区边界更新、或者统计局公布了新一年人口时才重新计算。
DISTRICTS_FILE = "#{DIR}/wa_police_districts.json"
GEOJSON_FILE   = "#{DIR}/wa_police_districts.geojson"
DISTRICTS_PKG  = "https://catalogue.data.wa.gov.au/api/3/action/package_show?id=wa-police-district-boundaries"
ERP_URL        = "https://data.api.abs.gov.au/rest/data/ABS,ABS_ANNUAL_ERP_ASGS2021/ERP.SA2..A?startPeriod=2021&format=csvfile"
CENSUS_URL     = "https://data.api.abs.gov.au/rest/data/ABS,C21_G01_SAL,1.0.0/3.P_1..SAL.5?format=csvfilewithlabels"
SA2_URL        = "https://geo.abs.gov.au/arcgis/rest/services/ASGS2021/SA2/MapServer/0/query?" +
                 URI.encode_www_form(where: "state_code_2021='5'", outFields: "sa2_code_2021", returnGeometry: true,
                                     outSR: 4326, maxAllowableOffset: 0.002, f: "json")

step("西澳警区") do
  old = (JSON.parse(File.read(DISTRICTS_FILE)) rescue nil)
  # 先查"边界和人口有没有新版本"。这两个网站偶尔会临时连不上：已经有旧文件时，就先用旧的、明天再查（不算失败）
  begin
    pkg = get_json(DISTRICTS_PKG)["result"]
    stamp = pkg["metadata_modified"]
    # 每个 SA2 统计区每年的估计人口
    head, rows = csv_table(download(ERP_URL) || raise("下载估计人口失败"))
    ic, iy, iv = %w[ASGS_2021 TIME_PERIOD OBS_VALUE].map { |k| head.index(k) or raise "估计人口格式变了" }
    erp = Hash.new { |h, k| h[k] = {} }
    rows.each { |c| erp[c[ic]][c[iy].to_i] = c[iv].to_f if c[ic].to_s.start_with?("5") && c[iv] =~ /\d/ }
    pop_year = erp.values.flat_map(&:keys).max or raise "估计人口是空的"
  rescue StandardError => e
    raise unless old && File.exist?(GEOJSON_FILE)
    puts "西澳警区：暂时查不到有没有新版本（#{e.message}），先用现有数据，明天再查"
    next
  end
  if old && old["boundary_modified"] == stamp && old["population_year"] == pop_year && File.exist?(GEOJSON_FILE)
    puts "西澳警区：边界和人口都没有变（边界 #{stamp}，人口 #{pop_year} 年），不用重新计算"
    next
  end

  # 警区边界（西澳警察局，shapefile）
  url = pkg["resources"].map { |r| r["url"].to_s }.find { |u| u =~ /\.zip\z/i } or raise "找不到警区边界文件"
  zip = download(url, binary: true) or raise "下载警区边界失败"
  districts = Dir.mktmpdir do |tmp|
    File.binwrite("#{tmp}/d.zip", zip)
    system("unzip", "-o", "-q", "#{tmp}/d.zip", "-d", tmp) or raise "解压失败"
    read_shapefile(tmp)
  end
  districts = districts.map do |a, rings|
    with_bbox({ "name" => a["DISTRICT"], "region" => a["REGION"], "label" => title_case(a["MAP_LABEL"].to_s), "full" => rings },
              rings.map { |r| simplify(r, 0.0001) })
  end
  raise "警区太少（#{districts.size}）" if districts.size < 10

  # SA2 统计区边界（澳洲统计局）
  sa2 = get_json(SA2_URL)["features"].select { |f| f["geometry"] }
                                    .map { |f| with_bbox({ "code" => f["attributes"]["sa2_code_2021"] }, f["geometry"]["rings"]) }
  raise "SA2 太少（#{sa2.size}）" if sa2.size < 200

  # 2021 年人口普查：每个区的人口
  head, rows = csv_table(download(CENSUS_URL) || raise("下载人口普查失败"))
  i_name, i_val = head.index("Region"), head.index("OBS_VALUE")
  census = {}
  rows.each { |c| census[c[i_name].sub(/ \(WA\)\z/, "").upcase] = c[i_val].to_i if c[i_val] =~ /\d/ }
  raise "人口普查数据太少（#{census.size}）" if census.size < 1000

  # 西澳所有区（suburb）→ 区里面的一个点 → 落在哪个警区、哪个 SA2
  feats = slip_query("Boundaries/MapServer/16", where: "1=1", outFields: "name", returnGeometry: true,
                     outSR: 4326, maxAllowableOffset: 0.002)
  raise "区太少（#{feats.size}）" if feats.size < 1000
  suburbs = {}
  share = Hash.new { |h, k| h[k] = Hash.new(0) }   # SA2 → 警区 → 2021 年人口
  feats.each do |f|
    name = f["attributes"]["name"].to_s.upcase
    pt = interior_point(f["geometry"]["rings"])
    d = locate(pt, districts)
    s = locate(pt, sa2)
    share[s["code"]][d["name"]] += census[name].to_i if s && d
    suburbs[name] = { "d" => d && d["name"], "pop21" => census[name] }.compact
  end

  # 每个 SA2 的最新人口，按区的人口比例分给警区；里面没有对上区的 SA2，看它自己的中心点在哪个警区
  totals = Hash.new(0.0)
  sa2.each do |s|
    v = erp[s["code"]][pop_year].to_f
    sh = share[s["code"]]
    base = sh.values.sum.to_f
    if base > 0
      sh.each { |d, p| totals[d] += v * p / base }
    elsif (d = locate(interior_point(s["rings"]), districts))
      totals[d["name"]] += v
    end
  end
  meta = {
    "source" => "WA Police Force District Boundaries (WAPOL-002); ABS Estimated Resident Population by SA2 (#{pop_year}); ABS Census 2021 G01 (Suburbs and Localities)",
    "boundary_modified" => stamp, "population_year" => pop_year, "updated" => Time.now.utc.iso8601,
    "districts" => districts.map { |x| [x["name"], { "label" => x["label"], "region" => x["region"], "population" => totals[x["name"]].round }] }.to_h
  }
  write_json_rows("wa_police_districts.json", meta, "suburbs", suburbs.sort.to_h)

  # 珀斯 8 个警区的简化边界，给地图画犯罪率用
  features = districts.select { |x| x["region"] == "METROPOLITAN" }.map do |x|
    polys = []
    x["full"].each do |r|
      r2 = simplify(r, 0.0003).map { |p| p.map { |v| v.round(4) } }
      next if r2.size < 4
      host = ring_area(r) > 0 && polys.find { |pg| point_in_rings?(r[0], [pg[0]]) }
      if host
        host << r2.reverse            # 洞（shapefile 里是逆时针）
      else
        polys << [ring_area(r) > 0 ? r2 : r2.reverse]   # 外圈：shapefile 顺时针 → GeoJSON 逆时针
      end
    end
    { "type" => "Feature",
      "properties" => { "district" => x["name"], "label" => x["label"], "lp" => interior_point(x["full"]).map { |v| v.round(4) } },
      "geometry" => { "type" => "MultiPolygon", "coordinates" => polys } }
  end
  File.write(GEOJSON_FILE, JSON.generate({ "type" => "FeatureCollection", "features" => features }) + "\n")

  missing = suburbs.count { |_, s| s["d"].nil? }
  nopop = suburbs.count { |_, s| s["pop21"].nil? }
  puts "西澳警区：#{districts.size} 个警区，#{suburbs.size} 个区（#{missing} 个没对上警区，#{nopop} 个在 2021 年人口普查里没有）"
  puts "   全州人口（#{pop_year}）：#{totals.values.sum.round}"
  meta["districts"].each { |k, v| puts "   #{k}: #{v["population"]}" if v["region"] == "METROPOLITAN" }
end

# ---------- 5. 西澳犯罪统计（按警区、按月、按罪案类型） ----------
CRIME_URL  = "https://www.wa.gov.au/media/48429/download?inline"
CRIME_FILE = "#{DIR}/crime_wa.json"
# 网页上单独列出的几类：key → [中文名, 判断这一行算不算这一类（l1 = 具体罪名，l2 = 大类）]
CRIME_CATS = {
  "burglary_dwelling" => ["入室盗窃",           ->(l1, l2) { l1 == "Burglary (Dwelling)" }],
  "stealing_mv"       => ["偷车",               ->(l1, l2) { l2 == "Stealing of Motor Vehicle" }],
  "stealing_from_mv"  => ["车内财物被偷",       ->(l1, l2) { l1.start_with?("Stealing From Motor Vehicle") }],
  "property_damage"   => ["财物损坏",           ->(l1, l2) { l2 == "Property Damage" || l2 == "Graffiti" }],
  "assault"           => ["人身攻击（非家庭）", ->(l1, l2) { l2 == "Assault (Non-Family)" }],
  "family_violence"   => ["家庭暴力",           ->(l1, l2) { l2 == "Assault (Family)" || l2 == "Threatening Behaviour (Family)" }],
  "robbery"           => ["抢劫",               ->(l1, l2) { l2 == "Robbery" }],
  "drugs"             => ["毒品",               ->(l1, l2) { l2 == "Drug Offences" }]
}

# 读警方的 Excel：每个地区（全州、都会区、每个警区）一页，每行一个月，每列一种罪名。
# 第 1 行 B 格是地区名；"Month and Year" 那一行是具体罪名（"... Total" 是小计，跳过）；
# 它上面一行是大类（一个大类占好几列，写在第一列）。"Total Selected ..." 这类合计列也跳过，避免重复计算。
# 每找到一个数字就调用一次 block：地区（大写）、月份（2026-09）、具体罪名、大类、数量
def read_wapol_sheets(path)
  read = ->(inner) { IO.popen(["unzip", "-p", path, inner], &:read).force_encoding("UTF-8") }
  strings = read.("xl/sharedStrings.xml").scan(/<si>(.*?)<\/si>/m).map { |(x)| x.scan(/<t[^>]*>([^<]*)<\/t>/).join.gsub("&amp;", "&").strip }
  colnum = ->(c) { c.each_char.reduce(0) { |a, ch| a * 26 + ch.ord - 64 } }
  rels = read.("xl/_rels/workbook.xml.rels")
  sheets = read.("xl/workbook.xml").scan(/<sheet [^>]*r:id="([^"]+)"/).flatten.map do |rid|
    rels[/Id="#{rid}"[^>]*Target="([^"]+)"/, 1] || rels[/Target="([^"]+)"[^>]*Id="#{rid}"/, 1]
  end.compact
  found = 0
  sheets.each do |target|
    rows = read.("xl/" + target.sub(%r{\A/?xl/}, "")).scan(/<row [^>]*?r="(\d+)"[^>]*>(.*?)<\/row>/m).map do |_, row|
      cells = {}
      row.scan(/<c r="([A-Z]+)\d+"([^>]*?)(?:\/>|>(.*?)<\/c>)/m) do |col, attrs, inner|
        v = inner.to_s[/<v>([^<]*)<\/v>/, 1]
        next if v.nil?
        cells[colnum.(col)] = attrs.include?('t="s"') ? strings[v.to_i] : v
      end
      cells
    end
    next unless rows[0] && rows[0][1].to_s.start_with?("Region")
    region = rows[0][2].to_s.strip.upcase
    hi = rows.index { |r| r[1].to_s.strip == "Month and Year" } or next
    labels = rows[hi]
    groups = rows[0...hi].reverse.find { |r| r.size > 3 && r.keys.min > 1 } || {}
    group_of = ->(c) { k = groups.keys.select { |g| g <= c }.max; k && groups[k].to_s }
    leaf = labels.select { |c, name| c > 1 && !name.to_s.empty? && name !~ / Total\z/ && name !~ /\ATotal / && group_of.(c) !~ /\ATotal / }
    raise "犯罪统计：#{region} 这一页找不到罪名" if leaf.size < 30
    rows[(hi + 1)..-1].each do |r|
      serial = r[1].to_f
      next unless serial > 30000
      month = (Date.new(1899, 12, 30) + serial.to_i).strftime("%Y-%m")
      leaf.each { |c, name| yield region, month, name.to_s, group_of.(c), r[c].to_f if r[c] }
    end
    found += 1
  end
  raise "犯罪统计的格式变了：没有找到按地区分页的数据" if found < 10
end

step("西澳犯罪统计") do
  dist = JSON.parse(File.read(DISTRICTS_FILE)) rescue raise("还没有警区文件")
  inputs = { "crime" => last_modified(CRIME_URL), "districts" => dist["boundary_modified"], "population_year" => dist["population_year"] }
  old = (JSON.parse(File.read(CRIME_FILE)) rescue nil)
  if old && inputs["crime"].nil?   # 警方网站临时连不上：先用现有数据，明天再查（不算失败）
    puts "西澳犯罪统计：暂时查不到警方有没有发布新数据，先用现有数据，明天再查"
    next
  end
  if old && old["inputs"] == inputs
    puts "西澳犯罪统计：警方还没有发布新数据（#{inputs["crime"]}），不用重新计算"
    next
  end
  xlsx = download(CRIME_URL, binary: true) or raise "下载犯罪统计失败"
  counts = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = Hash.new(0) } }   # 地区 → 月份 → 类别 → 数量
  Dir.mktmpdir do |tmp|
    path = "#{tmp}/crime.xlsx"
    File.binwrite(path, xlsx)
    read_wapol_sheets(path) { |region, month, l1, l2, n| m = counts[region][month]; m["total"] += n; CRIME_CATS.each { |key, (_, test)| m[key] += n if test.(l1, l2) } }
  end
  raise "犯罪统计内容太少" if counts.size < 10
  latest = counts["WESTERN AUSTRALIA"].select { |_, m| m["total"] > 0 }.keys.max or raise "找不到最新月份"
  last12 = (0..11).map { |i| month_add(latest, -i) }
  prev12 = (12..23).map { |i| month_add(latest, -i) }
  keys = ["total"] + CRIME_CATS.keys
  sum = ->(region, months) { keys.map { |k| [k, months.sum { |mo| counts[region][mo][k] }.round] }.to_h }
  rate = ->(c, popn) { popn.to_i > 0 ? c.transform_values { |v| (v * 1000.0 / popn).round(2) } : nil }
  dpop = dist["districts"]
  metro_pop = dpop.values.select { |d| d["region"] == "METROPOLITAN" }.sum { |d| d["population"].to_i }
  state_pop = dpop.values.sum { |d| d["population"].to_i }
  area = lambda do |region, popn, extra = {}|
    c = sum.(region, last12)
    { "last12" => c, "prev12" => sum.(region, prev12), "population" => popn, "rate" => rate.(c, popn) }.merge(extra).compact
  end
  out = {
    "source" => "WA Police Force, crime time series (wa.gov.au); population: ABS estimated resident population #{dist["population_year"]}",
    "inputs" => inputs, "updated" => Time.now.utc.iso8601, "latest_month" => latest,
    "period" => { "from" => last12.last, "to" => last12.first }, "prev_period" => { "from" => prev12.last, "to" => prev12.first },
    "population_year" => dist["population_year"],
    "categories" => { "total" => "全部罪案" }.merge(CRIME_CATS.transform_values(&:first)),
    "metro" => area.("METROPOLITAN REGION", metro_pop), "state" => area.("WESTERN AUSTRALIA", state_pop),
    "districts" => counts.keys.select { |r| r.end_with?("DISTRICT") }.sort.map { |r|
      d = dpop[r] || {}
      [r, area.(r, d["population"], { "label" => d["label"] || title_case(r.sub(/ DISTRICT\z/, "")), "region" => d["region"] })]
    }.to_h
  }
  write_json("crime_wa.json", out)
  m = out["metro"]
  puts "西澳犯罪统计：#{out["period"]["from"]} 至 #{out["period"]["to"]}，珀斯都会区每千人 #{m.dig("rate", "total")} 起/年（入室盗窃 #{m.dig("rate", "burglary_dwelling")}）"
  out["districts"].each { |k, v| puts "   #{k}: 每千人 #{v.dig("rate", "total")}，入室盗窃 #{v.dig("rate", "burglary_dwelling")}" if v["region"] == "METROPOLITAN" }
end

abort "这些项目下载失败，已保留旧数据：#{FAILED.join('、')}" unless FAILED.empty?
