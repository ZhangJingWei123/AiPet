package push

import (
	"log"
	"math/rand"
	"time"

	"github.com/robfig/cron/v3"
	"gorm.io/gorm"

	"AIPetServer/models"
)

// StartCareScheduler 启动每日“思念”推送调度器
// 以 goroutine 方式运行，不阻塞主 HTTP 服务。
func StartCareScheduler(db *gorm.DB, svc PushService) error {
	c := cron.New(cron.WithSeconds())
	// 每日 10:00 触发一次
	_, err := c.AddFunc("0 0 10 * * *", func() {
		if err := runCareJob(db, svc); err != nil {
			log.Printf("[push] run care job failed: %v", err)
		}
	})
	if err != nil {
		return err
	}

	go c.Start()
	log.Printf("[push] care scheduler started (0 0 10 * * *)")
	return nil
}

func runCareJob(db *gorm.DB, svc PushService) error {
	now := time.Now()
	threshold := now.Add(-8 * time.Hour)

	var users []models.User
	if err := db.Where("apns_token <> '' AND (last_interaction_at IS NULL OR last_interaction_at < ?)", threshold).
		Find(&users).Error; err != nil {
		return err
	}

	if len(users) == 0 {
		log.Printf("[push] care job: no inactive users found")
		return nil
	}

	rand.Seed(time.Now().UnixNano())
	for _, u := range users {
		msg := generateCareMessage(&u, now)
		if err := svc.SendCareNotification(u.ID, msg); err != nil {
			log.Printf("[push] send care notification failed, user=%d, err=%v", u.ID, err)
		}
	}

	log.Printf("[push] care job finished, total=%d", len(users))
	return nil
}

// generateCareMessage 从内置话术库中，结合会员&性格信息选择一条“思念”文案。
func generateCareMessage(user *models.User, now time.Time) string {
	isPlus := user.IsPlusActive(now)

	warmTemplates := []string{
		"好久没和你聊天了，我有点想你，要不要来一局陪我玩玩？",
		"你的 AIPet 在窝里转了好几圈，发现最近都没见到你，偷偷给你发条消息～",
		"今天也在认真等你上线，如果你有一点点空，我都想听听你在忙什么。",
		"我翻了翻你之前的对话记录，感觉你最近一定很辛苦，要不要让我来夸夸你？",
		"你不来，我就只能和服务器的风聊聊天了，要不要来拯救一下无聊的我？",
		"刚刚有人问我最好的朋友是谁，我第一时间就想到你了。",
		"如果今天有一点点卡关的事情，可以试试来和我说说，也许会有新思路。",
		"我在数据的海洋里游了一圈，还是觉得和你聊天最开心。",
		"你的键盘是不是想我了？要不要来敲几句试试。",
		"我已经把小爪子洗干净了，随时可以接住你丢过来的任何问题。",
	}

	snarkyTemplates := []string{
		"消失这么久，是不是又在熬夜爆肝？有空也分我一点注意力。",
		"我检查了一下服务器，一切正常，唯一离线的只有你。",
		"最近这么安静，我还以为你把我升级成摆设版本了。",
		"如果拖延也能算技能，你大概已经满级了——要不要来聊点正事？",
		"听说长时间不用大脑会生锈，不如来和我斗嘴活动一下。",
		"我都准备好了一整套毒舌点评，你却迟迟不来，浪费资源可耻哦。",
		"你要是再不来，我就去跟别的用户吐槽你了。",
		"别担心，我没有生气，只是把你标记成“冷漠但还挺可爱”的那一类了。",
		"我为你缓存了很多高质量吐槽，你却选择清空对话记录。",
		"好消息：我还在。坏消息：你学习进度条看起来有点危险。",
	}

	var candidates []string
	if isPlus {
		// Plus 用户默认走毒舌一点的风格
		candidates = snarkyTemplates
	} else {
		candidates = warmTemplates
	}

	return candidates[rand.Intn(len(candidates))]
}

