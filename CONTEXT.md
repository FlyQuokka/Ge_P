# CONTEXT — Ge_P 房价监控

> 这份文件说明项目是做什么的、文件放在哪里、怎么运作。以后无论是自己还是 AI 助手接手，先读这份。

## 目标

做一个 **Perth（珀斯）房价监控网页**，同时对比澳洲八大首府城市的房价。

- 网页部署在 **GitHub Pages**（免费、无需服务器）
- 数据由 **GitHub Actions** 每天自动检查更新，不需要手动操作
- 重点看 **月度数据**（realestate.com.au），能及时反映涨跌；季度官方数据用来看长期走势

## 文件结构（每个文件放在哪里）

```
Ge_P/                              ← 仓库根目录
├── index.html                     ← 网页本体（页面、样式、图表都在这一个文件里）
├── CONTEXT.md                     ← 本文件：项目说明
├── data/
│   ├── monthly.csv                ← 月度数据：各城市每月中位价、月度/年度变化（自动累积）
│   ├── annual_growth.csv          ← 月度数据：各城市年度涨幅历史，2015 年至今（每次整份重写）
│   ├── prices.csv                 ← 季度数据：ABS 成交中位价，2002 年至今（自动更新）
│   └── last_checked.txt           ← 上次自动检查的时间（自动生成）
├── scripts/
│   └── update_monthly.rb          ← 抓取月度数据的脚本（由 Actions 运行）
└── .github/
    └── workflows/
        └── update-data.yml        ← 定时任务：每天运行一次
```

没有需要安装的东西，也没有"编译"步骤。`data/` 里的文件都不用手改。

## 怎么运作

1. **每天 UTC 22:00（珀斯早上 6 点）**，GitHub Actions 运行 `update-data.yml`
2. 第 ① 步运行 `scripts/update_monthly.rb`，读取 PropTrack 最新一个月的数据：
   - 这个月的数据写进 `data/monthly.csv`（已有的月份覆盖，新月份追加 —— 所以历史会越积越长）
   - 年度涨幅历史整份写进 `data/annual_growth.csv`
3. 第 ② 步从 ABS 下载季度数据，保存为 `data/prices.csv`
4. 两步互不影响：一个失败，另一个照常更新。失败的那次运行会显示红色 ✗，旧数据保留不动
5. 自动提交（commit），GitHub Pages 随后自动重新发布

## 数据来源

### ① 月度：realestate.com.au / PropTrack Home Price Index

- PropTrack 是 realestate.com.au（REA Group）旗下的数据部门，每月 1–3 号发布上个月的房价指数
- 页面：https://www.proptrack.com.au/home-price-index/
- 抓取方式：该页面嵌入了 4 个 Flourish 图表，数据直接写在图表网页的源码里，脚本读取的就是它们：
  - `9981590` 各首府城市年度涨幅（按月，2015 年至今；不含 Darwin）
  - `9981562` 全部住宅表 · `9981587` 独立屋表 · `9981583` 公寓表（月度变化 / 年度变化 / 中位价）
  - 网址格式：`https://flo.uri.sh/visualisation/<编号>/embed`
- `data/monthly.csv` 的列：`month, region, type, median, monthly_pct, annual_pct`
  - `type`：`dwelling` 全部住宅 / `house` 独立屋 / `unit` 公寓
  - `region`：8 个首府城市 + `Capital cities`（首府合计）+ `National`（全国）
- **历史数据怎么来的**：2025-09 至 2026-09 是从 PropTrack 每月的 PDF 报告里手工整理的（全部住宅）；
  独立屋/公寓从 2026-09 开始有。2026-10 起由脚本自动获取。
- **重要局限**：
  - PropTrack 每个月都会修订历史数据。我们存的是"当月报告公布的数值"，所以相邻两个月中位价的差距，
    可能和公布的"月度变化"对不上（例如 Perth 2026 年 8→9→10 月公布的月度变化都是约 -0.3%，
    但公布的中位价是 $980k → $968k → $949k）。网页上的"较近期高点"是用公布的中位价直接算的，仅供参考。
  - 2026-09 全国中位价：报告表格写 $886,000，报告首页写 $881,000，这里采用首页的 $881,000。
  - 如果 PropTrack 更换图表（编号变了）或改版页面，脚本会报错停止，需要更新脚本里的图表编号。
  - 直接抓 realestate.com.au 主站的房源/区域页面不可行（有反爬虫保护，也违反其使用条款）。

### ② 季度：ABS（澳大利亚统计局）

- **Total Value of Dwellings**（目录号 6432.0），数据集 `RES_DWELL`，免费、官方、无需 API key
- 接口：`https://data.api.abs.gov.au/rest/data/ABS,RES_DWELL,1.0.0/...`
- 指标：`3` = 独立屋成交中位价，`4` = 公寓/联排成交中位价（单位"千澳元"，网页里乘以 1000）
- 地区代码：`5GPER` Perth · `1GSYD` Sydney · `2GMEL` Melbourne · `3GBRI` Brisbane ·
  `4GADE` Adelaide · `6GHOB` Hobart · `7GDAR` Darwin · `8ACTE` Canberra
- 每季度发布一次（季度结束后约 2–3 个月），所以比月度数据滞后很多；最新一季是初步数据

> 两个来源统计方法不同（PropTrack 是估值模型指数，ABS 是实际成交中位价），数字不能直接比较。

## 网页内容

**月度部分（realestate.com.au）**
1. Perth 全部住宅 / 独立屋 / 公寓中位价 + 月度、年度变化 + 距近期高点跌幅
2. 月度中位价走势图（可切换城市）
3. 年度涨幅走势图：Perth 对比任一城市（3 年 / 5 年 / 全部）
4. 各城市本月数据表（Perth 高亮）

**长期部分（ABS 季度）**
5. Perth 独立屋与公寓长期走势（5 年 / 10 年 / 全部）
6. Perth 与任一城市长期对比

图表使用 Chart.js（从 cdnjs 加载，无需安装）。网页支持手机和深色模式。

## 首次设置步骤（只做一次）

1. 把上面的文件上传到 GitHub 仓库 `Ge_P`，保持同样的文件夹结构
2. **开启 Pages**：仓库 → Settings → Pages → Source 选 "Deploy from a branch" → Branch 选 `main`、文件夹 `/ (root)` → Save
   - ⚠️ 私有仓库使用 GitHub Pages 需要付费账户（GitHub Pro）。免费账户需要把仓库改为 Public，或改用其他托管方式
3. **允许 Actions 写入**：Settings → Actions → General → Workflow permissions → 选 "Read and write permissions" → Save
4. **手动运行一次测试**：仓库 → Actions → "Update house price data" → Run workflow
5. 几分钟后打开 `https://<你的用户名>.github.io/Ge_P/`

## 本地预览

网页需要通过网址打开（直接双击 index.html 会读不到数据）。在 Ge_P 文件夹里运行：

```bash
ruby -run -e httpd . -p 8000
```

然后浏览器打开 http://localhost:8000

手动更新一次月度数据（在 Ge_P 文件夹里运行）：

```bash
ruby scripts/update_monthly.rb
```

## 以后可以加的功能（想法）

- 补充更早的月度历史（PropTrack 的 PDF 报告可追溯到 2022 年 3 月）
- 加入 Cotality（原 CoreLogic）月度指数作对照 —— 它和 PropTrack 的数字经常不同
- Perth 各区（suburb）房价 —— 需要其他数据源（如 REIWA、Domain API）
- 租金数据、租金回报率
- 价格变化超过某个幅度时发邮件提醒

## 更新记录

- 2026-11-11：第一版。Perth + 八大首府城市成交中位价，ABS 季度数据。
- 2026-11-11：第二版。加入 realestate.com.au (PropTrack) 月度数据作为主要内容（2025-09 至 2026-10），
  新增年度涨幅走势图；自动更新从每周改为每天；ABS 季度数据保留为长期走势。
