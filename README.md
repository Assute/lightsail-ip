# Lightsail Monitor

用于统一管理：

- AWS Lightsail 自动检测 / 自动切换 IP
- Cloudflare DNS 自动解析更新
- 月流量统计与超限自动关机
- Telegram 通知
- 交互式安装与配置

## 文件说明

- `install.sh`：一键安装脚本
- `lightsail_monitor.js`：核心逻辑
- `lightsail-monitor.sh`：交互式管理菜单
- `lightsail-ip.sh`：兼容旧入口
- `config.example.json`：配置示例

## 一键安装

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Assute/lightsail-monitor/main/install.sh)"
```

如果你已经把仓库 clone 到本地，也可以直接：

```bash
bash ./install.sh
```

安装完成后会自动进入交互菜单，后续也可以直接执行：

```bash
lightsail-monitor
```

## 当前支持的交互功能

1. 添加 Lightsail 服务器
2. 添加根域名 / Cloudflare Token
3. 添加自动切换 IP 任务
4. 添加自动解析域名任务
5. 添加流量限制任务
6. 设置 Telegram 通知
7. 查看配置摘要
8. 立即执行检测
9. 安装 / 更新 Cron 定时任务
10. 删除 Cron 定时任务

## 服务器配置项

每台 Lightsail 服务器支持：

- 备注
- 地区
- `aws_access_key_id`
- `aws_secret_access_key`
- `proxy_url`（可留空）
- `instance_name`（建议填写，安装菜单会自动拉取实例列表供选择）

> 切换 IP 和查询流量时，会优先使用该服务器配置里的代理。
>
> `instance_name` 是 AWS Lightsail 控制台里那台实例的真实名称，不是你自己写的备注名。

## 自动切换 IP 逻辑

脚本会：

1. 读取当前记录的公网 IP
2. 通过 `ping` 判断是否出现 `100% packet loss`
3. 如果被判定为不可用：
   - 如果当前是静态 IP：释放旧静态 IP，再申请同名静态 IP，并重新绑定实例
   - 如果当前不是静态 IP：自动创建并绑定新的静态 IP
4. 保存新的 IP
5. 自动更新该服务器绑定的 Cloudflare 子域名
6. 发送 Telegram 通知

## 流量限制逻辑

脚本按 **UTC 当月 1 号到当前时间** 统计：

- `NetworkOut`
- `NetworkIn`

然后计算总流量：

```text
总流量 = 出站流量 + 入站流量
```

当总流量 **大于或等于** 你设置的阈值（GB）时，会自动执行：

```text
stop_instance
```

并发送 Telegram 通知。

## 自动解析域名逻辑

自动解析任务由三部分组成：

- 选择已开启自动切换 IP 的 Lightsail 服务器
- 选择已保存的根域名 / Cloudflare Token
- 填写一个或多个子域名

例如：

- 根域名：`example.com`
- 子域名：`sg,www,@`

则会自动维护：

- `sg.example.com`
- `www.example.com`
- `example.com`

其中 `@` 表示根域名本身。

## Telegram 通知

支持设置：

- Bot Token
- Chat ID

通知场景包括：

- IP 切换成功
- 流量超限自动关机
- 执行失败

## 手动执行

执行全部任务：

```bash
node ./lightsail_monitor.js run
```

只执行单台服务器：

```bash
node ./lightsail_monitor.js run --server lightsail-sg
```

查看配置摘要：

```bash
node ./lightsail_monitor.js summary
```

## 配置格式

见 `config.example.json`。

如果你之前使用的是旧版 `config.json`（`accounts` 结构），新脚本会自动兼容并迁移到新结构。
