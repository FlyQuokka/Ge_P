# 找房页面（第三页）南澳（SA）部分的数据更新脚本
# 放置位置：仓库里的 scripts/update_househunt_sa.rb（共用的小工具在 scripts/househunt_lib.rb）
#
# 生成的文件（都在 data/househunt/sa/ 里）：
#   suburbs.json          南澳所有区（suburb）：名称、邮编、范围                              —— Location SA
#   schools.json          南澳公立学校（教育部名单；南澳没有公开的私立学校名单）                  —— 南澳教育部
#   catchments/*.json     公立学校学区（school zone，只有一部分热门学校有）                       —— 南澳教育部
#   overlays/*.json       规划覆盖区（山火、遗产、风貌区、酸性土、机场噪音、道路拓宽、海岸），切成小块 —— Planning and Design Code
#   crime.json            每个区最近 12 个月的罪案数（只有针对人身和财产的罪案）、人口和每千人比率   —— 南澳警察局 SAPOL、澳洲统计局
#
# 规划覆盖区的原始文件有 1.1 GB（压缩后 5 亿字节），所以只下载其中一份 GeoJSON，边下载边解压，只留下要用的几种覆盖区；
# 这个文件几乎每天都会更新，但覆盖区很少变，所以最多每 7 天重新处理一次。
# 洪水覆盖区和规划分区不在这里下载：网页查地址时直接去政府地图服务查。
# 每一项单独处理；某一项失败时保留它原来的文件，其他照常更新，最后报告哪些失败了。

require_relative "househunt_lib"
require "zlib"

SA_DIR     = "#{DIR}/sa"
SA_CATCH   = "#{SA_DIR}/catchments"
SA_OVL     = "#{SA_DIR}/overlays"
[SA_DIR, SA_CATCH, SA_OVL].each { |d| Dir.mkdir(d) unless Dir.exist?(d) }
SA_BASE    = "https://location.sa.gov.au/server6/rest/services/GrowthManagementPublic/CodeAmendments_BaseLayers_plansadb/MapServer"
SA_CKAN    = "https://data.sa.gov.au/data/api/3/action/package_show?id="

def sa_package(id)
  get_json(SA_CKAN + id)["result"] or raise "数据目录里找不到 #{id}"
end

# ---------- 1. 南澳所有区（suburb）：名称、邮编、范围，以及区里面的一个点 ----------
SA_SUBURBS = []
step("南澳区域名单") do
  arc_all("#{SA_BASE}/1", where: "1=1", outFields: "suburb,postcode", returnGeometry: true, outSR: 4326,
          maxAllowableOffset: 0.001, orderByFields: "objectid").each do |f|
    rings = (f["geometry"] || {})["rings"] or next
    pts = rings.flatten(1)
    xs = pts.map(&:first)
    ys = pts.map(&:last)
    SA_SUBURBS << { "n" => title_case(f["attributes"]["suburb"].to_s.strip), "p" => f["attributes"]["postcode"].to_s.strip,
                    "bbox" => [xs.min, ys.min, xs.max, ys.max].map { |v| v.round(4) }, "pt" => interior_point(rings) }
  end
  list = SA_SUBURBS.uniq { |s| [s["n"], s["p"]] }.sort_by { |s| [s["n"], s["p"]] }
  raise "区太少（#{list.size}）" if list.size < 1500
  File.write("#{SA_DIR}/suburbs.json", "[\n" + list.map { |s| s.reject { |k, _| k == "pt" }.to_json }.join(",\n") + "\n]\n")
  puts "南澳区域名单：#{list.size} 个"
end

# 数据目录里一个数据集的资源，按名字里的年份取最新的（例如 "...2025EY.zip"、"...sites 2023"）
def sa_latest_resource(pkg_id, pattern)
  pkg = sa_package(pkg_id)
  list = pkg["resources"].select { |r| r["url"].to_s =~ pattern || r["name"].to_s =~ pattern }
                         .map { |r| [r, (r["name"].to_s + r["url"].to_s).scan(/20\d\d/).map(&:to_i).max.to_i] }
  raise "#{pkg_id} 里找不到要的文件" if list.empty?
  r, year = list.max_by(&:last)
  [r["url"], year, pkg["metadata_modified"]]
end

# ---------- 2. 公立学校 ----------
SA_KIND = { "Primary Education" => "P", "Secondary Education" => "S", "Primary/Secondary Combined" => "K12",
            "Aboriginal/Anangu Schools" => "K12", "Special Education" => "X" }
step("南澳学校") do
  url, year, = sa_latest_resource("sa-government-preschool-and-school-sites", /sites.*\.csv\z/i)
  text = download(url) or raise "下载学校名单失败"
  text = text.dup.force_encoding("Windows-1252").encode("UTF-8") unless text.valid_encoding?
  head, rows = csv_table(text.delete_prefix([0xFEFF].pack("U")))
  col = ->(n) { head.index(n) or raise "学校名单格式变了（没有 #{n}）" }
  schools = rows.map do |r|
    kind = SA_KIND[r[col.("Type_of_Schooling")].to_s.strip] or next   # 去掉幼儿园、儿童中心
    lat, lon = r[col.("Latitude")].to_f, r[col.("Longitude")].to_f
    next if lat.zero? || lon.zero?
    name = r[col.("School_Name")].to_s.strip
    { "c" => r[col.("School_Number")].to_i.to_s, "n" => name, "g" => 1, "k" => kind, "y" => r[col.("Year_Levels")].to_s.strip,
      "sx" => name =~ /\bGirls\b/i ? "G" : name =~ /\bBoys\b/i ? "B" : nil, "lat" => lat.round(5), "lon" => lon.round(5),
      "t" => title_case(r[col.("Suburb")].to_s.strip) }.reject { |_, v| v.nil? || v == "" }
  end.compact.sort_by { |s| s["n"] }
  raise "公立学校太少（#{schools.size}）" if schools.size < 400
  meta = { "source" => "South Australian Department for Education, SA Government preschool and school sites #{year} (CC BY)", "year" => year,
           "updated" => Time.now.utc.iso8601, "kinds" => { "P" => "小学", "S" => "中学", "K12" => "小学到中学", "X" => "特殊学校" } }
  write_json_rows("sa/schools.json", meta, "schools", schools)
  puts "南澳学校（#{year}）：公立 #{schools.size} 所"
end

# ---------- 3. 公立学校学区（school zone：只有一部分热门学校有学区） ----------
step("南澳学区") do
  zones = { "P" => sa_latest_resource("school-zones-for-south-australian-govt-primary-schools", /PrimarySchoolZones\d{4}EY\.zip\z/i),
            "S" => sa_latest_resource("school-zones-for-south-australian-govt-high-schools", /HighSchoolZones\d{4}EY\.zip\z/i) }
  stamp = zones.map { |t, (u, y, _)| "#{t}:#{y}:#{File.basename(u)}" }.join(" ")
  old = (JSON.parse(File.read("#{SA_CATCH}/index.json")) rescue nil)
  if old && old["source_modified"] == stamp
    puts "南澳学区：教育部没有更新学区（#{stamp}），不用重新计算"
    next
  end
  feats = []
  zones.each do |t, (url, _, _)|
    Dir.mktmpdir do |tmp|
      File.binwrite("#{tmp}/z.zip", download(url, binary: true) || raise("下载学区失败"))
      system("unzip", "-o", "-q", "#{tmp}/z.zip", "-d", tmp) or raise "解压失败"
      shp = Dir["#{tmp}/**/*.shp"].first or raise "学区文件里没有 shapefile"
      read_shapefile(File.dirname(shp)).each do |a, rings|
        rings = rings.map { |r| simplify(r, 0.00002) }.select { |r| r.size >= 4 }
        feats << { id: a["org_num"].to_i.to_s, t: t, ct: t, rings: rings } unless rings.empty?
      end
    end
  end
  raise "学区太少（#{feats.size}）" if feats.size < 80
  all = feats.flat_map { |f| f[:rings] }.flatten(1)
  root = [all.map(&:first).min - 0.001, all.map(&:last).min - 0.001, all.map(&:first).max + 0.001, all.map(&:last).max + 0.001]
  Dir["#{SA_CATCH}/t*.json"].each { |f| File.delete(f) }
  tiles = []
  build_tiles(SA_CATCH, root, feats, 0, tiles)
  year = zones.values.map { |_, y, _| y }.max
  index = { "source" => "South Australian Department for Education, school zones for government schools (#{year} enrolment year, CC BY)",
            "source_modified" => stamp, "enrolment_year" => year, "updated" => Time.now.utc.iso8601,
            "types" => { "P" => "小学", "S" => "中学" },
            "zoned" => feats.map { |f| f[:id] }.uniq.sort,   # 有学区的学校（其他学校一般按就近入学）
            "tiles" => tiles }
  File.write("#{SA_CATCH}/index.json", JSON.generate(index) + "\n")
  puts "南澳学区：#{feats.size} 个学区（#{year} 学年），切成 #{tiles.size} 块"
end

# ---------- 4. 规划覆盖区（Planning and Design Code overlays） ----------
OVERLAY_ZIP = "https://www.dptiapps.com.au/dataportal/PDCodeOverlays_geojson.zip"
OVERLAY_ENTRY = "PDCodeOverlays_GDA94.geojson"
# 要用的覆盖区 → [简写, 简化的容差（度；0.00001 约 1 米）]。乡村的大片山火区画得粗一点
SA_OVERLAYS = {
  "Hazards (Bushfire - High Risk)" => ["BH", 0.00005], "Hazards (Bushfire - Medium Risk)" => ["BM", 0.00005],
  "Hazards (Bushfire - General)" => ["BG", 0.0001], "Hazards (Bushfire - Urban Interface)" => ["BU", 0.00005],
  "Hazards (Bushfire - Regional)" => ["BR", 0.0005], "Hazards (Bushfire - Outback)" => ["BO", 0.001],
  "Hazards (Acid Sulfate Soils)" => ["AS", 0.0001],
  "State Heritage Place" => ["SHP", 0.00001], "State Heritage Area" => ["SHA", 0.00005], "Local Heritage Place" => ["LHP", 0.00001],
  "Historic Area" => ["HA", 0.00003], "Character Area" => ["CA", 0.00003], "Character Preservation District" => ["CPD", 0.0002],
  "Aircraft Noise Exposure" => ["ANEF", 0.00005], "Future Road Widening" => ["FRW", 0.00001], "Future Local Road Widening" => ["FLRW", 0.00001],
  "Coastal Flooding" => ["CF", 0.00005], "Coastal Areas" => ["COA", 0.0001]
}
OVERLAY_MAX_DAYS = 7

# zip 文件里某一项的位置（只读文件最后一小段的目录，不下载整个文件）
def zip_entry(url, name)
  uri = URI(url)
  Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 120) do |http|
    tail = http.get(uri.request_uri, "Range" => "bytes=-65536").body.b
    e = tail.rindex([0x06054b50].pack("V")) or raise "看不懂覆盖区 zip 的目录"
    pos = tail.index([0x02014b50].pack("V")) or raise "看不懂覆盖区 zip 的目录"
    while pos && tail[pos, 4] == [0x02014b50].pack("V")
      csize, nl, el, cl, off = tail[pos + 20, 4].unpack1("V"), tail[pos + 28, 2].unpack1("v"), tail[pos + 30, 2].unpack1("v"),
                               tail[pos + 32, 2].unpack1("v"), tail[pos + 42, 4].unpack1("V")
      if tail[pos + 46, nl] == name
        head = http.get(uri.request_uri, "Range" => "bytes=#{off}-#{off + 63}").body.b
        raise "覆盖区 zip 的格式变了" unless head[0, 4] == [0x04034b50].pack("V") && head[8, 2].unpack1("v") == 8
        start = off + 30 + head[26, 2].unpack1("v") + head[28, 2].unpack1("v")
        return [start, csize]
      end
      pos += 46 + nl + el + cl
    end
    raise "覆盖区 zip 里没有 #{name}"
  end
end

# 边下载边解压，每一行是一个覆盖区（GeoJSON Feature），只留下要用的
def stream_overlays(url, start, csize)
  uri = URI(url)
  z = Zlib::Inflate.new(-Zlib::MAX_WBITS)
  buf = +""
  kept = []
  Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 600) do |http|
    req = Net::HTTP::Get.new(uri)
    req["Range"] = "bytes=#{start}-#{start + csize - 1}"
    http.request(req) do |res|
      raise "下载覆盖区失败（#{res.code}）" unless res.code == "206"
      res.read_body do |chunk|
        buf << z.inflate(chunk)
        while (i = buf.index("\n"))
          line = buf.slice!(0, i + 1)
          name = line[/\A\{ "type": "Feature", "properties": \{ "id": "[^"]*", "name": "([^"]*)"/, 1]
          kept << line if name && SA_OVERLAYS.key?(name)
        end
      end
    end
  end
  z.close
  kept
end

step("南澳规划覆盖区") do
  stamp = last_modified(OVERLAY_ZIP)
  old = (JSON.parse(File.read("#{SA_OVL}/index.json")) rescue nil)
  if old && (stamp.nil? || old["source_modified"] == stamp ||
             Time.now.utc - Time.parse(old["updated"]) < OVERLAY_MAX_DAYS * 86_400)
    puts "南澳规划覆盖区：上次处理是 #{old["updated"][0, 10]}（每 #{OVERLAY_MAX_DAYS} 天最多处理一次），不用重新处理"
    next
  end
  start, csize = zip_entry(OVERLAY_ZIP, OVERLAY_ENTRY)
  lines = stream_overlays(OVERLAY_ZIP, start, csize)
  feats = []
  counts = Hash.new(0)
  lines.each do |line|
    f = JSON.parse(line.strip.chomp(","))
    code, tol = SA_OVERLAYS[f["properties"]["name"]]
    g = f["geometry"] or next
    polys = g["type"] == "MultiPolygon" ? g["coordinates"] : g["type"] == "Polygon" ? [g["coordinates"]] : []
    rings = polys.flatten(1).map { |r| simplify(r.map { |p| p.first(2) }, tol) }.select { |r| r.size >= 4 }
    next if rings.empty?
    feats << { id: code, t: (f["properties"]["value"] || "").to_s.strip, ct: f["properties"]["id"].to_s, rings: rings }
    counts[code] += 1
  end
  raise "覆盖区太少（#{feats.size}）" if feats.size < 5000 || counts.size < 12
  all = feats.flat_map { |f| f[:rings] }.flatten(1)
  root = [all.map(&:first).min - 0.001, all.map(&:last).min - 0.001, all.map(&:first).max + 0.001, all.map(&:last).max + 0.001]
  Dir["#{SA_OVL}/t*.json"].each { |f| File.delete(f) }
  tiles = []
  build_tiles(SA_OVL, root, feats, 0, tiles)
  index = { "source" => "Planning and Design Code overlays (PlanSA, Data.SA, CC BY)", "source_modified" => stamp, "updated" => Time.now.utc.iso8601,
            "names" => SA_OVERLAYS.map { |n, (c, _)| [c, n] }.to_h, "counts" => counts, "tiles" => tiles }
  File.write("#{SA_OVL}/index.json", JSON.generate(index) + "\n")
  sizes = Dir["#{SA_OVL}/t*.json"].map { |f| File.size(f) }
  puts "南澳规划覆盖区：#{feats.size} 个（#{counts.map { |k, v| "#{k} #{v}" }.join("、")}），切成 #{tiles.size} 块，合计 #{sizes.sum / 1024} KB"
end

# ---------- 5. 犯罪统计（SAPOL：每个区每天、每种罪名的数量，每季度发布；只有针对人身和财产的罪案） ----------
SA_CENSUS = "https://data.api.abs.gov.au/rest/data/ABS,C21_G01_SAL,1.0.0/3.P_1..SAL.4?format=csvfilewithlabels"
SA_ERP    = "https://data.api.abs.gov.au/rest/data/ABS,ABS_ANNUAL_ERP_ASGS2021/ERP.SA2..A?startPeriod=2021&format=csvfile"
SA_SA2    = "https://geo.abs.gov.au/arcgis/rest/services/ASGS2021/SA2/MapServer/0"
SA_CRIME_FILE = "#{SA_DIR}/crime.json"
# key → [中文名, 判断条件（l2 = 中类，l3 = 小类）]。key 和其他州一样；南澳没有的类别（车内财物、家暴、毒品）是 nil
SA_CRIME_CATS = {
  "burglary_dwelling" => ["入室盗窃",   ->(l2, l3) { l3 == "SCT - Residence" }],
  "stealing_mv"       => ["偷车",       ->(l2, l3) { l3 =~ /\AMotor vehicle theft/i }],
  "stealing_from_mv"  => nil,
  "property_damage"   => ["财物损坏",   ->(l2, l3) { l2 == "PROPERTY DAMAGE" }],
  "assault"           => ["人身攻击",   ->(l2, l3) { l2 == "ASSAULT" }],
  "family_violence"   => nil,
  "robbery"           => ["抢劫",       ->(l2, l3) { l2 =~ /\AROBBERY/ }],
  "drugs"             => nil
}
SA_CRIME_KEYS = ["total"] + SA_CRIME_CATS.keys

step("南澳犯罪统计") do
  raise "区域名单没有准备好" if SA_SUBURBS.empty?
  pkg = sa_package("crime-statistics")
  # 每个财政年度一个文件（最新的一年只有前几个季度）。取最新的三个
  files = pkg["resources"].select { |r| r["name"].to_s =~ /\ACrime Statistics 20\d\d-\d\d/i && r["url"].to_s =~ /\.csv\z/i }
                          .sort_by { |r| r["name"].to_s[/20\d\d-\d\d/] }.last(3)
  raise "找不到犯罪统计文件" if files.size < 2
  stamp = files.map { |r| "#{File.basename(r["url"])}@#{r["last_modified"]}" }
  head, rows = csv_table(download(SA_ERP) || raise("下载估计人口失败"))
  ic, iy, iv = %w[ASGS_2021 TIME_PERIOD OBS_VALUE].map { |k| head.index(k) or raise "估计人口格式变了" }
  erp = Hash.new { |h, k| h[k] = {} }
  rows.each { |c| erp[c[ic]][c[iy].to_i] = c[iv].to_f if c[ic].to_s.start_with?("4") && c[iv] =~ /\d/ }
  pop_year = erp.values.flat_map(&:keys).max or raise "估计人口是空的"
  old = (JSON.parse(File.read(SA_CRIME_FILE)) rescue nil)
  if old && old["inputs"] == { "crime" => stamp, "population_year" => pop_year }
    puts "南澳犯罪统计：SAPOL 还没有发布新数据，不用重新计算"
    next
  end

  # 1）读 SAPOL：每行 = 日期、区、邮编、大类、中类、小类、数量
  by_month = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = Array.new(SA_CRIME_KEYS.size, 0) } }
  files.each do |r|
    head, rows = csv_table((download(r["url"]) or raise "下载 #{r["name"]} 失败").delete_prefix([0xFEFF].pack("U")))
    i_date, i_sub, i_pc, i_l2, i_l3, i_n = ["Reported Date", "Suburb - Incident", "Postcode - Incident", "Offence Level 2 Description",
                                            "Offence Level 3 Description", "Offence count"].map { |n| head.index(n) or raise "犯罪统计表头变了（没有 #{n}）" }
    rows.each do |c|
      d = c[i_date].to_s.match(%r{\A(\d{1,2})/(\d{1,2})/(\d{4})}) or next
      ym = format("%04d-%02d", d[3].to_i, d[2].to_i)
      n = c[i_n].to_i
      key = "#{key_name(c[i_sub])}|#{c[i_pc].to_s.strip}"
      v = by_month[key][ym]
      v[0] += n
      SA_CRIME_CATS.each_with_index { |(_, cat), i| v[i + 1] += n if cat && cat[1].(c[i_l2].to_s.strip, c[i_l3].to_s.strip) }
    end
  end
  latest = by_month.values.flat_map(&:keys).max
  last12 = (0..11).map { |i| month_add(latest, -i) }
  prev12 = (12..23).map { |i| month_add(latest, -i) }
  counts = by_month.transform_values do |m|
    { "last" => SA_CRIME_KEYS.each_index.map { |i| last12.sum { |ym| (m[ym] || [])[i].to_i } },
      "prev" => prev12.sum { |ym| (m[ym] || [0])[0].to_i } }
  end
  raise "犯罪统计内容太少（#{counts.size} 个区）" if counts.size < 800
  have_prev = prev12.all? { |ym| by_month.values.any? { |m| m.key?(ym) } }

  # 2）人口：2021 年人口普查 × 所在 SA2 的估计人口增长
  head, rows = csv_table(download(SA_CENSUS) || raise("下载人口普查失败"))
  i_name, i_val = head.index("Region"), head.index("OBS_VALUE")
  census = {}
  rows.each { |c| census[key_name(c[i_name].sub(/ \(S\.?A\.?\)\z/i, ""))] = c[i_val].to_i if c[i_val] =~ /\d/ }
  raise "人口普查数据太少（#{census.size}）" if census.size < 1500
  sa2 = get_json("#{SA_SA2}/query?" + URI.encode_www_form(where: "state_code_2021='4'", outFields: "sa2_code_2021", returnGeometry: true,
                                                         outSR: 4326, maxAllowableOffset: 0.002, f: "json"))["features"]
          .select { |f| f["geometry"] }.map { |f| with_bbox({ "code" => f["attributes"]["sa2_code_2021"] }, f["geometry"]["rings"]) }
  raise "SA2 太少（#{sa2.size}）" if sa2.size < 150

  # 3）每个区：按 "名字|邮编" 对上 SAPOL；对不上而名字只有一个的，用这个名字的所有邮编
  name_count = Hash.new(0)
  SA_SUBURBS.each { |s| name_count[key_name(s["n"])] += 1 }
  by_name = Hash.new { |h, k| h[k] = [] }
  counts.each_key { |k| by_name[k.split("|").first] << k }
  per = ->(n, p) { p.to_i > 0 ? (n * 1000.0 / p).round(2) : nil }
  suburbs = {}
  SA_SUBURBS.each do |s|
    name = key_name(s["n"])
    keys = [by_name[name].find { |k| k == "#{name}|#{s["p"]}" }].compact
    keys = by_name[name] if keys.empty? && name_count[name] == 1
    next if keys.empty? || suburbs.key?("#{name}|#{s["p"]}")
    a = locate(s["pt"], sa2)
    growth = a && erp[a["code"]][2021].to_f > 0 ? erp[a["code"]][pop_year].to_f / erp[a["code"]][2021] : nil
    base = census[name]
    pop = base && (base * (growth || 1.0)).round
    c = SA_CRIME_KEYS.each_index.map { |i| SA_CRIME_KEYS[i] != "total" && SA_CRIME_CATS[SA_CRIME_KEYS[i]].nil? ? nil : keys.sum { |k| counts[k]["last"][i] } }
    row = { "k" => name, "pop" => pop, "c" => c }
    row["p"] = keys.sum { |k| counts[k]["prev"] } if have_prev
    suburbs["#{name}|#{s["p"]}"] = row.compact
  end
  matched = suburbs.values.select { |r| r["pop"].to_i > 0 }
  state_pop = matched.sum { |r| r["pop"] }
  state = SA_CRIME_KEYS.each_with_index.map { |k, i| [k, k != "total" && SA_CRIME_CATS[k].nil? ? nil : per.(matched.sum { |r| r["c"][i].to_i }, state_pop)] }.to_h
  meta = {
    "source" => "South Australia Police (SAPOL), offences against the person and property by suburb; population: ABS Census 2021 (suburbs) grown to ABS estimated resident population #{pop_year} (SA2)",
    "inputs" => { "crime" => stamp, "population_year" => pop_year }, "updated" => Time.now.utc.iso8601, "latest_month" => latest,
    "period" => { "from" => last12.last, "to" => latest }, "prev_period" => have_prev ? { "from" => prev12.last, "to" => prev12.first } : nil,
    "population_year" => pop_year, "keys" => SA_CRIME_KEYS, "scope" => "person_property",
    "categories" => { "total" => "全部罪案（人身和财产）" }.merge(SA_CRIME_CATS.compact.transform_values(&:first)),
    "state" => { "population" => state_pop, "rate" => state }, "small_population" => 1000
  }.compact
  write_json_rows("sa/crime.json", meta, "suburbs", suburbs.sort.to_h)
  puts "南澳犯罪统计：#{meta["period"]["from"]} 至 #{latest}，全州每千人 #{state["total"]} 起/年（入室盗窃 #{state["burglary_dwelling"]}）；" \
       "#{suburbs.size} 个区有数据，#{matched.size} 个有人口数" + (have_prev ? "" : "（缺前 12 个月的数据，不比较变化）")
  %w[NORWOOD|5067 ADELAIDE|5000 GLENUNGA|5064 BURNSIDE|5066 ELIZABETH|5112 PROSPECT|5082].each do |k|
    r = suburbs[k]
    puts "   #{k}: #{r ? "人口 #{r["pop"]}，每千人 #{per.(r["c"][0], r["pop"])}，入室盗窃 #{per.(r["c"][1], r["pop"])}" : "没有"}"
  end
end

abort "这些项目下载失败，已保留旧数据：#{FAILED.join('、')}" unless FAILED.empty?
