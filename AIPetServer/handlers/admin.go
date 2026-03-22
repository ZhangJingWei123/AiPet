package handlers

import (
	"context"
	"html/template"
	"net/http"
	"time"

	"github.com/cloudwego/hertz/pkg/app"
	"github.com/cloudwego/hertz/pkg/app/server"
)

// AdminMiddleware 通过环境变量注入的 adminToken 做简单保护
//
// 校验顺序：
// - query: ?token=xxx
// - header: X-Admin-Token
// - cookie: admin_token
func AdminMiddleware(adminToken string) app.HandlerFunc {
	return func(ctx context.Context, c *app.RequestContext) {
		// 若未配置 adminToken，则默认关闭鉴权（适用于开发环境）
		if adminToken == "" {
			c.Next(ctx)
			return
		}

		token := string(c.Query("token"))
		if token == "" {
			token = string(c.Request.Header.Peek("X-Admin-Token"))
		}
		if token == "" {
			if v := c.Cookie("admin_token"); len(v) > 0 {
				token = string(v)
			}
		}

		if token != adminToken {
			c.AbortWithStatusJSON(http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}

		// 登录成功后为后续接口设置 cookie，减少每次手动带 token 的负担
		c.SetCookie("admin_token", adminToken, 3600*24, "/admin", "", 0, false, true)

		c.Next(ctx)
	}
}

// RegisterAdminRoutes 注册 Admin 大盘页面与聚合 API
func RegisterAdminRoutes(h *server.Hertz, adminToken string) {
	// 设置内嵌模板，避免依赖静态文件，便于在 Render 等环境一键部署
	h.SetHTMLTemplate(template.Must(template.New("admin_dashboard").Parse(adminHTMLTemplate)))

	g := h.Group("/admin")
	g.Use(AdminMiddleware(adminToken))

	g.GET("", AdminDashboardPage())
	g.GET("/api/metrics", AdminMetricsAPI())
}

// AdminDashboardPage 返回单页面管理后台（Tailwind + Chart.js）
func AdminDashboardPage() app.HandlerFunc {
	return func(ctx context.Context, c *app.RequestContext) {
		c.HTML(http.StatusOK, "admin_dashboard", nil)
	}
}

// AdminMetricsAPI 聚合核心业务指标，供前端图表使用
func AdminMetricsAPI() app.HandlerFunc {
	type metricPoint struct {
		Date  time.Time `json:"date"`
		Value float64   `json:"value"`
	}

	type personalityShare struct {
		DNAID      string  `json:"dna_id"`
		Count      int64   `json:"count"`
		Percentage float64 `json:"percentage"`
	}

	type response struct {
		DAUToday        int32              `json:"dau_today"`
		DAULast7Days    []metricPoint      `json:"dau_last_7_days"`
		RevenueLast7Days []metricPoint     `json:"revenue_last_7_days"`
		LLMTokensLast7Days []metricPoint   `json:"llm_tokens_last_7_days"`
		PersonalityShare []personalityShare `json:"personality_share"`
	}

	return func(ctx context.Context, c *app.RequestContext) {
		db, ok := getDBFromContext(c)
		if !ok {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "服务器配置错误"})
			return
		}

	var dauRows []struct {
		Date time.Time
		Cnt  int32
	}
	if err := db.WithContext(ctx).
		Raw(`SELECT DATE(created_at) AS date, COUNT(DISTINCT user_id) AS cnt
FROM events
WHERE created_at >= NOW() - INTERVAL '7 days'
GROUP BY DATE(created_at)
ORDER BY DATE(created_at)`).
		Scan(&dauRows).Error; err != nil {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "查询 DAU 失败"})
			return
		}

	var dauToday int32
	var dauPoints []metricPoint
	for _, r := range dauRows {
		if r.Date.Truncate(24*time.Hour).Equal(time.Now().Truncate(24 * time.Hour)) {
			dauToday = r.Cnt
		}
		dauPoints = append(dauPoints, metricPoint{Date: r.Date, Value: float64(r.Cnt)})
	}

	// 最近 7 天流水：按 amount_cents 累加（单位：元）
	var revenueRows []struct {
		Date  time.Time
		Total float64
	}
	if err := db.WithContext(ctx).
		Raw(`SELECT DATE(created_at) AS date,
       COALESCE(SUM((properties->>'amount_cents')::numeric), 0) / 100.0 AS total
FROM events
WHERE event_name IN ('mock_plus_purchase', 'storekit_plus_purchase')
  AND created_at >= NOW() - INTERVAL '7 days'
GROUP BY DATE(created_at)
ORDER BY DATE(created_at)`).
		Scan(&revenueRows).Error; err != nil {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "查询流水失败"})
			return
	}

	var revenuePoints []metricPoint
	for _, r := range revenueRows {
		revenuePoints = append(revenuePoints, metricPoint{Date: r.Date, Value: r.Total})
	}

	// LLM Token 消耗走势：按 estimated_tokens 累加
	var llmRows []struct {
		Date  time.Time
		Total float64
	}
	if err := db.WithContext(ctx).
		Raw(`SELECT DATE(created_at) AS date,
       COALESCE(SUM((properties->>'estimated_tokens')::numeric), 0) AS total
FROM events
WHERE event_name = 'llm_reply_completed'
  AND created_at >= NOW() - INTERVAL '7 days'
GROUP BY DATE(created_at)
ORDER BY DATE(created_at)`).
		Scan(&llmRows).Error; err != nil {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "查询 LLM Token 失败"})
			return
	}

	var llmPoints []metricPoint
	for _, r := range llmRows {
		llmPoints = append(llmPoints, metricPoint{Date: r.Date, Value: r.Total})
	}

	// 各性格 DNA 占比：最近 7 天内有对话的 DNA 分布
	var shareRows []struct {
		DNA   string
		Cnt   int64
		Total int64
	}
	if err := db.WithContext(ctx).
		Raw(`WITH src AS (
    SELECT (properties->>'personality_dna_id') AS dna
    FROM events
    WHERE event_name = 'llm_reply_completed'
      AND created_at >= NOW() - INTERVAL '7 days'
)
SELECT dna, COUNT(*) AS cnt, SUM(COUNT(*)) OVER () AS total
FROM src
WHERE dna IS NOT NULL AND dna <> ''
GROUP BY dna`).
		Scan(&shareRows).Error; err != nil {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "查询性格 DNA 占比失败"})
			return
	}

	var shares []personalityShare
	for _, r := range shareRows {
		p := 0.0
		if r.Total > 0 {
			p = float64(r.Cnt) * 100.0 / float64(r.Total)
		}
		shares = append(shares, personalityShare{DNAID: r.DNA, Count: r.Cnt, Percentage: p})
	}

	c.JSON(http.StatusOK, response{
		DAUToday:          dauToday,
		DAULast7Days:      dauPoints,
		RevenueLast7Days:  revenuePoints,
		LLMTokensLast7Days: llmPoints,
		PersonalityShare:  shares,
	})
	}
}

// adminHTMLTemplate 为内嵌的管理后台页面模板
//
// 使用 Tailwind + Chart.js 展示核心业务指标，一眼看清业务健康状态。
const adminHTMLTemplate = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>AIPet 管理大盘</title>
  <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/dayjs@1.11.10/dayjs.min.js"></script>
  <link href="https://cdn.jsdelivr.net/npm/tailwindcss@2.2.19/dist/tailwind.min.css" rel="stylesheet" />
</head>
<body class="bg-gray-50 text-gray-900">
  <div class="min-h-screen flex flex-col">
    <header class="bg-white shadow-sm">
      <div class="max-w-6xl mx-auto px-4 py-4 flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">AIPet 运营大盘</h1>
          <p class="text-xs text-gray-500 mt-1">实时关注 DAU、流水、LLM Token 与性格 DNA 结构</p>
        </div>
        <div class="text-right">
          <p class="text-xs text-gray-400">环境：Render / Production</p>
          <p id="last-updated" class="text-xs text-gray-400">最近更新：--</p>
        </div>
      </div>
    </header>

    <main class="flex-1 max-w-6xl mx-auto px-4 py-6 space-y-6">
      <section class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <div class="bg-white rounded-lg shadow-sm p-4 border border-gray-100">
          <p class="text-xs text-gray-500">今日 DAU</p>
          <p id="metric-dau-today" class="text-3xl font-bold mt-1">--</p>
          <p class="text-xs text-green-600 mt-1" id="metric-dau-desc">最近 7 天趋势如右图所示</p>
        </div>
        <div class="bg-white rounded-lg shadow-sm p-4 border border-gray-100">
          <p class="text-xs text-gray-500">最近 7 天累计流水</p>
          <p id="metric-revenue-7d" class="text-3xl font-bold mt-1">--</p>
          <p class="text-xs text-gray-400 mt-1">单位：人民币（元）</p>
        </div>
        <div class="bg-white rounded-lg shadow-sm p-4 border border-gray-100">
          <p class="text-xs text-gray-500">最近 7 天 LLM Token</p>
          <p id="metric-llm-7d" class="text-3xl font-bold mt-1">--</p>
          <p class="text-xs text-gray-400 mt-1">单位：估算 Token 数</p>
        </div>
      </section>

      <section class="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <div class="bg-white rounded-lg shadow-sm p-4 border border-gray-100 lg:col-span-2">
          <div class="flex items-center justify-between mb-2">
            <h2 class="text-sm font-semibold text-gray-800">DAU & 流水走势（近 7 天）</h2>
          </div>
          <canvas id="chart-dau-revenue" height="120"></canvas>
        </div>

        <div class="bg-white rounded-lg shadow-sm p-4 border border-gray-100">
          <div class="flex items-center justify-between mb-2">
            <h2 class="text-sm font-semibold text-gray-800">性格 DNA 占比</h2>
          </div>
          <canvas id="chart-dna" height="120"></canvas>
        </div>
      </section>

      <section class="bg-white rounded-lg shadow-sm p-4 border border-gray-100">
        <div class="flex items-center justify-between mb-2">
          <h2 class="text-sm font-semibold text-gray-800">LLM Token 消耗走势（近 7 天）</h2>
        </div>
        <canvas id="chart-llm" height="120"></canvas>
      </section>
    </main>
  </div>

  <script>
    async function fetchMetrics() {
      const res = await fetch('/admin/api/metrics', { credentials: 'include' });
      if (!res.ok) throw new Error('加载指标失败');
      return await res.json();
    }

    function formatDateLabel(dateStr) {
      return dayjs(dateStr).format('MM-DD');
    }

    function updateSummaryCards(data) {
      document.getElementById('metric-dau-today').textContent = data.dau_today ?? '--';

      const revenueTotal = (data.revenue_last_7_days || []).reduce((sum, p) => sum + (p.value || 0), 0);
      document.getElementById('metric-revenue-7d').textContent = revenueTotal.toFixed(2);

      const llmTotal = (data.llm_tokens_last_7_days || []).reduce((sum, p) => sum + (p.value || 0), 0);
      document.getElementById('metric-llm-7d').textContent = Math.round(llmTotal).toLocaleString();

      document.getElementById('last-updated').textContent = '最近更新：' + dayjs().format('YYYY-MM-DD HH:mm:ss');
    }

    function buildDauRevenueChart(ctx, data) {
      const labels = (data.dau_last_7_days || []).map(p => formatDateLabel(p.date));
      const dauValues = (data.dau_last_7_days || []).map(p => p.value);
      const revenueValues = (data.revenue_last_7_days || []).map(p => p.value);

      return new Chart(ctx, {
        type: 'line',
        data: {
          labels,
          datasets: [
            {
              label: 'DAU',
              data: dauValues,
              borderColor: '#3b82f6',
              backgroundColor: 'rgba(59,130,246,0.1)',
              yAxisID: 'y',
              tension: 0.3,
              fill: true,
            },
            {
              label: '流水（元）',
              data: revenueValues,
              borderColor: '#f97316',
              backgroundColor: 'rgba(249,115,22,0.1)',
              yAxisID: 'y1',
              tension: 0.3,
              fill: false,
            },
          ],
        },
        options: {
          responsive: true,
          interaction: { mode: 'index', intersect: false },
          plugins: {
            legend: { display: true },
          },
          scales: {
            y: {
              type: 'linear',
              position: 'left',
              grid: { drawOnChartArea: false },
            },
            y1: {
              type: 'linear',
              position: 'right',
              grid: { drawOnChartArea: false },
            },
          },
        },
      });
    }

    function buildLLMChart(ctx, data) {
      const labels = (data.llm_tokens_last_7_days || []).map(p => formatDateLabel(p.date));
      const values = (data.llm_tokens_last_7_days || []).map(p => p.value);

      return new Chart(ctx, {
        type: 'bar',
        data: {
          labels,
          datasets: [
            {
              label: 'LLM Token 消耗',
              data: values,
              backgroundColor: '#10b981',
            },
          ],
        },
        options: {
          responsive: true,
          plugins: {
            legend: { display: false },
          },
          scales: {
            y: {
              beginAtZero: true,
            },
          },
        },
      });
    }

    function buildDNAPieChart(ctx, data) {
      const items = data.personality_share || [];
      const labels = items.map(i => i.dna_id || 'unknown');
      const values = items.map(i => i.percentage);
      const colors = ['#3b82f6', '#10b981', '#f97316', '#6366f1', '#ec4899', '#14b8a6'];

      return new Chart(ctx, {
        type: 'doughnut',
        data: {
          labels,
          datasets: [{
            data: values,
            backgroundColor: labels.map((_, idx) => colors[idx % colors.length]),
          }],
        },
        options: {
          plugins: {
            legend: { position: 'bottom' },
          },
        },
      });
    }

    (async () => {
      try {
        const data = await fetchMetrics();
        updateSummaryCards(data);

        const ctxDauRevenue = document.getElementById('chart-dau-revenue').getContext('2d');
        const ctxLLM = document.getElementById('chart-llm').getContext('2d');
        const ctxDNA = document.getElementById('chart-dna').getContext('2d');

        buildDauRevenueChart(ctxDauRevenue, data);
        buildLLMChart(ctxLLM, data);
        buildDNAPieChart(ctxDNA, data);
      } catch (err) {
        console.error(err);
        alert('加载运营大盘数据失败，请稍后重试。');
      }
    })();
  </script>
</body>
</html>
`
