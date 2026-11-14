# 找房页面（第三页）用的数据更新脚本
# 放置位置：仓库里的 scripts/update_househunt.rb
#
# 生成 2 个文件（都在 data/househunt/ 里）：
#   suburbs.json  珀斯和皮尔地区的区域名单：名称、邮编、范围          —— 西澳 Landgate 区域边界（SLIP 公开服务）
#   rates.json    澳洲平均房贷利率（自住、新贷款）和现金利率          —— 澳洲储备银行 RBA 统计表 F6、F1.1
#
# 房子的隐藏信息（strata、洪水、山火等）不在这里下载：网页会在你查某个地址时，直接去政府地图服务查询。
# 每一项单独下载；某一项失败时保留它原来的文件，其他照常更新，最后报告哪些失败了。
# 不需要安装任何东西：GitHub Actions 自带 Ruby。

require "net/http"
require "json"
require "uri"
require "time"

DIR    = "data/househunt"
FAILED = []
Dir.mkdir(DIR) unless Dir.exist?(DIR)

def download(url)
  uri = URI(url)
  3.times do
    begin
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 30, read_timeout: 120) do |http|
        http.get(uri.request_uri, "User-Agent" => "Mozilla/5.0")
      end
      return res.body.force_encoding("UTF-8") if res.is_a?(Net::HTTPSuccess)
    rescue StandardError => e
      warn "  下载出错 #{e.class}：#{url}"
    end
    sleep 5
  end
  nil
end

# 尝试做一件事；出错就记下来，保留旧文件
def step(name)
  yield
rescue StandardError => e
  warn "#{name} 失败：#{e.message}"
  FAILED << name
end

# "SOUTH PERTH" → "South Perth"，"O'CONNOR" → "O'Connor"
def title_case(name)
  name.downcase.split(" ").map { |w| w.split("'").map(&:capitalize).join("'") }.join(" ")
end

# ---------- 1. 区域名单（珀斯和皮尔地区，用于输入区域名时的提示和地图定位） ----------
step("区域名单") do
  query = URI.encode_www_form(
    geometry: "115.45,-32.90,116.45,-31.30", geometryType: "esriGeometryEnvelope", inSR: 4326,
    spatialRel: "esriSpatialRelIntersects", outFields: "name,postcode", returnGeometry: true,
    outSR: 4326, maxAllowableOffset: 0.001, f: "json"
  )
  json = download("https://public-services.slip.wa.gov.au/public/rest/services/SLIP_Public_Services/Boundaries/MapServer/16/query?#{query}") or raise "下载失败"
  j = JSON.parse(json)
  raise j["error"]["message"].to_s if j["error"]
  list = j["features"].map do |f|
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
  File.write("#{DIR}/rates.json", JSON.pretty_generate(out) + "\n")
  puts "房贷利率：浮动 #{variable["value"]}%（#{variable["date"]}），现金利率 #{cash["value"]}%（#{cash["date"]}）"
end

abort "这些项目下载失败，已保留旧数据：#{FAILED.join('、')}" unless FAILED.empty?
