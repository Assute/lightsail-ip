#!/bin/bash

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.json}"
ACCOUNT_FILTER="${1:-}"
DEFAULT_PING_TIMES=30
CRON_MARKER_BEGIN="# lightsail-ip managed task begin"
CRON_MARKER_END="# lightsail-ip managed task end"
DEFAULT_CRON_LOG_FILE="${SCRIPT_DIR}/lightsail-ip.log"
DEFAULT_CRON_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
MAX_LOG_SIZE_BYTES=5242880
STATIC_IP_WAIT_INTERVAL_SECONDS=3
STATIC_IP_WAIT_MAX_ATTEMPTS=20

PINGTIMES=$DEFAULT_PING_TIMES
TELEGRAM_ENABLED="false"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
CLOUDFLARE_TOKEN=""
CURRENT_ACCOUNT_NAME=""
CURRENT_REGION=""
CURRENT_PROXY_URL=""
CURRENT_NOTIFICATION_ENABLED="true"
CURRENT_CLOUDFLARE_DOMAIN=""
MATCHED_ACCOUNT=0
CLOUDFLARE_API_BASE="https://api.cloudflare.com/client/v4"

readonly SCRIPT_DIR
readonly CONFIG_FILE
readonly ACCOUNT_FILTER
readonly DEFAULT_PING_TIMES
readonly CRON_MARKER_BEGIN
readonly CRON_MARKER_END
readonly DEFAULT_CRON_LOG_FILE
readonly DEFAULT_CRON_PATH
readonly MAX_LOG_SIZE_BYTES
readonly STATIC_IP_WAIT_INTERVAL_SECONDS
readonly STATIC_IP_WAIT_MAX_ATTEMPTS
readonly CLOUDFLARE_API_BASE

export AWS_PAGER=""

case $(uname) in
	"Darwin")
		# Mac OS X 操作系统
		CHECK_PING="100.0% packet loss"
		;;
	"Linux")
		# GNU/Linux 操作系统
		CHECK_PING="100% packet loss"
		;;
	*)
		echo -e "Unsupport System"
		exit 1
		;;
esac

function print_usage {
	echo "用法: bash ${0} [account_name]"
	echo "说明: 不传账号名时，交互模式下直接显示定时任务菜单，非交互模式下执行配置文件中的所有启用账号；传入账号名时只执行该账号。"
	echo "配置文件: ${CONFIG_FILE}"
}

function is_true {
	case "$1" in
		1|true|TRUE|yes|YES|on|ON)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

function require_command {
	local cmd="$1"
	if ! command -v "$cmd" >/dev/null 2>&1
	then
		echo "缺少依赖命令: $cmd"
		exit 1
	fi
}

function is_interactive_session {
	[ -t 0 ] && [ -t 1 ]
}

function detect_os_family {
	if [ -f /etc/os-release ]
	then
		. /etc/os-release
		case "${ID:-}" in
			alpine)
				printf '%s\n' "alpine"
				return 0
				;;
			debian|ubuntu)
				printf '%s\n' "debian"
				return 0
				;;
		esac

		case "${ID_LIKE:-}" in
			*debian*)
				printf '%s\n' "debian"
				return 0
				;;
			*alpine*)
				printf '%s\n' "alpine"
				return 0
				;;
		esac
	fi

	printf '%s\n' "unknown"
}

function get_script_path {
	printf '%s/%s\n' "$SCRIPT_DIR" "$(basename "${BASH_SOURCE[0]}")"
}

function get_existing_crontab {
	local current_crontab=""
	if current_crontab=$(crontab -l 2>/dev/null)
	then
		printf '%s\n' "$current_crontab"
	fi
}

function strip_managed_cron_block {
	local crontab_content="$1"
	printf '%s\n' "$crontab_content" | awk -v begin="$CRON_MARKER_BEGIN" -v end="$CRON_MARKER_END" '
		$0 == begin {skip=1; found=1; next}
		$0 == end {skip=0; next}
		skip != 1 {print}
	'
}

function has_managed_cron_block {
	local crontab_content="$1"
	printf '%s\n' "$crontab_content" | grep -Fq "$CRON_MARKER_BEGIN"
}

function ensure_crontab_available {
	if ! command -v crontab >/dev/null 2>&1
	then
		echo "缺少依赖命令: crontab"
		case "$(detect_os_family)" in
			alpine)
				echo "请先安装: apk add --no-cache dcron"
				;;
			debian)
				echo "请先安装: apt update && apt install -y cron"
				;;
			*)
				echo "请先安装系统的 cron/crontab 组件"
				;;
		esac
		return 1
	fi
}

function try_enable_cron_service {
	if command -v rc-service >/dev/null 2>&1
	then
		rc-service crond start >/dev/null 2>&1 || true
	fi

	if command -v rc-update >/dev/null 2>&1
	then
		rc-update add crond default >/dev/null 2>&1 || true
	fi

	if command -v systemctl >/dev/null 2>&1
	then
		systemctl enable --now cron >/dev/null 2>&1 || systemctl enable --now crond >/dev/null 2>&1 || true
	fi

	if command -v service >/dev/null 2>&1
	then
		service cron start >/dev/null 2>&1 || service crond start >/dev/null 2>&1 || true
	fi
}

function build_cron_command {
	local cron_account_filter="$1"
	local cron_log_file="$2"
	local script_path
	local command

	script_path=$(get_script_path)
	command="/bin/bash \"$script_path\""

	if [ -n "$cron_account_filter" ]
	then
		command="${command} \"$cron_account_filter\""
	fi

	command="${command} >> \"$cron_log_file\" 2>&1"
	printf '%s\n' "$command"
}

function truncate_log_if_needed {
	local log_file="$DEFAULT_CRON_LOG_FILE"
	local file_size

	if [ ! -f "$log_file" ]
	then
		return 0
	fi

	file_size=$(wc -c < "$log_file" 2>/dev/null | tr -d '[:space:]')
	if ! [[ "$file_size" =~ ^[0-9]+$ ]]
	then
		return 0
	fi

	if [ "$file_size" -gt "$MAX_LOG_SIZE_BYTES" ]
	then
		: > "$log_file"
		echo "日志超过 5MB，已自动清空"
	fi
}

function install_managed_cron_job {
	local cron_expression="$1"
	local cron_account_filter="$2"
	local cron_log_file="$3"
	local current_crontab
	local cleaned_crontab
	local cron_command

	if ! ensure_crontab_available
	then
		return 1
	fi

	current_crontab=$(get_existing_crontab)
	cleaned_crontab=$(strip_managed_cron_block "$current_crontab")
	cron_command=$(build_cron_command "$cron_account_filter" "$cron_log_file")

	{
		if [ -n "$cleaned_crontab" ]
		then
			printf '%s\n' "$cleaned_crontab"
		fi
		printf '%s\n' "$CRON_MARKER_BEGIN"
		printf 'PATH=%s\n' "$DEFAULT_CRON_PATH"
		printf '%s %s\n' "$cron_expression" "$cron_command"
		printf '%s\n' "$CRON_MARKER_END"
	} | crontab -

	try_enable_cron_service

	echo "定时任务已设置成功"
	echo "计划表达式: $cron_expression"
	echo "日志文件: $cron_log_file"
}

function remove_managed_cron_job {
	local current_crontab
	local cleaned_crontab

	if ! ensure_crontab_available
	then
		return 1
	fi

	current_crontab=$(get_existing_crontab)
	if ! has_managed_cron_block "$current_crontab"
	then
		echo "没有找到脚本创建的定时任务"
		return 0
	fi

	cleaned_crontab=$(strip_managed_cron_block "$current_crontab")
	if [ -n "$cleaned_crontab" ]
	then
		printf '%s\n' "$cleaned_crontab" | crontab -
	else
		crontab -r
	fi

	echo "定时任务已删除"
}

function configure_schedule_interactively {
	local minute_input
	local cron_expression

	echo "定时间隔分钟（1-59，默认 5）："
	read -r minute_input

	if [ -z "$minute_input" ]
	then
		cron_expression="*/5 * * * *"
	elif [[ "$minute_input" =~ ^[0-9]+$ ]]
	then
		if [ "$minute_input" -lt 1 ] || [ "$minute_input" -gt 59 ]
		then
			echo "分钟数必须在 1 到 59 之间"
			return 1
		fi
		cron_expression="*/${minute_input} * * * *"
	else
		cron_expression="$minute_input"
	fi

	install_managed_cron_job "$cron_expression" "" "$DEFAULT_CRON_LOG_FILE"
}

function manage_cron_interactively {
	local cron_choice

	echo "================ 定时任务管理 ================"
	echo "检测到系统: $(detect_os_family)"
	echo "1. 设置/更新定时任务"
	echo "2. 删除定时任务"
	echo "0. 返回"
	echo "请输入序号："
	read -r cron_choice

	case "$cron_choice" in
		1)
			configure_schedule_interactively
			;;
		2)
			remove_managed_cron_job
			;;
		0)
			return 0
			;;
		*)
			echo "无效选择"
			return 1
			;;
	esac
}

function run_accounts {
	if ! load_config
	then
		return 1
	fi

	local failed_accounts=0
	while IFS= read -r account_json
	do
		if ! process_account "$account_json"
		then
			failed_accounts=$((failed_accounts + 1))
		fi
	done < <(jq -c '.accounts[]' "$CONFIG_FILE")

	if [ -n "$ACCOUNT_FILTER" ] && [ "$MATCHED_ACCOUNT" -eq 0 ]
	then
		echo "未找到账号: $ACCOUNT_FILTER"
		return 1
	fi

	if [ "$failed_accounts" -gt 0 ]
	then
		echo "共有 ${failed_accounts} 个账号执行失败"
		return 1
	fi

	return 0
}

function clear_proxy_environment {
	unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy
}

function clear_aws_environment {
	unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_REGION AWS_PROFILE AWS_DEFAULT_PROFILE
}

function configure_proxy_environment {
	local proxy_url="$1"

	clear_proxy_environment

	if [ -z "$proxy_url" ]
	then
		echo "代理: 未启用"
		return 0
	fi

	export HTTP_PROXY="$proxy_url"
	export HTTPS_PROXY="$proxy_url"
	export http_proxy="$proxy_url"
	export https_proxy="$proxy_url"

	echo "代理: $proxy_url"
}

function aws_call {
	local output
	if ! output=$(aws "$@" 2>&1)
	then
		echo "$output" >&2
		return 1
	fi

	printf '%s\n' "$output"
}

function save_account_ip {
	local ip="$1"
	local tmp_file

	tmp_file=$(mktemp "${CONFIG_FILE}.XXXXXX")
	if [ -z "$tmp_file" ]
	then
		echo "创建临时配置文件失败"
		return 1
	fi

	if ! jq --arg name "$CURRENT_ACCOUNT_NAME" --arg ip "$ip" \
		'(.accounts[] | select(.name == $name)).ip = $ip' \
		"$CONFIG_FILE" > "$tmp_file"
	then
		rm -f "$tmp_file"
		echo "写入配置文件失败: $CONFIG_FILE"
		return 1
	fi

	chmod 600 "$tmp_file" 2>/dev/null || true
	if ! mv "$tmp_file" "$CONFIG_FILE"
	then
		rm -f "$tmp_file"
		echo "更新配置文件失败: $CONFIG_FILE"
		return 1
	fi

	return 0
}

function get_cloudflare_error_message {
	local response_json="$1"
	printf '%s' "$response_json" | jq -r '
		if ((.errors // []) | length) > 0 then
			(.errors | map(.message // (.code | tostring)) | join("; "))
		elif ((.messages // []) | length) > 0 then
			(.messages | map(.message // .) | join("; "))
		else
			"unknown error"
		end
	'
}

function cloudflare_api_json {
	local method="$1"
	local url="$2"
	local payload="${3:-}"
	local response_json
	local error_message

	if [ -n "$payload" ]
	then
		if ! response_json=$(curl -sS -X "$method" "$url" \
			-H "Authorization: Bearer ${CLOUDFLARE_TOKEN}" \
			-H "Content-Type: application/json" \
			--data "$payload")
		then
			echo "Cloudflare API 请求失败" >&2
			return 1
		fi
	else
		if ! response_json=$(curl -sS -X "$method" "$url" \
			-H "Authorization: Bearer ${CLOUDFLARE_TOKEN}" \
			-H "Content-Type: application/json")
		then
			echo "Cloudflare API 请求失败" >&2
			return 1
		fi
	fi

	if [ "$(printf '%s' "$response_json" | jq -r '.success // false')" != "true" ]
	then
		error_message=$(get_cloudflare_error_message "$response_json")
		echo "Cloudflare API 请求失败: ${error_message}" >&2
		return 1
	fi

	printf '%s\n' "$response_json"
}

function find_cloudflare_zone_json {
	local domain="$1"
	local zone_candidate
	local response_json
	local error_message
	local i
	local j
	local label_count
	local -a labels

	IFS='.' read -r -a labels <<< "$domain"
	label_count=${#labels[@]}
	if [ "$label_count" -lt 2 ]
	then
		echo "Cloudflare 域名格式无效: ${domain}" >&2
		return 1
	fi

	for (( i = 0 ; i < label_count - 1 ; i++ ))
	do
		zone_candidate="${labels[$i]}"
		for (( j = i + 1 ; j < label_count ; j++ ))
		do
			zone_candidate="${zone_candidate}.${labels[$j]}"
		done

		if ! response_json=$(curl -sS -G "${CLOUDFLARE_API_BASE}/zones" \
			-H "Authorization: Bearer ${CLOUDFLARE_TOKEN}" \
			-H "Content-Type: application/json" \
			--data-urlencode "name=${zone_candidate}" \
			--data-urlencode "per_page=1")
		then
			echo "Cloudflare Zone 查询失败" >&2
			return 1
		fi

		if [ "$(printf '%s' "$response_json" | jq -r '.success // false')" != "true" ]
		then
			error_message=$(get_cloudflare_error_message "$response_json")
			echo "Cloudflare Zone 查询失败: ${error_message}" >&2
			return 1
		fi

		if [ "$(printf '%s' "$response_json" | jq -r '.result | length')" -gt 0 ]
		then
			printf '%s\n' "$response_json"
			return 0
		fi
	done

	echo "找不到与域名匹配的 Cloudflare Zone: ${domain}" >&2
	return 1
}

function get_cloudflare_a_records_json {
	local zone_id="$1"
	local domain="$2"
	local response_json
	local error_message

	if ! response_json=$(curl -sS -G "${CLOUDFLARE_API_BASE}/zones/${zone_id}/dns_records" \
		-H "Authorization: Bearer ${CLOUDFLARE_TOKEN}" \
		-H "Content-Type: application/json" \
		--data-urlencode "type=A" \
		--data-urlencode "name=${domain}" \
		--data-urlencode "per_page=100")
	then
		echo "Cloudflare DNS 记录查询失败" >&2
		return 1
	fi

	if [ "$(printf '%s' "$response_json" | jq -r '.success // false')" != "true" ]
	then
		error_message=$(get_cloudflare_error_message "$response_json")
		echo "Cloudflare DNS 记录查询失败: ${error_message}" >&2
		return 1
	fi

	printf '%s\n' "$response_json"
}

function update_cloudflare_dns_if_needed {
	local new_ip="$1"
	local zone_json
	local zone_id
	local zone_name
	local records_json
	local record_count
	local record_json
	local record_id
	local record_ttl
	local record_proxied
	local payload
	local updated_count=0

	if [ -z "$CURRENT_CLOUDFLARE_DOMAIN" ]
	then
		return 0
	fi

	if [ -z "$CLOUDFLARE_TOKEN" ]
	then
		echo "已填写域名但未配置 Cloudflare 全局令牌，跳过 DNS 更新" >&2
		return 1
	fi

	if ! zone_json=$(find_cloudflare_zone_json "$CURRENT_CLOUDFLARE_DOMAIN")
	then
		return 1
	fi

	zone_id=$(printf '%s' "$zone_json" | jq -r '.result[0].id // empty')
	zone_name=$(printf '%s' "$zone_json" | jq -r '.result[0].name // empty')
	if [ -z "$zone_id" ]
	then
		echo "Cloudflare Zone 信息不完整: ${CURRENT_CLOUDFLARE_DOMAIN}" >&2
		return 1
	fi

	if ! records_json=$(get_cloudflare_a_records_json "$zone_id" "$CURRENT_CLOUDFLARE_DOMAIN")
	then
		return 1
	fi

	record_count=$(printf '%s' "$records_json" | jq -r '.result | length')
	if [ "$record_count" -eq 0 ]
	then
		payload=$(jq -nc --arg name "$CURRENT_CLOUDFLARE_DOMAIN" --arg content "$new_ip" \
			'{type:"A", name:$name, content:$content, ttl:1, proxied:false}')
		if ! cloudflare_api_json "POST" "${CLOUDFLARE_API_BASE}/zones/${zone_id}/dns_records" "$payload" > /dev/null
		then
			return 1
		fi

		echo "Cloudflare DNS 已创建: ${CURRENT_CLOUDFLARE_DOMAIN} -> ${new_ip} (zone: ${zone_name})"
		return 0
	fi

	while IFS= read -r record_json
	do
		[ -z "$record_json" ] && continue
		record_id=$(printf '%s' "$record_json" | jq -r '.id // empty')
		record_ttl=$(printf '%s' "$record_json" | jq -r '.ttl // 1')
		record_proxied=$(printf '%s' "$record_json" | jq -r '.proxied // false')

		if [ -z "$record_id" ]
		then
			echo "Cloudflare DNS 记录缺少 id，跳过" >&2
			continue
		fi

		payload=$(jq -nc \
			--arg type "A" \
			--arg name "$CURRENT_CLOUDFLARE_DOMAIN" \
			--arg content "$new_ip" \
			--argjson ttl "$record_ttl" \
			--argjson proxied "$record_proxied" \
			'{type:$type, name:$name, content:$content, ttl:$ttl, proxied:$proxied}')

		if ! cloudflare_api_json "PUT" "${CLOUDFLARE_API_BASE}/zones/${zone_id}/dns_records/${record_id}" "$payload" > /dev/null
		then
			return 1
		fi

		updated_count=$((updated_count + 1))
	done < <(printf '%s' "$records_json" | jq -c '.result[]')

	if [ "$updated_count" -eq 0 ]
	then
		echo "Cloudflare DNS 没有可更新的 A 记录: ${CURRENT_CLOUDFLARE_DOMAIN}" >&2
		return 1
	fi

	echo "Cloudflare DNS 已更新: ${CURRENT_CLOUDFLARE_DOMAIN} -> ${new_ip} (zone: ${zone_name}, 记录数: ${updated_count})"
	return 0
}

function fetch_static_ips_from_aws {
	local ipjson
	local candidates_json

	if ! ipjson=$(aws_call lightsail --region "$CURRENT_REGION" get-static-ips)
	then
		echo "获取静态IP列表失败: ${CURRENT_ACCOUNT_NAME}" >&2
		return 1
	fi

	if ! candidates_json=$(printf '%s' "$ipjson" | jq -c '[.staticIps[]? | select((.name // "") != "" and (.attachedTo // "") != "" and (.ipAddress // "") != "") | {static_ip_name: .name, instance_name: .attachedTo, ip: .ipAddress}]')
	then
		echo "解析静态IP列表失败: ${CURRENT_ACCOUNT_NAME}" >&2
		return 1
	fi

	printf '%s\n' "$candidates_json"
}

function fetch_instance_public_ips_from_aws {
	local instance_json
	local candidates_json

	if ! instance_json=$(aws_call lightsail --region "$CURRENT_REGION" get-instances)
	then
		echo "获取实例列表失败: ${CURRENT_ACCOUNT_NAME}" >&2
		return 1
	fi

	if ! candidates_json=$(printf '%s' "$instance_json" | jq -c '[.instances[]? | select((.name // "") != "" and (.publicIpAddress // "") != "") | {instance_name: .name, ip: .publicIpAddress}]')
	then
		echo "解析实例列表失败: ${CURRENT_ACCOUNT_NAME}" >&2
		return 1
	fi

	printf '%s\n' "$candidates_json"
}

function generate_auto_static_ip_name {
	local timestamp
	timestamp=$(date +%Y%m%d%H%M%S)
	printf 'auto-%s-%s-%s' "$CURRENT_ACCOUNT_NAME" "$CURRENT_REGION" "$timestamp" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-'
}

function get_static_ip_json {
	local static_ip_name="$1"
	aws_call lightsail --region "$CURRENT_REGION" get-static-ip --static-ip-name "$static_ip_name"
}

function wait_for_static_ip_attachment {
	local static_ip_name="$1"
	local instance_name="$2"
	local attempt
	local static_ip_json
	local attached_to
	local ip_address

	for (( attempt = 1 ; attempt <= STATIC_IP_WAIT_MAX_ATTEMPTS ; attempt++ ))
	do
		if ! static_ip_json=$(get_static_ip_json "$static_ip_name")
		then
			sleep "$STATIC_IP_WAIT_INTERVAL_SECONDS"
			continue
		fi

		attached_to=$(printf '%s' "$static_ip_json" | jq -r '.staticIp.attachedTo // empty')
		ip_address=$(printf '%s' "$static_ip_json" | jq -r '.staticIp.ipAddress // empty')
		if [ "$attached_to" = "$instance_name" ] && [ -n "$ip_address" ]
		then
			printf '%s\n' "$ip_address"
			return 0
		fi

		sleep "$STATIC_IP_WAIT_INTERVAL_SECONDS"
	done

	echo "等待静态IP绑定完成超时: ${static_ip_name}" >&2
	return 1
}

function allocate_and_attach_static_ip_to_instance {
	local instance_name="$1"
	local static_ip_name
	local new_ip

	static_ip_name=$(generate_auto_static_ip_name)

	if ! aws_call lightsail --region "$CURRENT_REGION" allocate-static-ip --static-ip-name "$static_ip_name" > /dev/null
	then
		echo "为实例模式自动创建静态IP失败: ${instance_name}" >&2
		return 1
	fi

	if ! aws_call lightsail --region "$CURRENT_REGION" attach-static-ip --static-ip-name "$static_ip_name" --instance-name "$instance_name" > /dev/null
	then
		echo "自动绑定新静态IP失败: ${instance_name}" >&2
		aws_call lightsail --region "$CURRENT_REGION" release-static-ip --static-ip-name "$static_ip_name" > /dev/null 2>&1 || true
		return 1
	fi

	if ! new_ip=$(wait_for_static_ip_attachment "$static_ip_name" "$instance_name")
	then
		return 1
	fi

	printf '%s\n' "$new_ip"
}

function select_static_ip_entry {
	local candidates_json="$1"
	local current_ip="$2"
	local candidate_count
	local matched_count

	candidate_count=$(printf '%s' "$candidates_json" | jq -r 'length')
	if [ "$candidate_count" -eq 0 ]
	then
		echo "当前账号没有可用的静态IP" >&2
		return 1
	fi

	if [ -n "$current_ip" ]
	then
		matched_count=$(printf '%s' "$candidates_json" | jq -r --arg ip "$current_ip" '[.[] | select(.ip == $ip)] | length')
		if [ "$matched_count" -gt 0 ]
		then
			printf '%s' "$candidates_json" | jq -c --arg ip "$current_ip" 'first(.[] | select(.ip == $ip))'
			return 0
		fi

		if [ "$candidate_count" -eq 1 ]
		then
			echo "配置里的IP未在 AWS 当前静态IP列表中找到，改用账号唯一的静态IP" >&2
			printf '%s' "$candidates_json" | jq -c '.[0]'
			return 0
		fi

		echo "配置里的IP未在 AWS 当前静态IP列表中找到，且账号下有多个静态IP，无法确定目标" >&2
		return 1
	fi

	if [ "$candidate_count" -gt 1 ]
	then
		echo "配置里没有IP，账号下有多个静态IP，默认使用第一个静态IP进行初始化" >&2
	fi

	printf '%s' "$candidates_json" | jq -c '.[0]'
}

function select_instance_ip_entry {
	local candidates_json="$1"
	local current_ip="$2"
	local candidate_count
	local matched_count

	candidate_count=$(printf '%s' "$candidates_json" | jq -r 'length')
	if [ "$candidate_count" -eq 0 ]
	then
		echo "当前账号没有可用的实例公网IP" >&2
		return 1
	fi

	if [ -n "$current_ip" ]
	then
		matched_count=$(printf '%s' "$candidates_json" | jq -r --arg ip "$current_ip" '[.[] | select(.ip == $ip)] | length')
		if [ "$matched_count" -gt 0 ]
		then
			printf '%s' "$candidates_json" | jq -c --arg ip "$current_ip" 'first(.[] | select(.ip == $ip))'
			return 0
		fi

		if [ "$candidate_count" -eq 1 ]
		then
			echo "配置里的IP未在 AWS 当前实例公网IP列表中找到，改用账号唯一的实例公网IP" >&2
			printf '%s' "$candidates_json" | jq -c '.[0]'
			return 0
		fi

		echo "配置里的IP未在 AWS 当前实例公网IP列表中找到，且账号下有多个实例公网IP，无法确定目标" >&2
		return 1
	fi

	if [ "$candidate_count" -gt 1 ]
	then
		echo "配置里没有IP，账号下有多个实例公网IP，默认使用第一个实例公网IP进行初始化" >&2
	fi

	printf '%s' "$candidates_json" | jq -c '.[0]'
}

function load_or_init_account_ip {
	local account_json="$1"
	local current_ip
	local candidates_json
	local target_entry_json

	current_ip=$(printf '%s' "$account_json" | jq -r '.ip // empty')
	if [ -n "$current_ip" ]
	then
		printf '%s\n' "$current_ip"
		return 0
	fi

	echo "配置中没有已记录的IP，正在从 AWS 初始化" >&2
	if ! candidates_json=$(fetch_static_ips_from_aws)
	then
		return 1
	fi

	if [ "$(printf '%s' "$candidates_json" | jq -r 'length')" -gt 0 ]
	then
		if ! target_entry_json=$(select_static_ip_entry "$candidates_json" "")
		then
			return 1
		fi
	else
		echo "当前账号没有静态IP，改为使用实例公网IP初始化" >&2
		if ! candidates_json=$(fetch_instance_public_ips_from_aws)
		then
			return 1
		fi

		if ! target_entry_json=$(select_instance_ip_entry "$candidates_json" "")
		then
			return 1
		fi
	fi

	current_ip=$(printf '%s' "$target_entry_json" | jq -r '.ip // empty')
	if [ -z "$current_ip" ]
	then
		echo "初始化时没有获取到IP" >&2
		return 1
	fi

	if ! save_account_ip "$current_ip"
	then
		return 1
	fi

	echo "已将当前IP写入配置文件: ${current_ip}" >&2
	printf '%s\n' "$current_ip"
}

function load_rotation_target {
	local current_ip="$1"
	local candidates_json
	local instance_candidates_json
	local instance_entry_json
	local target_entry_json

	if ! candidates_json=$(fetch_static_ips_from_aws)
	then
		return 1
	fi

	if [ "$(printf '%s' "$candidates_json" | jq -r 'length')" -gt 0 ]
	then
		if ! target_entry_json=$(select_static_ip_entry "$candidates_json" "$current_ip")
		then
			return 1
		fi

		printf '%s' "$target_entry_json" | jq -c '. + {mode:"static"}'
		return 0
	fi

	if ! instance_candidates_json=$(fetch_instance_public_ips_from_aws)
	then
		return 1
	fi

	if ! instance_entry_json=$(select_instance_ip_entry "$instance_candidates_json" "$current_ip")
	then
		return 1
	fi

	printf '%s' "$instance_entry_json" | jq -c '. + {mode:"instance"}'
	return 0
}

function load_config {
	if [ ! -f "$CONFIG_FILE" ]
	then
		echo "配置文件不存在: $CONFIG_FILE"
		return 1
	fi

	if ! jq -e '.accounts and (.accounts | type == "array")' "$CONFIG_FILE" >/dev/null 2>&1
	then
		echo "配置文件格式错误，必须包含 accounts 数组: $CONFIG_FILE"
		return 1
	fi

	PINGTIMES=$(jq -r '.defaults.ping_times // 30' "$CONFIG_FILE")
	if ! [[ "$PINGTIMES" =~ ^[0-9]+$ ]] || [ "$PINGTIMES" -le 0 ]
	then
		echo "defaults.ping_times 必须是大于 0 的整数"
		return 1
	fi

	TELEGRAM_ENABLED=$(jq -r 'if .telegram.enabled == null then false else .telegram.enabled end' "$CONFIG_FILE")
	TELEGRAM_BOT_TOKEN=$(jq -r '.telegram.bot_token // empty' "$CONFIG_FILE")
	TELEGRAM_CHAT_ID=$(jq -r '.telegram.chat_id // empty' "$CONFIG_FILE")
	CLOUDFLARE_TOKEN=$(jq -r '.cloudflare.token // empty' "$CONFIG_FILE")

	if [ "$(jq -r '.accounts | length' "$CONFIG_FILE")" -eq 0 ]
	then
		echo "配置文件中没有任何账号: $CONFIG_FILE"
		return 1
	fi
}

function notification {
	if ! is_true "$CURRENT_NOTIFICATION_ENABLED"
	then
		return 0
	fi

	if ! is_true "$TELEGRAM_ENABLED"
	then
		return 0
	fi

	if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ] || [ "$TELEGRAM_BOT_TOKEN" = "BOT_TOKEN" ] || [ "$TELEGRAM_CHAT_ID" = "CHAT_ID" ]
	then
		echo -e 'telegram config missing'
		return 1
	fi

	local message="$1"$'\n'"$2"
	local json
	if ! json=$(curl -sS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
		--data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
		--data-urlencode "text=${message}")
	then
		echo -e 'notice send faild'
		return 1
	fi

	local ok
	local errmsg
	ok=$(printf '%s' "$json" | jq -r '.ok // false')
	errmsg=$(printf '%s' "$json" | jq -r '.description // "unknown error"')
	if [ "$ok" = "true" ]
	then
		echo -e 'notice send success'
	else
		echo -e 'notice send faild'
		echo -e "the error message is ${errmsg}"
	fi
}

function configure_account_environment {
	local account_json="$1"
	local access_key_id
	local secret_access_key
	local proxy_url
	local cloudflare_domain

	CURRENT_ACCOUNT_NAME=$(printf '%s' "$account_json" | jq -r '.name // empty')
	CURRENT_REGION=$(printf '%s' "$account_json" | jq -r '.region // empty')
	access_key_id=$(printf '%s' "$account_json" | jq -r '.aws_access_key_id // empty')
	secret_access_key=$(printf '%s' "$account_json" | jq -r '.aws_secret_access_key // empty')
	proxy_url=$(printf '%s' "$account_json" | jq -r '.proxy_url // empty')
	cloudflare_domain=$(printf '%s' "$account_json" | jq -r '.domain // empty')
	CURRENT_NOTIFICATION_ENABLED=$(printf '%s' "$account_json" | jq -r 'if .notification_enabled == null then true else .notification_enabled end')

	if [ -z "$CURRENT_ACCOUNT_NAME" ]
	then
		echo "账号配置缺少 name"
		return 1
	fi

	if [ -z "$CURRENT_REGION" ] || [ -z "$access_key_id" ] || [ -z "$secret_access_key" ]
	then
		echo "账号 ${CURRENT_ACCOUNT_NAME} 缺少必要字段: region/aws_access_key_id/aws_secret_access_key"
		return 1
	fi

	CURRENT_PROXY_URL="$proxy_url"
	CURRENT_CLOUDFLARE_DOMAIN="$cloudflare_domain"

	clear_aws_environment
	export AWS_ACCESS_KEY_ID="$access_key_id"
	export AWS_SECRET_ACCESS_KEY="$secret_access_key"
	export AWS_DEFAULT_REGION="$CURRENT_REGION"
	export AWS_REGION="$CURRENT_REGION"

	configure_proxy_environment "$CURRENT_PROXY_URL"
}

function process_account {
	local account_json="$1"
	local account_name
	local account_enabled
	local current_ip
	local old_ip
	local target_entry_json
	local rotation_mode
	local instance_name
	local static_ip_name
	local instancejson
	local new_ip
	local tmp_file

	account_name=$(printf '%s' "$account_json" | jq -r '.name // empty')
	account_enabled=$(printf '%s' "$account_json" | jq -r 'if .enabled == null then true else .enabled end')

	if [ -n "$ACCOUNT_FILTER" ] && [ "$ACCOUNT_FILTER" != "$account_name" ]
	then
		return 0
	fi

	if [ -n "$ACCOUNT_FILTER" ]
	then
		MATCHED_ACCOUNT=1
	fi

	if ! is_true "$account_enabled"
	then
		echo "跳过已禁用账号: ${account_name}"
		return 0
	fi

	echo -e '================================================================='
	echo "账号名称: ${account_name}"

	if ! configure_account_environment "$account_json"
	then
		clear_proxy_environment
		clear_aws_environment
		return 1
	fi

	echo "区域: ${CURRENT_REGION}"

	if ! current_ip=$(load_or_init_account_ip "$account_json")
	then
		clear_proxy_environment
		clear_aws_environment
		return 1
	fi

	old_ip="$current_ip"
	echo "当前记录IP: ${old_ip}"
	echo -e "1. 正在检测 ${old_ip} 是否被墙"

	tmp_file=$(mktemp "/tmp/${CURRENT_ACCOUNT_NAME}.ping.XXXXXX")
	ping -c "$PINGTIMES" "$old_ip" > "$tmp_file" 2>&1

	if grep -Fq "$CHECK_PING" "$tmp_file"
	then
		echo -e "2. 被墙了"

		if ! target_entry_json=$(load_rotation_target "$old_ip")
		then
			echo "无法确定需要更换的IP目标"
			rm -f "$tmp_file"
			clear_proxy_environment
			clear_aws_environment
			return 1
		fi

		rotation_mode=$(printf '%s' "$target_entry_json" | jq -r '.mode // "static"')
		instance_name=$(printf '%s' "$target_entry_json" | jq -r '.instance_name // empty')
		static_ip_name=$(printf '%s' "$target_entry_json" | jq -r '.static_ip_name // empty')

		echo "实例名称: ${instance_name:-未绑定}"
		if [ "$rotation_mode" = "static" ]
		then
			echo "静态IP名称: ${static_ip_name:-未知}"

			if [ -z "$instance_name" ] || [ -z "$static_ip_name" ]
			then
				echo "静态IP信息不完整，无法更换"
				rm -f "$tmp_file"
				clear_proxy_environment
				clear_aws_environment
				return 1
			fi

			if ! aws_call lightsail --region "$CURRENT_REGION" release-static-ip --static-ip-name "$static_ip_name" > /dev/null
			then
				echo "释放静态IP失败: ${static_ip_name}"
				rm -f "$tmp_file"
				clear_proxy_environment
				clear_aws_environment
				return 1
			fi

			if ! aws_call lightsail --region "$CURRENT_REGION" allocate-static-ip --static-ip-name "$static_ip_name" > /dev/null
			then
				echo "新建静态IP失败: ${static_ip_name}"
				rm -f "$tmp_file"
				clear_proxy_environment
				clear_aws_environment
				return 1
			fi

			if ! aws_call lightsail --region "$CURRENT_REGION" attach-static-ip --static-ip-name "$static_ip_name" --instance-name "$instance_name" > /dev/null
			then
				echo "绑定静态IP失败: ${static_ip_name}"
				rm -f "$tmp_file"
				clear_proxy_environment
				clear_aws_environment
				return 1
			fi

			if ! instancejson=$(aws_call lightsail --region "$CURRENT_REGION" get-instance --instance-name "$instance_name")
			then
				echo "获取新IP失败: ${instance_name}"
				rm -f "$tmp_file"
				clear_proxy_environment
				clear_aws_environment
				return 1
			fi

			new_ip=$(printf '%s' "$instancejson" | jq -r '.instance.publicIpAddress // empty')
			if [ -z "$new_ip" ]
			then
				echo "没有获取到新IP"
				rm -f "$tmp_file"
				clear_proxy_environment
				clear_aws_environment
				return 1
			fi
		else
			if [ -z "$instance_name" ]
			then
				echo "实例公网IP信息不完整，无法更换"
				rm -f "$tmp_file"
				clear_proxy_environment
				clear_aws_environment
				return 1
			fi

			echo "当前是实例公网IP模式，自动创建并绑定新的静态IP"
			if ! new_ip=$(allocate_and_attach_static_ip_to_instance "$instance_name")
			then
				rm -f "$tmp_file"
				clear_proxy_environment
				clear_aws_environment
				return 1
			fi
		fi

		echo -e "3. 新IP地址: ${new_ip}"
		if ! save_account_ip "$new_ip"
		then
			echo "新IP写回配置文件失败: ${CURRENT_ACCOUNT_NAME}"
			rm -f "$tmp_file"
			clear_proxy_environment
			clear_aws_environment
			return 1
		fi

		if ! update_cloudflare_dns_if_needed "$new_ip"
		then
			echo "Cloudflare DNS 更新失败: ${CURRENT_ACCOUNT_NAME}"
			rm -f "$tmp_file"
			clear_proxy_environment
			clear_aws_environment
			return 1
		fi

		echo -e "4. 新IP已写回配置文件"
		notification "IP地址已更换" "${CURRENT_ACCOUNT_NAME} (${CURRENT_REGION}) 的 ${instance_name} 服务器IP:${old_ip}已更换至${new_ip}。"
	else
		echo -e "2. 没有被墙"
	fi

	rm -f "$tmp_file"

	clear_proxy_environment
	clear_aws_environment
	echo "账号执行完成: ${CURRENT_ACCOUNT_NAME}"
	return 0
}

function main {
	require_command aws
	require_command jq
	require_command curl
	require_command ping

	if [ "$ACCOUNT_FILTER" = "-h" ] || [ "$ACCOUNT_FILTER" = "--help" ]
	then
		print_usage
		return 0
	fi

	if ! is_interactive_session
	then
		truncate_log_if_needed
	fi

	echo -e '***************************** START *****************************'

	if [ -z "$ACCOUNT_FILTER" ] && is_interactive_session
	then
		manage_cron_interactively
		echo -e '****************************** END ******************************'
		return $?
	fi

	if ! run_accounts
	then
		echo -e '****************************** END ******************************'
		return 1
	fi

	echo -e '****************************** END ******************************'
	return 0
}

main
exit $?
