// 加减仓模拟 + 刷新按钮 CDP 实测：真实输入注入 + DOM 断言
// 用法：node scripts/cdp-sim.mjs [port]
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

/** CDP 真实点击元素中心：先 scrollIntoView 保证元素进入视口（低于视口的坐标注入会被丢弃），仍在视口外时兜底 el.click() */
async function click(ws, selector) {
    const exists = await evalOn(
        ws,
        `(() => { const el = document.querySelector(${JSON.stringify(selector)}); if (!el) return false; el.scrollIntoView({ block: "center" }); return true; })()`
    );
    if (!exists) {
        throw new Error(`元素不存在: ${selector}`);
    }
    await sleep(250);
    const info = await evalOn(
        ws,
        `(() => { const r = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2, vw: window.innerWidth, vh: window.innerHeight }; })()`
    );
    if (info.x >= 0 && info.y >= 0 && info.x < info.vw && info.y < info.vh) {
        await call(ws, "Input.dispatchMouseEvent", { type: "mouseMoved", x: info.x, y: info.y, button: "none", pointerType: "mouse" });
        await call(ws, "Input.dispatchMouseEvent", { type: "mousePressed", x: info.x, y: info.y, button: "left", clickCount: 1, pointerType: "mouse" });
        await call(ws, "Input.dispatchMouseEvent", { type: "mouseReleased", x: info.x, y: info.y, button: "left", clickCount: 1, pointerType: "mouse" });
    } else {
        await evalOn(ws, `document.querySelector(${JSON.stringify(selector)}).click()`);
    }
    await sleep(250);
}

/** 程序化设值触发 React onChange（幂等，适合精确数值注入） */
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

/** 读取模拟面板各结果格文本（label -> value 映射） */
function simResultsExpr() {
    return `(() => {
        const out = {};
        for (const el of document.querySelectorAll(".ycs-sim__results .ycs-calc__result")) {
            const label = el.querySelector(".ycs-calc__result-label")?.textContent ?? "";
            const value = el.querySelector(".ycs-calc__result-value")?.textContent ?? "";
            out[label] = value;
        }
        return out;
    })()`;
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
    let home = null;
    for (const t of targets) {
        const ws = await connect(t.webSocketDebuggerUrl);
        const label = await evalOn(ws, "window.__TAURI_INTERNALS__?.metadata?.currentWindow?.label ?? 'unknown'");
        if (label === "home") {
            home = ws;
        } else {
            ws.close();
        }
    }
    if (!home) {
        throw new Error("未找到 home 窗口");
    }

    // 等待渲染就绪（右栏面板出现：无仓位 = 新建表单 / 有仓位 = 持仓卡，二态皆渲染 .ycs-panel）
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline) {
        if ((await evalOn(home, `document.querySelector(".ycs-panel") !== null`))) {
            break;
        }
        await sleep(500);
    }
    await sleep(800);

    // ===== 1. 新建基础仓位并保存（用户例子：开仓 1.0、数量 10、杠杆 10、做多） =====
    // 持久化仓位跨套件残留（config.json），有仓位态先删除清场回到新建表单
    if ((await evalOn(home, `document.querySelector(".ycs-newpos__remove") !== null`))) {
        await click(home, ".ycs-newpos__remove");
        await sleep(600);
    }
    // 持久化仓位可能回填 short 方向，显式点击做多按钮保证确定性初始态
    await click(home, `.ycs-newpos__form .ycs-calc__direction button:first-child`);
    await setInput(home, `.ycs-newpos__form .ycs-calc__field:nth-child(2) input`, "1");
    await setInput(home, `.ycs-newpos__form .ycs-calc__field:nth-child(3) input`, "10");
    await setInput(home, `.ycs-newpos__form .ycs-calc__field:nth-child(4) input`, "10");
    await sleep(300);
    // 保存后右栏切换为持仓卡 + 模拟操作卡（等待落盘 + 父级 state 更新重渲染）
    await click(home, ".ycs-newpos__save");
    await sleep(800);

    // ===== 2. 加仓模拟：0.9 加仓 10 个 → 新均价 0.95、数量 20 =====
    // 上一轮验证可能把 simAction 切到 reduce（React state 跨测试保留），显式复位到加仓
    await click(home, `.ycs-sim__form .ycs-calc__direction button:first-child`);
    await setInput(home, `.ycs-sim__form .ycs-calc__field:nth-child(2) input`, "0.9");
    await setInput(home, `.ycs-sim__form .ycs-calc__field:nth-child(3) input`, "10");
    await sleep(400);
    let sim = await evalOn(home, simResultsExpr());
    check("加仓模拟-操作后均价 0.95", sim["操作后均价"]?.startsWith("0.95"), `avg='${sim["操作后均价"]}'`);
    check("加仓模拟-操作后数量 20", sim["操作后数量"]?.startsWith("20"), `qty='${sim["操作后数量"]}'`);
    check("加仓模拟-保证金 1.9", sim["操作后保证金"]?.startsWith("1.9"), `margin='${sim["操作后保证金"]}'`);
    check("加仓模拟-无已实现盈亏格", !("本次已实现盈亏" in sim), `keys=${Object.keys(sim).join(",")}`);

    // ===== 3. 切到减仓：均价不变 1.0、锁定已实现盈亏 =====
    await click(home, `.ycs-sim__form .ycs-calc__dir-btn:last-child`);
    await sleep(300);
    sim = await evalOn(home, simResultsExpr());
    check("减仓模拟-均价不变 1", sim["操作后均价"]?.startsWith("1"), `avg='${sim["操作后均价"]}'`);
    check("减仓模拟-数量 0（全平）", sim["操作后数量"]?.startsWith("0"), `qty='${sim["操作后数量"]}'`);
    check("减仓模拟-已实现盈亏 -1.00", sim["本次已实现盈亏"]?.startsWith("-1.00"), `realized='${sim["本次已实现盈亏"]}'`);

    // ===== 4. 减仓超量提示 =====
    await setInput(home, `.ycs-sim__form .ycs-calc__field:nth-child(3) input`, "11");
    await sleep(300);
    const overHint = await evalOn(home, `document.querySelector(".ycs-sim__hint")?.textContent ?? ""`);
    sim = await evalOn(home, simResultsExpr());
    check("减仓超量-提示出现", overHint.includes("超出"), `hint='${overHint}'`);
    check("减仓超量-结果占位", sim["操作后均价"] === "—", `avg='${sim["操作后均价"]}'`);

    // ===== 5. 刷新按钮：点击后更新时间变化 =====
    const timeBefore = await evalOn(home, `document.querySelector(".ycs-marketbar__time")?.textContent ?? ""`);
    await click(home, `.ycs-marketbar__refresh-btn`);
    await sleep(2500);
    const timeAfter = await evalOn(home, `document.querySelector(".ycs-marketbar__time")?.textContent ?? ""`);
    check("刷新按钮-更新时间存在且刷新", timeAfter.includes("更新") && timeAfter !== timeBefore, `before='${timeBefore}' after='${timeAfter}'`);

    // ===== 6. 模拟面板不落盘：sim 区共 3 个按钮（加/减仓切换 2 个 + 应用 1 个），无保存按钮 =====
    const simButtons = await evalOn(home, `document.querySelectorAll(".ycs-sim button").length`);
    const simSaveGone = await evalOn(home, `document.querySelector(".ycs-sim .ycs-newpos__save") === null`);
    const simHasApply = await evalOn(home, `document.querySelector(".ycs-sim__apply") !== null`);
    check("模拟面板-切换+应用无保存", simButtons === 3 && simSaveGone && simHasApply, `buttons=${simButtons} saveGone=${simSaveGone} apply=${simHasApply}`);

    console.log(`RESULT pass=${pass} fail=${fail}`);
    home.close();
    process.exit(fail > 0 ? 1 : 0);
}

main().catch((e) => {
    console.error("FAILED:", e.message);
    process.exit(1);
});