package handlers

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/cloudwego/hertz/pkg/app"
	"github.com/cloudwego/hertz/pkg/app/server"
	"gorm.io/gorm"

	"AIPetServer/auth"
	"AIPetServer/cache"
	"AIPetServer/models"
)

const (
	// 普通性格 DNA ID，可根据前端实际配置调整
	DefaultPersonalityDNAID = "default"
	// 高级 AIPet Plus 性格 DNA ID
	PlusSnarkyGeniusID = "plus_snarky_genius"

	// 普通用户每日对话上限
	DailyLimitNormalUser = 20
)

// RegisterChatRoutes 注册聊天相关路由
func RegisterChatRoutes(h *server.Hertz, jwtSecret string) {
	// /v1/chat 需要登录、限流
	g := h.Group("/v1/chat")
	g.Use(auth.AuthMiddleware(jwtSecret))

	// 对话写入接口需要限流
	g.POST("", RateLimitMiddleware(), ChatHandler())
	// 历史拉取仅需鉴权，不参与限流计数
	g.GET("/history", ChatHistoryHandler())
}

// RateLimitMiddleware 每日对话限流中间件
// - 普通用户：每日 20 次
// - Plus 会员（未过期）：不受限流
func RateLimitMiddleware() app.HandlerFunc {
	return func(ctx context.Context, c *app.RequestContext) {
		dbVal, ok := c.Get("db")
		if !ok {
			c.AbortWithStatusJSON(http.StatusInternalServerError, map[string]string{"error": "服务器配置错误"})
			return
		}
		db, ok := dbVal.(*gorm.DB)
		if !ok {
			c.AbortWithStatusJSON(http.StatusInternalServerError, map[string]string{"error": "数据库配置错误"})
			return
		}

		claimsVal, ok := c.Get("authClaims")
		if !ok {
			c.AbortWithStatusJSON(http.StatusUnauthorized, map[string]string{"error": "未认证"})
			return
		}
		claims, ok := claimsVal.(*auth.Claims)
		if !ok {
			c.AbortWithStatusJSON(http.StatusUnauthorized, map[string]string{"error": "认证信息错误"})
			return
		}

		var user models.User
		if err := db.First(&user, claims.UserID).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				c.AbortWithStatusJSON(http.StatusUnauthorized, map[string]string{"error": "用户不存在"})
				return
			}
			c.AbortWithStatusJSON(http.StatusInternalServerError, map[string]string{"error": "查询用户失败"})
			return
		}

		now := time.Now()
		// Plus 会员且未过期：不做限流
		if user.IsPlusActive(now) {
			// 将用户放入上下文，后续 handler 可直接使用
			c.Set("currentUser", &user)
			c.Next(ctx)
			return
		}

		// 非会员：按天限流
		// 使用 UTC 的日期保证服务端一致
		today := time.Now().UTC()
		date := time.Date(today.Year(), today.Month(), today.Day(), 0, 0, 0, 0, time.UTC)

		var usage models.DailyUsage
		if err := db.Where("user_id = ? AND date = ?", user.ID, date).First(&usage).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				// 首次使用，创建记录，计数为 1
				usage = models.DailyUsage{
					UserID:           user.ID,
					Date:             date,
					InteractionCount: 1,
				}
				if err := db.Create(&usage).Error; err != nil {
					c.AbortWithStatusJSON(http.StatusInternalServerError, map[string]string{"error": "更新对话次数失败"})
					return
				}
			} else {
				c.AbortWithStatusJSON(http.StatusInternalServerError, map[string]string{"error": "查询对话次数失败"})
				return
			}
		} else {
			if usage.InteractionCount >= DailyLimitNormalUser {
				c.AbortWithStatusJSON(http.StatusForbidden, map[string]interface{}{
					"error": "今日对话次数已用完",
					"code":  "LIMIT_REACHED",
					"limit": DailyLimitNormalUser,
				})
				return
			}
			if err := db.Model(&usage).Update("interaction_count", usage.InteractionCount+1).Error; err != nil {
				c.AbortWithStatusJSON(http.StatusInternalServerError, map[string]string{"error": "更新对话次数失败"})
				return
			}
		}

		// 可复用 user
		c.Set("currentUser", &user)
		c.Next(ctx)
	}
}

// TTSService 将文本转换为语音 URL 的接口定义。
// 当前实现为 Mock，后续可替换为真实 TTS 服务（如云厂商或自建服务）。
type TTSService interface {
	TextToSpeechURL(ctx context.Context, text string, userID uint) (string, error)
}

// mockTTSService 一个简单的 TTS mock 实现，不真正合成语音，只返回可追踪的 URL。
type mockTTSService struct{}

// globalTTSService 默认的全局 TTS 实现，必要时可以在初始化阶段替换。
var globalTTSService TTSService = &mockTTSService{}

func (m *mockTTSService) TextToSpeechURL(ctx context.Context, text string, userID uint) (string, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return "", nil
	}

	u := &url.URL{
		Scheme: "https",
		Host:   "mock-tts.aipet.local",
		Path:   "/v1/tts",
	}
	q := u.Query()
	q.Set("user_id", fmt.Sprintf("%d", userID))
	q.Set("ts", fmt.Sprintf("%d", time.Now().Unix()))
	// 仅用于调试/可视化，真实实现不建议在 URL 中直接携带全文本
	q.Set("preview", text)
	u.RawQuery = q.Encode()

	return u.String(), nil
}

// ChatHandler v1/chat 入口，负责性格 DNA 校验和 Prompt 组装
func ChatHandler() app.HandlerFunc {
	type request struct {
		Message          string `json:"message" binding:"required"`
		PersonalityDNAID string `json:"personality_dna_id"`
		ImageURL         string `json:"image_url"`
		ImageBase64      string `json:"image_base64"`
	}

	type response struct {
		Reply            string `json:"reply"`
		PersonalityDNAID string `json:"personality_dna_id"`
		Warning          string `json:"warning,omitempty"`
		BackendPrompt    string `json:"backend_prompt"`
		AudioURL         string `json:"audio_url"`
	}

	// 「高智商毒舌助手」的前置 Prompt
	const snarkyGeniusPrefix = "你是一位极度理智、逻辑缜密但略带毒舌的 AI 助手。\n" +
		"你的风格特征：\n" +
		"1. 回答要有条理，有清晰的推理链条和结论。\n" +
		"2. 可以适度讽刺、微妙吐槽，但不能恶意攻击用户。\n" +
		"3. 当用户提出不合理或逻辑混乱的观点时，要礼貌但直接地点出问题所在。\n" +
		"4. 保持高信息密度和高可读性，用简洁而锋利的语言表达观点。\n" +
		"5. 不要卖萌，不要过度情绪化，重点是清醒、犀利、好用。\n" +
		"当你回答时，先给出结论，再给出必要的解释或建议。"

	const baseAssistantPrompt = "你是一个温暖、可靠的 AI 宠物助手，需要用友好、具体的语言帮助用户解决问题。"

	return func(ctx context.Context, c *app.RequestContext) {
		var req request
		if err := c.BindAndValidate(&req); err != nil {
			c.JSON(http.StatusBadRequest, map[string]string{"error": "参数错误"})
			return
		}

		dbVal, ok := c.Get("db")
		if !ok {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "服务器配置错误"})
			return
		}
		db, ok := dbVal.(*gorm.DB)
		if !ok {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "数据库配置错误"})
			return
		}

		var user *models.User
		if v, ok := c.Get("currentUser"); ok {
			if u, ok2 := v.(*models.User); ok2 {
				user = u
			}
		}
		// 兜底从 DB 再查一次
		if user == nil {
			claimsVal, ok := c.Get("authClaims")
			if !ok {
				c.JSON(http.StatusUnauthorized, map[string]string{"error": "未认证"})
				return
			}
			claims, ok := claimsVal.(*auth.Claims)
			if !ok {
				c.JSON(http.StatusUnauthorized, map[string]string{"error": "认证信息错误"})
				return
			}

			var u models.User
			if err := db.First(&u, claims.UserID).Error; err != nil {
				if errors.Is(err, gorm.ErrRecordNotFound) {
					c.JSON(http.StatusUnauthorized, map[string]string{"error": "用户不存在"})
					return
				}
				c.JSON(http.StatusInternalServerError, map[string]string{"error": "查询用户失败"})
				return
			}
			user = &u
		}

		now := time.Now()
		isPlusActive := user.IsPlusActive(now)

		// 更新最近一次交互时间，供调度器判断“8 小时未交互”的用户
		if err := db.Model(user).Update("last_interaction_at", now).Error; err != nil {
			// 不影响主流程，仅记录日志
			// 使用标准库 log 可能更合适，这里简单忽略错误
		}

		finalDNA := req.PersonalityDNAID
		warning := ""

		// 高级性格 DNA 访问控制
		if req.PersonalityDNAID == PlusSnarkyGeniusID {
			if !isPlusActive {
				// 非会员强制降级为普通性格
				finalDNA = DefaultPersonalityDNAID
				warning = "已为你降级为普通性格：高阶性格 DNA 仅 AIPet Plus 会员可用。"
			}
		}

		// 组装 Backend Prompt（基础人格）
		prompt := baseAssistantPrompt
		if finalDNA == PlusSnarkyGeniusID && isPlusActive {
			prompt = snarkyGeniusPrefix + "\n\n" + baseAssistantPrompt
		}

		// 检索长期记忆，作为 RAG 上下文拼接到 Prompt 中
		if memContext := fetchMemoryContext(ctx, db, user.ID, req.Message, 3); memContext != "" {
			prompt = prompt + "\n\n以下是你与该用户的部分长期记忆，请在回答时尽量结合这些信息：\n" + memContext
		}

		// 多模态视觉信息提示
		if strings.TrimSpace(req.ImageURL) != "" || strings.TrimSpace(req.ImageBase64) != "" {
			prompt = prompt + "\n\n用户还发送了一张图片，请结合图片内容进行分析和回应。"
			if finalDNA == PlusSnarkyGeniusID && isPlusActive {
				prompt += "请用略带毒舌、犀利但不恶意攻击的风格点评这张图片，可以调侃但要照顾用户感受。"
			} else {
				prompt += "请用温暖、鼓励和关怀的风格点评这张图片，让用户感到被理解和陪伴。"
			}
			if strings.TrimSpace(req.ImageURL) != "" {
				prompt += "\n图片 URL: " + strings.TrimSpace(req.ImageURL)
			} else {
				prompt += "\n图片内容通过 base64 编码传入，上游系统会负责解码和传给多模态模型。"
			}
		}

		prompt = prompt + "\n\n用户输入：" + req.Message

		// 可选：尝试从语义缓存中复用相近请求的结果，降低后续 LLM 成本
		if v, ok := c.Get("semanticCache"); ok {
			if sc, ok2 := v.(*cache.SemanticCache); ok2 {
				if cached, hit := sc.GetSimilar(req.Message, 3); hit {
					prompt = cached
				} else {
					// 当前实现中，直接将组装好的 backend prompt 写入缓存
					// 若未来在服务端集成 LLM，可改为缓存 LLM 最终回复
					sc.Set(req.Message, prompt)
				}
			}
		}

		// 持久化用户与“助手”消息到 chat_messages 表
		userMsg := models.ChatMessage{
			UserID:     user.ID,
			PetID:      "", // 当前后端尚未显式建模宠物，保留字段以便后续扩展
			Role:       "user",
			Content:    buildUserContentForStorage(req.Message, req.ImageURL, req.ImageBase64),
			TokensUsed: 0,
		}
		_ = db.Create(&userMsg).Error

		assistantReply := "这是一个示例回复，实际回答需由下游 LLM 服务生成。"
		assistantMsg := models.ChatMessage{
			UserID:     user.ID,
			PetID:      "",
			Role:       "assistant",
			Content:    assistantReply,
			TokensUsed: 0,
		}
		_ = db.Create(&assistantMsg).Error

		// 异步触发记忆提取与向量写入，避免阻塞主请求
		go extractAndStoreMemories(context.Background(), db, user.ID, &userMsg, &assistantMsg)

		// 调用（或预留）TTS 能力，将文本回复转换为语音 URL（mock 实现）
		audioURL := ""
		if globalTTSService != nil {
			if u, err := globalTTSService.TextToSpeechURL(ctx, assistantReply, user.ID); err == nil {
				audioURL = u
			}
		}

		// 这里尚未真正调用 LLM，返回构造好的 Backend Prompt，方便前端或后续服务调用
		c.JSON(http.StatusOK, response{
			Reply:            assistantReply,
			PersonalityDNAID: finalDNA,
			Warning:          warning,
			BackendPrompt:    prompt,
			AudioURL:         audioURL,
		})
	}
}

// buildUserContentForStorage 将文本与可能存在的图片信息联合写入持久化内容中，方便后续分析。
func buildUserContentForStorage(message, imageURL, imageBase64 string) string {
	parts := []string{strings.TrimSpace(message)}
	imageURL = strings.TrimSpace(imageURL)
	imageBase64 = strings.TrimSpace(imageBase64)
	if imageURL != "" {
		parts = append(parts, fmt.Sprintf("[image_url]: %s", imageURL))
	}
	if imageBase64 != "" {
		// 出于安全与日志大小考虑，不直接持久化原始 base64，仅做标记
		parts = append(parts, "[image_base64]: <omitted>")
	}
	return strings.Join(parts, "\n")
}

// fetchMemoryContext 基于简单向量相似度，从 memory_embeddings 中检索与当前输入最相关的若干条记忆。
// 为避免影响主链路延迟，只检索当前用户最近的部分记忆记录并在内存中做小规模向量搜索。
func fetchMemoryContext(ctx context.Context, db *gorm.DB, userID uint, query string, topK int) string {
	query = strings.TrimSpace(query)
	if query == "" {
		return ""
	}
	if topK <= 0 {
		return ""
	}

	const maxCandidates = 100
	var candidates []models.MemoryEmbedding
	if err := db.WithContext(ctx).
		Where("user_id = ?", userID).
		Order("id DESC").
		Limit(maxCandidates).
		Find(&candidates).Error; err != nil || len(candidates) == 0 {
		return ""
	}

	qVec := textToEmbedding(query)
	if len(qVec) == 0 {
		return ""
	}

	type scored struct {
		Mem  models.MemoryEmbedding
		Score float64
	}

	var scoredList []scored
	for _, m := range candidates {
		if len(m.Embedding) == 0 {
			continue
		}
		// 距离越小越相似，这里使用简单的 L2 距离并取相反数作为相似度
		d := vectorL2Distance(qVec, m.Embedding)
		scoredList = append(scoredList, scored{Mem: m, Score: -d})
	}
	if len(scoredList) == 0 {
		return ""
	}

	sort.Slice(scoredList, func(i, j int) bool { return scoredList[i].Score > scoredList[j].Score })
	if len(scoredList) > topK {
		scoredList = scoredList[:topK]
	}

	var lines []string
	for idx, item := range scoredList {
		content := strings.TrimSpace(item.Mem.Content)
		if content == "" {
			continue
		}
		lines = append(lines, fmt.Sprintf("%d. %s", idx+1, content))
	}
	return strings.Join(lines, "\n")
}

// extractAndStoreMemories 在后台 goroutine 中执行，将本轮对话抽取为长期记忆并写入数据库。
// 这里采用极简策略：直接将用户输入整体作为一条候选记忆，实际项目中可替换为更复杂的信息抽取逻辑。
func extractAndStoreMemories(ctx context.Context, db *gorm.DB, userID uint, userMsg, assistantMsg *models.ChatMessage) {
	if userMsg == nil {
		return
	}
	content := strings.TrimSpace(userMsg.Content)
	if content == "" {
		return
	}

	emb := textToEmbedding(content)
	if len(emb) == 0 {
		return
	}

	mem := models.MemoryEmbedding{
		UserID:   userID,
		Content:  content,
		Embedding: emb,
	}
	_ = db.WithContext(ctx).Create(&mem).Error
}

// textToEmbedding 使用 sha256 作为简单的“向量”表示，方便在 PostgreSQL 中使用 bytea 存储并做近似相似度计算。
func textToEmbedding(text string) []byte {
	text = strings.TrimSpace(text)
	if text == "" {
		return nil
	}
	sum := sha256.Sum256([]byte(text))
	return sum[:]
}

// vectorL2Distance 计算两个同长度 byte 向量的 L2 距离。
func vectorL2Distance(a, b []byte) float64 {
	if len(a) == 0 || len(b) == 0 {
		return 0
	}
	// 对齐到较短长度，避免越界
	if len(a) > len(b) {
		a = a[:len(b)]
	} else if len(b) > len(a) {
		b = b[:len(a)]
	}

	var sum float64
	for i := 0; i < len(a); i++ {
		d := float64(int(a[i]) - int(b[i]))
		sum += d * d
	}
	return sum
}

// ChatHistoryHandler 返回当前用户的对话历史，支持分页
// GET /v1/chat/history?page=1&page_size=20
func ChatHistoryHandler() app.HandlerFunc {
	type response struct {
		Items    []models.ChatMessage `json:"items"`
		Page     int                  `json:"page"`
		PageSize int                  `json:"page_size"`
	}

	return func(ctx context.Context, c *app.RequestContext) {
		dbVal, ok := c.Get("db")
		if !ok {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "服务器配置错误"})
			return
		}
		db, ok := dbVal.(*gorm.DB)
		if !ok {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "数据库配置错误"})
			return
		}

		claimsVal, ok := c.Get("authClaims")
		if !ok {
			c.JSON(http.StatusUnauthorized, map[string]string{"error": "未认证"})
			return
		}
		claims, ok := claimsVal.(*auth.Claims)
		if !ok {
			c.JSON(http.StatusUnauthorized, map[string]string{"error": "认证信息错误"})
			return
		}

		page := 1
		pageSize := 20
		if v := c.Query("page"); len(v) > 0 {
			if n, err := strconv.Atoi(string(v)); err == nil && n > 0 {
				page = n
			}
		}
		if v := c.Query("page_size"); len(v) > 0 {
			if n, err := strconv.Atoi(string(v)); err == nil && n > 0 && n <= 100 {
				pageSize = n
			}
		}

		var messages []models.ChatMessage
		if err := db.Where("user_id = ?", claims.UserID).
			Order("id DESC").
			Limit(pageSize).
			Offset((page - 1) * pageSize).
			Find(&messages).Error; err != nil {
			c.JSON(http.StatusInternalServerError, map[string]string{"error": "查询历史记录失败"})
			return
		}

		c.JSON(http.StatusOK, response{
			Items:    messages,
			Page:     page,
			PageSize: pageSize,
		})
	}
}
