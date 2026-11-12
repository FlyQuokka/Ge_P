# 长期数据更新脚本
# 放置位置：仓库里的 scripts/update_longrun.rb
#
# 它读两份清单，然后下载清单里列出的所有数据：
#   data/longrun/countries.json  国家清单（代码、名称、货币）
#   data/longrun/cities.json     城市清单（哪个国家、哪个城市、从哪个来源下载）
#
# 生成 4 个文件（都在 data/longrun/ 里）：
#   national.csv  各国全国房价指数，季度（BIS）
#   fx.csv        各种货币兑美元的汇率，季度平均（BIS）
#   cpi.csv       各国物价指数，季度（BIS），用来扣除通胀
#   cities.csv    各城市房价 = history_*.csv（手工整理的历史数据）
#                              + ABS 季度数据（澳洲）
#                              + FHFA 都会区指数（美国）
#                              + BIS 城市指数（欧洲、中国）
#
# 想加一个国家：在 countries.json 里加一行。
# 想加一个城市：在 cities.json 里加一行（source 写 fhfa 或 bis_dpp，id 写它在该来源里的编号）。
# 都不用改这个脚本。

require "net/http"
require "json"
require "uri"

DIR       = "data/longrun"
COUNTRIES = JSON.parse(File.read("#{DIR}/countries.json", encoding: "UTF-8"))
CITIES    = JSON.parse(File.read("#{DIR}/cities.json", encoding: "UTF-8"))
FAILED    = []   # 记录下载失败的项目，最后统一报告

# ---------- 小工具 ----------
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

# BIS 接口：返回 [{ "列名" => 值, ... }, ...]
def bis(flow, key)
  csv = download("https://stats.bis.org/api/v1/data/#{flow}/#{key}?format=csv&detail=dataonly")
  return [] unless csv && csv.start_with?("FREQ")
  lines = csv.strip.split(/\r?\n/)
  head  = lines.shift.split(",")
  lines.map { |l| head.zip(l.split(",")).to_h }
end

# 读已有的 CSV（某项下载失败时，用来保留它原来的数据）
def old_rows(file)
  File.exist?(file) ? File.readlines(file, chomp: true, encoding: "UTF-8").drop(1).reject(&:empty?) : []
end

def write_csv(file, header, rows)
  File.write(file, ([header] + rows).join("\n") + "\n")
end

# "2011-03" → "2011-Q1"
def quarter_of(month)
  y, m = month.split("-")
  "#{y}-Q#{(m.to_i + 2) / 3}"
end

# 把月度数据变成季度平均：{ "2011-01" => 1.0, ... } → { "2011-Q1" => 1.0, ... }
def monthly_to_quarterly(by_month)
  by_month.group_by { |m, _| quarter_of(m) }
          .map { |q, list| [q, (list.sum { |_, v| v } / list.size).round(4)] }.to_h
end

# ---------- 1. 全国房价指数（BIS WS_SPP） ----------
# VALUE：N = 名义，R = 实际（扣除通胀）；UNIT_MEASURE 628 = 指数（2010 年 = 100）
national = Hash.new { |h, k| h[k] = {} }
old_rows("#{DIR}/national.csv").each do |l|
  country, period, nominal, real = l.split(",")
  national[country][period] = [nominal, real]
end
COUNTRIES.each do |c|
  code = c["code"]
  data = Hash.new { |h, k| h[k] = {} }
  bis("WS_SPP", "Q.#{c['bis'] || code}..").each do |r|
    data[r["TIME_PERIOD"]][r["VALUE"]] = r["OBS_VALUE"] if r["UNIT_MEASURE"] == "628" && !r["OBS_VALUE"].to_s.empty?
  end
  data = data.select { |_, v| v["N"] && v["R"] }.map { |p, v| [p, [v["N"], v["R"]]] }.to_h
  if data.size >= 40
    national[code] = data
    puts "全国指数 #{code}：#{data.keys.min} 至 #{data.keys.max}"
  else
    FAILED << "全国指数 #{code}"
  end
end
codes = COUNTRIES.map { |c| c["code"] }
write_csv("#{DIR}/national.csv", "country,period,nominal,real",
          codes.flat_map { |code| national[code].keys.sort.map { |p| [code, p, *national[code][p]].join(",") } })

# ---------- 2. 汇率（BIS WS_XRU）：1 美元 = 多少本币，季度平均 ----------
fx = Hash.new { |h, k| h[k] = {} }
old_rows("#{DIR}/fx.csv").each { |l| cur, p, v = l.split(","); fx[cur][p] = v }
COUNTRIES.each do |c|
  cur = c["currency"]
  next if cur.nil? || cur == "USD"
  data = bis("WS_XRU", "Q.#{c['bis'] || c['code']}.#{cur}.A")
         .reject { |r| r["OBS_VALUE"].to_s.empty? || r["OBS_VALUE"] == "NaN" }
         .map { |r| [r["TIME_PERIOD"], r["OBS_VALUE"]] }.to_h
  if data.size >= 40
    fx[cur] = data
    puts "汇率 #{cur}：#{data.keys.min} 至 #{data.keys.max}"
  else
    FAILED << "汇率 #{cur}"
  end
end
write_csv("#{DIR}/fx.csv", "currency,period,per_usd",
          fx.keys.sort.flat_map { |cur| fx[cur].keys.sort.map { |p| [cur, p, fx[cur][p]].join(",") } })

# ---------- 3. 物价指数（BIS WS_LONG_CPI，月度 → 季度平均） ----------
cpi = Hash.new { |h, k| h[k] = {} }
old_rows("#{DIR}/cpi.csv").each { |l| country, p, v = l.split(","); cpi[country][p] = v.to_f }
COUNTRIES.each do |c|
  code = c["code"]
  monthly = bis("WS_LONG_CPI", "M.#{c['bis'] || code}.628")
            .reject { |r| r["OBS_VALUE"].to_s.empty? || r["OBS_VALUE"] == "NaN" }
            .map { |r| [r["TIME_PERIOD"], r["OBS_VALUE"].to_f] }.to_h
  if monthly.size < 120
    FAILED << "物价指数 #{code}"
    next
  end
  data = monthly_to_quarterly(monthly)
  # BIS 的物价指数有的国家起步较晚（如欧元区 1990 年）。更早的年份用"名义房价指数 ÷ 实际房价指数"推算，
  # 并按两者都有的第一个季度对齐后接在前面。
  first = data.keys.min
  implied = national[code].map { |p, (n, r)| [p, n.to_f / r.to_f] }.to_h
  if implied[first]
    scale = data[first] / implied[first]
    implied.each { |p, v| data[p] = (v * scale).round(4) if p < first }
  end
  cpi[code] = data
  puts "物价指数 #{code}：#{data.keys.min} 至 #{data.keys.max}"
end
write_csv("#{DIR}/cpi.csv", "country,period,index",
          codes.flat_map { |code| cpi[code].keys.sort.map { |p| [code, p, cpi[code][p]].join(",") } })

# ---------- 4. 各城市房价 ----------
# 统一格式：country,city,type,period,value,source
#   type：house 独立屋 / unit 公寓（澳洲，单位是当地货币）；index 指数；avg_price 每平方米均价
#   period：年份 "1975" 或季度 "2002-Q1"
rows = []

# 4a. 手工整理的历史数据
Dir.glob("#{DIR}/history_*.csv").sort.each { |f| rows.concat(old_rows(f)) }

# 4b. 澳大利亚：ABS 季度成交中位价（data/prices.csv，单位是千澳元）
ABS_CITIES = { "1GSYD" => "Sydney", "2GMEL" => "Melbourne", "3GBRI" => "Brisbane", "4GADE" => "Adelaide",
               "5GPER" => "Perth", "6GHOB" => "Hobart", "7GDAR" => "Darwin", "8ACTE" => "Canberra" }
ABS_TYPES  = { "3" => "house", "4" => "unit" }
if File.exist?("data/prices.csv")
  abs  = File.readlines("data/prices.csv", chomp: true)
  head = abs.shift.split(",")
  i_m, i_r, i_t, i_v = %w[MEASURE REGION TIME_PERIOD OBS_VALUE].map { |c| head.index(c) }
  abs.each do |l|
    c = l.split(",")
    city, type = ABS_CITIES[c[i_r]], ABS_TYPES[c[i_m]]
    next unless city && type && c[i_v] && !c[i_v].empty?
    rows << ["AU", city, type, c[i_t], (c[i_v].to_f * 1000).round, "abs"].join(",")
  end
end

# 4c / 4d. 清单里需要下载的城市
previous = old_rows("#{DIR}/cities.csv").group_by { |l| l.split(",")[0, 2] }   # 旧数据，按 [国家, 城市] 分组

# 美国：FHFA 都会区房价指数（All-Transactions，季度，1975 年起）。一个文件包含所有都会区。
fhfa_cities = CITIES.select { |c| c["source"] == "fhfa" }
fhfa = {}
unless fhfa_cities.empty?
  csv = download("https://www.fhfa.gov/hpi/download/quarterly_datasets/hpi_at_metro.csv")
  wanted = fhfa_cities.map { |c| c["id"] }
  (csv || "").each_line do |l|
    # 每行："都会区名称",编号,年,季度,指数,(标准误)
    m = l.match(/",(\d+),(\d{4}),(\d),([0-9.]+),/) or next
    next unless wanted.include?(m[1])
    (fhfa[m[1]] ||= {})["#{m[2]}-Q#{m[3]}"] = m[4]
  end
end

CITIES.each do |c|
  series =
    case c["source"]
    when "fhfa"
      fhfa[c["id"]] || {}
    when "bis_dpp"
      # BIS 详细房价数据（WS_DPP）。id 第一位是频率：Q 季度，M 月度（月度会换算成季度平均）
      data = bis("WS_DPP", c["id"]).reject { |r| r["OBS_VALUE"].to_s.empty? || r["OBS_VALUE"] == "NaN" }
                                   .map { |r| [r["TIME_PERIOD"], r["OBS_VALUE"].to_f] }.to_h
      c["id"].start_with?("M.") ? monthly_to_quarterly(data) : data
    else
      next   # source 是 local 的城市不用下载
    end

  if series.size >= 20
    series.keys.sort.each { |p| rows << [c["country"], c["city"], "index", p, series[p], c["source"]].join(",") }
    puts "城市 #{c['city']}：#{series.keys.min} 至 #{series.keys.max}"
  else
    FAILED << "城市 #{c['city']}"
    rows.concat((previous[[c["country"], c["city"]]] || []).select { |l| l.end_with?("," + c["source"]) })
  end
end

abort "城市数据太少，本次不更新 cities.csv" if rows.size < 400
write_csv("#{DIR}/cities.csv", "country,city,type,period,value,source", rows.uniq.sort)
puts "城市数据：共 #{rows.uniq.size} 行"

abort "这些项目下载失败，已保留旧数据：#{FAILED.join('、')}" unless FAILED.empty?
