// 受控浏览器（cdp-page-control）适配：读登录 cookie / UA、拉起点、等扫码。
// 只做转发，不放业务判断；cookie 的筛选与登录成功判定在调用方。
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { fail } from './render.mjs';

// The controlled browser is an optional external capability.  WEREAD_CDP_CHANNEL
// names a cdp-channel.mjs; the default is the one this machine's Pi skills install.
// Cookie login and every read-only command work without it.
const channelPath = () => process.env.WEREAD_CDP_CHANNEL
  || path.join(os.homedir(), '.pi', 'agent', 'shared', 'skills', 'cdp-page-control', 'scripts', 'cdp-channel.mjs');
const WEREAD_SUFFIX = 'weread.qq.com';

const sleep = (ms) => new Promise(resolve => { setTimeout(resolve, ms); });

async function loadChannel() {
  const channel = channelPath();
  if (!fs.existsSync(channel)) {
    fail('deps', `找不到受控浏览器的 CDP 通道：${channel}`,
         '设置 WEREAD_CDP_CHANNEL 指向 cdp-channel.mjs；只读书架与笔记不需要受控浏览器');
  }
  return import(pathToFileURL(channel).href);
}

/** 受控浏览器版本信息；没在跑返回 null。 */
export async function browserVersion() {
  const channel = await loadChannel();
  return channel.version().catch(() => null);
}

/** 读受控浏览器里 weread.qq.com 的 cookie（含 HttpOnly 值）+ 浏览器 UA；没在跑返回 null。 */
export async function readBrowserAuth() {
  const channel = await loadChannel();
  const version = await channel.version().catch(() => null);
  if (!version) return null;
  const cdp = await channel.connectBrowser();
  let cookies = [];
  try {
    ({ cookies } = await cdp.send('Storage.getCookies', {}, { timeoutMs: 20000 }));
  } finally {
    cdp.close();
  }
  const jar = {};
  for (const cookie of cookies || []) {
    const host = String(cookie.domain ?? '').replace(/^\./, '').toLowerCase();
    if (host.endsWith(WEREAD_SUFFIX) && !(cookie.name in jar)) jar[cookie.name] = cookie.value;
  }
  return { cookies: jar, ua: String(version['User-Agent'] ?? '').trim() };
}

/** 登录成功的判据：拿到微信读书的身份与会话 cookie。 */
export const isLoggedInJar = (jar = {}) => Boolean(jar.wr_vid && jar.wr_skey);

/** 受控浏览器里属于微信读书的页面。 */
async function wereadPages() {
  const channel = await loadChannel();
  const pages = await channel.listTargets().catch(() => []);
  return (pages || []).filter(t => t.type === 'page' && String(t.url || '').includes(WEREAD_SUFFIX));
}

/**
 * 拉起点（幂等）：控制端是 cdp-page-control 的 launch 原语。
 * 直接调 cdp-channel 的 JS 函数，不经过命令行壳——
 * Windows 上那个壳是 .cmd，Node 的 spawnSync 执行不了（ENOENT）。
 * 浏览器已在跑且有微信读书页面时只复用，不再新开标签。
 */
export async function launchBrowser(url = 'https://weread.qq.com/') {
  if ((await wereadPages().catch(() => [])).length) return true;
  const channel = await loadChannel();
  try {
    await channel.launch({ url });
    return true;
  } catch {
    return false;
  }
}

/**
 * 让页面上出现一张可扫的二维码：新开一个干净的微信读书标签页，点「登录」拉出扫码弹层。
 * 三条实测教训（都不走）：
 *   ① 复用已开弹层的页面 →「登录」是 toggle，再点会把它关掉；
 *   ② 重设已存在 qrconnect iframe 的 src 想「刷新」→ 会话与 ts 参数绑定，改了会立刻判失效；
 *   ③ 页面刚打开就点 → SPA 未就绪，点击落空；点完要验证弹层真的出现，没出现再点（最多 3 次）。
 * 弹层就绪后把页面标题改成「【请用微信扫码】微信读书登录」——受控浏览器里常同时开着
 * 多个同名订阅页，用户要靠标题一眼找到该扫哪一页。
 * 打开失败返回 false（调用方给提示）。
 */
export async function openLoginPanel() {
  const channel = await loadChannel();
  let cdp = null;
  try {
    const tab = await channel.openTab('https://weread.qq.com/');
    ({ cdp } = await channel.connectPage(undefined, tab.id));
    const qrVisible = () => channel.evaluate(cdp, `(() => {
      const qr = [...document.querySelectorAll('iframe')].find(f => String(f.src || '').includes('qrconnect'));
      if (!qr) return false;
      const rect = qr.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    })()`, { timeoutMs: 5000 }).catch(() => false);
    const markPageTitle = () => channel
      .evaluate(cdp, `document.title = '【请用微信扫码】微信读书登录'`, { timeoutMs: 5000 })
      .catch(() => {}); // 标题只是给用户指路，失败不影响登录
    for (let attempt = 0; attempt < 3; attempt += 1) {
      if (await qrVisible()) {
        await markPageTitle();
        return true;
      }
      const box = await channel.waitForElement(cdp, 'text=登录', 15000, 250);
      await channel.clickAt(cdp, box);
      await new Promise(resolve => setTimeout(resolve, 3000));
    }
    if (await qrVisible()) {
      await markPageTitle();
      return true;
    }
    return false;
  } catch {
    return false;
  } finally {
    if (cdp) cdp.close();
  }
}

/** 等扫码完成：轮询受控浏览器 cookie，直到 wr_vid + wr_skey 出现。 */
export async function waitForBrowserLogin({ timeoutMs = 180000, pollMs = 2500 } = {}) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const found = await readBrowserAuth().catch(() => null);
    if (found && isLoggedInJar(found.cookies)) return found;
    if (Date.now() >= deadline) return null;
    await sleep(pollMs);
  }
}
