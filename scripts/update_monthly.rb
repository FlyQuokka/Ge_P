# 每月房价数据更新脚本
# 放置位置：仓库里的 scripts/update_monthly.rb
#
# 作用：从 realestate.com.au 旗下 PropTrack 的 Home Price Index 页面
#       (https://www.proptrack.com.au/home-price-index/) 所嵌入的图表里读取最新一个月的数据，
#       1) 把这个月的各城市数据写入 data/monthly.csv（已有的月份会被覆盖，没有的会新增）
#       2) 把"年度涨幅"的完整月度历史写入 data/annual_growth.csv（每次整份重写）
#
# 不需要安装任何东西，GitHub Actions 自带 Ruby。

require "net/http"
require "json"
require "uri"

# PropTrack 页面里 4 个图表的编号（Flourish 图表）
CHARTS = {
  "growth"   => 9981590,  # 各首府城市年度涨幅，按月，2015 年至今
  "dwelling" => 9981562,  # 全部住宅：月度涨幅 / 年度涨幅 / 中位价
  "house"    => 9981587,  # 独立屋
  "unit"     => 9981583   # 公寓
}

# PropTrack 表格里的名称 → 我们 CSV 里用的名称
REGIONS = {
  "Perth" => "Perth", "Sydney" => "Sydney", "Melbourne" => "Melbourne",
  "Brisbane" => "Brisbane", "Adelaide" => "Adelaide", "Hobart" => "Hobart",
  "Darwin" => "Darwin", "ACT" => "Canberra", "Canberra" => "Canberra",
  "Capital Cities" => "Capital cities", "National" => "National"
}

MONTHLY_FILE = "data/monthly.csv"
GROWTH_FILE  = "data/annual_growth.csv"
HEADER = "month,region,type,median,monthly_pct,annual_pct"

def fetch(id)
  uri = URI("https://flo.uri.sh/visualisation/#{id}/embed")
  5.times do
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 30, read_timeout: 60) do |http|
      http.get(uri.request_uri, "User-Agent" => "Mozilla/5.0")
    end
    return res.body.force_encoding("UTF-8") if res.is_a?(Net::HTTPSuccess)
    if res.is_a?(Net::HTTPRedirection)
      uri = URI.join(uri.to_s, res["location"])
    else
      sleep 5
    end
  end
  abort "下载失败：图表 #{id}"
end

# 网页源码里有一行 "_Flourish_data = {...}," ，把这段 JSON 取出来
def extract(html, name)
  line = html[/^\s*(?:var )?#{name} = (\{.*\})[,;]?\s*$/, 1]
  abort "页面格式变了：找不到 #{name}" unless line
  JSON.parse(line)
end

def pct(text)
  Float(text.to_s.strip.delete("%+"))
end

# ---------- 1. 年度涨幅历史（同时告诉我们最新数据是哪个月） ----------
html   = fetch(CHARTS["growth"])
cities = extract(html, "_Flourish_data_column_names")["data"]["value"]
rows   = extract(html, "_Flourish_data")["data"]

growth = rows.map do |r|
  d, m, y = r["label"].split("/").map(&:to_i)          # 例如 "01/10/2026" = 2026 年 10 月
  [format("%04d-%02d", y, m), r["value"].map { |v| pct(v) }]
end
growth.sort_by!(&:first)
latest_month, latest_values = growth.last
abort "年度涨幅数据太少" if growth.size < 100 || !cities.include?("Perth")

# ---------- 2. 最新一个月的三张表 ----------
new_rows = []
%w[dwelling house unit].each do |type|
  table = extract(fetch(CHARTS[type]), "_Flourish_data")["rows"]
  table.each do |r|
    name, monthly, annual, median = r["columns"]
    region = REGIONS[name.delete("*").strip]
    next unless region
    value = Integer(median.delete("$, "))
    abort "中位价不合理：#{name} #{median}" unless value.between?(100_000, 5_000_000)
    new_rows << [latest_month, region, type, value, pct(monthly), pct(annual)]
  end
end
abort "表格里城市不全" unless new_rows.size == 30

# 安全检查：表格和年度涨幅图必须是同一个月的数据（用 Perth 的年度涨幅核对）
perth_table = new_rows.find { |r| r[1] == "Perth" && r[2] == "dwelling" }[5]
perth_chart = latest_values[cities.index("Perth")]
if (perth_table - perth_chart).abs > 0.05
  abort "表格(#{perth_table}%)和走势图(#{perth_chart}%)不是同一个月的数据，本次不更新。"
end

# ---------- 3. 写入 data/monthly.csv ----------
old = File.exist?(MONTHLY_FILE) ? File.readlines(MONTHLY_FILE, chomp: true).drop(1).reject(&:empty?) : []
kept = old.reject { |line| line.start_with?(latest_month + ",") }
all  = (kept + new_rows.map { |r| r.join(",") }).sort
File.write(MONTHLY_FILE, ([HEADER] + all).join("\n") + "\n")

# ---------- 4. 写入 data/annual_growth.csv ----------
lines = ["month," + cities.join(",")] + growth.map { |month, vals| ([month] + vals).join(",") }
File.write(GROWTH_FILE, lines.join("\n") + "\n")

puts "完成：最新月份 #{latest_month}，Perth 全部住宅中位价 $#{new_rows.find { |r| r[1] == 'Perth' && r[2] == 'dwelling' }[3]}"
