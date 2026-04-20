# AWS Lightsail IP 自动检测 / 更换脚本

用于 **AWS Lightsail IP 检测、自动更换、Telegram 通知、Cloudflare DNS 更新、定时任务管理** 的 Bash 脚本。

---

## 功能

- 支持多账号
- 支持多区域
- 支持账号级代理
- 支持 Telegram 机器人通知
- 支持 Cloudflare A 记录自动更新
- 支持一个账号绑定多个域名
- 支持多个根域名分别使用不同 Cloudflare Token
- 支持 Alpine / Debian / Ubuntu
- 支持交互式设置 / 删除定时任务
- 日志超过 `5MB` 自动清空
- 自动把最新 IP 写回 `config.json`

---

## Git 仓库

克隆：

```bash
git clone https://github.com/Assute/lightsail-ip.git /opt/AWS
cd /opt/AWS
cp config.example.json config.json
```

更新：

```bash
cd /opt/AWS
git pull
```

---

## 目录结构

```bash
/opt/AWS/
├── lightsail-ip.sh
├── config.example.json
├── config.json
└── lightsail-ip.log
```

---

## 依赖

脚本依赖：

- `bash`
- `aws`
- `jq`
- `curl`
- `ping`
- `crontab`

### Debian / Ubuntu

```bash
apt update
apt install -y bash jq curl unzip iputils-ping ca-certificates cron less groff
cd /tmp
curl -L "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli
aws --version
```

如果是 `aarch64` / `arm64`，把下载地址改成：

```bash
https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip
```

### Alpine（省空间版）

```bash
setup-apkrepos -c
sed -i 's#http://#https://#g' /etc/apk/repositories
apk update
apk add --no-cache bash jq curl iputils ca-certificates aws-cli dcron
```

> Alpine 这里直接使用 community 仓库中的 `aws-cli`，优先省空间。

---

## 配置文件

默认读取脚本同目录下的：

```bash
config.json
```

初始化：

```bash
cp config.example.json config.json
```

### 推荐配置示例

```json
{
  "defaults": {
    "ping_times": 30
  },
  "telegram": {
    "enabled": true,
    "bot_token": "YOUR_TELEGRAM_BOT_TOKEN",
    "chat_id": "YOUR_TELEGRAM_CHAT_ID"
  },
  "cloudflare": {
    "tokens": [
      {
        "root_domain": "example.com",
        "token": "YOUR_CLOUDFLARE_TOKEN_EXAMPLE_COM"
      },
      {
        "root_domain": "example.net",
        "token": "YOUR_CLOUDFLARE_TOKEN_EXAMPLE_NET"
      }
    ]
  },
  "accounts": [
    {
      "name": "lightsail-kr",
      "enabled": true,
      "region": "ap-northeast-2",
      "aws_access_key_id": "YOUR_AWS_ACCESS_KEY_ID",
      "aws_secret_access_key": "YOUR_AWS_SECRET_ACCESS_KEY",
      "ip": "",
      "proxy_url": "",
      "domains": [
        "a.example.com",
        "b.example.com"
      ],
      "notification_enabled": true
    }
  ]
}
```

### 兼容旧写法

脚本仍兼容旧版单 Token / 单域名配置：

```json
{
  "cloudflare": {
    "root_domain": "example.com",
    "token": "YOUR_CLOUDFLARE_API_TOKEN"
  },
  "accounts": [
    {
      "domain": "a.example.com"
    }
  ]
}
```

---

## 字段说明

### `defaults`

- `ping_times`：每次检测 `ping` 次数

### `telegram`

- `enabled`：是否启用 Telegram 通知
- `bot_token`：Telegram Bot Token
- `chat_id`：Telegram Chat ID

### `cloudflare`

推荐使用：

```json
"cloudflare": {
  "tokens": [
    {
      "root_domain": "example.com",
      "token": "..."
    }
  ]
}
```

字段说明：

- `root_domain`：Cloudflare Zone 对应根域名
- `token`：该根域名使用的 Cloudflare API Token

脚本会根据账号中的域名，自动匹配最合适的 `root_domain`。

### `accounts`

- `name`：账号名称
- `enabled`：是否启用
- `region`：AWS 区域
- `aws_access_key_id`：AWS Access Key
- `aws_secret_access_key`：AWS Secret Key
- `ip`：当前记录 IP，可留空
- `proxy_url`：代理地址，可留空
- `domains`：要自动更新到 Cloudflare 的域名数组，可留空
- `domain`：旧版单域名写法，仍兼容
- `notification_enabled`：当前账号是否发送 Telegram 通知

### 常用地区码

| 地区 | 地区码 |
|---|---|
| 美国东部（俄亥俄） | `us-east-2` |
| 美国东部（弗吉尼亚北部） | `us-east-1` |
| 美国西部（俄勒冈） | `us-west-2` |
| 亚太地区（孟买） | `ap-south-1` |
| 亚太地区（首尔） | `ap-northeast-2` |
| 亚太地区（新加坡） | `ap-southeast-1` |
| 亚太地区（悉尼） | `ap-southeast-2` |
| 亚太地区（东京） | `ap-northeast-1` |
| 加拿大（中部） | `ca-central-1` |
| 欧洲（法兰克福） | `eu-central-1` |
| 欧洲（爱尔兰） | `eu-west-1` |
| 欧洲（伦敦） | `eu-west-2` |
| 欧洲（巴黎） | `eu-west-3` |

---

## 运行模式

### 1）交互模式

直接运行：

```bash
cd /opt/AWS
bash ./lightsail-ip.sh
```

会显示：

```text
1. 设置/更新定时任务
2. 删除定时任务
0. 返回
```

### 2）执行模式

- 非交互执行时：自动读取 `config.json` 中所有启用账号并执行
- 传入账号名时：只执行指定账号

示例：

```bash
bash ./lightsail-ip.sh lightsail-kr
```

---

## IP 更换逻辑

脚本会先读取账号配置中的 `ip`。

### 情况 1：账号下已有静态 IP

会执行：

1. 检测当前 IP
2. 释放旧静态 IP
3. 重新申请同名静态 IP
4. 绑定到实例
5. 获取新 IP
6. 写回 `config.json`

### 情况 2：账号下没有静态 IP

会执行：

1. 读取实例公网 IP 作为初始 IP
2. 当检测到需要更换时
3. 自动创建新的静态 IP
4. 自动绑定到实例
5. 写回 `config.json`

---

## Cloudflare DNS 更新逻辑

当账号配置了 `domain` 或 `domains` 时：

1. 脚本根据域名匹配 `cloudflare.tokens` 中最合适的 `root_domain`
2. 查询对应 Zone
3. 查询该域名的 A 记录
4. 有记录则更新
5. 没有记录则自动创建

例如：

- 域名：`a.example.com`
- Token 根域：`example.com`

则会自动使用 `example.com` 对应的 Token。

---

## 定时任务

交互运行脚本后，选择：

```text
1. 设置/更新定时任务
```

然后输入分钟数，例如：

```text
5
```

会生成类似：

```cron
# lightsail-ip managed task begin
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * /bin/bash "/opt/AWS/lightsail-ip.sh" >> "/opt/AWS/lightsail-ip.log" 2>&1
# lightsail-ip managed task end
```

查看当前定时任务：

```bash
crontab -l
```

删除脚本创建的定时任务：

```bash
bash ./lightsail-ip.sh
```

选择：

```text
2
```

---

## 日志

日志默认写入：

```bash
/opt/AWS/lightsail-ip.log
```

查看日志：

```bash
tail -f /opt/AWS/lightsail-ip.log
```

日志规则：

- 超过 `5MB`
- 下次非交互执行前自动清空
- 不备份旧日志

---

## Telegram 通知

当 IP 被更换后，脚本会发送 Telegram 通知。

需要准备：

- `bot_token`
- `chat_id`

---

## 安全建议

真实配置中通常包含：

- AWS Access Key
- AWS Secret Key
- Telegram Bot Token
- Cloudflare Token
- 代理账号密码

不要把真实 `config.json` 提交到 GitHub。

建议：

- 提交前使用模板文件
- 将 `config.json` 加入 `.gitignore`
- 服务器上收紧权限

例如：

```bash
chmod 700 /opt/AWS
chmod 700 /opt/AWS/lightsail-ip.sh
chmod 600 /opt/AWS/config.json
```

---

## 支持系统

- Alpine
- Debian
- Ubuntu

---

## License

MIT
