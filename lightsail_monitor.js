#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const os = require("os");
const crypto = require("crypto");
const { spawnSync } = require("child_process");
const axios = require("axios");
const ProxyAgent = require("proxy-agent");
const { NodeHttpHandler } = require("@smithy/node-http-handler");
const {
  LightsailClient,
  GetStaticIpsCommand,
  GetInstancesCommand,
  GetInstanceMetricDataCommand,
  StopInstanceCommand,
  ReleaseStaticIpCommand,
  AllocateStaticIpCommand,
  AttachStaticIpCommand,
  GetStaticIpCommand,
} = require("@aws-sdk/client-lightsail");

const REGIONS = [
  ["美国东部（俄亥俄）", "us-east-2"],
  ["美国东部（弗吉尼亚北部）", "us-east-1"],
  ["美国西部（俄勒冈）", "us-west-2"],
  ["亚太地区（孟买）", "ap-south-1"],
  ["亚太地区（首尔）", "ap-northeast-2"],
  ["亚太地区（新加坡）", "ap-southeast-1"],
  ["亚太地区（悉尼）", "ap-southeast-2"],
  ["亚太地区（东京）", "ap-northeast-1"],
  ["加拿大（中部）", "ca-central-1"],
  ["欧洲（法兰克福）", "eu-central-1"],
  ["欧洲（爱尔兰）", "eu-west-1"],
  ["欧洲（伦敦）", "eu-west-2"],
  ["欧洲（巴黎）", "eu-west-3"],
];

const REGION_CODES = new Set(REGIONS.map(([, code]) => code));
const CRON_MARKER_BEGIN = "# lightsail-monitor managed task begin";
const CRON_MARKER_END = "# lightsail-monitor managed task end";
const DEFAULT_CRON_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
const DEFAULT_CRON_SCHEDULE = "*/5 * * * *";
const STATIC_IP_WAIT_INTERVAL_SECONDS = 3;
const STATIC_IP_WAIT_MAX_ATTEMPTS = 20;
const DEFAULT_TIMEOUT_MS = 30000;

function eprint(message) {
  process.stderr.write(`${message}\n`);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function newId(prefix) {
  return `${prefix}-${crypto.randomBytes(4).toString("hex")}`;
}

function uniqueStrings(items) {
  const result = [];
  const seen = new Set();
  for (const raw of items || []) {
    const value = String(raw || "").trim();
    if (!value || seen.has(value)) continue;
    seen.add(value);
    result.push(value);
  }
  return result;
}

function slugify(value) {
  const text = String(value || "").trim().toLowerCase().replace(/[^a-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "");
  return text || "server";
}

function formatGb(value) {
  if (value === null || value === undefined || Number.isNaN(Number(value))) return "-";
  return Number(value).toFixed(2);
}

function parseSubdomains(raw) {
  const parts = String(raw || "").trim().split(/[\s,，]+/).filter(Boolean);
  return uniqueStrings(parts.map((item) => {
    if (["@","root","ROOT","."].includes(item)) return "@";
    return item.replace(/^\./, "");
  }));
}

function fqdnFromSubdomain(rootDomain, subdomain) {
  if (!subdomain || ["@", "root", "ROOT"].includes(subdomain)) return rootDomain;
  return `${subdomain}.${rootDomain}`;
}

function nowUtc() {
  return new Date();
}

function toMonthStartUtc(date) {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), 1, 0, 0, 0));
}

function isoDate(value) {
  return value.toISOString();
}

function parseArgs(argv) {
  const result = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token.startsWith("--")) {
      const key = token.slice(2);
      const next = argv[i + 1];
      if (next !== undefined && !next.startsWith("--")) {
        result[key] = next;
        i += 1;
      } else {
        result[key] = true;
      }
    } else {
      result._.push(token);
    }
  }
  return result;
}

class ConfigStore {
  constructor(filePath) {
    this.path = filePath;
    this.data = null;
    this.migrated = false;
  }

  load() {
    if (this.data) return this.data;
    let raw = {};
    if (fs.existsSync(this.path)) {
      raw = JSON.parse(fs.readFileSync(this.path, "utf8"));
    }
    if (this.isLegacyV1(raw)) {
      raw = this.migrateV1ToV2(raw);
      this.migrated = true;
    }
    this.data = this.normalize(raw);
    return this.data;
  }

  save() {
    const data = this.load();
    fs.mkdirSync(path.dirname(this.path), { recursive: true });
    fs.writeFileSync(this.path, `${JSON.stringify(data, null, 2)}\n`, "utf8");
    this.migrated = false;
  }

  autoSaveIfMigrated() {
    if (this.migrated) this.save();
  }

  isLegacyV1(data) {
    return data && typeof data === "object" && Array.isArray(data.accounts) && !Array.isArray(data.lightsail_servers);
  }

  normalize(data) {
    const cfg = JSON.parse(JSON.stringify(data || {}));
    cfg.version = 2;
    cfg.defaults = cfg.defaults || {};
    cfg.defaults.ping_times = Number(cfg.defaults.ping_times || 30);
    cfg.defaults.cron_schedule = cfg.defaults.cron_schedule || DEFAULT_CRON_SCHEDULE;

    cfg.telegram = cfg.telegram || {};
    cfg.telegram.enabled = Boolean(cfg.telegram.enabled);
    cfg.telegram.bot_token = String(cfg.telegram.bot_token || "");
    cfg.telegram.chat_id = String(cfg.telegram.chat_id || "");

    cfg.domains = Array.isArray(cfg.domains) ? cfg.domains : [];
    cfg.lightsail_servers = Array.isArray(cfg.lightsail_servers) ? cfg.lightsail_servers : [];
    cfg.rotation_tasks = Array.isArray(cfg.rotation_tasks) ? cfg.rotation_tasks : [];
    cfg.dns_tasks = Array.isArray(cfg.dns_tasks) ? cfg.dns_tasks : [];
    cfg.traffic_tasks = Array.isArray(cfg.traffic_tasks) ? cfg.traffic_tasks : [];

    for (const server of cfg.lightsail_servers) {
      server.id = server.id || newId("srv");
      server.remark = String(server.remark || "");
      server.enabled = server.enabled !== false;
      server.region = String(server.region || "");
      server.aws_access_key_id = String(server.aws_access_key_id || "");
      server.aws_secret_access_key = String(server.aws_secret_access_key || "");
      server.proxy_url = String(server.proxy_url || "");
      server.current_ip = String(server.current_ip || server.ip || "");
      delete server.ip;
      server.instance_name = String(server.instance_name || "");
      server.notification_enabled = server.notification_enabled !== false;
    }

    for (const domain of cfg.domains) {
      domain.id = domain.id || newId("dom");
      domain.root_domain = String(domain.root_domain || "").toLowerCase();
      domain.token = String(domain.token || "");
      domain.enabled = domain.enabled !== false;
    }

    for (const task of cfg.rotation_tasks) {
      task.id = task.id || newId("rot");
      task.enabled = task.enabled !== false;
    }

    for (const task of cfg.dns_tasks) {
      task.id = task.id || newId("dns");
      task.enabled = task.enabled !== false;
      task.proxied = Boolean(task.proxied);
      task.subdomains = uniqueStrings(task.subdomains || []);
    }

    for (const task of cfg.traffic_tasks) {
      task.id = task.id || newId("traf");
      task.enabled = task.enabled !== false;
      task.limit_gb = Number(task.limit_gb || 0);
    }

    return cfg;
  }

  migrateV1ToV2(data) {
    const next = {
      version: 2,
      defaults: {
        ping_times: Number((((data || {}).defaults || {}).ping_times) || 30),
        cron_schedule: DEFAULT_CRON_SCHEDULE,
      },
      telegram: JSON.parse(JSON.stringify(data.telegram || { enabled: false, bot_token: "", chat_id: "" })),
      domains: [],
      lightsail_servers: [],
      rotation_tasks: [],
      dns_tasks: [],
      traffic_tasks: [],
    };

    const domainIdByRoot = {};
    const tokens = ((((data || {}).cloudflare || {}).tokens) || []);
    for (const item of tokens) {
      const rootDomain = String((item || {}).root_domain || "").trim().toLowerCase();
      const token = String((item || {}).token || "").trim();
      if (!rootDomain || !token) continue;
      const domainId = newId("dom");
      domainIdByRoot[rootDomain] = domainId;
      next.domains.push({
        id: domainId,
        root_domain: rootDomain,
        token,
        enabled: true,
      });
    }

    for (const account of data.accounts || []) {
      const serverId = newId("srv");
      next.lightsail_servers.push({
        id: serverId,
        remark: String((account || {}).name || "").trim(),
        enabled: (account || {}).enabled !== false,
        region: String((account || {}).region || "").trim(),
        aws_access_key_id: String((account || {}).aws_access_key_id || "").trim(),
        aws_secret_access_key: String((account || {}).aws_secret_access_key || "").trim(),
        proxy_url: String((account || {}).proxy_url || "").trim(),
        current_ip: String((account || {}).ip || "").trim(),
        instance_name: "",
        notification_enabled: (account || {}).notification_enabled !== false,
      });

      next.rotation_tasks.push({
        id: newId("rot"),
        server_id: serverId,
        enabled: (account || {}).enabled !== false,
      });

      const grouped = {};
      for (const fqdn of uniqueStrings((account || {}).domains || [])) {
        const domainLower = fqdn.toLowerCase();
        let matchedRoot = "";
        for (const rootDomain of Object.keys(domainIdByRoot).sort((a, b) => b.length - a.length)) {
          if (domainLower === rootDomain || domainLower.endsWith(`.${rootDomain}`)) {
            matchedRoot = rootDomain;
            break;
          }
        }
        if (!matchedRoot) continue;
        const subdomain = domainLower === matchedRoot ? "@" : domainLower.slice(0, -(matchedRoot.length + 1));
        grouped[matchedRoot] = grouped[matchedRoot] || [];
        grouped[matchedRoot].push(subdomain);
      }

      for (const [rootDomain, subdomains] of Object.entries(grouped)) {
        next.dns_tasks.push({
          id: newId("dns"),
          server_id: serverId,
          domain_id: domainIdByRoot[rootDomain],
          subdomains: uniqueStrings(subdomains),
          proxied: false,
          enabled: true,
        });
      }
    }

    return next;
  }
}

function findServer(config, ident) {
  const value = String(ident || "").trim();
  return config.lightsail_servers.find((server) => server.id === value || server.remark === value) || null;
}

function findDomain(config, ident) {
  const value = String(ident || "").trim().toLowerCase();
  return config.domains.find((domain) => String(domain.id || "").trim().toLowerCase() === value || String(domain.root_domain || "").trim().toLowerCase() === value) || null;
}

function getRotationTask(config, serverId) {
  return config.rotation_tasks.find((task) => task.server_id === serverId && task.enabled !== false) || null;
}

function getTrafficTask(config, serverId) {
  return config.traffic_tasks.find((task) => task.server_id === serverId && task.enabled !== false) || null;
}

function getDnsTasks(config, serverId) {
  return config.dns_tasks.filter((task) => task.server_id === serverId && task.enabled !== false);
}

function updateServer(config, serverId, fields) {
  const server = config.lightsail_servers.find((item) => item.id === serverId);
  if (!server) throw new Error(`找不到服务器: ${serverId}`);
  Object.assign(server, fields);
}

function buildAgent(proxyUrl) {
  const value = String(proxyUrl || "").trim();
  if (!value) return null;
  return new ProxyAgent(value);
}

class TelegramNotifier {
  constructor(config) {
    const telegram = config.telegram || {};
    this.enabled = Boolean(telegram.enabled);
    this.botToken = String(telegram.bot_token || "").trim();
    this.chatId = String(telegram.chat_id || "").trim();
  }

  async send(title, message, server = null) {
    if (!this.enabled || !this.botToken || !this.chatId) return;
    if (server && server.notification_enabled === false) return;
    try {
      const url = `https://api.telegram.org/bot${this.botToken}/sendMessage`;
      await axios.post(url, new URLSearchParams({
        chat_id: this.chatId,
        text: `${title}\n${message}`,
      }), {
        timeout: DEFAULT_TIMEOUT_MS,
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
      });
    } catch (error) {
      eprint(`Telegram 通知失败: ${error.message}`);
    }
  }
}

class CloudflareManager {
  constructor(proxyUrl = "") {
    this.agent = buildAgent(proxyUrl);
  }

  async request(method, url, token, options = {}) {
    const response = await axios({
      method,
      url,
      timeout: DEFAULT_TIMEOUT_MS,
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
        ...(options.headers || {}),
      },
      params: options.params,
      data: options.data,
      httpAgent: this.agent || undefined,
      httpsAgent: this.agent || undefined,
      proxy: false,
      validateStatus: () => true,
    });
    if (response.status < 200 || response.status >= 300) {
      throw new Error(`Cloudflare HTTP ${response.status}`);
    }
    const payload = response.data || {};
    if (!payload.success) {
      const errors = Array.isArray(payload.errors) ? payload.errors.map((item) => item.message || "unknown").join("; ") : "Cloudflare API 调用失败";
      throw new Error(errors || "Cloudflare API 调用失败");
    }
    return payload;
  }

  async findZone(rootDomain, token) {
    const payload = await this.request("GET", "https://api.cloudflare.com/client/v4/zones", token, {
      params: { name: rootDomain, status: "active", page: 1, per_page: 50 },
    });
    const zone = (payload.result || []).find((item) => String(item.name || "").toLowerCase() === rootDomain.toLowerCase());
    if (!zone) throw new Error(`找不到 Cloudflare Zone: ${rootDomain}`);
    return zone;
  }

  async listExactARecords(zoneId, fqdn, token) {
    const payload = await this.request("GET", `https://api.cloudflare.com/client/v4/zones/${zoneId}/dns_records`, token, {
      params: { type: "A", name: fqdn, page: 1, per_page: 100 },
    });
    return (payload.result || []).filter((item) => item.type === "A" && item.name === fqdn);
  }

  async upsertARecord(rootDomain, token, fqdn, ipAddress, proxied) {
    const zone = await this.findZone(rootDomain, token);
    if (!zone.id) throw new Error(`Zone 缺少 id: ${rootDomain}`);
    const payload = {
      type: "A",
      name: fqdn,
      content: ipAddress,
      ttl: 1,
      proxied: Boolean(proxied),
    };
    const records = await this.listExactARecords(zone.id, fqdn, token);
    if (records.length === 0) {
      await this.request("POST", `https://api.cloudflare.com/client/v4/zones/${zone.id}/dns_records`, token, { data: payload });
      console.log(`Cloudflare 已创建: ${fqdn} -> ${ipAddress}`);
      return;
    }
    for (const record of records) {
      if (!record.id) continue;
      await this.request("PUT", `https://api.cloudflare.com/client/v4/zones/${zone.id}/dns_records/${record.id}`, token, { data: payload });
    }
    console.log(`Cloudflare 已更新: ${fqdn} -> ${ipAddress}`);
  }
}

class LightsailManager {
  constructor(server) {
    this.server = server;
    this.region = String(server.region || "").trim();
    this.proxyUrl = String(server.proxy_url || "").trim();
    this.agent = buildAgent(this.proxyUrl);
    this.client = new LightsailClient({
      region: this.region,
      credentials: {
        accessKeyId: String(server.aws_access_key_id || "").trim(),
        secretAccessKey: String(server.aws_secret_access_key || "").trim(),
      },
      requestHandler: new NodeHttpHandler({
        httpAgent: this.agent || undefined,
        httpsAgent: this.agent || undefined,
        connectionTimeout: DEFAULT_TIMEOUT_MS,
        socketTimeout: DEFAULT_TIMEOUT_MS,
      }),
      maxAttempts: 3,
    });
  }

  async listInstances() {
    const response = await this.client.send(new GetInstancesCommand({}));
    return (response.instances || [])
      .filter((item) => item.name)
      .map((item) => ({
        instance_name: item.name,
        ip: item.publicIpAddress || "",
      }));
  }

  async fetchStaticIpCandidates() {
    const response = await this.client.send(new GetStaticIpsCommand({}));
    return (response.staticIps || [])
      .filter((item) => item.name && item.attachedTo && item.ipAddress)
      .map((item) => ({
        mode: "static",
        static_ip_name: item.name,
        instance_name: item.attachedTo,
        ip: item.ipAddress,
      }));
  }

  async fetchInstanceCandidates() {
    const response = await this.client.send(new GetInstancesCommand({}));
    return (response.instances || [])
      .filter((item) => item.name && item.publicIpAddress)
      .map((item) => ({
        mode: "instance",
        instance_name: item.name,
        ip: item.publicIpAddress,
      }));
  }

  pickCandidate(candidates, currentIp, label, preferredInstanceName = "") {
    if (!candidates.length) throw new Error(`当前账号没有可用的${label}`);
    if (preferredInstanceName) {
      const instanceMatches = candidates.filter((item) => item.instance_name === preferredInstanceName);
      if (instanceMatches.length === 1) return instanceMatches[0];
      if (instanceMatches.length > 1) {
        if (currentIp) {
          const ipMatches = instanceMatches.filter((item) => item.ip === currentIp);
          if (ipMatches.length === 1) return ipMatches[0];
        }
        throw new Error(`实例 ${preferredInstanceName} 对应多个${label}候选，无法唯一确定`);
      }
      eprint(`指定的 instance_name ${preferredInstanceName} 未在${label}列表中找到`);
    }
    if (currentIp) {
      const matches = candidates.filter((item) => item.ip === currentIp);
      if (matches.length === 1) return matches[0];
      if (candidates.length === 1) {
        eprint(`配置中的 IP ${currentIp} 未在${label}列表中找到，改用唯一候选`);
        return candidates[0];
      }
      throw new Error(`配置中的 IP ${currentIp} 未在${label}列表中找到，且候选不止一个`);
    }
    if (candidates.length > 1) {
      eprint(`配置里没有 current_ip，${label} 候选不止一个，默认使用第一个: ${candidates[0].ip}`);
    }
    return candidates[0];
  }

  async resolveRotationTarget(currentIp, preferredInstanceName = "") {
    const staticCandidates = await this.fetchStaticIpCandidates();
    if (staticCandidates.length) return this.pickCandidate(staticCandidates, currentIp, "静态 IP", preferredInstanceName);
    const instanceCandidates = await this.fetchInstanceCandidates();
    return this.pickCandidate(instanceCandidates, currentIp, "实例公网 IP", preferredInstanceName);
  }

  async initializeCurrentIp(preferredInstanceName = "") {
    return this.resolveRotationTarget("", preferredInstanceName);
  }

  async getMetricSum(instanceName, metricName, startTime, endTime) {
    const response = await this.client.send(new GetInstanceMetricDataCommand({
      instanceName,
      metricName,
      period: 86400,
      startTime,
      endTime,
      unit: "Bytes",
      statistics: ["Sum"],
    }));
    return (response.metricData || []).reduce((sum, item) => sum + Number(item.sum || 0), 0);
  }

  async queryMonthlyTraffic(instanceName) {
    const now = nowUtc();
    const start = toMonthStartUtc(now);
    const outBytes = await this.getMetricSum(instanceName, "NetworkOut", start, now);
    const inBytes = await this.getMetricSum(instanceName, "NetworkIn", start, now);
    const totalBytes = outBytes + inBytes;
    return {
      instance_name: instanceName,
      month_start: isoDate(start),
      checked_at: isoDate(now),
      out_gb: outBytes / (1024 ** 3),
      in_gb: inBytes / (1024 ** 3),
      total_gb: totalBytes / (1024 ** 3),
    };
  }

  async stopInstance(instanceName) {
    await this.client.send(new StopInstanceCommand({ instanceName }));
  }

  async releaseStaticIp(staticIpName) {
    await this.client.send(new ReleaseStaticIpCommand({ staticIpName }));
  }

  async allocateStaticIp(staticIpName) {
    await this.client.send(new AllocateStaticIpCommand({ staticIpName }));
  }

  async attachStaticIp(staticIpName, instanceName) {
    await this.client.send(new AttachStaticIpCommand({ staticIpName, instanceName }));
  }

  async getStaticIp(staticIpName) {
    return this.client.send(new GetStaticIpCommand({ staticIpName }));
  }

  async waitForStaticIpAttachment(staticIpName, instanceName) {
    for (let i = 0; i < STATIC_IP_WAIT_MAX_ATTEMPTS; i += 1) {
      const response = await this.getStaticIp(staticIpName);
      const item = response.staticIp || {};
      if (item.attachedTo === instanceName && item.ipAddress) return item.ipAddress;
      await sleep(STATIC_IP_WAIT_INTERVAL_SECONDS * 1000);
    }
    throw new Error(`等待静态 IP 绑定超时: ${staticIpName}`);
  }

  generateAutoStaticIpName(instanceName) {
    return `${slugify(instanceName)}-${Math.floor(Date.now() / 1000)}`;
  }

  async rotateIp(target) {
    const instanceName = target.instance_name || "";
    if (!instanceName) throw new Error("缺少实例名称，无法切换 IP");

    if (target.mode === "static") {
      const staticIpName = target.static_ip_name || "";
      if (!staticIpName) throw new Error("缺少静态 IP 名称，无法切换 IP");
      await this.releaseStaticIp(staticIpName);
      await this.allocateStaticIp(staticIpName);
      await this.attachStaticIp(staticIpName, instanceName);
      const newIp = await this.waitForStaticIpAttachment(staticIpName, instanceName);
      return { mode: "static", instance_name: instanceName, static_ip_name: staticIpName, new_ip: newIp };
    }

    const staticIpName = this.generateAutoStaticIpName(instanceName);
    await this.allocateStaticIp(staticIpName);
    try {
      await this.attachStaticIp(staticIpName, instanceName);
      const newIp = await this.waitForStaticIpAttachment(staticIpName, instanceName);
      return { mode: "static", instance_name: instanceName, static_ip_name: staticIpName, new_ip: newIp };
    } catch (error) {
      try {
        await this.releaseStaticIp(staticIpName);
      } catch (_) {}
      throw error;
    }
  }
}

function pingIsFullyLost(ipAddress, pingTimes) {
  const isWin = os.platform().startsWith("win");
  const args = [isWin ? "-n" : "-c", String(pingTimes), ipAddress];
  const result = spawnSync("ping", args, { encoding: "utf8" });
  const output = `${result.stdout || ""}\n${result.stderr || ""}`;
  const match = output.match(/(\d+(?:\.\d+)?)%\s*packet loss/i);
  if (match) return Number(match[1]) >= 100;
  if (isWin) return output.toLowerCase().includes("100% loss") || output.includes("请求超时");
  return false;
}

function buildCronRunCommand(scriptPath, configPath, serverIdent = "") {
  let command = `node "${scriptPath}" --config "${configPath}" run`;
  if (serverIdent) command += ` --server "${serverIdent}"`;
  return command;
}

function installCron(scriptPath, configPath, schedule, serverIdent = "") {
  const current = spawnSync("crontab", ["-l"], { encoding: "utf8" });
  const content = current.status === 0 ? current.stdout : "";
  const cleaned = [];
  let skipping = false;
  for (const line of content.split(/\r?\n/)) {
    if (line.trim() === CRON_MARKER_BEGIN) {
      skipping = true;
      continue;
    }
    if (line.trim() === CRON_MARKER_END) {
      skipping = false;
      continue;
    }
    if (!skipping) cleaned.push(line);
  }
  cleaned.push(
    CRON_MARKER_BEGIN,
    `PATH=${DEFAULT_CRON_PATH}`,
    `${schedule} ${buildCronRunCommand(scriptPath, configPath, serverIdent)} >> "${path.join(path.dirname(scriptPath), "lightsail-monitor.log")}" 2>&1`,
    CRON_MARKER_END,
    "",
  );
  const result = spawnSync("crontab", ["-"], { input: cleaned.join("\n"), encoding: "utf8" });
  if (result.status !== 0) throw new Error(result.stderr || "安装 crontab 失败");
}

function removeCron() {
  const current = spawnSync("crontab", ["-l"], { encoding: "utf8" });
  if (current.status !== 0) return;
  const cleaned = [];
  let skipping = false;
  for (const line of current.stdout.split(/\r?\n/)) {
    if (line.trim() === CRON_MARKER_BEGIN) {
      skipping = true;
      continue;
    }
    if (line.trim() === CRON_MARKER_END) {
      skipping = false;
      continue;
    }
    if (!skipping) cleaned.push(line);
  }
  const result = spawnSync("crontab", ["-"], { input: `${cleaned.join("\n")}\n`, encoding: "utf8" });
  if (result.status !== 0) throw new Error(result.stderr || "删除 crontab 失败");
}

function printRegions() {
  REGIONS.forEach(([label, code], index) => {
    console.log(`${index + 1}|${label}|${code}`);
  });
}

function printServers(config, rotationOnly = false) {
  let index = 0;
  for (const server of config.lightsail_servers) {
    if (rotationOnly && !getRotationTask(config, server.id)) continue;
    index += 1;
    const trafficTask = getTrafficTask(config, server.id);
    console.log([
      index,
      server.id,
      server.remark,
      server.region,
      server.current_ip || "",
      server.proxy_url ? "yes" : "no",
      getRotationTask(config, server.id) ? "yes" : "no",
      trafficTask ? Number(trafficTask.limit_gb).toFixed(2) : "-",
    ].join("|"));
  }
}

function printDomains(config) {
  let index = 0;
  for (const domain of config.domains) {
    if (domain.enabled === false) continue;
    index += 1;
    console.log([index, domain.id, domain.root_domain].join("|"));
  }
}

function printSummary(config) {
  console.log("=== Lightsail 服务器 ===");
  if (!config.lightsail_servers.length) console.log("暂无服务器");
  config.lightsail_servers.forEach((server, index) => {
    const trafficTask = getTrafficTask(config, server.id);
    console.log(
      `${index + 1}. ${server.remark} [${server.region}] 实例=${server.instance_name || "-"} IP=${server.current_ip || "-"} 代理=${server.proxy_url ? "有" : "无"} 自动切换=${getRotationTask(config, server.id) ? "开" : "关"} 流量限制=${trafficTask ? `${formatGb(trafficTask.limit_gb)}GB` : "-"}`,
    );
  });

  console.log("\n=== Cloudflare 根域名 ===");
  if (!config.domains.length) console.log("暂无域名");
  config.domains.forEach((domain, index) => console.log(`${index + 1}. ${domain.root_domain}`));

  console.log("\n=== 自动解析任务 ===");
  if (!config.dns_tasks.length) console.log("暂无自动解析任务");
  config.dns_tasks.forEach((task, index) => {
    const server = findServer(config, task.server_id);
    const domain = findDomain(config, task.domain_id);
    console.log(`${index + 1}. ${server ? server.remark : task.server_id} -> ${domain ? domain.root_domain : task.domain_id} [${(task.subdomains || []).join(", ") || "-"}]`);
  });

  console.log("\n=== Telegram ===");
  console.log(`启用: ${config.telegram.enabled ? "是" : "否"}`);
  console.log(`chat_id: ${config.telegram.chat_id || "-"}`);
}

class Runner {
  constructor(store, serverFilter = "") {
    this.store = store;
    this.config = store.load();
    this.serverFilter = String(serverFilter || "").trim();
    this.notifier = new TelegramNotifier(this.config);
  }

  resolveServers() {
    const servers = this.config.lightsail_servers.filter((server) => server.enabled !== false);
    if (!this.serverFilter) return servers;
    const server = findServer(this.config, this.serverFilter);
    if (!server) throw new Error(`找不到服务器: ${this.serverFilter}`);
    if (server.enabled === false) throw new Error(`服务器已禁用: ${this.serverFilter}`);
    return [server];
  }

  async ensureServerIp(manager, server) {
    const currentIp = String(server.current_ip || "").trim();
    if (currentIp) return currentIp;
    const target = await manager.initializeCurrentIp(String(server.instance_name || "").trim());
    updateServer(this.config, server.id, {
      current_ip: target.ip || "",
      instance_name: target.instance_name || server.instance_name || "",
    });
    this.store.save();
    console.log(`已初始化 ${server.remark} 当前 IP: ${target.ip || ""}`);
    if (target.instance_name) console.log(`已识别实例名称: ${target.instance_name}`);
    return target.ip || "";
  }

  async checkTraffic(manager, server) {
    const task = getTrafficTask(this.config, server.id);
    if (!task) return false;

    const currentIp = await this.ensureServerIp(manager, server);
    const target = await manager.resolveRotationTarget(currentIp, String(server.instance_name || "").trim());
    const instanceName = target.instance_name || server.instance_name || "";
    if (!instanceName) throw new Error(`${server.remark} 无法识别实例名称，不能查询流量`);

    updateServer(this.config, server.id, { instance_name: instanceName });
    this.store.save();

    const info = await manager.queryMonthlyTraffic(instanceName);
    console.log(`[流量] ${server.remark} / ${instanceName}: 总计 ${info.total_gb.toFixed(2)} GB (出站 ${info.out_gb.toFixed(2)} GB, 入站 ${info.in_gb.toFixed(2)} GB)`);

    const limitGb = Number(task.limit_gb || 0);
    if (limitGb > 0 && info.total_gb >= limitGb) {
      console.log(`[流量] 已达到阈值 ${limitGb.toFixed(2)} GB，正在关机`);
      await manager.stopInstance(instanceName);
      await this.notifier.send(
        "Lightsail 流量超限",
        `${server.remark} (${server.region}) 本月流量 ${info.total_gb.toFixed(2)} GB，已达到阈值 ${limitGb.toFixed(2)} GB，已执行关机。`,
        server,
      );
      return true;
    }
    return false;
  }

  async updateDns(server, newIp) {
    const dnsTasks = getDnsTasks(this.config, server.id);
    if (!dnsTasks.length) {
      console.log(`[DNS] ${server.remark} 没有关联的自动解析任务`);
      return 0;
    }

    const manager = new CloudflareManager(server.proxy_url || "");
    let updated = 0;
    for (const task of dnsTasks) {
      const domain = findDomain(this.config, task.domain_id);
      if (!domain || domain.enabled === false) {
        eprint(`[DNS] 跳过无效域名任务: ${task.id}`);
        continue;
      }
      for (const subdomain of task.subdomains || []) {
        const fqdn = fqdnFromSubdomain(domain.root_domain, subdomain);
        await manager.upsertARecord(domain.root_domain, domain.token, fqdn, newIp, Boolean(task.proxied));
        updated += 1;
      }
    }
    return updated;
  }

  async runRotation(manager, server) {
    if (!getRotationTask(this.config, server.id)) return;

    const currentIp = await this.ensureServerIp(manager, server);
    console.log(`[检测] ${server.remark} 当前 IP: ${currentIp}`);
    const pingTimes = Number(((this.config.defaults || {}).ping_times) || 30);
    const blocked = pingIsFullyLost(currentIp, pingTimes);
    if (!blocked) {
      console.log(`[检测] ${server.remark} 未发现 100% 丢包，不切换 IP`);
      return;
    }

    console.log(`[检测] ${server.remark} 已出现 100% 丢包，准备切换 IP`);
    const target = await manager.resolveRotationTarget(currentIp, String(server.instance_name || "").trim());
    const rotated = await manager.rotateIp(target);
    const newIp = rotated.new_ip;
    updateServer(this.config, server.id, {
      current_ip: newIp,
      instance_name: rotated.instance_name || "",
    });
    this.store.save();
    const updatedCount = await this.updateDns(server, newIp);
    console.log(`[切换] ${server.remark} 新 IP: ${newIp}`);
    await this.notifier.send(
      "Lightsail IP 已切换",
      `${server.remark} (${server.region}) IP 已从 ${currentIp} 切换到 ${newIp}，实例 ${rotated.instance_name || "-"}，同步解析 ${updatedCount} 条记录。`,
      server,
    );
  }

  async run() {
    const servers = this.resolveServers();
    if (!servers.length) {
      console.log("没有可执行的服务器");
      return 0;
    }
    this.store.autoSaveIfMigrated();

    for (const server of servers) {
      console.log("=".repeat(72));
      console.log(`服务器: ${server.remark} [${server.region}]`);
      try {
        const manager = new LightsailManager(server);
        const stopped = await this.checkTraffic(manager, server);
        if (stopped) {
          console.log(`[流量] ${server.remark} 已关机，跳过 IP 切换`);
          continue;
        }
        await this.runRotation(manager, server);
      } catch (error) {
        eprint(`[失败] ${server.remark}: ${error.message}`);
        await this.notifier.send("Lightsail 任务失败", `${server.remark} (${server.region}) 执行失败: ${error.message}`, server);
        return 1;
      }
    }
    return 0;
  }
}

function requireRegion(region) {
  const value = String(region || "").trim();
  if (!REGION_CODES.has(value)) throw new Error(`不支持的地区: ${value}`);
  return value;
}

function requireValue(name, value) {
  const finalValue = String(value || "").trim();
  if (!finalValue) throw new Error(`${name} 不能为空`);
  return finalValue;
}

function commandAddServer(store, args) {
  const config = store.load();
  const remark = requireValue("备注", args.remark);
  if (findServer(config, remark)) throw new Error(`已存在同名服务器备注: ${remark}`);
  config.lightsail_servers.push({
    id: newId("srv"),
    remark,
    enabled: true,
    region: requireRegion(args.region),
    aws_access_key_id: requireValue("aws_access_key_id", args["aws-access-key-id"]),
    aws_secret_access_key: requireValue("aws_secret_access_key", args["aws-secret-access-key"]),
    proxy_url: String(args["proxy-url"] || "").trim(),
    current_ip: "",
    instance_name: String(args["instance-name"] || "").trim(),
    notification_enabled: true,
  });
  store.save();
  console.log(`已添加 Lightsail 服务器: ${remark}`);
  return 0;
}

async function commandListAwsInstances(args) {
  const tempServer = {
    region: requireRegion(args.region),
    aws_access_key_id: requireValue("aws_access_key_id", args["aws-access-key-id"]),
    aws_secret_access_key: requireValue("aws_secret_access_key", args["aws-secret-access-key"]),
    proxy_url: String(args["proxy-url"] || "").trim(),
  };
  const manager = new LightsailManager(tempServer);
  const instances = await manager.listInstances();
  instances.forEach((item, index) => {
    console.log([index + 1, item.instance_name, item.ip || ""].join("|"));
  });
  return 0;
}

function commandAddDomain(store, args) {
  const config = store.load();
  const rootDomain = requireValue("根域名", args["root-domain"]).toLowerCase();
  if (findDomain(config, rootDomain)) throw new Error(`根域名已存在: ${rootDomain}`);
  config.domains.push({
    id: newId("dom"),
    root_domain: rootDomain,
    token: requireValue("Cloudflare Token", args.token),
    enabled: true,
  });
  store.save();
  console.log(`已添加根域名: ${rootDomain}`);
  return 0;
}

function commandAddRotation(store, args) {
  const config = store.load();
  const server = findServer(config, requireValue("服务器", args.server));
  if (!server) throw new Error(`找不到服务器: ${args.server}`);
  if (getRotationTask(config, server.id)) {
    console.log(`自动切换 IP 已存在: ${server.remark}`);
    return 0;
  }
  config.rotation_tasks.push({ id: newId("rot"), server_id: server.id, enabled: true });
  store.save();
  console.log(`已启用自动切换 IP: ${server.remark}`);
  return 0;
}

function commandAddDns(store, args) {
  const config = store.load();
  const server = findServer(config, requireValue("服务器", args.server));
  if (!server) throw new Error(`找不到服务器: ${args.server}`);
  if (!getRotationTask(config, server.id)) throw new Error(`${server.remark} 还没有自动切换 IP 任务`);
  const domain = findDomain(config, requireValue("根域名", args.domain));
  if (!domain) throw new Error(`找不到根域名: ${args.domain}`);
  const subdomains = parseSubdomains(args.subdomains);
  if (!subdomains.length) throw new Error("至少填写一个子域名");

  const existed = config.dns_tasks.find((task) => task.server_id === server.id && task.domain_id === domain.id);
  if (existed) {
    existed.subdomains = uniqueStrings([...(existed.subdomains || []), ...subdomains]);
    store.save();
    console.log(`已合并自动解析任务: ${server.remark} -> ${domain.root_domain}`);
    return 0;
  }

  config.dns_tasks.push({
    id: newId("dns"),
    server_id: server.id,
    domain_id: domain.id,
    subdomains,
    proxied: false,
    enabled: true,
  });
  store.save();
  console.log(`已添加自动解析任务: ${server.remark} -> ${domain.root_domain}`);
  return 0;
}

function commandAddTraffic(store, args) {
  const config = store.load();
  const server = findServer(config, requireValue("服务器", args.server));
  if (!server) throw new Error(`找不到服务器: ${args.server}`);
  const limitGb = Number(args["limit-gb"]);
  if (!(limitGb > 0)) throw new Error("流量阈值必须大于 0");
  const existed = getTrafficTask(config, server.id);
  if (existed) {
    existed.limit_gb = limitGb;
    existed.enabled = true;
  } else {
    config.traffic_tasks.push({ id: newId("traf"), server_id: server.id, limit_gb: limitGb, enabled: true });
  }
  store.save();
  console.log(`已设置流量限制: ${server.remark} >= ${limitGb.toFixed(2)} GB 自动关机`);
  return 0;
}

function commandSetTelegram(store, args) {
  const config = store.load();
  config.telegram = {
    enabled: true,
    bot_token: requireValue("Telegram Bot Token", args["bot-token"]),
    chat_id: requireValue("Telegram Chat ID", args["chat-id"]),
  };
  store.save();
  console.log("Telegram 通知已保存");
  return 0;
}

async function commandRun(store, args) {
  const runner = new Runner(store, args.server || "");
  return runner.run();
}

function printUsage(scriptName) {
  console.log(`用法:
  node ${scriptName} [--config path] list-regions
  node ${scriptName} [--config path] list-servers
  node ${scriptName} [--config path] list-rotation-servers
  node ${scriptName} [--config path] list-domains
  node ${scriptName} list-aws-instances --region ap-southeast-1 --aws-access-key-id KEY --aws-secret-access-key SECRET [--proxy-url URL]
  node ${scriptName} [--config path] summary
  node ${scriptName} [--config path] add-server --remark 名称 --region ap-southeast-1 --aws-access-key-id KEY --aws-secret-access-key SECRET [--proxy-url URL] [--instance-name NAME]
  node ${scriptName} [--config path] add-domain --root-domain example.com --token CF_TOKEN
  node ${scriptName} [--config path] add-rotation --server lightsail-sg
  node ${scriptName} [--config path] add-dns --server lightsail-sg --domain example.com --subdomains sg,www,@
  node ${scriptName} [--config path] add-traffic --server lightsail-sg --limit-gb 850
  node ${scriptName} [--config path] set-telegram --bot-token TOKEN --chat-id CHAT_ID
  node ${scriptName} [--config path] run [--server lightsail-sg]
  node ${scriptName} [--config path] install-cron [--schedule "*/5 * * * *"] [--server lightsail-sg]
  node ${scriptName} [--config path] remove-cron`);
}

async function main() {
  const scriptPath = path.resolve(__filename);
  const args = parseArgs(process.argv.slice(2));
  const command = args._[0];
  const configPath = path.resolve(String(args.config || process.env.LIGHTSAIL_MONITOR_CONFIG || path.join(path.dirname(scriptPath), "config.json")));
  const store = new ConfigStore(configPath);

  try {
    if (!command || command === "-h" || command === "--help" || command === "help") {
      printUsage(path.basename(scriptPath));
      return 0;
    }

    if (command === "list-regions") return printRegions(), 0;
    if (command === "list-servers") return printServers(store.load(), false), 0;
    if (command === "list-rotation-servers") return printServers(store.load(), true), 0;
    if (command === "list-domains") return printDomains(store.load()), 0;
    if (command === "summary") return printSummary(store.load()), 0;
    if (command === "list-aws-instances") return commandListAwsInstances(args);
    if (command === "add-server") return commandAddServer(store, args);
    if (command === "add-domain") return commandAddDomain(store, args);
    if (command === "add-rotation") return commandAddRotation(store, args);
    if (command === "add-dns") return commandAddDns(store, args);
    if (command === "add-traffic") return commandAddTraffic(store, args);
    if (command === "set-telegram") return commandSetTelegram(store, args);
    if (command === "run") return commandRun(store, args);
    if (command === "install-cron") {
      installCron(scriptPath, configPath, String(args.schedule || DEFAULT_CRON_SCHEDULE), String(args.server || ""));
      console.log(`Cron 已安装: ${String(args.schedule || DEFAULT_CRON_SCHEDULE)}`);
      return 0;
    }
    if (command === "remove-cron") {
      removeCron();
      console.log("Cron 已移除");
      return 0;
    }

    printUsage(path.basename(scriptPath));
    return 1;
  } catch (error) {
    eprint(`错误: ${error.message}`);
    return 1;
  }
}

main().then((code) => {
  process.exit(Number(code) || 0);
});
