// WebView2 CDP 自测客户端：识别窗口 label 并读取 Home 实时 DOM 状态
// 用法：node scripts/cdp.mjs [port]
const DEBUG_PORT = Number(process.argv[2] ?? 9333);

async function getTargets() {
    const res = await fetch(`http://127.0.0.1:${DEBUG_PORT}/json/list`);
    return res.json();
}

function connect(wsUrl) {
    return new Promise((resolve, reject) => {
        const ws = new WebSocket(wsUrl);
        ws.onopen = () => resolve(ws);
        ws.onerror = () => reject(new Error(`连接失败: ${wsUrl}`));
    });
}

let nextId = 1;
function call(ws, method, params = {}) {
    return new Promise((resolve, reject) => {
        const id = nextId++;
        const onMsg = (event) => {
            const msg = JSON.parse(String(event.data));
            if (msg.id === id) {
                ws.removeEventListener("message", onMsg);
                if (msg.error) {
                    reject(new Error(`${method}: ${JSON.stringify(msg.error)}`));
                } else {
                    resolve(msg.result);
                }
            }
        };
        ws.addEventListener("message", onMsg);
        ws.send(JSON.stringify({ id, method, params }));
    });
}

async function evalOn(ws, expression) {
    const r = await call(ws, "Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) {
        throw new Error(`evaluate 异常: ${JSON.stringify(r.exceptionDetails)}`);
    }
    return r.result.value;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const HOME_STATE_EXPR = `(() => {
    const q = (s) => document.querySelector(s);
    const qa = (s) => document.querySelectorAll(s);
    return {
        symbolActive: q(".ycs-home__symbol--active")?.textContent?.trim() ?? null,
        symbolButtons: qa(".ycs-home__symbol").length,
        activeInterval: q(".ycs-intervals__btn--active")?.textContent ?? null,
        price: q(".ycs-marketbar__price")?.textContent ?? null,
        change: q(".ycs-marketbar__change")?.textContent ?? null,
        extra: q(".ycs-marketbar__extra")?.textContent ?? null,
        updateTime: q(".ycs-marketbar__time")?.textContent ?? null,
        canvas: (() => { const c = q("canvas"); return c ? c.width + "x" + c.height : null; })(),
        calcInputs: qa(".ycs-calc__input").length,
        status: q(".ycs-chart-panel__status")?.textContent ?? null,
        error: q(".ycs-chart-panel__error span")?.textContent ?? null,
        listStatus: q(".ycs-home__list-status")?.textContent ?? null,
    };
})()`;

const CAPSULE_STATE_EXPR = `(() => {
    const q = (s) => document.querySelector(s);
    return {
        hasCapsule: !!q(".ycs-capsule"),
        symbol: q(".ycs-symbol")?.textContent ?? null,
        price: q(".ycs-price")?.textContent ?? null,
        change: q(".ycs-change")?.textContent ?? null,
        sparkline: !!q(".ycs-sparkline polyline"),
        bodyBg: getComputedStyle(document.body).backgroundColor,
        rootBg: getComputedStyle(document.documentElement).backgroundColor,
        rect: q(".ycs-capsule")?.getBoundingClientRect()?.toJSON?.() ?? null,
    };
})()`;

async function main() {
    const targets = (await getTargets()).filter((t) => t.type === "page");
    const found = {};
    for (const t of targets) {
        const ws = await connect(t.webSocketDebuggerUrl);
        const label = await evalOn(ws, "window.__TAURI_INTERNALS__?.metadata?.currentWindow?.label ?? 'unknown'");
        found[label] = { ws, target: t };
        console.log(`TARGET ${t.id.slice(0, 10)} label=${label} title=${t.title}`);
    }
    if (found.home) {
        const s1 = await evalOn(found.home.ws, HOME_STATE_EXPR);
        console.log("HOME STATE #1:", JSON.stringify(s1));
        console.log(
            "HOME BG:",
            await evalOn(found.home.ws, `getComputedStyle(document.querySelector(".ycs-home")).backgroundColor + " / body=" + getComputedStyle(document.body).backgroundColor`)
        );
        await sleep(6000);
        const s2 = await evalOn(found.home.ws, HOME_STATE_EXPR);
        console.log("HOME STATE #2 (6s later):", JSON.stringify(s2));
        console.log("PRICE CHANGED:", s1.price !== s2.price || s1.extra !== s2.extra);
    }
    if (found.capsule) {
        const c = await evalOn(found.capsule.ws, CAPSULE_STATE_EXPR);
        console.log("CAPSULE STATE:", JSON.stringify(c));
    }
    for (const { ws } of Object.values(found)) {
        ws.close();
    }
}

main().catch((e) => {
    console.error("FAILED:", e.message);
    process.exit(1);
});