// CDP 交互自测：真实输入注入 + DOM 状态断言（不依赖网络）
// 用法：node scripts/cdp-interact.mjs [port]
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
        throw new Error(`evaluate 异常: ${JSON.stringify(r.exceptionDetails.exception?.description ?? r.exceptionDetails)}`);
    }
    return r.result.value;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** CDP 真实鼠标事件（走 Chromium 输入管线，等效用户输入含命中测试） */
async function clickAt(ws, x, y, clicks = 1) {
    for (let i = 0; i < clicks; i++) {
        await call(ws, "Input.dispatchMouseEvent", { type: "mouseMoved", x, y, button: "none", pointerType: "mouse" });
        await call(ws, "Input.dispatchMouseEvent", { type: "mousePressed", x, y, button: "left", clickCount: i + 1, pointerType: "mouse" });
        await call(ws, "Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button: "left", clickCount: i + 1, pointerType: "mouse" });
        if (i === 0 && clicks === 2) {
            await sleep(80);
        }
    }
}

/** 查询元素中心坐标（CSS 像素） */
function centerOf(selector) {
    return `(() => { const el = document.querySelector(${JSON.stringify(selector)}); if (!el) return null; const r = el.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()`;
}

/** 先 scrollIntoView 再取中心坐标：低于视口的坐标注入会被 CDP 静默丢弃（页面可能被上一套件滚到底部） */
async function scrolledCenter(ws, selector) {
    await evalOn(ws, `document.querySelector(${JSON.stringify(selector)})?.scrollIntoView({ block: "center" })`);
    await sleep(250);
    return evalOn(ws, centerOf(selector));
}

let pass = 0;
let fail = 0;
function check(name, ok, detail = "") {
    if (ok) {
        pass++;
        console.log(`PASS ${name} ${detail}`);
    } else {
        fail++;
        console.log(`FAIL ${name} ${detail}`);
    }
}

async function main() {
    const targets = (await getTargets()).filter((t) => t.type === "page");
    const found = {};
    for (const t of targets) {
        const ws = await connect(t.webSocketDebuggerUrl);
        const label = await evalOn(ws, "window.__TAURI_INTERNALS__?.metadata?.currentWindow?.label ?? 'unknown'");
        found[label] = ws;
    }
    const home = found.home;
    const capsule = found.capsule;
    if (!home || !capsule) {
        throw new Error(`窗口不全: ${Object.keys(found).join(",")}`);
    }

    // 等待 home 页面完成首屏渲染（React 挂载 + 合约列表加载）
    const waitReady = async (ws, selector, timeoutMs) => {
        const deadline = Date.now() + timeoutMs;
        while (Date.now() < deadline) {
            const ok = await evalOn(ws, `document.querySelector(${JSON.stringify(selector)}) !== null`);
            if (ok) {
                return true;
            }
            await sleep(500);
        }
        return false;
    };
    const homeReady = await waitReady(home, ".ycs-home__symbol", 30000);
    if (!homeReady) {
        throw new Error("home 页面 30 秒内未完成渲染");
    }
    await sleep(1000);

    // ===== 1. 搜索过滤（程序化设值触发 React onChange，幂等） =====
    // 先清空搜索框（上一套件可能残留过滤词导致 before 计数失真）
    await evalOn(home, `(() => {
        const input = document.querySelector(".ycs-home__search");
        const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
        setter.call(input, "");
        input.dispatchEvent(new Event("input", { bubbles: true }));
        return true;
    })()`);
    await sleep(400);
    const before = await evalOn(home, `document.querySelectorAll(".ycs-home__symbol").length`);
    await evalOn(home, `(() => {
        const input = document.querySelector(".ycs-home__search");
        const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
        setter.call(input, "BTC");
        input.dispatchEvent(new Event("input", { bubbles: true }));
        return true;
    })()`);
    await sleep(400);
    const after = await evalOn(home, `document.querySelectorAll(".ycs-home__symbol").length`);
    const firstHit = await evalOn(home, `document.querySelector(".ycs-home__symbol-name")?.textContent ?? null`);
    check("搜索过滤 BTC", after < before && after >= 1 && String(firstHit).includes("BTC"), `(${before} -> ${after}, first=${firstHit})`);

    // 清空搜索恢复完整列表
    await evalOn(home, `(() => {
        const input = document.querySelector(".ycs-home__search");
        const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
        setter.call(input, "");
        input.dispatchEvent(new Event("input", { bubbles: true }));
        return true;
    })()`);
    await sleep(300);

    // ===== 2. 点击 BTCUSDT 切换合约（先搜索过滤让目标进入渲染列表——侧边栏默认只渲染全量字母序前 60，BTCUSDT 不在其中） =====
    await evalOn(home, `(() => {
        const input = document.querySelector(".ycs-home__search");
        const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
        setter.call(input, "BTCUSDT");
        input.dispatchEvent(new Event("input", { bubbles: true }));
        return true;
    })()`);
    await sleep(400);
    await evalOn(home, `(() => { const btn = [...document.querySelectorAll(".ycs-home__symbol")].find((el) => el.querySelector(".ycs-home__symbol-name")?.textContent === "BTCUSDT"); if (btn) btn.scrollIntoView({ block: "center" }); return true; })()`);
    await sleep(250);
    const btcBtn = await evalOn(
        home,
        `(() => { const btn = [...document.querySelectorAll(".ycs-home__symbol")].find((el) => el.querySelector(".ycs-home__symbol-name")?.textContent === "BTCUSDT"); if (!btn) return null; const r = btn.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()`
    );
    if (!btcBtn) {
        throw new Error("列表中未找到 BTCUSDT");
    }
    await clickAt(home, btcBtn.x, btcBtn.y);
    await sleep(600);
    // 断言须在清空搜索前读取：清空后侧边栏只渲染字母序前 60，BTCUSDT 不在其中（active class 元素被卸载）
    const activeSymbol = await evalOn(home, `document.querySelector(".ycs-home__symbol--active .ycs-home__symbol-name")?.textContent ?? null`);
    const overviewSymbol = await evalOn(home, `document.querySelector(".ycs-marketbar__symbol")?.textContent ?? null`);
    check("切换合约激活态", activeSymbol === "BTCUSDT" && overviewSymbol === "BTCUSDT", `active=${activeSymbol} overview=${overviewSymbol}`);
    // 清空搜索恢复完整列表
    await evalOn(home, `(() => {
        const input = document.querySelector(".ycs-home__search");
        const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
        setter.call(input, "");
        input.dispatchEvent(new Event("input", { bubbles: true }));
        return true;
    })()`);
    await sleep(300);

    // ===== 3. 周期切换 =====
    const hourBtn = await scrolledCenter(home, ".ycs-intervals__btn:nth-child(4)");
    await clickAt(home, hourBtn.x, hourBtn.y);
    await sleep(500);
    const interval = await evalOn(home, `document.querySelector(".ycs-intervals__btn--active")?.textContent ?? null`);
    check("周期切换 1h", interval === "1h", `active=${interval}`);

    // ===== 3.5 首页零滚动（新布局应整页一屏容纳，无纵向滚动条） =====
    const noScroll = await evalOn(home, `document.scrollingElement.scrollHeight <= document.scrollingElement.clientHeight`);
    check("首页零滚动", noScroll === true, `scrollHeight=${await evalOn(home, "document.scrollingElement.scrollHeight")} clientHeight=${await evalOn(home, "document.scrollingElement.clientHeight")}`);

    // ===== 4. 计算器输入 =====
    // 清场：持久化仓位跨套件残留时右栏是持仓卡（无 .ycs-newpos__save），先删除回到新建表单态
    if ((await evalOn(home, `document.querySelector(".ycs-newpos__remove") !== null`))) {
        const removeCenter = await scrolledCenter(home, ".ycs-newpos__remove");
        await clickAt(home, removeCenter.x, removeCenter.y);
        await sleep(800);
    }
    const priceInput = await scrolledCenter(home, ".ycs-newpos__form .ycs-calc__input");
    await clickAt(home, priceInput.x, priceInput.y);
    for (const ch of "100") {
        await call(home, "Input.dispatchKeyEvent", { type: "keyDown", text: ch });
        await call(home, "Input.dispatchKeyEvent", { type: "keyUp", key: ch });
        await sleep(80);
    }
    await sleep(300);
    const saveDisabled = await evalOn(home, `document.querySelector(".ycs-newpos__save")?.disabled ?? null`);
    const hint = await evalOn(home, `document.querySelector(".ycs-newpos__hint")?.textContent ?? null`);
    check("计算器输入联动保存按钮", saveDisabled === true, `disabled=${saveDisabled} hint=${hint}`);

    // ===== 5. 双击胶囊打开首页（产品语义：双击 = open_home 幂等显示，非 toggle；断言双击后可见） =====
    const { execSync } = await import("node:child_process");
    const runSelftest = (action) =>
        String(execSync(`powershell -NoProfile -ExecutionPolicy Bypass -File scripts/selftest.ps1 ${action} home`, { stdio: ["pipe", "pipe", "pipe"] }).toString()).trim();
    const capsuleCenter = await evalOn(capsule, centerOf(".ycs-capsule"));
    await clickAt(capsule, capsuleCenter.x, capsuleCenter.y, 2);
    await sleep(1500);
    const shownOk = runSelftest("isvis").includes("True");
    check("双击胶囊打开首页", shownOk, `shownAfterDblClick=${shownOk}`);

    // ===== 6. 单击胶囊切换隐藏（等待 250ms 定时器后内容卸载） =====
    await clickAt(capsule, capsuleCenter.x, capsuleCenter.y, 1);
    await sleep(700);
    const priceGone = await evalOn(capsule, `document.querySelector(".ycs-price") === null`);
    check("单击隐藏胶囊内容", priceGone === true, `priceGone=${priceGone}`);
    // 恢复显示
    await clickAt(capsule, capsuleCenter.x, capsuleCenter.y, 1);
    await sleep(700);

    console.log(`RESULT pass=${pass} fail=${fail}`);
    for (const ws of Object.values(found)) {
        ws.close();
    }
    process.exit(fail > 0 ? 1 : 0);
}

main().catch((e) => {
    console.error("FAILED:", e.message);
    process.exit(1);
});