// 本地书 ↔ 微信读书书籍的绑定台账，以及书名/章节名的归一化匹配。
// 台账是「这本本地文件读的是账号里的哪本书」的唯一权威：进度写回与划线叠加都先查它；
// 没有绑定时调用方才回退到书名匹配。数据在本机私有目录，不进共享仓库。
import fs from 'node:fs';
import path from 'node:path';
import { dataDir, loadVersioned, saveVersioned } from './store.mjs';

export const BINDINGS_VERSION = 1;

export const bindingsPath = () => path.join(dataDir(), 'bindings.json');

/** 读台账；文件不存在是空台账，读坏了就报错（不猜、不覆盖）。 */
export function loadBindings() {
  const state = loadVersioned(bindingsPath(), { version: BINDINGS_VERSION });
  if (state.error === 'newer') {
    throw new Error(`绑定台账由更新版本的 etaf-weread 写过（版本 ${state.from}）：${bindingsPath()}。升级包，或备份后删除该文件重建。`);
  }
  if (state.error) {
    throw new Error(`绑定台账读不出来：${bindingsPath()}（${state.error}${state.message ? `: ${state.message}` : ''}）`);
  }
  const stored = state.data?.bindings;
  return (stored && typeof stored === 'object' && !Array.isArray(stored)) ? { ...stored } : {};
}

export function saveBindings(bindings) {
  return saveVersioned(bindingsPath(), { bindings }, { version: BINDINGS_VERSION });
}

export const bindingKey = file => path.resolve(String(file));

/** 这条本地文件的绑定，或 null。 */
export const getBinding = file => loadBindings()[bindingKey(file)] ?? null;

/** 记一条绑定并回读生效值（写台账的调用方用它对外报告）。 */
export function setBinding(file, entry) {
  const bindings = loadBindings();
  const key = bindingKey(file);
  bindings[key] = { ...entry, boundAt: new Date().toISOString() };
  saveBindings(bindings);
  return { file: key, entry: getBinding(key) };
}

/** 删一条绑定；返回它原来是否存在。 */
export function removeBinding(file) {
  const bindings = loadBindings();
  const key = bindingKey(file);
  const existed = Object.hasOwn(bindings, key);
  delete bindings[key];
  saveBindings(bindings);
  return existed;
}

// 归一化去掉「怎么拿到这本书」的噪音：全角半角、括号注记（作者/来源/版本），
// 再压掉空白与标点，只留可比的核心书名。
export const normalizeTitle = value => String(value ?? '')
  .normalize('NFKC')
  .replace(/[（(《【\[][^）)】\]》]*[）)】\]》]/g, ' ')
  .replace(/z-?library|epub|mobi|azw3|pdf|txt/gi, ' ')
  .replace(/[\s·．.,，。:：;；!！?？'"“”‘’\-—_/\\|]+/g, '')
  .toLowerCase();

export const LOCAL_EXTENSIONS = ['.epub', '.pdf', '.mobi', '.azw3', '.txt', '.md', '.markdown'];

/** 扫目录里的本地书（递归；跳过点开头的目录与文件）。 */
export function scanLibrary(directory) {
  const files = [];
  const walk = dir => {
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (entry.name.startsWith('.')) continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (LOCAL_EXTENSIONS.includes(path.extname(entry.name).toLowerCase())) {
        files.push({ file: full, title: path.basename(entry.name, path.extname(entry.name)) });
      }
    }
  };
  walk(path.resolve(String(directory)));
  return files.sort((a, b) => a.file.localeCompare(b.file));
}

/**
 * 为每个本地文件给一条绑定建议。
 * level: exact（归一化后同名）/ partial（一方包含另一方）/ ambiguous（多个候选）/ none。
 */
export function proposeBindings(files, books) {
  const indexed = books.map(book => ({ book, key: normalizeTitle(book.title) })).filter(entry => entry.key);
  return files.map(file => {
    const key = normalizeTitle(file.title);
    const exact = key ? indexed.filter(entry => entry.key === key) : [];
    if (exact.length === 1) return { file: file.file, title: file.title, level: 'exact', book: exact[0].book };
    if (exact.length > 1) return { file: file.file, title: file.title, level: 'ambiguous', candidates: exact.map(entry => entry.book) };
    const partial = key
      ? indexed.filter(entry => entry.key.includes(key) || key.includes(entry.key))
      : [];
    if (partial.length === 1) return { file: file.file, title: file.title, level: 'partial', book: partial[0].book };
    return {
      file: file.file,
      title: file.title,
      level: partial.length ? 'ambiguous' : 'none',
      candidates: partial.map(entry => entry.book),
    };
  });
}

/**
 * 从账号目录里挑出本地这一章对应的云章节。
 * 先按标题（归一化后同名，再包含），标题对不上时退回百分比；都挑不出来返回 null。
 */
export function pickChapter(chapters, { title, percent } = {}) {
  if (title) {
    const key = normalizeTitle(title);
    if (key) {
      const exact = chapters.filter(chapter => normalizeTitle(chapter.title) === key);
      if (exact.length) return { chapter: exact[0], matched: 'title' };
      const partial = chapters.filter(chapter => {
        const candidate = normalizeTitle(chapter.title);
        return candidate && (candidate.includes(key) || key.includes(candidate));
      });
      if (partial.length) return { chapter: partial[0], matched: 'title' };
    }
  }
  if (percent != null && Number.isFinite(Number(percent)) && chapters.length) {
    const share = Math.max(0, Math.min(100, Number(percent)));
    const index = Math.min(chapters.length - 1, Math.floor((share / 100) * chapters.length));
    return { chapter: chapters[index], matched: 'percent' };
  }
  return null;
}
