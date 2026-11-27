# 记录每个数据源连续失败了几天，只有连续失败 3 天才让这次运行显示为失败（GitHub 会发邮件）
# 放置位置：仓库里的 scripts/track_failures.rb，由 .github/workflows/update-data.yml 在保存数据之前运行
#
# 为什么：各个数据网站偶尔会临时出故障（一天后自己就好了），那一天会保留旧数据，不影响网页。
# 以前任何一次失败都会发失败邮件，太多"假警报"；现在只有连续几天都失败（真的出问题了）才提醒。
#
# 输入：环境变量 OUTCOME_MONTHLY 等（每一步的结果：success / failure）
# 输出：data/run_status.json（每个数据源连续失败的天数、最近一次成功和失败的时间）
#       以及给 GitHub 的 alert=true / false

require "json"
require "time"

FILE  = "data/run_status.json"
LIMIT = 3   # 连续失败几天才提醒
SOURCES = {
  "monthly"     => "月度房价（realestate.com.au）",
  "quarterly"   => "季度房价（ABS）",
  "longrun"     => "长期数据（BIS 等）",
  "commodities" => "黄金和石油",
  "househunt"   => "找房（区域、利率、学校、犯罪率）"
}

old = (JSON.parse(File.read(FILE)) rescue {})
now = Time.now.utc.iso8601
status = {}
alerts = []

SOURCES.each do |key, label|
  prev = (old["sources"] || {})[key] || {}
  outcome = ENV["OUTCOME_#{key.upcase}"].to_s
  s = { "label" => label, "fail_days" => prev["fail_days"].to_i,
        "last_success" => prev["last_success"], "last_failure" => prev["last_failure"] }
  if outcome == "failure"
    s["fail_days"] += 1
    s["last_failure"] = now
  elsif outcome == "success"
    s["fail_days"] = 0
    s["last_success"] = now
  end
  status[key] = s.compact
  note = s["fail_days"].zero? ? "正常" : "连续失败 #{s["fail_days"]} 天"
  puts "#{label}：#{note}"
  alerts << "#{label} 已经连续 #{s["fail_days"]} 天失败" if s["fail_days"] >= LIMIT
end

File.write(FILE, JSON.pretty_generate({ "checked" => now, "alert_after_days" => LIMIT, "sources" => status }) + "\n")

if alerts.any?
  puts "需要处理：#{alerts.join('；')}"
else
  puts "没有需要处理的问题（偶尔一天失败会保留旧数据，连续 #{LIMIT} 天失败才会提醒）"
end
if ENV["GITHUB_OUTPUT"]
  File.open(ENV["GITHUB_OUTPUT"], "a") { |f| f.puts "alert=#{alerts.any?}" }
end
