package cache

import "sync"

// Entry 表示缓存中的一条记录
type Entry struct {
	Key   string
	Value string
}

// SemanticCache 使用简单的 Levenshtein 距离做“语义”近似匹配的缓存。
// 这可以作为后续对接 LLM 的 Mock Vector/语义缓存层。
type SemanticCache struct {
	mu    sync.RWMutex
	items []Entry
}

func NewSemanticCache() *SemanticCache {
	return &SemanticCache{}
}

// Set 写入一条缓存
func (c *SemanticCache) Set(key, value string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.items = append(c.items, Entry{Key: key, Value: value})
}

// GetSimilar 基于 Levenshtein 距离，从已有 key 中找一条“语义相近”的记录。
// maxDistance 越小，要求越严格。
func (c *SemanticCache) GetSimilar(key string, maxDistance int) (string, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()

	bestDist := maxDistance + 1
	bestVal := ""
	for _, it := range c.items {
		d := levenshteinDistance(key, it.Key)
		if d < bestDist {
			bestDist = d
			bestVal = it.Value
		}
	}

	if bestDist <= maxDistance {
		return bestVal, true
	}
	return "", false
}

// levenshteinDistance 计算两个字符串的 Levenshtein 距离
func levenshteinDistance(a, b string) int {
	la := len(a)
	lb := len(b)
	if la == 0 {
		return lb
	}
	if lb == 0 {
		return la
	}

	dp := make([][]int, la+1)
	for i := range dp {
		dp[i] = make([]int, lb+1)
	}

	for i := 0; i <= la; i++ {
		dp[i][0] = i
	}
	for j := 0; j <= lb; j++ {
		dp[0][j] = j
	}

	for i := 1; i <= la; i++ {
		for j := 1; j <= lb; j++ {
			cost := 0
			if a[i-1] != b[j-1] {
				cost = 1
			}
			deletion := dp[i-1][j] + 1
			insertion := dp[i][j-1] + 1
			substitution := dp[i-1][j-1] + cost

			min := deletion
			if insertion < min {
				min = insertion
			}
			if substitution < min {
				min = substitution
			}
			dp[i][j] = min
		}
	}

	return dp[la][lb]
}

