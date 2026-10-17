// 把官方网页阅读器的位置驱动到指定章节；这是进度写回账号的唯一可行路径。
//
// 为什么不用 HTTP：阅读器上报进度的写接口 POST /web/book/read 要求它自己的签名
// （字段 s 与请求头 x-wrpa-0，由页面上的 Tencent CHAOS VM 生成）；把抓到的请求用
// cookie 重放会被服务端静默丢弃（实测：HTTP 200 返回 {}，书架进度不动）。
// 官方阅读器在「打开目录跳章」或「翻页」时会自己上报，账号进度随即更新，所以这里
// 借受控浏览器替账号点这几下。
//
// 协议（维护者与测试用）：
//   输入 { enc, title, pages, timeoutMs }
//   步骤 确保受控浏览器在跑 → 新开阅读器标签页 → 等页面就绪 → 打开目录 →
//        点标题匹配到的章节 →（可选）向后翻 pages 页 → 关闭标签页
//   输出 { steps: [...] }；挑不到章节、浏览器不可用等以 SkillError 抛出。
// 测试：WEREAD_SYNC_FAKE=<json 文件> 时不碰浏览器，按文件内容回话（{ok:false,code,message}
//       可模拟失败）；WEREAD_SYNC_FAKE_LOG=<文件> 时把收到的请求追加进去，供断言参数。
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { SkillError, fail } from './render.mjs';
import { cliCommand } from './cli.mjs';

// The controlled browser is an optional external capability.  WEREAD_CDP_CHANNEL
// names a cdp-channel.mjs; the default is the one this machine's Pi skills install.
// Cookie login and every read-only command work without it.
const channelPath = () => process.env.WEREAD_CDP_CHANNEL
  || path.join(os.homedir(), '.pi', 'agent', 'shared', 'skills', 'cdp-page-control', 'scripts', 'cdp-channel.mjs');
const CATALOG_BUTTON = 'button.readerControls_item.catalog';
const CATALOG_ITEM = '.readerCatalog_list_item';
const CHAPTER_MARK = 'data-weread-sync-chapter';
const NEXT_MARK = 'data-weread-sync-next';
const PAGER_BUTTON = 'button.renderTarget_pager_button';
const sleep = ms => new Promise(resolve => { setTimeout(resolve, ms); });
const debug = (...args) => { if (process.env.WEREAD_SYNC_DEBUG) console.error('[reader-sync]', ...args); };

async function loadChannel() {
  const channel = channelPath();
  if (!fs.existsSync(channel)) {
    fail('deps', `找不到受控浏览器的 CDP 通道：${channel}`,
      '设置 WEREAD_CDP_CHANNEL 指向 cdp-channel.mjs；只读书架与笔记不需要受控浏览器');
  }
  return import(pathToFileURL(channel).href);
}

// 与 find/book 命令同一套归一化：目录项还带着「当前读到 x%」「书签」等尾巴。
const normalized = value => String(value ?? '')
  .normalize('NFKC')
  .replace(/[（(《【\[][^）)】\]》]*[）)】\]》]/g, ' ')
  .replace(/[\s·．.,，。:：;；!！?？'"“”‘’\-—_/\\|]+/g, '')
  .toLowerCase();

/** 在目录里找到标题匹配的章节项并打标；返回它的文本或 null。 */
const markChapterExpr = title => `(() => {
  const want = ${JSON.stringify(normalized(title))};
  const strip = value => String(value ?? '')
    .normalize('NFKC')
    .replace(/[（(《【\\[][^）)】\\]》]*[）)】\\]》]/g, ' ')
    .replace(/[\\s·．.,，。:：;；!！?？'"“”‘’\\-—_/\\\\|]+/g, '')
    .toLowerCase()
    .replace(/当前读到.*$|书签/g, '');
  const items = [...document.querySelectorAll(${JSON.stringify(CATALOG_ITEM)})];
  const hit = items.find(item => {
    const text = strip(item.textContent);
    return want && (text === want || text.startsWith(want));
  });
  if (!hit) return null;
  items.forEach(item => item.removeAttribute(${JSON.stringify(CHAPTER_MARK)}));
  hit.setAttribute(${JSON.stringify(CHAPTER_MARK)}, '1');
  return hit.textContent.trim().slice(0, 60);
})()`;

/** 给右侧「下一页」按钮打标；页面没有分页按钮时返回 false。 */
const markNextPageExpr = `(() => {
  const buttons = [...document.querySelectorAll(${JSON.stringify(PAGER_BUTTON)})]
    .filter(button => {
      const rect = button.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0 && rect.x + rect.width / 2 > innerWidth / 2;
    });
  const hit = buttons[buttons.length - 1];
  if (!hit) return false;
  hit.setAttribute(${JSON.stringify(NEXT_MARK)}, '1');
  return true;
})()`;

async function driveFake(request) {
  const plan = JSON.parse(fs.readFileSync(process.env.WEREAD_SYNC_FAKE, 'utf8'));
  if (process.env.WEREAD_SYNC_FAKE_LOG) {
    fs.appendFileSync(process.env.WEREAD_SYNC_FAKE_LOG, `${JSON.stringify(request)}\n`);
  }
  if (plan.ok === false) {
    throw new SkillError(plan.code ?? 'external', plan.message ?? '假阅读器拒绝了这次驱动', { hint: plan.hint ?? '' });
  }
  return { steps: ['fake-drive', ...(plan.steps ?? [])] };
}

/**
 * 把阅读器驱动到 TITLE 对应的章节；可选再向后翻 PAGES 页。
 * ENC 是阅读器地址里的书标识（书籍接口的 deepLink v=…），TITLE 是云目录里的章节名。
 */
export async function driveReaderToChapter({ enc, title, pages = 0, timeoutMs = 30000 } = {}) {
  const request = { enc, title, pages };
  if (process.env.WEREAD_SYNC_FAKE) return driveFake(request);
  const channel = await loadChannel();
  const steps = [];
  const running = await channel.version().catch(() => null);
  if (!running) {
    await channel.launch({});
    steps.push('launch-browser');
  }
  const url = `https://weread.qq.com/web/reader/${encodeURIComponent(enc)}`;
  // 后台新窗口：background 保证不抢前台焦点（实测 lsappinfo front 不变），
  // newWindow 让页面即使 visibility=hidden 也照常渲染——同一个窗口里的后台标签页
  // 点不动目录面板（CSS 动画被节流），所以两者都要。
  const browser = await channel.connectBrowser();
  let tabId = null;
  try {
    const created = await browser.send('Target.createTarget', { url, background: true, newWindow: true }, { timeoutMs: 15000 });
    tabId = created?.targetId ?? null;
  } finally {
    browser.close();
  }
  if (!tabId) fail('deps', '受控浏览器没有返回新标签页', '看受控浏览器是否在运行（cdp-channel 的 status）后重试');
  steps.push(`open-reader:${tabId}`);
  const { cdp } = await channel.connectPage(null, tabId);
  try {
    const ready = await channel.evaluate(cdp, 'document.readyState', { timeoutMs: 10000 }).catch(() => null);
    if (ready === 'loading') await channel.waitLoad(cdp, timeoutMs);
    // 目录按钮在书还在恢复进度时点击可能被重渲染吃掉；一次点击不算数，
    // 「查面板状态 → 没开就再点」直到目录真的展开。
    const catalogOpenExpr = `(() => { const item = document.querySelector(${JSON.stringify(CATALOG_ITEM)}); if (!item) return false; const rect = item.getBoundingClientRect(); return rect.width > 0 && rect.height > 0; })()`;
    const catalogDeadline = Date.now() + Math.min(timeoutMs, 25000);
    let catalogOpen = false;
    for (;;) {
      catalogOpen = await channel.evaluate(cdp, catalogOpenExpr, { timeoutMs: 8000 }).catch(() => false);
      if (catalogOpen) break;
      if (Date.now() >= catalogDeadline) break;
      const catalog = await channel.waitForElement(cdp, CATALOG_BUTTON, Math.min(timeoutMs, 10000));
      await channel.clickAt(cdp, catalog);
      await sleep(800);
    }
    if (!catalogOpen) {
      throw new SkillError('notfound', '阅读器目录打不开', { hint: '在受控浏览器里手动打开这本书，确认目录按钮可用后重试' });
    }
    steps.push('open-catalog');
    // 目录刚展开时阅读器还会重渲染（恢复进度等），打上的标记可能被冲掉，
    // 所以每次重新标记并确认可点，再真正点击。
    const deadline = Date.now() + Math.min(timeoutMs, 20000);
    let marked = null;
    for (;;) {
      const found = await channel.evaluate(cdp, markChapterExpr(title), { timeoutMs: 10000 });
      debug('mark attempt', JSON.stringify(found));
      if (found) {
        const rect = await channel.evaluate(cdp, channel.visibleRectExpr(`[${CHAPTER_MARK}]`), { timeoutMs: 5000 });
        debug('mark rect', JSON.stringify(rect));
        if (rect && rect.inView !== false) {
          await channel.clickAt(cdp, rect);
          marked = found;
          break;
        }
      }
      if (Date.now() >= deadline) break;
      await sleep(400);
    }
    if (!marked) {
      throw new SkillError('notfound', `阅读器目录里没有可点击的《${title}》这一章`,
        { hint: `换个 --chapter-title（照 ${cliCommand()} book 的目录写），或改用 --percent` });
    }
    steps.push(`jump-chapter:${marked}`);
    for (let index = 0; index < pages; index += 1) {
      const markedNext = await channel.evaluate(cdp, markNextPageExpr, { timeoutMs: 10000 }).catch(() => false);
      if (!markedNext) break;
      await channel.clickAt(cdp, await channel.waitForElement(cdp, `[${NEXT_MARK}]`, 10000));
      await channel.evaluate(cdp, `document.querySelector('[${NEXT_MARK}]')?.removeAttribute('${NEXT_MARK}')`, { timeoutMs: 5000 }).catch(() => {});
      steps.push(`turn-page:${index + 1}`);
      await sleep(700);
    }
    // 阅读器的进度上报有节流；点完先让页面把这次跳转报出去，再关窗口。
    await sleep(2500);
    return { steps };
  } finally {
    // 阅读器在跳章/翻页时已经上报；关掉这次开的标签页，别给自动化浏览器留残余页面。
    await channel.httpJson(`/json/close/${tabId}`).catch(() => {});
  }
}
