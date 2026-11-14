import * as adb from './vendor/adb.js';
import * as stream from './vendor/stream-extra.js';
import CredentialStore from './vendor/adb-credential-web.js';
import { unzipSync } from './vendor/fflate.js';

export const BRIDGE_BASE = 'http://127.0.0.1:8765'; // 固定值，不给用户填
const DEFAULT_PORT = 5555;                            // 固定端口，不进输入框
const sleep = ms => new Promise(r => setTimeout(r, ms));

let handle = null; // { adb, closeSocket }

// ── 把 WebSocket 字节流包成 ADB 的包流 ───────────────
async function bridgeStream(host, port) {
  const wsUrl = BRIDGE_BASE.replace(/^http/, 'ws') +
    `/adb?host=${encodeURIComponent(host)}&port=${port}`;
  const socket = new WebSocket(wsUrl);
  socket.binaryType = 'arraybuffer';

  await new Promise((resolve, reject) => {
    const t = setTimeout(() => { try { socket.close(); } catch {} reject(new Error('桥接连接超时，请确认已运行 webadb-bridge')); }, 8000);
    socket.onopen = () => { clearTimeout(t); resolve(); };
    socket.onerror = () => { clearTimeout(t); reject(new Error('无法连接本地桥接：请在电脑上运行 webadb-bridge')); };
  });

  const readable = new ReadableStream({
    start(c) {
      socket.onmessage = e => {
        if (e.data instanceof ArrayBuffer) c.enqueue(new Uint8Array(e.data));
        else c.error(new Error('桥接返回了非二进制数据'));
      };
      socket.onerror = () => c.error(new Error('桥接连接错误'));
      socket.onclose = () => c.close();
    },
    cancel() { try { socket.close(); } catch {} },
  });
  const writable = new stream.MaybeConsumable.WritableStream({
    write(chunk) { if (socket.readyState !== WebSocket.OPEN) throw new Error('桥接已关闭'); socket.send(chunk); },
    close() { try { socket.close(); } catch {} },
    abort() { try { socket.close(); } catch {} },
  });

  return {
    connection: {
      readable: readable.pipeThrough(new stream.StructDeserializeStream(adb.AdbPacket)),
      writable: stream.pipeFrom(writable, new adb.AdbPacketSerializeStream()),
    },
    closeSocket: () => { try { socket.close(); } catch {} },
  };
}

// ── 连接（含 RSA 认证；首次要在盒子上允许调试）────────
export async function connect({ ip, port = DEFAULT_PORT } = {}) {
  if (!/^(?:\d{1,3}\.){3}\d{1,3}$/.test(ip || '')) throw new Error('请输入合法 IPv4，如 192.168.66.157');
  const { connection, closeSocket } = await bridgeStream(ip, port);
  let transport;
  try {
    transport = await withTimeout(
      adb.AdbDaemonTransport.authenticate({ serial: `${ip}:${port}`, connection, credentialStore: new CredentialStore('boxadb') }),
      30000, '连接超时：请在盒子上允许 ADB 调试后重试'
    );
  } catch (e) {
    closeSocket();
    throw /auth/i.test(String(e?.message || e)) ? new Error('设备未授权：请先完成 adb tcpip 5555 并允许调试') : e;
  }
  const a = new adb.Adb(transport);
  handle = { adb: a, closeSocket };
  a.disconnected.then(() => { if (handle && handle.adb === a) handle = null; }, () => {});
  return { adb: a, closeSocket };
}

export function connected() { return !!handle; }

export async function disconnect() {
  if (!handle) return;
  const h = handle; handle = null;
  try { await h.adb.close(); } catch {}
  try { h.closeSocket(); } catch {}
}

function requireAdb() { if (!handle) throw new Error('未连接设备'); return handle.adb; }

// ── 底层：跑一条一次性 shell，返回文本输出 ──────────────
// 用 subprocess（shellProtocol 优先，其次 noneProtocol），命令结束流会关闭，
// 不会像 createSocket('shell:') 那样在某些 adbd 上不关流导致永久 await。
export async function shell(cmd) {
  const a = requireAdb();
  const sp = a.subprocess?.shellProtocol;
  const np = a.subprocess?.noneProtocol;
  try {
    if (sp) {
      const proc = await sp.spawn(cmd);
      try {
        const [out, err] = await Promise.all([collect(proc.stdout), collect(proc.stderr)]);
        await Promise.race([proc.exited, sleep(3000)]);
        const dec = new TextDecoder();
        return dec.decode(out) + (err && err.length ? dec.decode(err) : '');
      } finally { try { await proc.stdin?.close(); } catch {} }
    }
    if (np) {
      const proc = await np.spawn(cmd);
      try {
        const out = await collect(proc.output);
        await Promise.race([proc.exited, sleep(3000)]);
        return new TextDecoder().decode(out);
      } finally { try { await proc.stdin?.close(); } catch {} }
    }
    const sock = await a.createSocket('shell:' + cmd);
    try { return new TextDecoder().decode(await collect(sock.readable)); }
    finally { try { await sock.close(); } catch {} }
  } catch (e) {
    if (e && /abort|timeout/i.test(String(e.name||''))) return '';
    throw e;
  }
}

async function collect(readable) {
  const r = readable.getReader(); const parts = [];
  for (;;) { const { value, done } = await r.read(); if (done) break; parts.push(value); }
  const size = parts.reduce((s, c) => s + c.length, 0);
  const out = new Uint8Array(size); let p = 0; for (const c of parts) { out.set(c, p); p += c.length; }
  return out;
}

// ── 列应用：scope='third' 第三方（-3）/ 'system' 系统（-s）；顺带标记已禁用的包 ──
export async function listApps({ scope = 'third' } = {}) {
  const raw = await shell(`pm list packages ${scope === 'system' ? '-s' : '-3'}`);
  const pkgs = raw.split('\n').map(l => (l.match(/^package:(.+)$/) || [])[1]).filter(Boolean);
  let disabled = new Set();
  try {
    const d = await shell('pm list packages -d');
    disabled = new Set(d.split('\n').map(l => (l.match(/^package:(.+)$/) || [])[1]).filter(Boolean));
  } catch {}
  // 尽力补一个人类可读名：从包名尾段（真实图标/label 走 PackageManager dump，后续增强）
  return pkgs.map(pkg => ({ pkg, name: pkg.split('.').filter(Boolean).slice(-1)[0] || pkg, disabled: disabled.has(pkg) }));
}

export async function keyevent(code) { return shell(`input keyevent ${code}`); }

export async function launch(pkg) {
  const a = requireAdb();
  const out = await shell(`monkey -p ${pkg} -c android.intent.category.LAUNCHER 1`);
  if (/no activities|no events|error|exception/i.test(out)) {
    // 回退：取 launcher activity 再 am start
    const act = (await shell(`cmd package resolve-activity --brief ${pkg}`)).split('\n').pop().trim();
    if (act && act.includes('/')) return shell(`am start -n ${act}`);
    throw new Error('无法启动该应用');
  }
  return out;
}
export async function forceStop(pkg) { return shell(`am force-stop ${pkg}`); }
export async function clearData(pkg)  { return shell(`pm clear ${pkg}`); }
export async function uninstall(pkg)  { return shell(`pm uninstall ${pkg}`); }

// 系统应用不能卸载，只能禁用（disable-user 对当前用户生效，无需 root，可随时 enable 恢复）
export async function disableApp(pkg) {
  const out = await shell(`pm disable-user --user 0 ${pkg}`);
  if (!/new state:\s*disabled/i.test(out)) throw new Error((out || '').trim() || '禁用失败：该应用可能受系统保护');
  return out;
}
export async function enableApp(pkg) {
  const out = await shell(`pm enable ${pkg}`);
  if (!/new state:\s*(enabled|default)/i.test(out)) throw new Error((out || '').trim() || '启用失败');
  return out;
}

// 用 exec: 服务跑一条命令并往其 stdin 写二进制（必须 exec:，shell: 会套 PTY 改坏字节）
async function shellWriteBytes(cmd, bytes) {
  const a = requireAdb();
  const sock = await a.createSocket('exec:' + cmd);
  try {
    const w = sock.writable.getWriter();
    await w.write(bytes);
    try { await w.close(); } catch {}
    const out = await collect(sock.readable);
    return new TextDecoder().decode(out);
  } finally { try { await sock.close(); } catch {} }
}

// 用 adb sync 把整段字节写到设备文件（obb 用；obb 必须落存储）
async function pushBytes(path, bytes, mtimeSec) {
  const a = requireAdb();
  const sync = await a.sync();
  try {
    const rs = new ReadableStream({ start(c) { c.enqueue(bytes); c.close(); } });
    await sync.write({ filename: path, file: rs, permission: 0o644, mtime: mtimeSec || Math.floor(Date.now() / 1000) });
  } finally { try { await sync.dispose(); } catch {} }
}

// ── ABI 预检：在把 APK 传给盒子之前先判断架构兼容性（32 位系统装 64 位包等）──
const KNOWN_ABIS = ['arm64-v8a', 'armeabi-v7a', 'armeabi', 'x86', 'x86_64', 'riscv64'];
const ABI_LABEL = {
  'arm64-v8a': '64 位 ARM（arm64-v8a）',
  'armeabi-v7a': '32 位 ARM（armeabi-v7a）',
  armeabi: '32 位 ARM（armeabi）',
  x86_64: '64 位 x86',
  x86: '32 位 x86',
  riscv64: 'RISC-V 64',
};
const abiLabel = a => ABI_LABEL[a] || a;

// 扫描 apk 字节里的 zip 条目名（不解压内容），收集它需要的 native ABI。
// 信号来源：lib/<abi>/ 目录、config.<abi>.apk split 文件名。
// 返回 Set（可能为空=无 native 代码）；包结构读不出来时返回 null（不拦截，交给设备裁决）。
export function apkRequiredAbis(bytes) {
  const found = new Set();
  try {
    unzipSync(bytes, { filter: f => {
      const n = f.name || '';
      if (n.startsWith('lib/')) {
        const d = n.split('/')[1];
        if (d && KNOWN_ABIS.includes(d)) found.add(d);
      }
      const cm = n.match(/(?:^|\/)config\.([a-z0-9_]+)\.apk$/i);
      if (cm) {
        const a = cm[1].replace(/_/g, '-');
        if (KNOWN_ABIS.includes(a)) found.add(a);
      }
      return false; // 只读目录，不 inflate 任何文件
    } });
  } catch { return null; }
  return found;
}

// 纯判断：required=包需要的 ABI 集合，deviceAbis=设备 abilist。
// 只要有一个 ABI 能对上就放行（universal 包在 32 位机可装）；完全对不上才拦。
export function decideAbiCompat(required, deviceAbis) {
  if (!required || !required.size) return { ok: true };
  if (!deviceAbis || !deviceAbis.length) return { ok: true };
  if ([...required].some(a => deviceAbis.includes(a))) return { ok: true };
  const is32Only = !deviceAbis.includes('arm64-v8a') && deviceAbis.some(a => a === 'armeabi-v7a' || a === 'armeabi');
  if (required.size === 1 && required.has('arm64-v8a') && is32Only) {
    return { ok: false, msg: '这个安装包是 64 位（arm64）版本，你的盒子是 32 位系统，装不了。请下载页面里标着「armeabi-v7a / 32 位」的版本' };
  }
  return { ok: false, msg: `架构不匹配：安装包需要 ${[...required].map(abiLabel).join(' 或 ')}，而盒子只支持 ${deviceAbis.map(abiLabel).join(' / ')}，无法安装` };
}

// 安装前统一预检（拿不到设备 abilist 时不拦截，避免误报）
async function checkAbiCompat(apks) {
  const required = new Set();
  for (const p of apks) {
    const a = apkRequiredAbis(p.bytes);
    if (!a) return; // 有包读不了结构：放行
    a.forEach(x => required.add(x));
  }
  if (!required.size) return;
  let deviceAbis = [];
  try {
    deviceAbis = (await shell('getprop ro.product.cpu.abilist')).trim().split(',').map(s => s.trim()).filter(Boolean);
  } catch { return; }
  const d = decideAbiCompat(required, deviceAbis);
  if (!d.ok) throw new Error(d.msg);
}

// 解析安装包 → { apks:[{name,bytes}], obbs:[{name,pkg,bytes}] }
async function parsePackage(file) {
  const lower = (file.name || '').toLowerCase();
  if (lower.endsWith('.apk')) {
    return { apks: [{ name: file.name, bytes: new Uint8Array(await file.arrayBuffer()) }], obbs: [] };
  }
  if (lower.endsWith('.xapk') || lower.endsWith('.apkm') || lower.endsWith('.apks') || lower.endsWith('.zip')) {
    const zip = unzipSync(new Uint8Array(await file.arrayBuffer()));
    let manifestPkg = '';
    if (zip['manifest.json']) { try { manifestPkg = JSON.parse(new TextDecoder().decode(zip['manifest.json'])).pkg || ''; } catch {} }
    const apks = [], obbs = [];
    for (const [k, v] of Object.entries(zip)) {
      const lk = k.toLowerCase();
      if (lk.endsWith('.apk')) apks.push({ name: k.split('/').pop(), bytes: v });
      else if (lk.endsWith('.obb')) {
        const base = k.split('/').pop();
        const pkg = manifestPkg || (base.match(/\.(.+)\.obb$/) || [])[1] || '';
        obbs.push({ name: base, bytes: v, pkg });
      }
    }
    return { apks, obbs };
  }
  throw new Error('不支持的文件类型（仅 .apk / .xapk / .apkm / .apks）');
}

// ── 安装：APK/XAPK/APKM/APKS，split + obb，流式（APK 不落地，pm install-create/write/commit）──
export async function installFile(file, onProgress) {
  const { apks, obbs } = await parsePackage(file);
  if (!apks.length) throw new Error((file.name || '包') + ' 里没有可安装的 .apk');
  await checkAbiCompat(apks);   // 传输前预检：32 位盒子装 64 位包等，直接用人话拦截
  // base 优先（简单启发式；install-write 一个会话内可含多 split）
  apks.sort((x, y) => (/base/i.test(x.name) ? 0 : 1) - (/base/i.test(y.name) ? 0 : 1));

  const total = apks.reduce((s, p) => s + p.bytes.length, 0) + obbs.reduce((s, o) => s + o.bytes.length, 0);
  let done = 0;
  const tick = n => { done += n; onProgress && onProgress(done, total); };
  const fail = t => /fail|error|exception/i.test(t) && !/success/i.test(t);

  const create = await shell('pm install-create -r');
  const m = create.match(/\[(\d+)\]/);
  if (!m) throw new Error('创建安装会话失败：' + create.trim());
  const sid = m[1];

  try {
    for (const p of apks) {
      const res = await shellWriteBytes(`pm install-write -S ${p.bytes.length} ${sid} ${p.name}`, p.bytes);
      tick(p.bytes.length);
      if (fail(res)) throw new Error('写入 ' + p.name + ' 失败：' + res.trim());
    }
    for (const o of obbs) {
      if (!o.pkg) continue;
      const dir = `/sdcard/Android/obb/${o.pkg}`;
      await shell(`mkdir -p ${dir}`);
      await pushBytes(`${dir}/${o.name}`, o.bytes);
      tick(o.bytes.length);
    }
    const commit = await shell(`pm install-commit ${sid}`);
    if (fail(commit)) throw new Error('提交安装失败：' + commit.trim());
    onProgress && onProgress(total, total);
    return (file.name || '包') + ' 安装完成';
  } catch (e) {
    shell(`pm install-abandon ${sid}`).catch(() => {});
    throw e;
  }
}

// ── 截图：先写设备文件再 sync 读回，避免 shell PTY 把二进制 \r\n 改坏 ──
export async function screenshot() {
  const a = requireAdb();
  const tmp = '/data/local/tmp/boxadb-shot.png';
  await shell(`screencap -p ${tmp}`);
  try {
    const sync = await a.sync();
    try { const bytes = await collect(sync.read(tmp)); return new Blob([bytes], { type: 'image/png' }); }
    finally { try { await sync.dispose(); } catch {} }
  } finally {
    // 无论成功/失败都删除盒子上的临时截图，避免占用存储
    try { await shell(`rm -f ${tmp}`); } catch {}
  }
}

// 取某个包的 base.apk 绝对路径（抽 manifest/arsc/图标文件用）
export async function baseApkPath(pkg) {
  const out = await shell(`pm path ${pkg}`);
  return (out || '').split('\n').map((s) => s.trim().replace(/^package:/, '')).find((s) => /base\.apk$/.test(s)) || null;
}

// 读设备上某个绝对路径文件的原始字节（复用截图同款 sync.read 二进制通道），返回 Uint8Array
export async function readFileBytes(devPath) {
  const a = requireAdb();
  const sync = await a.sync();
  try { return await collect(sync.read(devPath)); }
  finally { try { await sync.dispose(); } catch {} }
}

// 在设备上解析 APK(zip) 成员路径，返回“候选图标列表”（按分数降序，最多 8 个），供调用方逐个试抽。
// 每个 apk 的候选各自打分打印「score⇥apk⇥name」，外层 sort -rn 全局排序（跨 base 与 split）。
// 打分：base 仅作平手微加(+2)；ic_launcher/app_icon 精确名(+10)；banner 是 TV 宽幅图，不当方形图标重罚(-12)；
// 前景/背景层罚(-15)；密度靠近 xhdpi/xxhdpi 加分。返回 [{apk,member}, ...]（无则空数组）。
export async function pickIconMembers(pkg) {
  const script =
    "for f in $(pm path " + pkg + " | tr -d '\\r' | sed 's/^package://'); do " +
    "unzip -l \"$f\" 2>/dev/null | grep -E 'res/(mipmap|drawable)[^ ]*/.*\\.(png|webp)$' | awk -v A=\"$f\" " +
    "'{n=$NF;split(n,pp,\"/\");b=pp[length(pp)];s=(A ~ /base\\.apk$/)?2:0;" +
    "if(n ~ /\\/mipmap/)s=s+3;" +
    "if(b ~ /^(ic_launcher|app_icon|ic_app|icon)\\.(png|webp)$/)s=s+12;else if(b ~ /launcher|app_icon/)s=s+8;" +
    "if(b ~ /banner/)s=s-12;if(b ~ /(foreground|background|_fg|_bg)/)s=s-15;" +
    "if(b ~ /facebook|notify|notification|abc_|ic_star|button|splash|panel|share|send|search|ic_menu|spinner|progress|checkbox|radiobutton|textfield|textfield/)s=s-25;" +
    "d=-1;if(n ~ /xxxhdpi/)d=5;else if(n ~ /xxhdpi/)d=4;else if(n ~ /xhdpi/)d=3;else if(n ~ /tvdpi/)d=3;else if(n ~ /hdpi/)d=2;else if(n ~ /mdpi/)d=1;" +
    "if(d==3||d==4)s=s+8;else if(d==5)s=s+3;else if(d==2)s=s+4;else if(d==1)s=s+1;s=s+$1/1000000;" +
    "print s\"\\t\"A\"\\t\"n}' ; done | sort -rn | head -8";
  const out = await shell(script);
  const list = [];
  for (const line of (out || '').split('\n')) {
    const parts = line.trim().split('\t');
    if (parts.length >= 3 && parts[2]) list.push({ apk: parts[1], member: parts[2] });
  }
  return list;
}

// 从 APK 里抽取指定成员字节：设备上 unzip -p 落到唯一临时文件 → sync.read 回传 → rm。
// 走“设备落地文件 + sync 二进制读”，二进制不经过 shell stdout，规避 PTY/换行破坏。
// tmp 必须每次唯一：懒加载并发=2，共用固定名会交叉读写导致“串图标”。
let _icSeq = 0;
export async function extractZipMember(apkPath, memberPath) {
  const tmp = '/data/local/tmp/boxadb-ic-' + Date.now().toString(36) + '-' + (_icSeq++).toString(36) + '.tmp';
  try {
    await shell(`unzip -p '${apkPath}' '${memberPath}' > '${tmp}' 2>/dev/null; :`);
    const bytes = await readFileBytes(tmp);
    return (bytes && bytes.length) ? bytes : null;
  } finally {
    try { await shell(`rm -f '${tmp}'`); } catch {}
  }
}

export async function reboot(mode = '') {
  const a = requireAdb();
  if (!mode) { await shell('reboot'); return; }
  if (!/^[a-z]+$/.test(mode)) throw new Error('非法的重启模式');
  const sock = await a.createSocket('reboot:' + mode);
  try { await sock.close(); } catch {}
}

// ── 设备信息（含 CPU / 架构 / 分辨率的取数逻辑）──────
export async function fetchDevice(ip) {
  const gp = async k => (await shell('getprop ' + k)).trim();
  const safe = async (fn, dflt) => { try { return await fn(); } catch { return dflt; } };

  const brand = (await safe(async () => gp('ro.product.brand'), '')) || (await safe(async () => gp('ro.product.manufacturer'), '')) || '未知';
  const model = (await safe(async () => gp('ro.product.model'), '')) || '未知';
  const release = await safe(async () => gp('ro.build.version.release'), '');
  const sdk = await safe(async () => gp('ro.build.version.sdk'), '');
  const abilist64 = await safe(async () => gp('ro.product.cpu.abilist64'), '');
  const arch = abilist64 ? '64 位' : '32 位';
  let cpu = await safe(async () => gp('ro.soc.model'), '');
  if (!cpu) cpu = await safe(() => detectCpuFromDts(), '未知');
  cpu = prettyCpu(cpu) || '未知';   // soc.model 原始串（如 AMLS905X5M）也走厂商美化
  let resolution = '未知';
  const resM = (await safe(async () => shell('wm size'), '')).match(/(\d+)x(\d+)/); if (resM) resolution = `${resM[1]} × ${resM[2]}`;
  const osName = release ? `Android ${release}${sdk ? '（SDK ' + sdk + '）' : ''}` : '未知';

  // 存储
  let storageText = '—', storagePct = 0;
  await safe(async () => {
    // 优先 dumpsys diskstats（A11+ 非 root 也能读），失败再回退 df
    let p = parseDiskstats(await shell('dumpsys diskstats 2>/dev/null'));
    if (!p) p = parseDf(await shell('df /data 2>/dev/null || df /data/media 2>/dev/null || df'));
    if (p) { storageText = `已用 ${fmtKB(p.used)} / 共 ${fmtKB(p.total)}（剩 ${fmtKB(p.avail)}）`; storagePct = p.pct; }
  }, null);

  // 内存
  let mem = '—';
  await safe(async () => {
    const m = parseMeminfo(await shell('cat /proc/meminfo'));
    if (m) mem = `可用 ${fmtKB(m.avail)} / 共 ${fmtKB(m.total)}`;
  }, null);

  // 已装第三方应用数
  let appCount = '—';
  await safe(async () => {
    const n = (await shell('pm list packages -3')).split('\n').filter(l => l.startsWith('package:')).length;
    appCount = n + ' 个';
  }, null);

  // 运行时长
  let uptime = '—';
  await safe(async () => {
    const s = parseFloat((await shell('cat /proc/uptime')).trim().split(/\s+/)[0]);
    if (Number.isFinite(s)) uptime = fmtUptime(s);
  }, null);

  // GPU（多来源兜底：GLES/Vulkan 行 → ro.hardware.vulkan/egl 家族）
  let gpu = '未知';
  await safe(async () => {
    let name = parseGpu(await shell('dumpsys SurfaceFlinger 2>/dev/null | grep -iE "GLES:|Vulkan:" | head -1'));
    if (!name) {
      const fam = (await gp('ro.hardware.vulkan')) || (await gp('ro.hardware.egl')) || '';
      const f = fam.toLowerCase();
      if (/mali|bifrost|valhall|panfrost/.test(f)) name = 'Mali' + (f !== 'mali' ? ` (${fam})` : '');
      else if (/adreno/.test(f)) name = 'Adreno' + (f !== 'adreno' ? ` (${fam})` : '');
      else if (/powervr|pvrusd|rogue/.test(f)) name = 'PowerVR';
      else if (fam) name = fam;
    }
    if (name) gpu = name;
  }, null);

  return { brand, model, android: osName, cpu, arch, resolution,
           gpu, mem, appCount, uptime, storageText, storagePct,
           addr: `${ip}:${DEFAULT_PORT}` };
}

// —— 标准 Android 输出的解析/格式化（防御式）——
function tokKB(t){ const m=t.match(/^(\d+(?:\.\d+)?)([KMGT]?)B?$/i); if(!m) return null;
  const mult={ '':1,K:1,M:1024,G:1048576,T:1073741824 }[m[2].toUpperCase()]; return Math.round(parseFloat(m[1])*mult); }
function parseDf(out){
  for(const raw of (out||'').split('\n')){ const line=raw.trim(); if(!line||/Filesystem/i.test(line)) continue;
    const tk=line.split(/\s+/); const kb=tk.map(tokKB).filter(x=>x!=null&&x>0); const pm=tk.find(t=>/^\d+%$/.test(t));
    if(kb.length>=3){ const [total,used,avail]=kb; const pct=pm?parseInt(pm):Math.round(used/total*100); return {total,used,avail,pct}; } }
  return null; }
function parseDiskstats(out){ const f=(out||'').match(/Data-Free:\s*(\d+)/); const t=(out||'').match(/Data-Total:\s*(\d+)/);
  if(!f||!t) return null; const totalB=+t[1], freeB=+f[1], usedB=Math.max(0,totalB-freeB);
  return { total:Math.round(totalB/1024), used:Math.round(usedB/1024), avail:Math.round(freeB/1024), pct: totalB?Math.round(usedB/totalB*100):0 }; }
function parseMeminfo(out){
  const v={}; for(const line of (out||'').split('\n')){ const m=line.match(/^(\w+):\s+(\d+) kB/); if(m) v[m[1]]=+m[2]; }
  if(!v.MemTotal) return null;
  const avail = v.MemAvailable != null ? v.MemAvailable : (v.MemFree||0)+(v.Buffers||0)+(v.Cached||0);
  return { total:v.MemTotal, avail }; }
function fmtKB(kib){ if(!Number.isFinite(kib)||kib<=0) return '—';
  if(kib>=1048576) return (kib/1048576).toFixed(kib>=10485760?0:1)+' GB';
  if(kib>=1024) return Math.round(kib/1024)+' MB'; return kib+' KB'; }
function fmtUptime(sec){ const d=Math.floor(sec/86400),h=Math.floor(sec%86400/3600),m=Math.floor(sec%3600/60);
  if(d>0) return `${d} 天 ${h} 小时`; if(h>0) return `${h} 小时 ${m} 分`; return `${m} 分钟`; }
function parseGpu(out){ const m=(out||'').match(/(?:GLES|Vulkan):\s*(.+)/i); if(!m) return '';
  const parts=m[1].split(',').map(s=>s.trim()).filter(Boolean); return parts[1]||parts[0]||''; }

async function detectCpuFromDts() {
  // 盒子最靠谱：/proc/device-tree/compatible 里常有 amlogic,s905x5m 这类
  let raw = '';
  try { raw = (await shell(`cat /proc/device-tree/compatible 2>/dev/null | tr '\\0' ' '`)).trim(); } catch {}
  if (!raw) { try { raw = (await shell('getprop ro.board.platform')).trim(); } catch {} }
  return prettyCpu(raw);
}
function prettyCpu(s) {
  if (!s) return '未知';
  // 覆盖各厂商原始形态：AMLS905X5M / amlogic,s905x5m / Amlogic S905X5M（幂等）
  let m = s.match(/(?:amlogic|aml)[\s,-]*(s\d{3,4}[a-z0-9]*)/i);
  if (m) return 'Amlogic ' + m[1].toUpperCase();
  m = s.match(/^mt(\d+)/i); if (m) return 'MediaTek MT' + m[1];           // mt8695 → MediaTek MT8695
  m = s.match(/(rockchip|rk)(\w+)/i); if (m) return 'Rockchip ' + m[2].toUpperCase();
  m = s.match(/(allwinner|sun\d+[a-z]*)/i); if (m) return 'Allwinner ' + (m[1] || '').toUpperCase();
  m = s.match(/(qcom|msm\d+\w*)|(sm\d{3}\w*)|(sdm\d+\w*)/i);
  if (m) return 'Qualcomm ' + (m[2] || m[3] || m[1] || '').toUpperCase();
  return s;
}

// ── 交互 PTY（供 xterm 终端）；返回 pty：有 .output/.input 流、resize(rows,cols)、exited、kill ──
export async function openPty() {
  const a = requireAdb();
  return a.subprocess.shellProtocol.pty({ terminalType: 'xterm-256color' });
}

function withTimeout(promise, ms, msg) {
  return Promise.race([promise, new Promise((_, rej) => setTimeout(() => rej(new Error(msg)), ms))]);
}
