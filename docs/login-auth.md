# 登录功能说明（手机号验证码 + Apple ID）

## 概览

客户端：`AIPetApp`（SwiftUI）

服务端：`AIPetServer`（Hertz）

登录方式：

- 手机号 + 验证码
- Sign in with Apple（Apple ID）

登录成功后服务端返回 JWT：`access_token`（Bearer）。

---

## 服务端接口

### 发送短信验证码

- `POST /v1/auth/sms/send`
- 请求：

```json
{ "phone_number": "+8613800138000" }
```

- 成功响应：

```json
{ "success": true, "message": "验证码已发送" }
```

- 安全限制：
  - 同一手机号发送间隔：60 秒
  - 同一手机号每日发送次数：10 次

### 校验验证码并登录

- `POST /v1/auth/sms/verify`
- 请求：

```json
{ "phone_number": "+8613800138000", "code": "123456" }
```

- 成功响应：

```json
{
  "access_token": "<jwt>",
  "token_type": "Bearer",
  "expires_in": 86400,
  "user": {
    "id": 1,
    "user_uid": "u_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    "phone_number": "+8613800138000",
    "username": "+8613800138000"
  }
}
```

- 安全限制：
  - 错误验证码累计 5 次后进入冷却（10 分钟）

### Apple ID 登录

- `POST /v1/auth/apple`
- 请求：

```json
{ "identityToken": "<apple_identity_token>" }
```

- 成功响应：

```json
{
  "access_token": "<jwt>",
  "token_type": "Bearer",
  "expires_in": 86400,
  "user": {
    "id": 1,
    "user_uid": "u_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    "apple_id": "<sub>",
    "username": "<email>"
  }
}

### user_uid 说明

`user_uid` 为服务端生成的随机用户标识，用于对外展示/查询（避免直接暴露自增 `id`）。同一个账号（AppleID/手机号）会绑定唯一的 `user_uid`。
```

---

## 腾讯云短信配置（服务端）

### 必需环境变量

- `TENCENT_SMS_SECRET_ID`
- `TENCENT_SMS_SECRET_KEY`
- `TENCENT_SMS_APP_ID`
- `TENCENT_SMS_SIGN_NAME`
- `TENCENT_SMS_TEMPLATE_ID`

### 可选环境变量

- `TENCENT_SMS_REGION`（默认 `ap-guangzhou`）

### Redis（推荐）

用于验证码存储与频控。

- `REDIS_ADDR`
- `REDIS_PASSWORD`
- `REDIS_DB`

未配置 Redis 时会退化为内存存储，适合本地开发，不适合多实例部署。

---

## iOS 端集成要点

### 网络字段与路由

客户端已按服务端对齐：

- 路由统一使用 `/v1/auth/...`
- 手机号字段使用 `phone_number`（通过 `JSONEncoder.KeyEncodingStrategy.convertToSnakeCase` 生成）
- 登录响应使用 `access_token`（通过 `JSONDecoder.KeyDecodingStrategy.convertFromSnakeCase` 解析）

### Sign in with Apple

在 Xcode `Signing & Capabilities` 中开启：

- `Sign in with Apple`

并确保：

- 服务端可访问 `https://appleid.apple.com/auth/keys` 拉取公钥

---

## 本地验证

### 服务端

```bash
cd AIPetServer
go run main.go
```

### iOS（模拟器编译验证）

```bash
xcodebuild -project AIPetApp/AIPetApp.xcodeproj \
  -scheme AIPetApp \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  clean build CODE_SIGNING_ALLOWED=NO
```
