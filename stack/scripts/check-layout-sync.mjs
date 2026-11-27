#!/usr/bin/env node
// Site-chrome check. tmc-global's shared/src/data/site-nav.json is the source
// of the chrome every site renders through buildChrome; see
// check-layout-sync.sh for usage. Exit 0 = OK, 1 = problems (listed), 2 = error.
//
//   1. site-nav.json is well formed: known fields, hrefs that are paths or
//      URLs, icons NAV_ICONS has, unique entry paths, a copyright naming the
//      legal entity; and it is formatted (`--write` formats it).
//   2. Every site's catalogue, in every locale it ships, has a string for every
//      key that site draws (city's labels for everything; the others skip the
//      staff-only entries, status the signed-in ones too).
//   3. Every site builds its chrome with buildChrome({ site: '<its own>' }),
//      passes no overrides of its own, and keeps no nav list of its own; the
//      agreed SITE_CHROME_OVERRIDES all match an entry.
//   4. City's lib/site/links.ts (what its other pages link to) agrees with the
//      JSON: the social row, and the off-site URLs the chrome also carries.
//      City's NavModalKind has every `modal` kind the JSON names.
import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import {
    loadShared,
    loadCatalogues,
    findBuildChromeCalls,
    findOwnNavLists,
    loadCityLinks,
    CITY,
    PROCESSING,
    LEARN,
    STATUS,
    SITE_NAV_JSON,
    lookup,
} from './lib/chrome.mjs'

const WRITE = process.argv.includes('--write')
const QUIET = process.argv.includes('--quiet')

const SITES = [
    { name: 'website-city', repo: CITY, site: 'city', role: true, signedIn: true },
    { name: 'website-processing', repo: PROCESSING, site: 'processing', role: false, signedIn: true },
    { name: 'website-learn', repo: LEARN, site: 'learn', role: false, signedIn: true },
    // Nobody is signed in to city on status's origin.
    { name: 'website-status', repo: STATUS, site: 'status', role: false, signedIn: false },
]

const LEAF_KEYS = new Set(['labelKey', 'label', 'descKey', 'desc', 'href', 'icon', 'external', 'requiresAuth', 'roles', 'modal', 'exact', 'children', 'groupKey', 'group'])
const SECTION_KEYS = new Set(['labelKey', 'label', 'icon', 'roles', 'items'])
const COLUMN_KEYS = new Set(['headingKey', 'heading', 'links'])
const TOP_KEYS = new Set(['$comment', 'header', 'sidebar', 'footer', 'socials', 'slogan', 'copyright', 'legalEntity'])

let problems = 0
const report = []
function section(title, lines) {
    if (!lines?.length) return
    problems++
    report.push(`\n=== ${title}`, ...lines.map((l) => ` - ${l}`))
}

/* ---------------------------------------------------------- 1. the JSON */

function validate(d, shared) {
    const out = []
    const str = (v) => typeof v === 'string' && v.length > 0
    const bool = (where, e, k) => e[k] !== undefined && e[k] !== true && out.push(`${where}: ${k} must be true or absent`)
    const href = (where, h) =>
        !(typeof h === 'string' && /^(\/|https?:\/\/|mailto:)/.test(h)) && out.push(`${where}: href ${JSON.stringify(h)} is not a site path or URL`)
    const icon = (where, i) => i !== undefined && !shared.iconNames.has(i) && out.push(`${where}: icon ${JSON.stringify(i)} has no NAV_ICONS entry (tmc-global components/nav.ts)`)
    const roles = (where, r) =>
        r !== undefined && !(Array.isArray(r) && r.length && r.every(str)) && out.push(`${where}: roles must be a non-empty array of role names`)
    const unknown = (where, e, keys) => {
        for (const k of Object.keys(e)) if (!keys.has(k)) out.push(`${where}: unknown field ${JSON.stringify(k)}`)
    }
    const leaf = (where, e, { surface, hrefOptional = false }) => {
        unknown(where, e, LEAF_KEYS)
        if (!str(e.labelKey) || !str(e.label)) out.push(`${where}: needs labelKey and label (the English fallback)`)
        if (e.descKey !== undefined && !(str(e.descKey) && str(e.desc))) out.push(`${where}: descKey needs desc (the English fallback)`)
        if (!(hrefOptional && e.href === undefined)) href(where, e.href)
        icon(where, e.icon)
        roles(where, e.roles)
        for (const k of ['external', 'requiresAuth', 'exact']) bool(where, e, k)
        if (e.modal !== undefined && !str(e.modal)) out.push(`${where}: modal must be a pop-up kind`)
        if (e.exact && surface !== 'rail') out.push(`${where}: exact is only read on the rail`)
        if (e.children && surface !== 'header') out.push(`${where}: only header entries have children`)
        // A mega panel section heading: translated by tmc-global's i18n/nav-groups.ts, so no site catalogue carries it.
        if (e.groupKey !== undefined || e.group !== undefined) {
            if (surface !== 'header-child') out.push(`${where}: groupKey/group only name a header child's mega panel section`)
            else if (!str(e.groupKey) || !str(e.group)) out.push(`${where}: groupKey needs group (the English fallback), and group needs groupKey`)
            else if (shared.navGroupKeys && !shared.navGroupKeys.has(e.groupKey))
                out.push(`${where}: groupKey ${JSON.stringify(e.groupKey)} has no navGroups entry (tmc-global i18n/nav-groups.ts)`)
        }
        if (surface === 'footer' && (e.icon || e.modal || e.descKey)) out.push(`${where}: the footer draws no icon, pop-up or description`)
    }

    unknown('(top level)', d, TOP_KEYS)
    for (const k of ['header', 'sidebar', 'footer', 'socials']) if (!Array.isArray(d[k]) || !d[k].length) out.push(`${k}: missing or empty`)
    if (out.length) return out

    for (const i of d.header) {
        const w = `header ${i.labelKey}`
        leaf(w, i, { surface: 'header', hrefOptional: Array.isArray(i.children) && i.children.length > 0 })
        for (const c of i.children ?? []) leaf(`${w} > ${c.labelKey}`, c, { surface: 'header-child' })
    }
    for (const s of d.sidebar) {
        const w = `sidebar ${s.labelKey}`
        unknown(w, s, SECTION_KEYS)
        if (!str(s.labelKey) || !str(s.label)) out.push(`${w}: needs labelKey and label`)
        icon(w, s.icon)
        roles(w, s.roles)
        if (!Array.isArray(s.items) || !s.items.length) out.push(`${w}: no items`)
        for (const c of s.items ?? []) leaf(`${w} > ${c.labelKey}`, c, { surface: 'rail' })
        // A staff section whose leaves are not gated too would show them the
        // moment a leaf is lifted into another section.
        if (s.roles) for (const c of s.items ?? []) if (!c.roles) out.push(`${w} > ${c.labelKey}: in a roles section but has no roles of its own`)
    }
    for (const c of d.footer) {
        const w = `footer ${c.headingKey}`
        unknown(w, c, COLUMN_KEYS)
        if (!str(c.headingKey) || !str(c.heading)) out.push(`${w}: needs headingKey and heading`)
        for (const l of c.links ?? []) leaf(`${w} > ${l.labelKey}`, l, { surface: 'footer' })
    }
    for (const s of d.socials)
        if (!['key', 'label', 'href'].every((k) => str(s[k])) || Object.keys(s).length !== 3) out.push(`socials: ${JSON.stringify(s)} must be { key, label, href }`)
    if (!str(d.slogan)) out.push('slogan: missing')
    if (!str(d.legalEntity)) out.push('legalEntity: missing')
    if (!str(d.copyright) || !d.copyright.includes('{year}') || !d.copyright.includes(d.legalEntity))
        out.push(`copyright: must carry {year} and name ${d.legalEntity}`)

    const paths = shared.ChromeEntryPaths(d)
    const seen = new Set()
    for (const p of paths) seen.has(p) ? out.push(`entry path ${p} is not unique (overrides could not address it)`) : seen.add(p)
    return out
}

/* ------------------------------------------------------- 2. catalogues */

/** Every key a site draws: [surface, key, where]. */
function drawnKeys(d, site) {
    const keys = []
    const shown = (e) => (site.role || !e.roles) && (site.signedIn || !e.requiresAuth)
    for (const i of d.header.filter(shown)) {
        keys.push(['header', i.labelKey], ...(i.descKey ? [['header', i.descKey]] : []))
        for (const c of (i.children ?? []).filter(shown)) keys.push(['header', c.labelKey], ...(c.descKey ? [['header', c.descKey]] : []))
    }
    // The rail and the footer draw no descriptions, so their descKeys are not asked.
    for (const s of d.sidebar.filter(shown)) {
        keys.push(['rail', s.labelKey])
        for (const c of s.items.filter(shown)) keys.push(['rail', c.labelKey])
    }
    for (const c of d.footer) {
        keys.push(['footer', c.headingKey])
        for (const l of c.links.filter(shown)) keys.push(['footer', l.labelKey])
    }
    keys.push(['footer', 'slogan'], ['footer', 'copyright'])
    return [...new Map(keys.map((k) => [k.join('|'), k])).values()]
}

function coverage(d, site, cats, shared) {
    const missing = {}
    const bad = []
    for (const loc of cats.locales) {
        for (const [surface, key] of drawnKeys(d, site)) {
            const ns = surface === 'footer' ? 'footer' : 'nav'
            let v
            if (cats.kind === 'next-intl') v = cats.get(loc, ns, key)
            else {
                const asked = shared.ShellCatalogKey(`${ns}.${key}`, surface)
                const [askedNs, ...rest] = asked.split('.')
                v = cats.get(loc, askedNs, rest.join('.'))
                // The shared rail catalogue is the Astro sites' own fallback for a rail key.
                if (v === undefined && surface === 'rail') v = lookup(shared.shellSidebar[loc], key.replace(/\.label$/, ''))
            }
            if (typeof v !== 'string' || !v) (missing[loc] ??= []).push(`${ns}.${key}`)
            else if (key === 'copyright' && !(v.includes('{year}') && v.includes(d.legalEntity)))
                bad.push(`[${loc}] ${ns}.copyright does not carry {year} and name ${d.legalEntity}: ${v}`)
        }
    }
    return [
        ...Object.entries(missing).map(([loc, ks]) => `[${loc}] ${ks.length} key(s) missing, shown in ${loc === 'en' ? 'site-nav.json English' : 'English'}: ${ks.join(', ')}`),
        ...bad,
    ]
}

/* --------------------------------------------------------------- main */

try {
    const shared = loadShared()
    if (!existsSync(SITE_NAV_JSON)) throw new Error(`${SITE_NAV_JSON} not found`)
    const text = readFileSync(SITE_NAV_JSON, 'utf8')
    let d
    try {
        d = JSON.parse(text)
    } catch (e) {
        section('tmc-global site-nav.json does not parse', [String(e.message)])
    }

    if (d) {
        section('tmc-global site-nav.json', validate(d, shared))

        const formatted = JSON.stringify(d, null, 4) + '\n'
        if (formatted !== text) {
            if (WRITE) {
                writeFileSync(SITE_NAV_JSON, formatted)
                if (!QUIET) console.log(`formatted ${SITE_NAV_JSON}`)
            } else section('tmc-global site-nav.json is not formatted (run with --write)', ['4-space JSON.stringify, trailing newline'])
        }

        for (const site of SITES) {
            if (!existsSync(join(site.repo, 'src'))) {
                section(site.name, [`${site.repo}/src not found`])
                continue
            }
            const cats = loadCatalogues(site.repo)
            if (!QUIET) console.log(`${site.name}: ${cats.locales.length} locale(s), ${cats.kind} catalogues (${site.repo})`)
            section(`${site.name} catalogues do not cover site-nav.json's keys`, coverage(d, site, cats, shared))

            const calls = findBuildChromeCalls(join(site.repo, 'src'))
            section(
                `${site.name} chrome`,
                [
                    ...(calls.length ? [] : ['no buildChrome call in src/']),
                    ...calls
                        .filter((c) => c.site !== site.site || c.overrides)
                        .map((c) => `src/${c.file}: buildChrome is not { site: '${site.site}' } without own overrides (site=${c.site ?? 'none'}${c.overrides ? ', passes overrides' : ''})`),
                    ...findOwnNavLists(join(site.repo, 'src')).map((f) => `src/${f}: a nav list of its own; the chrome is site-nav.json`),
                ]
            )
            const unmatched = shared.buildChrome({ site: site.site, data: d, signedIn: true }).unmatched
            section(
                `SITE_CHROME_OVERRIDES.${site.site} entries that match nothing in site-nav.json`,
                unmatched
            )
        }

        const links = loadCityLinks()
        if (links) {
            const hrefs = new Set()
            const walk = (v) => (Array.isArray(v) ? v.forEach(walk) : v && typeof v === 'object' && (typeof v.href === 'string' && hrefs.add(v.href), Object.values(v).forEach(walk)))
            walk([d.header, d.sidebar, d.footer])
            const out = []
            for (const k of ['DISCORD_URL', 'BLOG_URL', 'DOCS_URL', 'STATUS_URL', 'CONTACT_URL'])
                if (typeof links[k] === 'string' && !hrefs.has(links[k])) out.push(`${k} = ${links[k]} is in no chrome entry`)
            const mine = (links.SOCIAL_LINKS ?? []).map((s) => `${s.key} ${s.label} ${s.href}`)
            const theirs = d.socials.map((s) => `${s.key} ${s.label} ${s.href}`)
            if (mine.join('\n') !== theirs.join('\n')) out.push(`SOCIAL_LINKS [${mine.join('; ')}] != site-nav.json socials [${theirs.join('; ')}]`)
            section("website-city lib/site/links.ts disagrees with site-nav.json (city's other pages use links.ts)", out)
        }

        // City opens a pop-up for each `modal` kind (`kind as NavModalKind`), so a
        // kind its NavModalKind union lacks would open nothing.
        const modalsFile = join(CITY, 'src/app/_components/lib/create/nav-modals.tsx')
        if (existsSync(modalsFile)) {
            const m = /export type NavModalKind =([\s\S]*?)\n(?=\S)/.exec(readFileSync(modalsFile, 'utf8'))
            const known = new Set([...(m?.[1] ?? '').matchAll(/^\s*\|?\s*'([\w-]+)'/gm)].map((x) => x[1]))
            const kinds = new Set()
            const walk = (v) => (Array.isArray(v) ? v.forEach(walk) : v && typeof v === 'object' && (typeof v.modal === 'string' && kinds.add(v.modal), Object.values(v).forEach(walk)))
            walk([d.header, d.sidebar])
            section(
                "website-city NavModalKind (lib/create/nav-modals.tsx) lacks site-nav.json's pop-up kinds",
                m ? [...kinds].filter((k) => !known.has(k)).map((k) => `modal: '${k}'`) : ['no `export type NavModalKind =` found']
            )
        }
    }
} catch (e) {
    console.error(`check-layout-sync: error: ${e.stack || e}`)
    process.exit(2)
}

if (problems) {
    console.log(`check-layout-sync: ${problems} problem(s) — tmc-global shared/src/data/site-nav.json is the source of the chrome.`)
    console.log(report.join('\n'))
    process.exit(1)
}
if (!QUIET) console.log("check-layout-sync: OK — site-nav.json is valid, every site's catalogues cover it, and every site builds its chrome from it.")
