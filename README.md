# AWS Lightsail IP 自动检测与定时更换脚本

一个用于 **AWS Lightsail 静态 IP 检测、自动更换、Telegram 通知、定时任务管理** 的 Bash 脚本。

适合放在服务器上长期运行，例如：

```bash
/opt/AWS
```

---

## 功能特性

- 支持 **多账号**
- 支持 **多区域**
- 支持 **按账号代理**
- 支持 **Telegram 机器人通知**
- 支持 **自动写回最新 IP 到 `config.json`**
- 支持 **交互式设置/删除定时任务**
- 支持 **Alpine / Debian / Ubuntu**
- 日志文件超过 **5MB 自动清空**

---

## 目录结构

```bash
/opt/AWS/
├── lightsail-ip.sh
├── config.json
└── lightsail-ip.log
```

---

## Git 仓库

克隆到服务器：

```bash
git clone https://github.com/Assute/lightsail-ip.git /opt/AWS
cd /opt/AWS
cp config.example.json config.json
```

更新代码：

```bash
cd /opt/AWS
git pull
```

---

## 依赖

脚本依赖以下命令：

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

如果你的机器是 `aarch64` / `arm64`，把上面的下载地址改成：

```bash
https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip
```

### Alpine

```bash
setup-apkrepos -c
sed -i 's#http://#https://#g' /etc/apk/repositories
apk update
apk add --no-cache bash jq curl iputils ca-certificates aws-cli dcron
```

> Alpine 这里使用的是 **community 仓库里的 `aws-cli` 包**，优先考虑省空间和安装简洁。

---

## 配置文件

默认读取脚本同目录下的：

```bash
config.json
```

建议先复制模板：

```bash
cp config.example.json config.json
```

示例：

```json
{
  "defaults": {
    "ping_times": 30
  },
  "telegram": {
    "enabled": true,
    "bot_token": "YOUR_BOT_TOKEN",
    "chat_id": "YOUR_CHAT_ID"
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
      "notification_enabled": true
    }
  ]
}
```

### 字段说明

#### `defaults`

- `ping_times`：`ping` 检测次数

#### `telegram`

- `enabled`：是否启用 Telegram 通知
- `bot_token`：Telegram Bot Token
- `chat_id`：Telegram Chat ID

#### `accounts`

- `name`：账号名称
- `enabled`：是否启用
- `region`：AWS 区域
- `aws_access_key_id`：AWS Access Key
- `aws_secret_access_key`：AWS Secret Key
- `ip`：当前记录 IP，可留空，脚本会自动初始化
- `proxy_url`：代理地址，可留空
- `notification_enabled`：当前账号是否发送通知

---

## 使用方法

### 1. 赋予执行权限

```bash
chmod +x /opt/AWS/lightsail-ip.sh
```

### 2. 进入脚本目录

```bash
cd /opt/AWS
```

### 3. 直接运行脚本

```bash
bash ./lightsail-ip.sh
```

会直接显示菜单：

```text
1. 设置/更新定时任务
2. 删除定时任务
0. 返回
```

---

## 定时任务说明

选择 `1` 后：

- 输入分钟数
- 直接使用当前目录下的 `config.json`
- 日志自动写入当前目录下的 `lightsail-ip.log`

例如输入 `5`，会生成类似：

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

---

## 手动执行单账号

如果你想手动执行某一个账号：

```bash
bash ./lightsail-ip.sh lightsail-kr
```

---

## 日志

日志文件默认位置：

```bash
/opt/AWS/lightsail-ip.log
```

查看日志：

```bash
tail -f /opt/AWS/lightsail-ip.log
```

### 日志大小限制

- 超过 `5MB`
- 下次非交互执行时自动清空
- **不备份旧日志**

---

## Telegram 通知

当检测到 IP 被更换后，脚本会向 Telegram 发送通知。

你需要先创建 Bot，并获取：

- `bot_token`
- `chat_id`

---

## 安全建议

`config.json` 中包含敏感信息：

- AWS Access Key
- AWS Secret Key
- Telegram Bot Token
- 代理账号密码

**不要把真实配置直接提交到 GitHub。**

建议：

- 提交前替换为占位符
- 将 `config.json` 加入 `.gitignore`
- 服务器上设置最小权限

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
