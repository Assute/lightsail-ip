#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE="${LIGHTSAIL_MONITOR_CONFIG:-${SCRIPT_DIR}/config.json}"
NODE_BIN="node"
if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
  NODE_BIN="nodejs"
fi

if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
  echo "找不到可用的 node，请先执行 install.sh"
  exit 1
fi

run_js() {
  "$NODE_BIN" "$SCRIPT_DIR/lightsail_monitor.js" --config "$CONFIG_FILE" "$@"
}

pause() {
  read -r -p "按回车继续..." _
}

prompt_non_empty() {
  local prompt_text="$1"
  local value=""
  while [ -z "$value" ]; do
    read -r -p "$prompt_text" value
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
  done
  printf '%s\n' "$value"
}

select_region() {
  echo "请选择地区：" >&2
  echo "（1）美国东部（俄亥俄） us-east-2             | （8）亚太地区（东京） ap-northeast-1" >&2
  echo "（2）美国东部（弗吉尼亚北部） us-east-1       | （9）加拿大（中部） ca-central-1" >&2
  echo "（3）美国西部（俄勒冈） us-west-2            | （10）欧洲（法兰克福） eu-central-1" >&2
  echo "（4）亚太地区（孟买） ap-south-1             | （11）欧洲（爱尔兰） eu-west-1" >&2
  echo "（5）亚太地区（首尔） ap-northeast-2         | （12）欧洲（伦敦） eu-west-2" >&2
  echo "（6）亚太地区（新加坡） ap-southeast-1       | （13）欧洲（巴黎） eu-west-3" >&2
  echo "（7）亚太地区（悉尼） ap-southeast-2" >&2
  while true; do
    read -r -p "输入地区序号: " selected
    case "$selected" in
      1) printf '%s\n' "us-east-2"; return 0 ;;
      2) printf '%s\n' "us-east-1"; return 0 ;;
      3) printf '%s\n' "us-west-2"; return 0 ;;
      4) printf '%s\n' "ap-south-1"; return 0 ;;
      5) printf '%s\n' "ap-northeast-2"; return 0 ;;
      6) printf '%s\n' "ap-southeast-1"; return 0 ;;
      7) printf '%s\n' "ap-southeast-2"; return 0 ;;
      8) printf '%s\n' "ap-northeast-1"; return 0 ;;
      9) printf '%s\n' "ca-central-1"; return 0 ;;
      10) printf '%s\n' "eu-central-1"; return 0 ;;
      11) printf '%s\n' "eu-west-1"; return 0 ;;
      12) printf '%s\n' "eu-west-2"; return 0 ;;
      13) printf '%s\n' "eu-west-3"; return 0 ;;
    esac
    echo "序号无效，请重新输入" >&2
  done
}

select_server() {
  local mode="${1:-all}"
  local lines=()
  if [ "$mode" = "rotation" ]; then
    mapfile -t lines < <(run_js list-rotation-servers)
  else
    mapfile -t lines < <(run_js list-servers)
  fi

  if [ "${#lines[@]}" -eq 0 ]; then
    echo "暂无可选服务器" >&2
    return 1
  fi

  echo "请选择 Lightsail 服务器：" >&2
  for line in "${lines[@]}"; do
    IFS='|' read -r idx id remark region current_ip proxy_set rotation_on traffic_limit <<< "$line"
    printf '%s) %s [%s] IP=%s 代理=%s 自动切换=%s 流量限制=%sGB\n' \
      "$idx" "$remark" "$region" "${current_ip:--}" "$proxy_set" "$rotation_on" "$traffic_limit" >&2
  done

  while true; do
    read -r -p "输入服务器序号: " selected
    for line in "${lines[@]}"; do
      IFS='|' read -r idx id remark region current_ip proxy_set rotation_on traffic_limit <<< "$line"
      if [ "$selected" = "$idx" ]; then
        printf '%s\n' "$id"
        return 0
      fi
    done
    echo "序号无效，请重新输入" >&2
  done
}

select_domain() {
  local lines=()
  mapfile -t lines < <(run_js list-domains)
  if [ "${#lines[@]}" -eq 0 ]; then
    echo "暂无可选根域名" >&2
    return 1
  fi
  echo "请选择根域名：" >&2
  for line in "${lines[@]}"; do
    IFS='|' read -r idx id root_domain <<< "$line"
    printf '%s) %s\n' "$idx" "$root_domain" >&2
  done
  while true; do
    read -r -p "输入根域名序号: " selected
    for line in "${lines[@]}"; do
      IFS='|' read -r idx id root_domain <<< "$line"
      if [ "$selected" = "$idx" ]; then
        printf '%s\n' "$id"
        return 0
      fi
    done
    echo "序号无效，请重新输入" >&2
  done
}

select_aws_instance() {
  local region="$1"
  local access_key="$2"
  local secret_key="$3"
  local proxy_url="$4"
  local lines=()
  if [ -n "$proxy_url" ]; then
    mapfile -t lines < <(run_js list-aws-instances --region "$region" --aws-access-key-id "$access_key" --aws-secret-access-key "$secret_key" --proxy-url "$proxy_url" 2>/dev/null)
  else
    mapfile -t lines < <(run_js list-aws-instances --region "$region" --aws-access-key-id "$access_key" --aws-secret-access-key "$secret_key" 2>/dev/null)
  fi

  if [ "${#lines[@]}" -eq 0 ]; then
    return 1
  fi

  echo "请选择该地区下的 Lightsail 实例：" >&2
  for line in "${lines[@]}"; do
    IFS='|' read -r idx instance_name ip <<< "$line"
    printf '%s) %s IP=%s\n' "$idx" "$instance_name" "${ip:--}" >&2
  done

  while true; do
    read -r -p "输入实例序号（直接回车可手动填写）: " selected
    if [ -z "$selected" ]; then
      return 1
    fi
    for line in "${lines[@]}"; do
      IFS='|' read -r idx instance_name ip <<< "$line"
      if [ "$selected" = "$idx" ]; then
        printf '%s\n' "$instance_name"
        return 0
      fi
    done
    echo "序号无效，请重新输入" >&2
  done
}

menu_add_server() {
  local remark region access_key secret_key proxy_url instance_name
  remark=$(prompt_non_empty "填写备注: ")
  region=$(select_region) || return 1
  access_key=$(prompt_non_empty "填写 aws_access_key_id: ")
  secret_key=$(prompt_non_empty "填写 aws_secret_access_key: ")
  read -r -p "填写 proxy_url（可留空）: " proxy_url
  if instance_name=$(select_aws_instance "$region" "$access_key" "$secret_key" "$proxy_url"); then
    echo "已选择实例: $instance_name"
  else
    read -r -p "自动获取实例失败或跳过，手动填写 instance_name（可留空）: " instance_name
  fi

  run_js add-server \
    --remark "$remark" \
    --region "$region" \
    --aws-access-key-id "$access_key" \
    --aws-secret-access-key "$secret_key" \
    --proxy-url "$proxy_url" \
    --instance-name "$instance_name"
}

menu_add_domain() {
  local root_domain token
  root_domain=$(prompt_non_empty "填写根域名: ")
  token=$(prompt_non_empty "填写 Cloudflare Token: ")
  run_js add-domain --root-domain "$root_domain" --token "$token"
}

menu_add_rotation() {
  local server_id
  server_id=$(select_server all) || return 1
  run_js add-rotation --server "$server_id"
}

menu_add_dns() {
  local server_id domain_id subdomains
  server_id=$(select_server rotation) || return 1
  domain_id=$(select_domain) || return 1
  subdomains=$(prompt_non_empty "填写子域名，多个用逗号分隔，根域名可填 @ : ")
  run_js add-dns --server "$server_id" --domain "$domain_id" --subdomains "$subdomains"
}

menu_add_traffic() {
  local server_id limit_gb
  server_id=$(select_server all) || return 1
  limit_gb=$(prompt_non_empty "填写流量限制 GB，等于或大于时关机: ")
  run_js add-traffic --server "$server_id" --limit-gb "$limit_gb"
}

menu_set_telegram() {
  local bot_token chat_id
  bot_token=$(prompt_non_empty "填写 Telegram Bot Token: ")
  chat_id=$(prompt_non_empty "填写 Telegram 用户ID或群ID: ")
  run_js set-telegram --bot-token "$bot_token" --chat-id "$chat_id"
}

menu_run_now() {
  local answer server_id
  read -r -p "是否只运行单台服务器？(y/N): " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    server_id=$(select_server all) || return 1
    run_js run --server "$server_id"
    return 0
  fi
  run_js run
}

menu_install_cron() {
  local schedule server_id answer
  read -r -p "填写 cron 表达式（默认 */5 * * * *）: " schedule
  schedule="${schedule:-*/5 * * * *}"
  read -r -p "是否只监控单台服务器？(y/N): " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    server_id=$(select_server all) || return 1
    run_js install-cron --schedule "$schedule" --server "$server_id"
    return 0
  fi
  run_js install-cron --schedule "$schedule"
}

show_menu() {
  cat <<'EOF'

================ Lightsail Monitor ================
1) 添加 Lightsail 服务器
2) 添加根域名 / Cloudflare Token
3) 添加自动切换 IP 任务
4) 添加自动解析域名任务
5) 添加流量限制任务
6) 设置 Telegram 通知
7) 查看配置摘要
8) 立即执行检测
9) 安装 / 更新 Cron 定时任务
10) 删除 Cron 定时任务
0) 退出
===================================================
EOF
}

while true; do
  show_menu
  read -r -p "请输入序号: " choice
  case "$choice" in
    1) menu_add_server; pause ;;
    2) menu_add_domain; pause ;;
    3) menu_add_rotation; pause ;;
    4) menu_add_dns; pause ;;
    5) menu_add_traffic; pause ;;
    6) menu_set_telegram; pause ;;
    7) run_js summary; pause ;;
    8) menu_run_now; pause ;;
    9) menu_install_cron; pause ;;
    10) run_js remove-cron; pause ;;
    0) exit 0 ;;
    *) echo "无效序号"; pause ;;
  esac
done
