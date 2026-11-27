# 找房页面（第三页）新州（NSW）部分的数据更新脚本
# 放置位置：仓库里的 scripts/update_househunt_nsw.rb（共用的小工具在 scripts/househunt_lib.rb）
#
# 生成的文件（都在 data/househunt/nsw/ 里）：
#   suburbs.json          新州所有区（suburb）：名称、邮编、范围                         —— NSW Spatial Services 行政边界
#   schools.json          新州学校：公立（教育部名单，含精英 / 部分精英中学）和私立（地名库）  —— NSW 教育部、NSW Spatial Services
#   catchments/*.json     公立学校学区（local enrolment area）的边界，切成小块，网页只下载用得到的那一块 —— NSW 教育部
#   crime.json            每个区最近 12 个月的罪案数、人口和每千人比率                   —— NSW 犯罪统计局 BOCSAR、澳洲统计局
#
# 房子本身的隐藏信息（strata、洪水、山火、规划等）不在这里下载：网页查地址时直接去新州政府地图服务查。
# 每一项单独处理；某一项失败时保留它原来的文件，其他照常更新，最后报告哪些失败了。

require_relative "househunt_lib"

NSW_DIR  = "#{DIR}/nsw"
CATCH_DIR = "#{NSW_DIR}/catchments"
[NSW_DIR, CATCH_DIR].each { |d| Dir.mkdir(d) unless Dir.exist?(d) }
SPATIAL  = "https://portal.spatial.nsw.gov.au/server/rest/services"
CKAN     = "https://data.nsw.gov.au/data/api/3/action/package_show?id="

# 数据目录（data.nsw.gov.au）里某个数据集：最后修改时间和下载链接
def ckan_package(id)
  get_json(CKAN + id)["result"] or raise "数据目录里找不到 #{id}"
end

# ---------- 1. 新州所有区（suburb）：名称、邮编、范围，以及区里面的一个点（算人口、对应犯罪统计用） ----------
NSW_SUBURBS = []
step("新州区域名单") do
  feats = arc_all("#{SPATIAL}/NSW_Administrative_Boundaries_Theme/FeatureServer/2",
                  where: "1=1", outFields: "suburbname,postcode", returnGeometry: true, outSR: 4326,
                  maxAllowableOffset: 0.001, orderByFields: "rid")
  feats.each do |f|
    rings = (f["geometry"] || {})["rings"] or next
    pts = rings.flatten(1)
    xs = pts.map(&:first)
    ys = pts.map(&:last)
    NSW_SUBURBS << { "n" => title_case(f["attributes"]["suburbname"].to_s), "p" => f["attributes"]["postcode"].to_s,
                     "bbox" => [xs.min, ys.min, xs.max, ys.max].map { |v| v.round(4) }, "pt" => interior_point(rings) }
  end
  list = NSW_SUBURBS.uniq { |s| [s["n"], s["p"]] }.sort_by { |s| [s["n"], s["p"]] }
  raise "区太少（#{list.size}）" if list.size < 4000
  File.write("#{NSW_DIR}/suburbs.json", "[\n" + list.map { |s| s.reject { |k, _| k == "pt" }.to_json }.join(",\n") + "\n]\n")
  puts "新州区域名单：#{list.size} 个"
end

# ---------- 2. 学校 ----------
# 公立：教育部的学校名单（每晚更新）。私立：新州地名库里的学校，去掉名单里已有的公立学校。
SCHOOLS_PKG = "nsw-education-nsw-public-schools-master-dataset"
ACT_BOX = [148.76, -35.93, 149.40, -35.12]   # 首都领地（ACT）的学校也在地名库里，去掉

def nsw_school_kind(level)
  case level
  when "Primary School", "Infants School" then "P"
  when "Secondary School" then "S"
  when "Central/Community School" then "K12"
  else "X"   # 特殊学校、环境教育中心等
  end
end

step("新州学校") do
  pkg = ckan_package(SCHOOLS_PKG)
  url = pkg["resources"].map { |r| r["url"].to_s }.find { |u| u =~ /master_dataset\.csv\z/i } or raise "找不到学校名单 CSV"
  head, rows = csv_table((download(url) or raise "下载学校名单失败").delete_prefix([0xFEFF].pack("U")))
  col = ->(n) { head.index(n) or raise "学校名单格式变了（没有 #{n}）" }
  publics = rows.map do |r|
    lat, lon = r[col.("Latitude")].to_f, r[col.("Longitude")].to_f
    next if lat.zero? || lon.zero?
    sel = { "Fully Selective" => "F", "Partially Selective" => "P" }[r[col.("Selective_school")]]
    gender = { "Boys" => "B", "Girls" => "G" }[r[col.("School_gender")]]
    { "c" => r[col.("School_code")], "n" => r[col.("School_name")].to_s.strip, "g" => 1, "k" => nsw_school_kind(r[col.("Level_of_schooling")]),
      "sel" => sel, "sx" => gender, "y" => r[col.("School_subtype")].to_s.strip, "e" => r[col.("latest_year_enrolment_FTE")].to_i,
      "lat" => lat.round(5), "lon" => lon.round(5), "t" => r[col.("Town_suburb")].to_s.strip, "w" => r[col.("Website")].to_s.strip }.reject { |_, v| v.nil? || v == "" }
  end.compact
  raise "公立学校太少（#{publics.size}）" if publics.size < 2000
  known = publics.map { |s| key_name(s["n"]) }.to_h { |n| [n, true] }
  # 公立学校的分校在地名库里名字常常略有不同（"Georges River College Hurstville Boys Campus"），按前 3 个词也算同一所
  prefix3 = ->(n) { w = n.gsub(/[^A-Z ]/, "").split(" "); w.size >= 3 ? w.first(3).join(" ") : nil }
  known_prefix = publics.map { |s| prefix3.(key_name(s["n"])) }.compact.to_h { |p| [p, true] }
  privates = []
  { 0 => "P", 1 => "K12", 2 => "S" }.each do |layer, kind|
    arc_all("#{SPATIAL}/NSW_FOI_Education_Facilities/FeatureServer/#{layer}", where: "operationalstatus=1", outFields: "generalname",
            returnGeometry: true, outSR: 4326, orderByFields: "objectid").each do |f|
      name = key_name(f["attributes"]["generalname"])
      x, y = f["geometry"] && [f["geometry"]["x"], f["geometry"]["y"]]
      next if name.empty? || x.nil? || known[name] || known_prefix[prefix3.(name)]
      next if name =~ /PUBLIC SCHOOL|HIGH SCHOOL\z|HIGH SCHOOL CENTRE|DISTANCE EDUCATION|TAFE|PRESCHOOL|KINDERGARTEN/
      next if x.between?(ACT_BOX[0], ACT_BOX[2]) && y.between?(ACT_BOX[1], ACT_BOX[3])
      privates << { "n" => title_case(name), "g" => 0, "k" => kind, "lat" => y.round(5), "lon" => x.round(5) }
    end
  end
  privates = privates.uniq { |s| s["n"] }
  schools = (publics + privates).sort_by { |s| s["n"] }
  meta = { "source" => "NSW Department of Education, NSW public schools master dataset; NSW Spatial Services, Features of Interest (education facilities)",
           "updated" => Time.now.utc.iso8601,
           "kinds" => { "P" => "小学", "S" => "中学", "K12" => "小学到中学", "X" => "特殊学校 / 环境教育中心等" },
           "selective" => { "F" => "全部考试入学（精英中学）", "P" => "部分考试入学" } }
  write_json_rows("nsw/schools.json", meta, "schools", schools)
  puts "新州学校：公立 #{publics.size} 所（精英 #{publics.count { |s| s["sel"] }} 所），私立 #{privates.size} 所"
end

# ---------- 3. 公立学校学区（local enrolment area） ----------
# 全州的学区边界有 10 MB，网页不可能一次下载。所以把它切成大小不同的方块（悉尼这种学校密的地方切得小），
# 每块一个文件，网页查某个地址时只下载那个地址所在的一块（切块的方法在 househunt_lib.rb 的 build_tiles）。
CATCH_PKG = "nsw-education-school-intake-zones-catchment-areas-for-nsw-government-schools"

step("新州学区") do
  pkg = ckan_package(CATCH_PKG)
  stamp = pkg["metadata_modified"]
  old = (JSON.parse(File.read("#{CATCH_DIR}/index.json")) rescue nil)
  if old && old["source_modified"] == stamp
    puts "新州学区：教育部没有更新学区（#{stamp}），不用重新计算"
    next
  end
  url = pkg["resources"].map { |r| r["url"].to_s }.find { |u| u =~ /catchments\.zip\z/i } or raise "找不到学区文件"
  zip = download(url, binary: true) or raise "下载学区失败"
  feats = []
  year = nil
  Dir.mktmpdir do |tmp|
    File.binwrite("#{tmp}/c.zip", zip)
    system("unzip", "-o", "-q", "#{tmp}/c.zip", "-d", tmp) or raise "解压失败"
    year = (JSON.parse(File.read("#{tmp}/catchment_sf_info.json"))["current_enrolment_year"] rescue nil)
    { "primary" => "P", "secondary" => "S" }.each do |kind, t|
      Dir.mkdir("#{tmp}/#{kind}")
      %w[shp dbf].each { |ext| File.rename("#{tmp}/catchments_#{kind}.#{ext}", "#{tmp}/#{kind}/c.#{ext}") }
      read_shapefile("#{tmp}/#{kind}").each do |a, rings|
        rings = rings.map { |r| simplify(r, 0.00002) }.select { |r| r.size >= 4 }
        feats << { id: a["USE_ID"], t: t, ct: a["CATCH_TYPE"], rings: rings } unless rings.empty?
      end
    end
  end
  raise "学区太少（#{feats.size}）" if feats.size < 1800
  all = feats.flat_map { |f| f[:rings] }.flatten(1)
  root = [all.map(&:first).min, all.map(&:last).min, all.map(&:first).max, all.map(&:last).max]
  root = [root[0] - 0.001, root[1] - 0.001, root[2] + 0.001, root[3] + 0.001]
  Dir["#{CATCH_DIR}/t*.json"].each { |f| File.delete(f) }
  tiles = []
  build_tiles(CATCH_DIR, root, feats, 0, tiles)
  index = { "source" => "NSW Department of Education, school intake zones (catchment areas) for NSW government schools",
            "source_modified" => stamp, "enrolment_year" => year, "updated" => Time.now.utc.iso8601,
            "types" => { "PRIMARY" => "小学", "INFANTS" => "幼小（K–2）", "CENTRAL_PRIMARY" => "中心学校（小学部分）",
                         "HIGH_COED" => "中学（男女合校）", "HIGH_BOYS" => "男子中学", "HIGH_GIRLS" => "女子中学", "CENTRAL_HIGH" => "中心学校（中学部分）" },
            "tiles" => tiles }
  File.write("#{CATCH_DIR}/index.json", JSON.generate(index) + "\n")
  sizes = Dir["#{CATCH_DIR}/t*.json"].map { |f| File.size(f) }
  puts "新州学区：#{feats.size} 个学区（#{year} 学年），切成 #{tiles.size} 块，最大 #{sizes.max / 1024} KB，合计 #{sizes.sum / 1024} KB"
end

# ---------- 4. 犯罪统计（BOCSAR，每个区每月、每种罪名的数量） ----------
BOCSAR_URL = "https://bocsarblob.blob.core.windows.net/bocsar-open-data/SuburbData.zip"
NSW_CENSUS = "https://data.api.abs.gov.au/rest/data/ABS,C21_G01_SAL,1.0.0/3.P_1..SAL.1?format=csvfilewithlabels"
NSW_ERP    = "https://data.api.abs.gov.au/rest/data/ABS,ABS_ANNUAL_ERP_ASGS2021/ERP.SA2..A?startPeriod=2021&format=csvfile"
NSW_SA2    = "https://geo.abs.gov.au/arcgis/rest/services/ASGS2021/SA2/MapServer/0"
NSW_CRIME_FILE = "#{NSW_DIR}/crime.json"
# key → [中文名, 判断条件（cat = 大类，sub = 具体罪名）]。key 和西澳一样，网页可以共用
NSW_CRIME_CATS = {
  "burglary_dwelling" => ["入室盗窃",           ->(cat, sub) { sub == "Break and enter dwelling" }],
  "stealing_mv"       => ["偷车",               ->(cat, sub) { sub == "Motor vehicle theft" }],
  "stealing_from_mv"  => ["车内财物被偷",       ->(cat, sub) { sub == "Steal from motor vehicle" }],
  "property_damage"   => ["财物损坏",           ->(cat, sub) { cat == "Malicious damage to property" }],
  "assault"           => ["人身攻击（非家庭）", ->(cat, sub) { sub == "Non-domestic violence related assault" }],
  "family_violence"   => ["家庭暴力",           ->(cat, sub) { sub == "Domestic violence related assault" }],
  "robbery"           => ["抢劫",               ->(cat, sub) { cat == "Robbery" }],
  "drugs"             => ["毒品",               ->(cat, sub) { cat == "Drug offences" }]
}
CRIME_KEYS = ["total"] + NSW_CRIME_CATS.keys

# 地方政府名字比较用："City of Parramatta Council" / "Parramatta" → "PARRAMATTA"
def lga_key(s)
  k = key_name(s).sub(/\ACITY OF /, "").sub(/ COUNCIL\z/, "")
  k = k.sub(/ (SHIRE|REGIONAL|CITY|MUNICIPAL)\z/, "") while k =~ / (SHIRE|REGIONAL|CITY|MUNICIPAL)\z/
  k.sub(/\ATHE /, "").gsub(/[^A-Z]/, "")
end

step("新州犯罪统计") do
  raise "区域名单没有准备好" if NSW_SUBURBS.empty?
  stamp = last_modified(BOCSAR_URL)
  old = (JSON.parse(File.read(NSW_CRIME_FILE)) rescue nil)
  if old && stamp.nil?
    puts "新州犯罪统计：暂时查不到 BOCSAR 有没有发布新数据，先用现有数据，明天再查"
    next
  end
  # 人口：澳洲统计局 SA2 估计人口（最新一年和 2021 年，算增长）
  head, rows = csv_table(download(NSW_ERP) || raise("下载估计人口失败"))
  ic, iy, iv = %w[ASGS_2021 TIME_PERIOD OBS_VALUE].map { |k| head.index(k) or raise "估计人口格式变了" }
  erp = Hash.new { |h, k| h[k] = {} }
  rows.each { |c| erp[c[ic]][c[iy].to_i] = c[iv].to_f if c[ic].to_s.start_with?("1") && c[iv] =~ /\d/ }
  pop_year = erp.values.flat_map(&:keys).max or raise "估计人口是空的"
  if old && old["inputs"] == { "crime" => stamp, "population_year" => pop_year }
    puts "新州犯罪统计：BOCSAR 还没有发布新数据（#{stamp}），不用重新计算"
    next
  end

  # 1）读 BOCSAR：每个区最近 24 个月
  counts = Hash.new { |h, k| h[k] = { "last" => Hash.new(0), "prev" => Hash.new(0) } }
  months = nil
  Dir.mktmpdir do |tmp|
    File.binwrite("#{tmp}/s.zip", download(BOCSAR_URL, binary: true) || raise("下载犯罪统计失败"))
    IO.popen(["unzip", "-p", "#{tmp}/s.zip"]) do |io|
      header = io.gets.to_s.strip
      cols = header[1..-2].split('","')
      raise "犯罪统计表头变了" unless cols[0] == "Suburb" && cols[1] == "Offence category"
      months = cols.last(24)
      io.each_line do |line|
        c = line.strip[1..-2].split('","')
        next if c.size < 27
        cat, sub = c[1], c[2]
        vals = c.last(24).map(&:to_i)
        last12, prev12 = vals.last(12).sum, vals.first(12).sum
        h = counts[key_name(c[0])]
        h["last"]["total"] += last12
        h["prev"]["total"] += prev12
        NSW_CRIME_CATS.each { |k, (_, test)| h["last"][k] += last12 if test.(cat, sub) }
      end
    end
  end
  raise "犯罪统计内容太少（#{counts.size} 个区）" if counts.size < 4000
  latest = Date.strptime("1 " + months.last, "%d %b %Y").strftime("%Y-%m")

  # 2）2021 年人口普查：每个区的人口（名字和 BOCSAR 一样带地方政府名，例如 "SUMMER HILL (INNER WEST)"）
  head, rows = csv_table(download(NSW_CENSUS) || raise("下载人口普查失败"))
  i_name, i_val = head.index("Region"), head.index("OBS_VALUE")
  census = {}
  rows.each { |c| census[key_name(c[i_name].sub(/ \(NSW\)\z/, "").sub(/ - NSW\)\z/, ")"))] = c[i_val].to_i if c[i_val] =~ /\d/ }
  raise "人口普查数据太少（#{census.size}）" if census.size < 4000

  # 3）政府地图上的每个区 → 对应 BOCSAR 的名字。同名的区（BOCSAR 写成 "名字 (地方政府)"）按所在地方政府区分
  lgas = arc_all("#{SPATIAL}/NSW_Administrative_Boundaries_Theme/FeatureServer/8", where: "1=1", outFields: "lganame",
                 returnGeometry: true, outSR: 4326, maxAllowableOffset: 0.002, orderByFields: "rid")
           .select { |f| f["geometry"] }.map { |f| with_bbox({ "name" => f["attributes"]["lganame"] }, f["geometry"]["rings"]) }
  sa2 = get_json("#{NSW_SA2}/query?" + URI.encode_www_form(where: "state_code_2021='1'", outFields: "sa2_code_2021", returnGeometry: true,
                                                         outSR: 4326, maxAllowableOffset: 0.002, f: "json"))["features"]
          .select { |f| f["geometry"] }.map { |f| with_bbox({ "code" => f["attributes"]["sa2_code_2021"] }, f["geometry"]["rings"]) }
  raise "SA2 太少（#{sa2.size}）" if sa2.size < 500
  qualified = Hash.new { |h, k| h[k] = [] }   # "SUMMER HILL" → ["SUMMER HILL (INNER WEST)", ...]
  counts.keys.each { |k| qualified[$1] << k if k =~ /\A(.+) \((.+)\)\z/ }
  by_admin = {}
  NSW_SUBURBS.each do |s|
    name = key_name(s["n"])
    key = if counts.key?(name) && qualified[name].empty?
            name
          elsif qualified[name].any?
            lga = locate(s["pt"], lgas)
            lga && qualified[name].find { |q| lga_key(q[/\((.+)\)\z/, 1]) == lga_key(lga["name"]) }
          end
    next unless key
    a = locate(s["pt"], sa2)
    growth = a && erp[a["code"]][2021].to_f > 0 ? erp[a["code"]][pop_year].to_f / erp[a["code"]][2021] : nil
    by_admin["#{name}|#{s["p"]}"] = { k: key, growth: growth }
  end

  # 4）每个区：人口（2021 年普查 × 所在 SA2 的人口增长）、罪案数
  pop_of = {}
  by_admin.each_value { |v| pop_of[v[:k]] ||= census[v[:k]] && (census[v[:k]] * (v[:growth] || 1.0)).round }
  per = ->(n, p) { p.to_i > 0 ? (n * 1000.0 / p).round(2) : nil }
  matched = counts.select { |k, _| pop_of[k].to_i > 0 }
  state_pop = matched.sum { |k, _| pop_of[k] }
  state = CRIME_KEYS.map { |c| [c, per.(matched.sum { |_, v| v["last"][c] }, state_pop)] }.to_h
  suburbs = by_admin.map do |adm, v|
    c = counts[v[:k]]
    row = { "k" => v[:k], "pop" => pop_of[v[:k]], "c" => CRIME_KEYS.map { |x| c["last"][x] }, "p" => c["prev"]["total"] }.compact
    [adm, row]
  end.sort.to_h
  meta = {
    "source" => "NSW Bureau of Crime Statistics and Research (BOCSAR), recorded criminal incidents by suburb; population: ABS Census 2021 (suburbs) grown to ABS estimated resident population #{pop_year} (SA2)",
    "inputs" => { "crime" => stamp, "population_year" => pop_year }, "updated" => Time.now.utc.iso8601, "latest_month" => latest,
    "period" => { "from" => month_add(latest, -11), "to" => latest }, "prev_period" => { "from" => month_add(latest, -23), "to" => month_add(latest, -12) },
    "population_year" => pop_year, "keys" => CRIME_KEYS,
    "categories" => { "total" => "全部罪案" }.merge(NSW_CRIME_CATS.transform_values(&:first)),
    "state" => { "population" => state_pop, "rate" => state }, "small_population" => 1000
  }
  write_json_rows("nsw/crime.json", meta, "suburbs", suburbs)
  missing = NSW_SUBURBS.size - by_admin.size
  puts "新州犯罪统计：#{meta["period"]["from"]} 至 #{latest}，全州每千人 #{state["total"]} 起/年（入室盗窃 #{state["burglary_dwelling"]}）；" \
       "#{suburbs.size} 个区有数据（#{missing} 个区对不上），#{matched.size} 个有人口数"
  %w[EPPING|2121 PARRAMATTA|2150 CHATSWOOD|2067 BLACKTOWN|2148 SUMMER\ HILL|2130].each do |k|
    r = suburbs[k]
    puts "   #{k}: #{r ? "#{r["k"]} 人口 #{r["pop"]}，每千人 #{per.(r["c"][0], r["pop"])}，入室盗窃 #{per.(r["c"][1], r["pop"])}" : "没有"}"
  end
end

abort "这些项目下载失败，已保留旧数据：#{FAILED.join('、')}" unless FAILED.empty?
