// 标题栏 + 胶囊盈亏 CDP 实测：自绘标题栏存在/窗口按钮行为/胶囊盈亏渲染/开关联动
// 测试仓位与用户仓位隔离：建仓前备份、结束前恢复（不动用户数据）
// 用法：node scripts/cdp-titlebar.mjs [port]
const port = Number(process.argv[2] ?? 9333);

async function getTargets() {
    const res = await fetch(`http://127.0.0.1:${port}/json/list`);
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
        throw new Error(`evaluate 异常: ${JSON.stringify(r.exceptionDetails.exception?.description ?? r.exceptionDetails).slice(0, 200)}`);
    }
    return r.result.value;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 坐标点击前 scrollIntoView（视口外坐标注入会被 CDP 静默丢弃），仍越界则兜底 el.click() */
async function click(ws, selector) {
    await evalOn(ws, `document.querySelector(${JSON.stringify(selector)})?.scrollIntoView({ block: "center" })`);
    await sleep(200);
    const pos = await evalOn(
        ws,
        `(() => { const el = document.querySelector(${JSON.stringify(selector)}); if (!el) return null; const r = el.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2, vw: window.innerWidth, vh: window.innerHeight }; })()`
    );
    if (pos === null) {
        throw new Error(`元素不存在: ${selector}`);
    }
    if (pos.x >= 0 && pos.y >= 0 && pos.x < pos.vw && pos.y < pos.vh) {
        await call(ws, "Input.dispatchMouseEvent", { type: "mouseMoved", x: pos.x, y: pos.y, button: "none", pointerType: "mouse" });
        await call(ws, "Input.dispatchMouseEvent", { type: "mousePressed", x: pos.x, y: pos.y, button: "left", clickCount: 1, pointerType: "mouse" });
        await call(ws, "Input.dispatchMouseEvent", { type: "mouseReleased", x: pos.x, y: pos.y, button: "left", clickCount: 1, pointerType: "mouse" });
    } else {
        await evalOn(ws, `document.querySelector(${JSON.stringify(selector)}).click()`);
    }
    await sleep(250);
}

/** 程序化设值触发 React onChange */
async function setInput(ws, selector, value) {
    await evalOn(
        ws,
        `(() => {
            const input = document.querySelector(${JSON.stringify(selector)});
            if (!input) throw new Error("input 不存在");
            const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
            setter.call(input, ${JSON.stringify(value)});
            input.dispatchEvent(new Event("input", { bubbles: true }));
            return true;
        })()`
    );
    await sleep(150);
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
    const { execSync } = await import("node:child_process");
    const runSelftest = (action, win) =>
        String(execSync(`powershell -NoProfile -ExecutionPolicy Bypass -File scripts/selftest.ps1 ${action} ${win}`, { stdio: ["pipe", "pipe", "pipe"] }).toString()).trim();

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

    // ===== 0. 确保 home 可见（上轮脚本可能留下最小化/隐藏态） =====
    if (runSelftest("isvis", "home").includes("False")) {
        const c0 = await evalOn(capsule, `(() => { const r = document.querySelector(".ycs-capsule").getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()`);
        await call(capsule, "Input.dispatchMouseEvent", { type: "mousePressed", x: c0.x, y: c0.y, button: "left", clickCount: 1, pointerType: "mouse" });
        await call(capsule, "Input.dispatchMouseEvent", { type: "mouseReleased", x: c0.x, y: c0.y, button: "left", clickCount: 1, pointerType: "mouse" });
        await sleep(80);
        await call(capsule, "Input.dispatchMouseEvent", { type: "mousePressed", x: c0.x, y: c0.y, button: "left", clickCount: 2, pointerType: "mouse" });
        await call(capsule, "Input.dispatchMouseEvent", { type: "mouseReleased", x: c0.x, y: c0.y, button: "left", clickCount: 2, pointerType: "mouse" });
        await sleep(1500);
    }

    // ===== 1. home 自绘标题栏存在与结构 =====
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline) {
        if ((await evalOn(home, `document.querySelector(".ycs-titlebar") !== null`))) {
            break;
        }
        await sleep(500);
    }
    await sleep(800);
    const tbInfo = await evalOn(
        home,
        `(() => { const tb = document.querySelector(".ycs-titlebar"); if (!tb) return null; return { title: tb.querySelector(".ycs-titlebar__title")?.textContent ?? "", hasDrag: tb.querySelector("[data-tauri-drag-region]") !== null, btnCount: tb.querySelectorAll(".ycs-titlebar__btn").length, bg: getComputedStyle(tb).backgroundColor }; })()`
    );
    check("home 标题栏存在", tbInfo !== null, `info=${JSON.stringify(tbInfo)}`);
    check("home 标题栏标题与拖动区", tbInfo?.title === "Taskbar Crypto Monitor" && tbInfo?.hasDrag === true, `title='${tbInfo?.title}' drag=${tbInfo?.hasDrag}`);
    check("home 标题栏深色背景与按钮", tbInfo?.bg.includes("15, 22, 38") && tbInfo?.btnCount === 2, `bg='${tbInfo?.bg}' btns=${tbInfo?.btnCount}`);

    // ===== 2. 胶囊主合约名（showSymbol 可能关闭，从 config 取）+ 备份用户仓位 =====
    const capsuleCfg = await evalOn(capsule, `window.__TAURI_INTERNALS__.invoke("get_config")`);
    const mainSymbol = capsuleCfg.symbol;
    /** 用户在该合约的原始仓位（测试结束前恢复） */
    const originalPosition = capsuleCfg.positions.find((p) => p.symbol === mainSymbol) ?? null;
    console.log(`INFO 主合约=${mainSymbol} 原仓位=${JSON.stringify(originalPosition)}`);

    // home 切到主合约（侧栏默认只渲染字母序前 60，需搜索）
    await evalOn(
        home,
        `(() => {
            const input = document.querySelector(".ycs-home__search");
            const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
            setter.call(input, ${JSON.stringify(mainSymbol)});
            input.dispatchEvent(new Event("input", { bubbles: true }));
            return true;
        })()`
    );
    await sleep(500);
    const switched = await evalOn(home, `document.querySelector(".ycs-marketbar__symbol")?.textContent ?? ""`);
    check("home 切换到胶囊主合约", switched === mainSymbol, `symbol='${switched}'`);

    // ===== 3. 关闭按钮 = 隐藏 home（胶囊仍活） =====
    await click(home, ".ycs-titlebar__btn--close");
    await sleep(1000);
    check("关闭按钮-隐藏 home 窗口", runSelftest("isvis", "home").includes("False"), `isvis=${runSelftest("isvis", "home")}`);
    check("关闭后-胶囊仍显示", runSelftest("isvis", "capsule").includes("True"), `isvis=${runSelftest("isvis", "capsule")}`);

    // 双击胶囊重新打开 home（后续测试需要）
    const c1 = await evalOn(capsule, `(() => { const r = document.querySelector(".ycs-capsule").getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()`);
    await call(capsule, "Input.dispatchMouseEvent", { type: "mousePressed", x: c1.x, y: c1.y, button: "left", clickCount: 1, pointerType: "mouse" });
    await call(capsule, "Input.dispatchMouseEvent", { type: "mouseReleased", x: c1.x, y: c1.y, button: "left", clickCount: 1, pointerType: "mouse" });
    await sleep(80);
    await call(capsule, "Input.dispatchMouseEvent", { type: "mousePressed", x: c1.x, y: c1.y, button: "left", clickCount: 2, pointerType: "mouse" });
    await call(capsule, "Input.dispatchMouseEvent", { type: "mouseReleased", x: c1.x, y: c1.y, button: "left", clickCount: 2, pointerType: "mouse" });
    await sleep(1500);
    check("双击胶囊-重新打开 home", runSelftest("isvis", "home").includes("True"), `isvis=${runSelftest("isvis", "home")}`);

    // ===== 4. 建测试仓位（1.0 做多 10 倍 5 个）→ 断言胶囊盈亏 =====
    if ((await evalOn(home, `document.querySelector(".ycs-newpos__remove") !== null`))) {
        await click(home, ".ycs-newpos__remove");
        await sleep(600);
    }
    await click(home, `.ycs-newpos__form .ycs-calc__direction button:first-child`);
    await setInput(home, `.ycs-newpos__form .ycs-calc__field:nth-child(2) input`, "1");
    await setInput(home, `.ycs-newpos__form .ycs-calc__field:nth-child(3) input`, "10");
    await setInput(home, `.ycs-newpos__form .ycs-calc__field:nth-child(4) input`, "5");
    await sleep(300);
    await click(home, ".ycs-newpos__save");
    await sleep(2000);
    const pnlInfo = await evalOn(
        capsule,
        `(() => { const el = document.querySelector(".ycs-pnl"); if (!el) return null; return { text: el.textContent ?? "", cls: el.className }; })()`
    );
    check("胶囊盈亏字段出现", pnlInfo !== null, `info=${JSON.stringify(pnlInfo)}`);
    if (pnlInfo !== null) {
        const capsulePrice = Number(await evalOn(capsule, `document.querySelector(".ycs-price")?.textContent?.replace(/,/g, "") ?? "0"`));
        const expect = (capsulePrice - 1) * 5;
        const shown = Number(pnlInfo.text.replace("u", "").replace("+", ""));
        const okSign = (expect >= 0 && pnlInfo.cls.includes("--up")) || (expect < 0 && pnlInfo.cls.includes("--down"));
        check("胶囊盈亏数值口径", Math.abs(shown - expect) < 0.5, `shown=${pnlInfo.text} expect=${expect.toFixed(2)} price=${capsulePrice}`);
        check("胶囊盈亏颜色类", okSign, `cls='${pnlInfo.cls}' expect>=0:${expect >= 0}`);
    }

    // ===== 5. 设置窗口：标题栏 + 精确切换"显示盈亏"开关 =====
    await evalOn(home, `window.__TAURI_INTERNALS__.invoke("open_settings")`);
    await sleep(1200);
    const targets2 = (await getTargets()).filter((t) => t.type === "page");
    let settings = null;
    for (const t of targets2) {
        const ws = await connect(t.webSocketDebuggerUrl);
        const label = await evalOn(ws, "window.__TAURI_INTERNALS__?.metadata?.currentWindow?.label ?? 'unknown'");
        if (label === "settings") {
            settings = ws;
        } else {
            ws.close();
        }
    }
    if (!settings) {
        throw new Error("设置窗口未打开");
    }
    const sDeadline = Date.now() + 20000;
    while (Date.now() < sDeadline) {
        if ((await evalOn(settings, `document.querySelector(".ycs-titlebar") !== null`))) {
            break;
        }
        await sleep(500);
    }
    const sTitle = await evalOn(settings, `document.querySelector(".ycs-titlebar__title")?.textContent ?? ""`);
    check("settings 标题栏存在", sTitle === "设置 - Taskbar Crypto Monitor", `title='${sTitle}'`);

    // 精确点击"显示盈亏"行的 checkbox（其它开关一律不动）
    const toggledOff = await evalOn(
        settings,
        `(() => { const row = [...document.querySelectorAll(".ycs-setting-row")].find((r) => r.querySelector(".ycs-setting-row__label")?.textContent === "显示盈亏"); if (!row) return "row-missing"; const box = row.querySelector(".ycs-setting-row__checkbox"); if (!box) return "box-missing"; box.click(); return "clicked"; })()`
    );
    check("settings 显示盈亏开关存在", toggledOff === "clicked", `result=${toggledOff}`);
    if (toggledOff === "clicked") {
        await sleep(1500);
        check("关闭开关-胶囊盈亏消失", (await evalOn(capsule, `document.querySelector(".ycs-pnl") === null`)) === true, "pnl 应已消失");
        await evalOn(
            settings,
            `(() => { const row = [...document.querySelectorAll(".ycs-setting-row")].find((r) => r.querySelector(".ycs-setting-row__label")?.textContent === "显示盈亏"); row.querySelector(".ycs-setting-row__checkbox").click(); return true; })()`
        );
        await sleep(1500);
        check("重开开关-胶囊盈亏恢复", (await evalOn(capsule, `document.querySelector(".ycs-pnl") !== null`)) === true, "pnl 应已恢复");
    }

    // ===== 6. 最小化按钮（rect 判定：最小化窗口 left 为 -32000） =====
    await click(home, ".ycs-titlebar__btn--min");
    await sleep(1000);
    const rectAfterMin = runSelftest("rect", "home");
    const minX = Number((rectAfterMin.match(/RECT.*?(-?\d+)/) ?? [])[1] ?? 0);
    check("最小化按钮-home 进入最小化态", minX < -1000, `rect=${rectAfterMin.slice(0, 60)}`);

    // ===== 7. 还原用户仓位（删除测试仓 + 恢复原仓位） =====
    await evalOn(
        home,
        `(async () => {
            const cfg = await window.__TAURI_INTERNALS__.invoke("get_config");
            cfg.positions = cfg.positions.filter((p) => p.symbol !== ${JSON.stringify(mainSymbol)});
            const restored = ${JSON.stringify(originalPosition)};
            if (restored !== null) {
                cfg.positions.push(restored);
            }
            await window.__TAURI_INTERNALS__.invoke("save_config", { config: cfg });
            return true;
        })()`
    );
    await sleep(800);
    const finalPositions = await evalOn(home, `window.__TAURI_INTERNALS__.invoke("get_config")`).then((c) => JSON.stringify(c.positions));
    const restoredOk = originalPosition === null ? finalPositions.includes(`${mainSymbol}`) === false : finalPositions.includes(`"quantity":${originalPosition.quantity}`) && finalPositions.includes(`"direction":"${originalPosition.direction}"`);
    check("测试仓位清理并还原用户仓位", restoredOk, `final=${finalPositions}`);

    console.log(`RESULT pass=${pass} fail=${fail}`);
    for (const ws of [home, capsule, ...(settings ? [settings] : [])]) {
        ws.close();
    }
    process.exit(fail > 0 ? 1 : 0);
}

main().catch((e) => {
    console.error("FAILED:", e.message);
    process.exit(1);
});