# 黄金和石油数据更新脚本
# 放置位置：仓库里的 scripts/update_commodities.rb
#
# 生成 5 个文件（都在 data/commodities/ 里）：
#   monthly.csv     月度价格（美元）：黄金（每盎司）、布伦特原油、WTI 原油（每桶），1960 年起   —— 世界银行
#   oil_daily.csv   每日原油现货价（美元/桶）：布伦特、WTI，1987 年起                          —— 美国能源信息署 EIA
#   gold_daily.csv  每日金价（美元/盎司）：每次运行记下当天的现货价，从 2026-11-13 开始积累       —— gold-api.com
#   fx_daily.csv    每日汇率：1 美元兑多少澳元 / 人民币 / 欧元，1999 年起                       —— 欧洲央行 ECB
#   fx_monthly.csv  月度汇率（月平均），1957 年起（欧元 1974 年起）                            —— 国际清算银行 BIS
#
# 每一项单独下载；某一项失败时保留它原来的文件，其他照常更新，最后报告哪些失败了。
# 不需要安装任何东西：GitHub Actions 自带 Ruby 和 unzip。

require "net/http"
require "json"
require "uri"
require "date"
require "time"
require "tmpdir"

DIR    = "data/commodities"
FAILED = []
Dir.mkdir(DIR) unless Dir.exist?(DIR)

def download(url, binary: false)
  uri = URI(url)
  5.times do
    begin
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 30, read_timeout: 120) do |http|
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

def old_rows(file)
  File.exist?(file) ? File.readlines(file, chomp: true, encoding: "UTF-8").drop(1).reject(&:empty?) : []
end

def write_csv(file, header, rows)
  File.write(file, ([header] + rows).join("\n") + "\n")
end

# 尝试做一件事；出错就记下来，保留旧文件
def step(name)
  yield
rescue StandardError => e
  warn "#{name} 失败：#{e.message}"
  FAILED << name
end

# ---------- 1. 世界银行月度价格（"Pink Sheet"） ----------
# 下载地址每个月会变，所以先打开世界银行的商品市场页面找到最新的 Excel 文件
step("世界银行月度价格") do
  page = download("https://www.worldbank.org/en/research/commodity-markets") or raise "打不开世界银行页面"
  link = page[%r{https://[^"']+CMO-Historical-Data-Monthly\.xlsx}] or raise "页面上找不到月度数据文件"
  xlsx = download(link, binary: true) or raise "下载 Excel 失败"

  Dir.mktmpdir do |tmp|
    path = File.join(tmp, "cmo.xlsx")
    File.binwrite(path, xlsx)
    # Excel 文件其实是一个压缩包，里面是 XML。用 unzip 读出"文字表"和"Monthly Prices"那一页
    read = ->(inner) { IO.popen(["unzip", "-p", path, inner], &:read).force_encoding("UTF-8") }
    workbook = read.("xl/workbook.xml")
    rels     = read.("xl/_rels/workbook.xml.rels")
    rid      = workbook[/<sheet [^>]*name="Monthly Prices"[^>]*r:id="([^"]+)"/, 1] or raise "找不到 Monthly Prices 这一页"
    target   = rels[/Id="#{rid}"[^>]*Target="([^"]+)"/, 1] || rels[/Target="([^"]+)"[^>]*Id="#{rid}"/, 1]
    sheet    = read.("xl/" + target.sub(%r{^/?xl/}, ""))
    strings  = read.("xl/sharedStrings.xml").scan(/<si>(.*?)<\/si>/m).map { |(x)| x.scan(/<t[^>]*>([^<]*)<\/t>/).join }

    rows = sheet.scan(/<row [^>]*>(.*?)<\/row>/m).map do |(r)|
      r.scan(/<c r="([A-Z]+)\d+"([^>]*?)(?:\/>|>(.*?)<\/c>)/m).map do |col, attrs, inner|
        v = inner.to_s[/<v>([^<]*)<\/v>/, 1]
        v = strings[v.to_i] if v && attrs.include?('t="s"')
        [col, v]
      end.to_h
    end

    header = rows.find { |r| r.values.include?("Gold") } or raise "找不到表头"
    col = ->(name) { header.key(name) or raise "找不到这一列：#{name}" }
    c_gold, c_brent, c_wti = col.("Gold"), col.("Crude oil, Brent"), col.("Crude oil, WTI")
    num = ->(v) { v && v =~ /\A-?[\d.]+(E-?\d+)?\z/i ? v.to_f.round(2) : nil }

    out = rows.select { |r| r["A"].to_s =~ /\A\d{4}M\d{2}\z/ }.map do |r|
      month = r["A"].sub("M", "-")
      vals = [num.(r[c_gold]), num.(r[c_brent]), num.(r[c_wti])]
      next if vals.all?(&:nil?)
      ([month] + vals.map { |v| v.nil? ? "" : v }).join(",")
    end.compact
    raise "月份太少（#{out.size}）" if out.size < 600
    write_csv("#{DIR}/monthly.csv", "month,gold_usd_oz,brent_usd_bbl,wti_usd_bbl", out)
    puts "世界银行月度：#{out.first[0, 7]} 至 #{out.last[0, 7]}（来自 #{link[/doc\/[^\/]+/]}）"
  end
end

# ---------- 2. EIA 每日原油现货价 ----------
# EIA 的网页表格每行是一周（周一到周五 5 个格子），空格子是假期
def eia_daily(series)
  html = download("https://www.eia.gov/dnav/pet/hist/LeafHandler.ashx?n=PET&s=#{series}&f=D") or raise "下载 EIA #{series} 失败"
  months = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec]
  out = {}
  html.scan(%r{<td class='B6'>(?:&nbsp;)*\s*(\d{4}) (\w{3})-\s*(\d+) to .*?</td>(.*?)</tr>}m).each do |y, mon, d, cells|
    start = Date.new(y.to_i, months.index(mon) + 1, d.to_i)
    cells.scan(%r{<td class='B3'>\s*([\d.]*)\s*</td>}).each_with_index do |(v), i|
      out[(start + i).to_s] = v.to_f unless v.empty?
    end
  end
  raise "EIA #{series} 数据太少（#{out.size}）" if out.size < 5000
  out
end

step("EIA 每日原油价格") do
  brent = eia_daily("RBRTE")
  wti   = eia_daily("RWTC")
  dates = (brent.keys | wti.keys).sort
  write_csv("#{DIR}/oil_daily.csv", "date,brent_usd_bbl,wti_usd_bbl",
            dates.map { |d| [d, brent[d] || "", wti[d] || ""].join(",") })
  puts "EIA 每日原油：#{dates.first} 至 #{dates.last}"
end

# ---------- 3. 每日金价（gold-api.com 最新现货价，每次运行记一笔） ----------
step("每日金价") do
  json = download("https://api.gold-api.com/price/XAU") or raise "下载金价失败"
  j = JSON.parse(json)
  price = j["price"].to_f
  raise "金价不合理：#{price}" unless price.between?(500, 20_000)
  date = (j["updatedAt"] ? Time.parse(j["updatedAt"]).utc.to_date : Date.today).to_s
  rows = old_rows("#{DIR}/gold_daily.csv").reject { |l| l.start_with?(date + ",") }
  rows << [date, price.round(2)].join(",")
  write_csv("#{DIR}/gold_daily.csv", "date,gold_usd_oz", rows.sort)
  puts "每日金价：#{date} #{price.round(2)} 美元/盎司（共 #{rows.size} 天）"
end

# ---------- 4. 欧洲央行每日汇率（以欧元为基准，换算成"1 美元兑多少"） ----------
step("欧洲央行每日汇率") do
  zip = download("https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist.zip", binary: true) or raise "下载 ECB 汇率失败"
  csv = Dir.mktmpdir do |tmp|
    path = File.join(tmp, "ecb.zip")
    File.binwrite(path, zip)
    IO.popen(["unzip", "-p", path], &:read)
  end
  lines = csv.strip.split(/\r?\n/)
  head  = lines.shift.split(",")
  i_usd, i_aud, i_cny = %w[USD AUD CNY].map { |c| head.index(c) }
  out = lines.map do |l|
    c = l.split(",")
    usd = c[i_usd].to_f
    next if usd <= 0
    rate = ->(i) { (v = c[i].to_f) > 0 ? (v / usd).round(6) : "" }   # 1 美元兑多少该货币
    [c[0], rate.(i_aud), rate.(i_cny), (1 / usd).round(6)].join(",")
  end.compact.sort
  raise "汇率数据太少" if out.size < 5000
  write_csv("#{DIR}/fx_daily.csv", "date,AUD,CNY,EUR", out)
  puts "ECB 每日汇率：#{out.first[0, 10]} 至 #{out.last[0, 10]}"
end

# ---------- 5. BIS 月度汇率（月平均，1 美元兑多少该货币） ----------
step("BIS 月度汇率") do
  csv = download("https://stats.bis.org/api/v1/data/WS_XRU/M.AU+CN+XM.AUD+CNY+EUR.A?format=csv&detail=dataonly") or raise "下载 BIS 汇率失败"
  lines = csv.strip.split(/\r?\n/)
  head  = lines.shift.split(",")
  i_cur, i_t, i_v = %w[CURRENCY TIME_PERIOD OBS_VALUE].map { |c| head.index(c) }
  data = Hash.new { |h, k| h[k] = {} }
  lines.each { |l| c = l.split(","); data[c[i_t]][c[i_cur]] = c[i_v] unless c[i_v].to_s.empty? || c[i_v] == "NaN" }
  out = data.keys.sort.map { |m| [m, *%w[AUD CNY EUR].map { |cur| data[m][cur] || "" }].join(",") }
  raise "汇率数据太少" if out.size < 600
  write_csv("#{DIR}/fx_monthly.csv", "month,AUD,CNY,EUR", out)
  puts "BIS 月度汇率：#{out.first[0, 7]} 至 #{out.last[0, 7]}"
end

abort "这些项目下载失败，已保留旧数据：#{FAILED.join('、')}" unless FAILED.empty?
