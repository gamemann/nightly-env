// Loaders for the site-chrome check (check-layout-sync.mjs): tmc-global's
// site-nav.json and buildChrome, read from SOURCE, and each site's own message
// catalogues and buildChrome calls, as plain data.
//
// site-nav.json is the source of the chrome; nothing here reads a site's nav
// lists, because no site keeps one. Each repo path can be pointed elsewhere (a
// worktree of another branch) with LAYOUT_SYNC_{CITY,PROCESSING,LEARN,STATUS,TMC_GLOBAL}.
//
// No dependencies: TypeScript is stripped with node's built-in
// `module.stripTypeScriptTypes`, and every import that is not data (icons,
// React, types) is replaced by a stub that yields the imported NAME, so an
// icon compares as the string "Compass".
import { readFileSync, existsSync, readdirSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { stripTypeScriptTypes } from 'node:module'
import { fileURLToPath } from 'node:url'

export const STACK = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const repoDir = (env, dir) => resolve(process.env[`LAYOUT_SYNC_${env}`] || join(STACK, dir))
export const CITY = repoDir('CITY', 'website-city')
export const PROCESSING = repoDir('PROCESSING', 'website-processing')
export const LEARN = repoDir('LEARN', 'website-learn')
export const STATUS = repoDir('STATUS', 'website-status')
export const SHARED = join(repoDir('TMC_GLOBAL', 'tmc-global'), 'shared')
export const SITE_NAV_JSON = join(SHARED, 'src/data/site-nav.json')

const STUB = new Proxy({}, { get: (_t, p) => (p === '__esModule' ? false : String(p)) })

function resolveFile(spec, from, alias) {
    let base
    for (const [pre, dir] of Object.entries(alias)) {
        if (spec === pre.replace(/\/$/, '') || spec.startsWith(pre)) {
            base = join(dir, spec.slice(pre.length))
            break
        }
    }
    if (!base && spec.startsWith('.')) base = resolve(dirname(from), spec)
    if (!base) return null
    for (const ext of ['', '.ts', '.tsx', '.js', '.mjs', '/index.ts']) {
        if (existsSync(base + ext) && !base.endsWith('/') && (ext || /\.([mc]?[jt]sx?|json)$/.test(base)))
            return base + ext
    }
    return null
}

/**
 * Evaluate a (JSX-free) TS module. `opts.alias` maps import prefixes to dirs;
 * `opts.stub(spec)` → true forces a stub; `opts.fixed[spec]` supplies a value.
 */
export function loadModule(file, opts = {}, cache = new Map()) {
    if (cache.has(file)) return cache.get(file)
    if (file.endsWith('.json')) {
        const data = JSON.parse(readFileSync(file, 'utf8'))
        cache.set(file, data)
        return data
    }
    const alias = opts.alias ?? {}
    let js = stripTypeScriptTypes(readFileSync(file, 'utf8'), { mode: 'strip' })
    const deps = []
    js = js.replace(
        /\bimport\s+(?:([\w$]+)\s*,?\s*)?(\*\s+as\s+[\w$]+|\{[^}]*\})?\s*from\s*(['"])([^'"]+)\3;?|\bimport\s*(['"])[^'"]+\5;?/g,
        (m, def, clause, _q, spec) => {
            if (!spec) return ''
            const i = deps.length
            deps.push(spec)
            const out = []
            if (def) out.push(`const ${def} = __d[${i}].default ?? __d[${i}];`)
            if (clause?.startsWith('*')) out.push(`const ${clause.split(/\s+/).pop()} = __d[${i}];`)
            else if (clause) {
                const names = clause
                    .slice(1, -1)
                    .split(',')
                    .map((s) => s.trim())
                    .filter((s) => s && !s.startsWith('type '))
                    .map((s) => s.replace(/\s+as\s+/, ': '))
                if (names.length) out.push(`const { ${names.join(', ')} } = __d[${i}];`)
            }
            return out.join(' ')
        }
    )
    const exported = []
    js = js.replace(/\bexport\s+(?:async\s+)?(const|let|var|function|class)\s+([\w$]+)/g, (_m, kw, name) => {
        exported.push(name)
        return `${kw} ${name}`
    })
    js = js.replace(/\bexport\s*\{([^}]*)\}\s*;?/g, (_m, names) => {
        for (const n of names.split(',').map((s) => s.trim()).filter(Boolean)) {
            const [local, as] = n.split(/\s+as\s+/)
            exported.push(as ? `${as}: ${local}` : local)
        }
        return ''
    })
    const values = deps.map((spec) => {
        if (opts.fixed && spec in opts.fixed) return opts.fixed[spec]
        if (opts.stub?.(spec)) return STUB
        const f = resolveFile(spec, file, alias)
        return f ? loadModule(f, opts, cache) : STUB
    })
    const mod = new Function('__d', `${js}\nreturn { ${exported.join(', ')} };`)(values)
    cache.set(file, mod)
    return mod
}

export const readJson = (f) => JSON.parse(readFileSync(f, 'utf8'))

export function lookup(obj, path) {
    let cur = obj
    for (const p of path.split('.')) {
        if (cur == null || typeof cur !== 'object') return undefined
        cur = cur[p]
    }
    return typeof cur === 'string' ? cur : undefined
}

function readdirSorted(d) {
    try {
        return readdirSync(d).sort((a, b) => (a === 'en' ? -1 : b === 'en' ? 1 : a.localeCompare(b)))
    } catch {
        return []
    }
}

function readdirRaw(d) {
    try {
        return readdirSync(d, { withFileTypes: true })
    } catch {
        return []
    }
}

/* ---------------------------------------------------------- tmc-global */

/**
 * tmc-global's chrome code, from source: buildChrome, ShellCatalogKey,
 * ChromeEntryPaths, SITE_CHROME_OVERRIDES, the NAV_ICONS names, and the shared
 * rail catalogue (the Astro sites' fallback for a rail key).
 */
export function loadShared() {
    const chromeFile = join(SHARED, 'src/components/chrome.ts')
    if (!existsSync(chromeFile)) throw new Error(`${chromeFile} not found — buildChrome moved?`)
    const cache = new Map()
    const opts = { stub: (s) => !s.startsWith('.') }
    const chrome = loadModule(chromeFile, opts, cache)
    for (const k of ['buildChrome', 'ShellCatalogKey', 'ChromeEntryPaths', 'SITE_CHROME_OVERRIDES'])
        if (!chrome[k]) throw new Error(`${chromeFile} no longer exports ${k}`)
    const { NAV_ICONS } = loadModule(join(SHARED, 'src/components/nav.ts'), opts, cache)
    const { shellSidebar } = loadModule(resolveFile('./src/i18n/sidebar', join(SHARED, 'x'), {}), opts, cache)
    return { ...chrome, iconNames: new Set(Object.keys(NAV_ICONS ?? {})), shellSidebar }
}

/* ------------------------------------------------------------- sites */

/**
 * A site's chrome catalogues: `{ locales, kind, get(locale, ns, key) }`.
 * `kind` 'next-intl' (city, status: `locales/<loc>/{nav,footer}.json`, keyed
 * as site-nav.json is) or 'astro' (learn, processing: `src/i18n` MESSAGES,
 * keyed through ShellCatalogKey). `get` reads the locale's own catalogue
 * only, with no English fallback, so a gap shows up as a gap.
 */
export function loadCatalogues(repo) {
    if (existsSync(join(repo, 'locales/en/nav.json'))) {
        const locales = readdirSorted(join(repo, 'locales')).filter((d) => existsSync(join(repo, 'locales', d, 'nav.json')))
        const cache = {}
        const cat = (loc, ns) => {
            const f = join(repo, 'locales', loc, `${ns}.json`)
            return (cache[`${loc}/${ns}`] ??= existsSync(f) ? readJson(f) : {})
        }
        return { kind: 'next-intl', locales, get: (loc, ns, key) => lookup(cat(loc, ns), key) }
    }
    const i18n = join(repo, 'src/i18n')
    if (existsSync(join(i18n, 'messages.ts'))) {
        const cache = new Map()
        const alias = { '@modcommunity/shared/i18n': join(SHARED, 'src/i18n/sidebar') }
        const opts = { alias, stub: (s) => !s.startsWith('.') && !(s in alias) }
        const { MESSAGES } = loadModule(join(i18n, 'messages.ts'), opts, cache)
        const { LOCALES } = loadModule(join(i18n, 'config.ts'), opts, cache)
        if (!MESSAGES || !LOCALES) throw new Error(`${i18n}: no MESSAGES / LOCALES export — catalogue layout changed?`)
        return { kind: 'astro', locales: [...LOCALES], get: (loc, ns, key) => lookup(MESSAGES[loc], `${ns}.${key}`) }
    }
    throw new Error(`${repo}: neither locales/en/nav.json nor src/i18n/messages.ts — where are its catalogues?`)
}

/**
 * Every `buildChrome({ ... })` call in a tree: the file, the `site` it passes,
 * whether it passes its own `overrides`.
 */
export function findBuildChromeCalls(dir) {
    const out = []
    const walk = (d) => {
        for (const e of readdirRaw(d)) {
            const f = join(d, e.name)
            if (e.isDirectory()) {
                if (e.name !== 'node_modules' && e.name !== '.next' && e.name !== 'dist') walk(f)
            } else if (/\.(tsx?|astro|mjs|js)$/.test(e.name) && !/\.test\.[tj]sx?$/.test(e.name)) {
                const text = readFileSync(f, 'utf8')
                // A call, not the import or a mention in a comment: `buildChrome({`.
                for (const m of text.matchAll(/\bbuildChrome\(\s*\{([^]*?)\}\s*\)/g))
                    out.push({
                        file: f.slice(dir.length + 1),
                        site: /\bsite:\s*['"]([\w-]+)['"]/.exec(m[1])?.[1] ?? null,
                        overrides: /\boverrides\b/.test(m[1]),
                    })
            }
        }
    }
    walk(dir)
    return out
}

/** Files in a tree that still declare their own chrome lists (the pre-buildChrome layouts). */
export function findOwnNavLists(dir) {
    const out = []
    const re = /\bexport\s+(?:const|function)\s+(PRIMARY_NAV|SIDEBAR_SECTIONS|FOOTER_LINKS|buildNav|buildSidebarSections|buildFooterColumns)\b/g
    const walk = (d) => {
        for (const e of readdirRaw(d)) {
            const f = join(d, e.name)
            if (e.isDirectory()) {
                if (e.name !== 'node_modules') walk(f)
            } else if (/\.(tsx?|mjs|js)$/.test(e.name)) {
                for (const m of readFileSync(f, 'utf8').matchAll(re)) out.push(`${f.slice(dir.length + 1)}: ${m[1]}`)
            }
        }
    }
    walk(dir)
    return out
}

/** City's `lib/site/links.ts`: the URLs and socials its pages use beside the chrome. */
export function loadCityLinks() {
    const f = join(CITY, 'src/lib/site/links.ts')
    if (!existsSync(f)) return null
    return loadModule(f, { fixed: { '~/env-public': { env: {} }, '~/env': { env: {} } }, stub: () => true })
}
