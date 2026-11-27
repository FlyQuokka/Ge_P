# 找房页面（第三页）维州（VIC）部分的数据更新脚本
# 放置位置：仓库里的 scripts/update_househunt_vic.rb（共用的小工具在 scripts/househunt_lib.rb）
#
# 生成的文件（都在 data/househunt/vic/ 里）：
#   suburbs.json          维州所有区（locality）：名称、邮编、范围                         —— Vicmap Admin
#   schools.json          维州学校：公立（含 4 所精英中学）、天主教和私立                    —— 维州教育部 School Locations
#   catchments/*.json     公立学校学区（school zone）的边界，切成小块，网页只下载用得到的那一块 —— 维州教育部 School Zones
#   crime.json            每个区最近 12 个月的罪案数、人口和每千人比率                   —— 维州犯罪统计局 CSA、澳洲统计局
#
# 房子本身的隐藏信息（owners corporation、洪水、山火、规划覆盖区等）不在这里下载：网页查地址时直接去 Vicmap 查。
# 每一项单独处理；某一项失败时保留它原来的文件，其他照常更新，最后报告哪些失败了。

require_relative "househunt_lib"

VIC_DIR   = "#{DIR}/vic"
VIC_CATCH = "#{VIC_DIR}/catchments"
[VIC_DIR, VIC_CATCH].each { |d| Dir.mkdir(d) unless Dir.exist?(d) }
VICMAP   = "https://services-ap1.arcgis.com/P744lA0wf4LlBZ84/arcgis/rest/services"
VIC_CKAN = "https://discover.data.vic.gov.au/api/3/action/package_show?id="

# 数据目录（data.vic.gov.au）里某个数据集；找不到返回 nil
def vic_package(id)
  j = JSON.parse(download(VIC_CKAN + id) || "{}")
  j["success"] ? j["result"] : nil
rescue JSON::ParserError
  nil
end

# 每年一个数据集的（学校名单、学区）：从明年往前找最新的一个
def latest_yearly(prefix)
  y = Time.now.year
  [y + 1, y, y - 1].each do |yr|
    pkg = vic_package("#{prefix}-#{yr}")
    return [yr, pkg] if pkg
  end
  raise "数据目录里找不到 #{prefix}-#{y - 1} 到 #{y + 1}"
end

# 区名：Vicmap 同名的区写成 "ASCOT (BALLARAT)"，网页和房产网站用的是 "Ascot"
def plain_name(s)
  key_name(s).sub(/ \([^)]*\)\z/, "")
end

# ---------- 1. 维州所有区（locality）：名称、邮编、范围，以及区里面的一个点 ----------
# 一个区可能跨好几个邮编（例如 Melbourne 有 3000 和 3004）：数一数每个邮编有多少门牌地址，用最多的那个；
# 全部邮编也记下来，犯罪统计（按"区名 + 邮编"）要用
VIC_SUBURBS = []
step("维州区域名单") do
  addr_pc = Hash.new { |h, k| h[k] = Hash.new(0) }
  arc_all("#{VICMAP}/Vicmap_Address/FeatureServer/0", where: "1=1", groupByFieldsForStatistics: "locality_name,postcode",
          outStatistics: [{ statisticType: "count", onStatisticField: "OBJECTID", outStatisticFieldName: "n" }].to_json,
          orderByFields: "locality_name,postcode").each do |f|
    a = f["attributes"]
    addr_pc[key_name(a["locality_name"])][a["postcode"].to_s] += a["n"].to_i if a["postcode"]
  end
  raise "门牌地址统计太少（#{addr_pc.size} 个区）" if addr_pc.size < 2800
  pcs = arc_all("#{VICMAP}/Vicmap_Admin/FeatureServer/14", where: "1=1", outFields: "postcode", returnGeometry: true, outSR: 4326,
                maxAllowableOffset: 0.001, orderByFields: "OBJECTID")
          .select { |f| f["geometry"] }.map { |f| with_bbox({ "p" => f["attributes"]["postcode"].to_s }, f["geometry"]["rings"]) }
  raise "邮编区太少（#{pcs.size}）" if pcs.size < 600
  feats = arc_all("#{VICMAP}/Vicmap_Admin/FeatureServer/11", where: "1=1", outFields: "locality_name", returnGeometry: true, outSR: 4326,
                  maxAllowableOffset: 0.001, orderByFields: "OBJECTID")
  feats.each do |f|
    rings = (f["geometry"] || {})["rings"] or next
    full = key_name(f["attributes"]["locality_name"])
    pt = interior_point(rings)
    counted = addr_pc[full]
    pc = counted.empty? ? (locate(pt, pcs) || {})["p"].to_s : counted.max_by { |_, n| n }.first
    pts = rings.flatten(1)
    xs = pts.map(&:first)
    ys = pts.map(&:last)
    VIC_SUBURBS << { "n" => title_case(plain_name(full)), "p" => pc, "q" => (full == plain_name(full) ? nil : full), "pcs" => counted,
                     "bbox" => [xs.min, ys.min, xs.max, ys.max].map { |v| v.round(4) }, "pt" => pt, "full" => full }
  end
  list = VIC_SUBURBS.uniq { |s| [s["n"], s["p"]] }.sort_by { |s| [s["n"], s["p"]] }
  raise "区太少（#{list.size}）" if list.size < 2800
  File.write("#{VIC_DIR}/suburbs.json",
             "[\n" + list.map { |s| s.reject { |k, v| %w[pt full pcs].include?(k) || v.nil? }.to_json }.join(",\n") + "\n]\n")
  puts "维州区域名单：#{list.size} 个（#{VIC_SUBURBS.count { |s| s["p"].empty? }} 个查不到邮编）"
end

# ---------- 2. 学校 ----------
# 教育部每年的学校名单（公立、天主教、私立都有，带经纬度）。精英中学（9 年级考试入学，没有学区）只有这 4 所
VIC_SELECTIVE = { "8025" => "B", "8135" => "G", "8865" => nil, "8866" => nil }   # 学校编号 → 男校 / 女校

def vic_school_kind(type)
  { "Primary" => "P", "Secondary" => "S", "Pri/Sec" => "K12" }[type] || "X"   # Special、Language 等算 X
end

step("维州学校") do
  year, pkg = latest_yearly("school-locations")
  url = pkg["resources"].map { |r| r["url"].to_s }.find { |u| !u.empty? } or raise "找不到学校名单 CSV"
  text = download(url) or raise "下载学校名单失败"
  text = text.dup.force_encoding("Windows-1252").encode("UTF-8") unless text.valid_encoding?   # 有的年份不是 UTF-8
  head, rows = csv_table(text.delete_prefix([0xFEFF].pack("U")))
  col = ->(n) { head.index(n) or raise "学校名单格式变了（没有 #{n}）" }
  schools = rows.map do |r|
    next unless r.size == head.size && r[col.("School_Status")] == "O"
    lon, lat = r[col.("X")].to_f, r[col.("Y")].to_f
    next if lat.zero? || lon.zero?
    gov = r[col.("Education_Sector")] == "Government"
    code = r[col.("School_No")].to_s.strip
    name = r[col.("School_Name")].to_s.strip
    sel = gov && VIC_SELECTIVE.key?(code)
    sx = sel ? VIC_SELECTIVE[code] : (name =~ /\bGirls\b/i ? "G" : name =~ /\bBoys\b/i ? "B" : nil)
    { "c" => code, "n" => name, "g" => gov ? 1 : 0, "k" => vic_school_kind(r[col.("School_Type")]), "sel" => sel ? "F" : nil, "sx" => sx,
      "sec" => gov ? nil : r[col.("Education_Sector")], "lat" => lat.round(5), "lon" => lon.round(5),
      "t" => title_case(r[col.("Address_Town")].to_s.strip) }.reject { |_, v| v.nil? || v == "" }
  end.compact.sort_by { |s| s["n"] }
  pub = schools.count { |s| s["g"] == 1 }
  raise "公立学校太少（#{pub}）" if pub < 1400
  sel = schools.select { |s| s["sel"] }.map { |s| s["n"] }
  raise "精英中学对不上（#{sel.join("、")}）" unless sel.size == VIC_SELECTIVE.size
  meta = { "source" => "Victorian Department of Education, School Locations #{year} (CC BY)", "year" => year, "updated" => Time.now.utc.iso8601,
           "kinds" => { "P" => "小学", "S" => "中学", "K12" => "小学到中学", "X" => "特殊学校 / 语言学校等" },
           "selective" => { "F" => "精英中学（9 年级考试入学）" } }
  write_json_rows("vic/schools.json", meta, "schools", schools)
  puts "维州学校（#{year}）：公立 #{pub} 所（精英 #{sel.size} 所），天主教和私立 #{schools.size - pub} 所"
end

# ---------- 3. 公立学校学区（school zone） ----------
# 小学用 Primary_Integrated，中学用 7 年级的学区（Secondary_Integrated_Year7），另外还有单性别中学、初中、高中的学区
VIC_ZONE_FILES = { "Primary_Integrated" => ["P", "P"], "Secondary_Integrated_Year7" => ["S", "Y7"],
                   "Standalone_singlesex" => ["S", "SS"], "Standalone_juniorsec" => ["S", "JS"], "Standalone_seniorsec" => ["S", "SR"] }

step("维州学区") do
  year, pkg = latest_yearly("victorian-government-school-zones")
  stamp = "#{year} #{pkg["metadata_modified"]}"
  old = (JSON.parse(File.read("#{VIC_CATCH}/index.json")) rescue nil)
  if old && old["source_modified"] == stamp
    puts "维州学区：教育部没有更新学区（#{stamp}），不用重新计算"
    next
  end
  url = pkg["resources"].map { |r| r["url"].to_s }.find { |u| u =~ /\.zip\z/i } or raise "找不到学区文件"
  zip = download(url, binary: true) or raise "下载学区失败"
  feats = []
  Dir.mktmpdir do |tmp|
    File.binwrite("#{tmp}/z.zip", zip)
    system("unzip", "-o", "-q", "#{tmp}/z.zip", "*.geojson", "-d", tmp) or raise "解压失败"
    VIC_ZONE_FILES.each do |base, (t, ct)|
      file = Dir["#{tmp}/**/#{base}_#{year}.geojson"].first
      raise "学区文件里没有 #{base}_#{year}" if file.nil? && ct != "JS" && ct != "SR"
      next unless file
      JSON.parse(File.read(file))["features"].each do |f|
        # ENTITY_CODE = "1" + 学校编号 + 两位校区号（1795001 → 7950 Kew High School）
        code = f["properties"]["ENTITY_CODE"].to_s[1..-3].to_i.to_s
        g = f["geometry"] or next
        polys = g["type"] == "MultiPolygon" ? g["coordinates"] : [g["coordinates"]]
        rings = polys.flatten(1).map { |r| simplify(r.map { |p| p.first(2) }, 0.00002) }.select { |r| r.size >= 4 }
        feats << { id: code, t: t, ct: ct, rings: rings } unless rings.empty?
      end
    end
  end
  raise "学区太少（#{feats.size}）" if feats.size < 1400
  all = feats.flat_map { |f| f[:rings] }.flatten(1)
  root = [all.map(&:first).min - 0.001, all.map(&:last).min - 0.001, all.map(&:first).max + 0.001, all.map(&:last).max + 0.001]
  Dir["#{VIC_CATCH}/t*.json"].each { |f| File.delete(f) }
  tiles = []
  build_tiles(VIC_CATCH, root, feats, 0, tiles)
  index = { "source" => "Victorian Department of Education, Victorian Government School Zones #{year} (CC BY)",
            "source_modified" => stamp, "enrolment_year" => year, "updated" => Time.now.utc.iso8601,
            "types" => { "P" => "小学", "Y7" => "中学（7 年级入学）", "SS" => "单性别中学", "JS" => "初中（7–9 年级）", "SR" => "高中部" },
            "tiles" => tiles }
  File.write("#{VIC_CATCH}/index.json", JSON.generate(index) + "\n")
  sizes = Dir["#{VIC_CATCH}/t*.json"].map { |f| File.size(f) }
  puts "维州学区：#{feats.size} 个学区（#{year} 学年），切成 #{tiles.size} 块，最大 #{sizes.max / 1024} KB，合计 #{sizes.sum / 1024} KB"
end

# ---------- 4. 犯罪统计（CSA：每个区、每种罪名一年的数量，每季度发布） ----------
VIC_CENSUS = "https://data.api.abs.gov.au/rest/data/ABS,C21_G01_SAL,1.0.0/3.P_1..SAL.2?format=csvfilewithlabels"
VIC_ERP    = "https://data.api.abs.gov.au/rest/data/ABS,ABS_ANNUAL_ERP_ASGS2021/ERP.SA2..A?startPeriod=2021&format=csvfile"
VIC_SA2    = "https://geo.abs.gov.au/arcgis/rest/services/ASGS2021/SA2/MapServer/0"
VIC_CRIME_FILE = "#{VIC_DIR}/crime.json"
# key → [中文名, 罪名代码（CSA 的 Offence Subgroup 开头）]。key 和西澳、新州一样，网页可以共用
VIC_CRIME_CATS = {
  "burglary_dwelling" => ["入室盗窃",           %w[B311 B321]],
  "stealing_mv"       => ["偷车",               %w[B41]],
  "stealing_from_mv"  => ["车内财物被偷",       %w[B42]],
  "property_damage"   => ["财物损坏",           %w[B2]],
  "assault"           => ["人身攻击（非家庭）", %w[A212 A22 A232]],
  "family_violence"   => ["家庭暴力",           %w[A211 A231]],
  "robbery"           => ["抢劫",               %w[A5]],
  "drugs"             => ["毒品",               %w[C]]
}
VIC_CRIME_KEYS = ["total"] + VIC_CRIME_CATS.keys
MONTHS = %w[January February March April May June July August September October November December]

# CSA 的数据表每季度一个文件，取"按地方政府"那一份里最新的
def csa_latest
  pkg = vic_package("data-tables-recorded-offences") or raise "数据目录里找不到 CSA 数据表"
  list = pkg["resources"].map do |r|
    u = r["url"].to_s
    next unless u =~ /LGA_Recorded_Offences_Year_Ending_(#{MONTHS.join("|")})_(\d{4})\.xlsx\z/i
    [u, $2.to_i * 12 + MONTHS.index($1.capitalize)]
  end.compact
  raise "找不到 CSA 按地方政府的数据表" if list.empty?
  list.max_by(&:last).first
end

# 逐行读 Excel 里一个很大的表（解压后 300 多 MB，不能一次读进来）。每行给出一组文字
def each_xlsx_row(path, sheet, strings)
  IO.popen(["unzip", "-p", path, "xl/worksheets/#{sheet}"]) do |io|
    buf = +""
    while (chunk = io.read(1 << 20))
      buf << chunk
      last = buf.rindex(%r{</(?:\w+:)?row>}) or next
      cut = buf.index(">", last) + 1
      buf[0...cut].scan(%r{<(?:\w+:)?row\b[^>]*>(.*?)</(?:\w+:)?row>}m) do |(row)|
        cells = row.scan(%r{<(?:\w+:)?c\b([^>]*?)(?:/>|>(.*?)</(?:\w+:)?c>)}m).map do |attrs, body|
          v = body.to_s[%r{<(?:\w+:)?v>([^<]*)<}, 1] || body.to_s.scan(%r{<(?:\w+:)?t[^>]*>([^<]*)<}).join
          attrs =~ /t="s"/ ? strings[v.to_i] : v.gsub("&amp;", "&")
        end
        yield cells
      end
      buf = buf[cut..-1]
    end
  end
end

step("维州犯罪统计") do
  raise "区域名单没有准备好" if VIC_SUBURBS.empty?
  url = csa_latest
  old = (JSON.parse(File.read(VIC_CRIME_FILE)) rescue nil)
  head, rows = csv_table(download(VIC_ERP) || raise("下载估计人口失败"))
  ic, iy, iv = %w[ASGS_2021 TIME_PERIOD OBS_VALUE].map { |k| head.index(k) or raise "估计人口格式变了" }
  erp = Hash.new { |h, k| h[k] = {} }
  rows.each { |c| erp[c[ic]][c[iy].to_i] = c[iv].to_f if c[ic].to_s.start_with?("2") && c[iv] =~ /\d/ }
  pop_year = erp.values.flat_map(&:keys).max or raise "估计人口是空的"
  if old && old["inputs"] == { "crime" => url, "population_year" => pop_year }
    puts "维州犯罪统计：CSA 还没有发布新数据，不用重新计算"
    next
  end

  # 1）读 CSA 表：Year、Year ending、地方政府、邮编、区名、大类、小类、细类、数量（每年一行，最近 10 年）
  counts = Hash.new { |h, k| h[k] = { "last" => Hash.new(0), "prev" => Hash.new(0) } }
  latest = ending = nil
  Dir.mktmpdir do |tmp|
    path = "#{tmp}/csa.xlsx"
    File.binwrite(path, download(url, binary: true) || raise("下载犯罪统计失败"))
    strings = IO.popen(["unzip", "-p", path, "xl/sharedStrings.xml"], &:read).force_encoding("UTF-8")
                .scan(%r{<(?:\w+:)?si>(.*?)</(?:\w+:)?si>}m).map { |(x)| x.scan(%r{<(?:\w+:)?t[^>]*>([^<]*)<}).join.gsub("&amp;", "&").strip }
    sheets = IO.popen(["unzip", "-Z1", path], &:read).split("\n").grep(%r{\Axl/worksheets/sheet\d+\.xml\z}).map { |s| File.basename(s) }
    # 哪一页是按区的：表头有 "Suburb/Town Name"
    sheet = sheets.find do |s|
      found = nil
      each_xlsx_row(path, s, strings) { |cells| found = cells.include?("Suburb/Town Name"); break }
      found
    end or raise "犯罪统计表里找不到按区（Suburb/Town Name）的那一页"
    cols = nil
    each_xlsx_row(path, sheet, strings) do |cells|
      if cols.nil?
        cols = %w[Year Year\ ending Postcode Suburb/Town\ Name Offence\ Subgroup Offence\ Count].map { |n| cells.index(n) or raise "犯罪统计表头变了（没有 #{n}）" }
        next
      end
      year, ye, pc, sub, grp, n = cols.map { |i| cells[i].to_s.strip }
      year = year.to_i
      next if year.zero?
      latest ||= year
      ending ||= ye
      break if year < latest - 1   # 表是按年份从新到旧排的，再往下是更早的年份
      h = counts["#{key_name(sub)}|#{pc}"]
      bucket = year == latest ? "last" : "prev"
      h[bucket]["total"] += n.to_i
      next unless bucket == "last"
      VIC_CRIME_CATS.each { |k, (_, codes)| h["last"][k] += n.to_i if codes.any? { |c| grp.start_with?(c) } }
    end
  end
  raise "犯罪统计内容太少（#{counts.size} 个区）" if counts.size < 2000
  mi = MONTHS.index(ending.to_s.capitalize) or raise "看不懂截止月份（#{ending}）"
  last_month = format("%04d-%02d", latest, mi + 1)

  # 2）2021 年人口普查：每个区的人口（名字和 Vicmap 一样，同名的带括号，例如 "Ascot (Ballarat)"；跟别的州重名的带 "(Vic.)"）
  head, rows = csv_table(download(VIC_CENSUS) || raise("下载人口普查失败"))
  i_name, i_val = head.index("Region"), head.index("OBS_VALUE")
  census = {}
  rows.each { |c| census[key_name(c[i_name].sub(/ \(Vic\.\)\z/, "").sub(/ - Vic\.\)\z/, ")"))] = c[i_val].to_i if c[i_val] =~ /\d/ }
  raise "人口普查数据太少（#{census.size}）" if census.size < 2800
  # 同名的区，人口普查用地方政府区分（"Bellfield (Banyule)"），Vicmap 用附近城镇（"BELLFIELD (GREATER MELBOURNE)"）：按区所在的地方政府对上
  lgas = arc_all("#{VICMAP}/Vicmap_Admin/FeatureServer/9", where: "1=1", outFields: "lga_name", returnGeometry: true, outSR: 4326,
                 maxAllowableOffset: 0.002, orderByFields: "OBJECTID")
           .select { |f| f["geometry"] }.map { |f| with_bbox({ "name" => f["attributes"]["lga_name"] }, f["geometry"]["rings"]) }
  lga_key = ->(n) { key_name(n).gsub(/[^A-Z]/, "") }
  census_pop = lambda do |s|
    return census[s["full"]] if census[s["full"]]
    plain = plain_name(s["full"])
    cands = census.keys.select { |k| k.start_with?(plain + " (") }
    lga = locate(s["pt"], lgas)
    hit = lga && cands.find { |k| lga_key.(k[/\((.+)\)\z/, 1]) == lga_key.(lga["name"]) }
    hit && census[hit]
  end

  # 3）CSA 的每个 "名字|邮编" → 维州的哪个区：同名的区里，这个邮编门牌地址最多的那个（有的区跨两个邮编，两行都算它的）；
  #    都没有这个邮编时，名字只有一个区就算它的
  sa2 = get_json("#{VIC_SA2}/query?" + URI.encode_www_form(where: "state_code_2021='2'", outFields: "sa2_code_2021", returnGeometry: true,
                                                         outSR: 4326, maxAllowableOffset: 0.002, f: "json"))["features"]
          .select { |f| f["geometry"] }.map { |f| with_bbox({ "code" => f["attributes"]["sa2_code_2021"] }, f["geometry"]["rings"]) }
  raise "SA2 太少（#{sa2.size}）" if sa2.size < 400
  by_name = Hash.new { |h, k| h[k] = [] }
  VIC_SUBURBS.each { |s| by_name[key_name(s["n"])] << s }
  keys_of = Hash.new { |h, k| h[k] = [] }   # 区（完整名字）→ CSA 的几行
  counts.each_key do |k|
    name, pc = k.split("|")
    cands = by_name[name]
    hit = cands.select { |s| s["pcs"][pc] > 0 }.max_by { |s| s["pcs"][pc] } || (cands.size == 1 ? cands[0] : nil)
    keys_of[hit["full"]] << k if hit
  end
  per = ->(n, p) { p.to_i > 0 ? (n * 1000.0 / p).round(2) : nil }
  suburbs = {}
  used = {}
  VIC_SUBURBS.each do |s|
    name = key_name(s["n"])
    keys = keys_of[s["full"]]
    next if keys.empty? || suburbs.key?("#{name}|#{s["p"]}")
    a = locate(s["pt"], sa2)
    growth = a && erp[a["code"]][2021].to_f > 0 ? erp[a["code"]][pop_year].to_f / erp[a["code"]][2021] : nil
    base = census_pop.(s)
    pop = base && (base * (growth || 1.0)).round
    c = VIC_CRIME_KEYS.map { |x| keys.sum { |k| counts[k]["last"][x] } }
    suburbs["#{name}|#{s["p"]}"] = { "k" => name, "pop" => pop, "c" => c, "p" => keys.sum { |k| counts[k]["prev"]["total"] } }.compact
    keys.each { |k| used[k] = true } if pop.to_i > 0
  end
  matched = suburbs.values.select { |r| r["pop"].to_i > 0 }
  state_pop = matched.sum { |r| r["pop"] }
  state = VIC_CRIME_KEYS.each_with_index.map { |k, i| [k, per.(matched.sum { |r| r["c"][i] }, state_pop)] }.to_h
  meta = {
    "source" => "Crime Statistics Agency Victoria, recorded offences by suburb/town (year ending #{ending} #{latest}); population: ABS Census 2021 (suburbs) grown to ABS estimated resident population #{pop_year} (SA2)",
    "inputs" => { "crime" => url, "population_year" => pop_year }, "updated" => Time.now.utc.iso8601, "latest_month" => last_month,
    "period" => { "from" => month_add(last_month, -11), "to" => last_month }, "prev_period" => { "from" => month_add(last_month, -23), "to" => month_add(last_month, -12) },
    "population_year" => pop_year, "keys" => VIC_CRIME_KEYS,
    "categories" => { "total" => "全部罪案" }.merge(VIC_CRIME_CATS.transform_values(&:first)),
    "state" => { "population" => state_pop, "rate" => state }, "small_population" => 1000
  }
  write_json_rows("vic/crime.json", meta, "suburbs", suburbs.sort.to_h)
  unused = counts.keys.reject { |k| used[k] }
  puts "维州犯罪统计：#{meta["period"]["from"]} 至 #{last_month}，全州每千人 #{state["total"]} 起/年（入室盗窃 #{state["burglary_dwelling"]}）；" \
       "#{suburbs.size} 个区有数据，#{matched.size} 个有人口数；CSA 里有 #{unused.size} 个区名对不上（#{unused.first(8).join("、")}…）"
  %w[KEW|3101 BOX\ HILL|3128 GLEN\ WAVERLEY|3150 DANDENONG|3175 MELBOURNE|3000 ASCOT|3364].each do |k|
    r = suburbs[k]
    puts "   #{k}: #{r ? "人口 #{r["pop"]}，每千人 #{per.(r["c"][0], r["pop"])}，入室盗窃 #{per.(r["c"][1], r["pop"])}" : "没有"}"
  end
end

abort "这些项目下载失败，已保留旧数据：#{FAILED.join('、')}" unless FAILED.empty?
