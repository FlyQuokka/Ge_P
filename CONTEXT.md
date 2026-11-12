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
│   ├── last_checked.txt           ← 上次自动检查的时间（自动生成）
│   └── longrun/                   ← 长期数据（1970 年至今）
│       ├── countries.json         ← 国家清单（代码、名称、货币）：想加国家就在这里加一行（手动维护）
│       ├── cities.json            ← 城市清单（国家、城市、中文名、来源、编号）：想加城市就加一行（手动维护）
│       ├── history_au_cities.csv  ← 澳洲各城市 1970–2003 年度中位价（手工整理，不会变）
│       ├── history_cn_national.csv← 中国全国新房均价 1991–2015（手工整理，不会变）
│       ├── national.csv           ← 各国全国房价指数，季度（自动更新，BIS）
│       ├── fx.csv                 ← 各货币兑美元汇率，季度平均（自动更新，BIS）
│       ├── cpi.csv                ← 各国物价指数，季度（自动更新，BIS）
│       └── cities.csv             ← 各城市房价 = 历史数据 + ABS + FHFA + BIS 城市指数（自动生成）
├── scripts/
│   ├── update_monthly.rb          ← 抓取月度数据的脚本（由 Actions 运行）
│   └── update_longrun.rb          ← 更新长期数据的脚本（由 Actions 运行）
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
4. 第 ③ 步运行 `scripts/update_longrun.rb`：按 `countries.json` 和 `cities.json` 下载各国全国指数、汇率、物价、
   外国城市指数，并把历史数据和刚更新的 ABS 数据合并成 `data/longrun/cities.csv`（所以必须排在第 ② 步之后）
5. 各步互不影响：一个失败，其他照常更新。失败的那次运行会显示红色 ✗，旧数据保留不动
6. 自动提交（commit），GitHub Pages 随后自动重新发布

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

### ③ 长期：各城市 1970–2003 年度中位价（学术论文）

- 来源：Peter Abelson & Demi Chung (2004)《Housing Prices in Australia: 1970 to 2003》，
  Macquarie University 经济系研究论文，表 1（独立屋）和表 3（公寓）。
  原网址已失效，用的是 Internet Archive 存档：
  `https://web.archive.org/web/2005/http://www.econ.mq.edu.au/research/Abelson_9_04.pdf`
- **这不是官方统计**。ABS 没有 2002 年以前各城市的成交中位价；作者根据各州土地登记/估价部门 (VG/LTO)、
  房地产协会 (REIA)、联邦银行 (CBA) 的记录拼接整理，早年部分数字是由均价折算（减 8–9%）的估计值。
- 存在 `data/longrun/history_au_cities.csv`，格式 `country,city,type,period,value,source`，一次整理，不会自动更新。
- 各城市起始年份：
  - 独立屋：Sydney / Melbourne / Perth 1970，Adelaide / Hobart / Canberra 1971，Brisbane 1973，Darwin 1986
  - 公寓：Sydney 1970，Melbourne / Adelaide 1974，Brisbane / Perth / Canberra 1980，Hobart 1984，Darwin 1997
- **与 ABS 的衔接**：网页上 2001 年及以前用论文的年度数据，2002 年起用 ABS 季度数据（公寓：2003 年及以前用论文，
  2003 年第 3 季度起用 ABS）。两者口径不同，衔接处有落差。用两者都有的 2002 年比较（ABS 四个季度平均 ÷ 论文）：
  Sydney +4%，Melbourne +1%，Brisbane −6%，Adelaide 0%，**Perth +3%**，Hobart −10%，Darwin −6%，Canberra +14%。
  公寓的落差更大（Perth 约 +20%，部分原因是 ABS 的"attached dwellings"包含联排）。跨越 2002 年的比较只能看大趋势。
- 涨幅图不跨来源计算：2002 年及以前 = 论文的当年 ÷ 上一年；2003 年起 = ABS 当季 ÷ 去年同季。
- 已知疑点：论文表 1 里 Perth 1973 和 1974 年都是 $18,850（可能是原文笔误），照原样保留。
  Hobart 1982 年原文印作 "40.325"，按 40,325 处理；Hobart 1982–83 是作者插值。

### ④ 长期：全国房价指数（BIS，1970 年至今）

- 来源：国际清算银行 (BIS) "Selected residential property prices"，数据集 `WS_SPP`，季度，免费、无需 API key
- 接口：`https://stats.bis.org/api/v1/data/WS_SPP/Q.<国家代码>..?format=csv`
  - `VALUE`：`N` 名义、`R` 实际（扣除通胀）；`UNIT_MEASURE`：`628` 指数（2010 = 100）、`771` 同比 %
- 存在 `data/longrun/national.csv`，格式 `country,period,nominal,real`
- 网页上"扣除通胀"用的物价指数来自 BIS 物价数据 `cpi.csv`（见第 ⑤ 部分）。澳洲 1970 → 2026 年第 2 季度物价约涨了 15 倍。
- BIS 只有全国数字，没有分城市。
- 目前清单里有 4 个：澳大利亚 `AU`、美国 `US`、中国 `CN`、欧元区 `XM`（2026-11-12 加入后三个）。
  各国口径不同（据 BIS 文档 https://www.bis.org/statistics/pp_selected_documentation.pdf ）：
  - 澳大利亚：1970–1986Q2 各首府中位价；1986Q3–2003Q2 八大首府独立屋；2003Q3–2021 八大首府全部住宅；2022 起全国全部住宅
  - 美国：1970–1975Q3 现有独栋住宅平均售价；1975Q4 起现有住宅价格指数
  - 中国：**2005Q2 才开始**；2005Q2–2015 是 70 城新建住宅，2016 起是 70 城二手住宅（国家统计局数据，BIS 计算）。
    这组数据显示 2005 年以来名义只涨约 49%、扣除通胀后略低于 2005 年，不少研究认为 70 城指数低估了实际涨幅，使用时要留意
  - 欧元区：1975–1991 是 BIS 估算；1992 起各成员国全部住宅

### ⑤ 国际对比：各国大城市、汇率、物价（2026-11-12 加入）

用户的目标：**找不同国家、不同城市房价曲线的规律**（涨跌周期是否相似），只要大城市。

| 内容 | 来源 | 频率 | 起始 |
|---|---|---|---|
| 美国 8 个都会区：纽约、洛杉矶、芝加哥、达拉斯、休斯敦、华盛顿、迈阿密、旧金山 | FHFA House Price Index（All-Transactions，独栋住宅，美国政府公开数据） | 季度 | 1975–76 |
| 欧元区 8 城：巴黎、柏林、马德里、罗马、米兰、阿姆斯特丹、维也纳、布鲁塞尔 | BIS 详细房价数据 `WS_DPP`（各国统计局 / 央行的数据） | 季度 | 布鲁塞尔 1973、维也纳 1986、巴黎 1992、阿姆斯特丹 1995、柏林 2003、马德里 2007、罗马 / 米兰 2010（到 2023 年底为止） |
| 北京（二手住宅） | BIS `WS_DPP`（国家统计局 70 城数据） | 月度 → 换算成季度 | 2011 |
| 中国全国新房均价（元 / 平方米） | 国家统计局"新建商品住宅平均销售价格"，经聚汇数据 (fangjia.gotohui.com) 转载 | 年度 | 1991–2015 |
| 汇率（1 美元兑多少澳元 / 人民币 / 欧元） | BIS `WS_XRU`，季度平均；欧元 1999 年以前是 BIS 的合成欧元 | 季度 | 澳元、人民币 1957；欧元 1974 |
| 物价指数（澳、美、中、欧元区） | BIS `WS_LONG_CPI`，月度换算成季度；欧元区 1990 年以前用"名义房价指数 ÷ 实际房价指数"推算后接上 | 季度 | 澳 1922、美 1913、中 1995、欧元区 1975 |

- 接口：
  - FHFA：`https://www.fhfa.gov/hpi/download/quarterly_datasets/hpi_at_metro.csv`（一个文件含所有都会区，按 CBSA 编号筛选）
  - BIS 城市：`https://stats.bis.org/api/v1/data/WS_DPP/<编号>?format=csv&detail=dataonly`，编号见 `cities.json`
  - BIS 汇率：`WS_XRU/Q.<国家>.<货币>.A`；BIS 物价：`WS_LONG_CPI/M.<国家>.628`
- 外国城市都是**指数**（type = `index`），不是价格，所以只出现在"国际对比"图里，不出现在澳洲的中位价图里。
- **各城市口径差别很大**，只适合比较走势和周期：巴黎是二手公寓，布鲁塞尔是二手独栋，维也纳含新旧公寓和独栋，
  柏林是自住房（vdp 银行协会），美国是独栋住宅的重复交易指数，北京是二手住宅。
- 美国大都会区在 FHFA 里按"分区 (MSAD)"统计，如纽约用的是 New York-Jersey City-White Plains 分区。

**中国数据的缺口（重要）**

- **中国城市目前只有北京**。BIS 只收录了北京。上海、广州、深圳等要用国家统计局 70 城数据，
  但统计局数据库的旧接口 (data.stats.gov.cn/easyquery.htm) 现在返回 403，新版门户没有公开接口，
  用程序抓取被判定为未授权访问，所以没有做。可行的办法：
  用户自己在统计局网站 https://data.stats.gov.cn 查询并导出 Excel，放进项目后整理成 `history_cn_cities.csv`；
  或用浏览器在该网站上逐个城市手动查看后抄录。
- **"往前再找 10 年"**：中国全国指数（BIS）2005 年才开始。更早的只找到全国新房均价（1991–2015，年度）。
  它是成交总额 ÷ 成交面积，不调整质量和地段（新房越卖越偏远时会被拉低），与 BIS 的指数不是同一种口径，
  所以作为单独的一条线"全国新房均价（年度）"放在中国城市分组里，没有和 BIS 指数拼接。
  2016 年以后的数值在转载网站上需要登录才显示，没有收录。2010–2015 年的数值未能与统计局原始出版物核对。
- 两条中国全国线可以互相印证：2005–2015 年新房均价涨了约 125%，同期 BIS 的 70 城指数只涨约 41%。

**国际对比图的算法**

- 最多 4 条线，每条线可选任一国家的全国指数或任一城市。
- 货币：各自本币 / 美元 / 人民币 / 澳元 / 欧元。换算 = 本币数值 × 当期平均汇率。默认美元。
- 扣除通胀：本币模式下用各自国家的物价；换算成同一种货币后，用该货币所在国的物价（如美元用美国物价）。
- 指数模式：所有要画的线都有数据的第一个时点算作 100。数据比所选起点晚两年以上的线不画，并提示。
- 年度涨幅模式：年度数据比上一年，季度数据比去年同一季度；不需要统一起点，所以所有线都会画。
- **看周期建议用"年度涨幅 + 各自本币 + 扣除通胀"**。换算成同一种货币后，曲线里混入了汇率本身的涨跌
  （澳元兑美元常有 ±30% 的波动），会掩盖房价自身的周期。
- 鼠标提示：各条线频率不同（年 / 季），所以每条线各显示离鼠标最近的一个点，并标明它是哪个时期。

### 怎么加一个国家或城市

**全国指数**：在 `data/longrun/countries.json` 里加一行即可，脚本和网页都读这个文件，不用改代码。例如：

```json
{ "code": "GB", "name": "英国", "name_en": "United Kingdom", "currency": "GBP" }
```

- `code` 用 BIS 的国家代码；`currency` 是货币代码，脚本会据此下载汇率和物价。
- 网页对比图的下拉框和货币选项会自动出现新国家 / 新货币（新货币的中文名要在 `index.html` 的 `CUR_CN` 里补一个）。

**能自动下载的城市**：在 `data/longrun/cities.json` 里加一行，例如
`{ "country": "US", "city": "Boston", "name": "波士顿", "source": "fhfa", "id": "14454" }`。
`source` 目前支持 `fhfa`（id = 都会区 CBSA 编号）和 `bis_dpp`（id = BIS 序列编号）；`local` 表示数据来自 history 文件，不用下载。
已查到但没加入的大城市编号：波士顿 14454、西雅图 42644、亚特兰大 12054、费城 37964、凤凰城 38060。

**只能手工整理的城市数据**：在 `data/longrun/` 里放一个 `history_xx_cities.csv`（列同 `history_au_cities.csv`；
`period` 可以是年 `1975` 或季度 `2002-Q1`），脚本会自动并入 `cities.csv`；再在 `cities.json` 里加一行（`source` 写 `local`），
网页的对比图下拉框就会列出它。

## 网页内容

**月度部分（realestate.com.au）**
1. Perth 全部住宅 / 独立屋 / 公寓中位价 + 月度、年度变化 + 距近期高点跌幅
2. 月度中位价走势图（可切换城市）
3. 年度涨幅走势图：Perth 对比任一城市（3 年 / 5 年 / 全部）
4. 各城市本月数据表（Perth 高亮）

**长期部分（1970 年至今：论文年度数据 + ABS 季度数据）**
统一选项：名义价格 / 扣除通胀；全部 / 1990 起 / 2002 起；对数坐标
5. Perth 独立屋与公寓
6. Perth 与任一城市对比（可选独立屋 / 公寓）
7. 年度涨幅 · 长期（跟随第 6 项的城市和类型）

**国际对比 · 国家与城市**
8. 房价走势对比：最多 4 条线，每条可选任一国家（全国）或任一城市；
   指数 / 年度涨幅；货币（各自本币 / 美元 / 人民币 / 澳元 / 欧元，默认美元）；名义 / 扣除通胀；
   起点 1970 / 1980 / 1990 / 2000 / 2005 / 2015（默认 2005）

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

手动更新一次长期数据：

```bash
ruby scripts/update_longrun.rb
```

## 以后可以加的功能（想法）

- 中国其他大城市（上海、广州、深圳等）：用户决定暂不补充，等以后能拿到准确的数据再说（见上方"中国数据的缺口"）
- 更多美国大城市：编号见"怎么加一个国家或城市"，加一行即可
- 1970 年以前：Stapledon 的研究有 1880 年起的澳洲（主要是 Sydney、Melbourne）房价；
  Jordà-Schularick-Taylor Macrohistory Database 有 1870 年起 18 个国家的年度房价指数（含澳、美、欧洲多国，不含中国）
- 1986–2001 年各城市的季度数据：ABS 旧版"已建成房屋价格指数"（6416.0）是季度指数，可以让这段从年度变成季度
- 补充更早的月度历史（PropTrack 的 PDF 报告可追溯到 2022 年 3 月）
- 加入 Cotality（原 CoreLogic）月度指数作对照 —— 它和 PropTrack 的数字经常不同
- Perth 各区（suburb）房价 —— 需要其他数据源（如 REIWA、Domain API）
- 租金数据、租金回报率
- 价格变化超过某个幅度时发邮件提醒

## 更新记录

- 2026-11-11：第一版。Perth + 八大首府城市成交中位价，ABS 季度数据。
- 2026-11-11：第二版。加入 realestate.com.au (PropTrack) 月度数据作为主要内容（2025-09 至 2026-10），
  新增年度涨幅走势图；自动更新从每周改为每天；ABS 季度数据保留为长期走势。已部署到 GitHub。
- 2026-11-12：第三版，当天已部署到 GitHub，自动更新任务在 GitHub 上运行成功。长期数据延伸到 1970 年：
  各城市年度中位价（Abelson & Chung 论文）+ 全国季度指数（BIS）；新增扣除通胀、对数坐标、国际对比图；
  数据和代码改为按国家清单驱动；随后在清单里加入了美国、中国、欧元区的全国指数。
  再之后加入各国大城市（美国 8、欧元区 8、北京）、汇率、物价，国际对比图改为可选 4 条线、可换货币、可看年度涨幅。
  已验证 GitHub 的服务器可以正常访问 FHFA 和 BIS。中国其他大城市暂不补充。
