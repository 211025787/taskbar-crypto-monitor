// 计算器逐键输入验证：模拟真实键盘逐字符敲入，断言每步 input.value 保留原始文本
// 用法：node scripts/cdp-calc.mjs [port]
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
        throw new Error(`evaluate 异常: ${JSON.stringify(r.exceptionDetails)}`);
    }
    return r.result.value;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 程序化清空输入框（React 受控回空串），避免上一套件残留值与键盘追加输入叠加 */
async function clearInput(ws, index) {
    await evalOn(
        ws,
        `(() => {
            const input = document.querySelectorAll(".ycs-calc__input")[${index}];
            if (!input) throw new Error("input 不存在");
            const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
            setter.call(input, "");
            input.dispatchEvent(new Event("input", { bubbles: true }));
            return true;
        })()`
    );
    await sleep(150);
}

/** CDP 真实键盘逐字符输入 */
async function typeText(ws, text) {
    for (const ch of text) {
        await call(ws, "Input.dispatchKeyEvent", { type: "keyDown", text: ch });
        await call(ws, "Input.dispatchKeyEvent", { type: "keyUp", key: ch });
        await sleep(60);
    }
}

/** CDP 真实点击元素中心：先 scrollIntoView 保证元素进入视口（视口外坐标注入会被 CDP 静默丢弃），仍在视口外时兜底 el.click() */
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

    // 等待右栏面板渲染（无仓位 = 新建表单 / 有仓位 = 持仓卡，二态皆渲染 .ycs-panel）
    const panelDeadline = Date.now() + 30000;
    while (Date.now() < panelDeadline) {
        if ((await evalOn(home, `document.querySelector(".ycs-panel") !== null`))) {
            break;
        }
        await sleep(500);
    }
    await sleep(800);

    // 清场：持久化仓位跨套件残留时有仓位态无新建表单（.ycs-calc__input 只剩模拟卡 2 个），先删除回到新建态
    if ((await evalOn(home, `document.querySelector(".ycs-newpos__remove") !== null`))) {
        await click(home, ".ycs-newpos__remove");
        await sleep(600);
    }

    // 等待新建表单渲染就绪（前三个 input 依次为 开仓价/杠杆/数量）
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline) {
        if ((await evalOn(home, `document.querySelectorAll(".ycs-calc__input").length`)) >= 3) {
            break;
        }
        await sleep(500);
    }
    await sleep(500);

    // ===== 开仓价逐键输入 "0.005134"：每步断言 value 保留原始前缀 =====
    await clearInput(home, 0);
    // 坐标点击前先 scrollIntoView：视口外坐标注入会被 CDP 静默丢弃
    await evalOn(home, `document.querySelectorAll(".ycs-calc__input")[0].scrollIntoView({ block: "center" })`);
    await sleep(250);
    const entryCenter = await evalOn(
        home,
        `(() => { const el = document.querySelectorAll(".ycs-calc__input")[0]; const r = el.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()`
    );
    await call(home, "Input.dispatchMouseEvent", { type: "mouseMoved", x: entryCenter.x, y: entryCenter.y, button: "none", pointerType: "mouse" });
    await call(home, "Input.dispatchMouseEvent", { type: "mousePressed", x: entryCenter.x, y: entryCenter.y, button: "left", clickCount: 1, pointerType: "mouse" });
    await call(home, "Input.dispatchMouseEvent", { type: "mouseReleased", x: entryCenter.x, y: entryCenter.y, button: "left", clickCount: 1, pointerType: "mouse" });
    await sleep(300);

    const ENTRY = "0.005134";
    let allStepsOk = true;
    const stepLog = [];
    for (let i = 0; i < ENTRY.length; i++) {
        await typeText(home, ENTRY[i]);
        await sleep(80);
        const value = await evalOn(home, `document.querySelectorAll(".ycs-calc__input")[0].value`);
        const expected = ENTRY.slice(0, i + 1);
        stepLog.push(`'${expected}'->'${value}'`);
        if (value !== expected) {
            allStepsOk = false;
        }
    }
    check("开仓价逐键输入 0.005134 全程无吞字符", allStepsOk, stepLog.join(" "));

    // ===== 数量逐键输入 "0.5"（前导 0 同样关键） =====
    await clearInput(home, 2);
    // 坐标点击前先 scrollIntoView：视口外坐标注入会被 CDP 静默丢弃
    await evalOn(home, `document.querySelectorAll(".ycs-calc__input")[2].scrollIntoView({ block: "center" })`);
    await sleep(250);
    const qtyCenter = await evalOn(
        home,
        `(() => { const el = document.querySelectorAll(".ycs-calc__input")[2]; const r = el.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()`
    );
    await call(home, "Input.dispatchMouseEvent", { type: "mousePressed", x: qtyCenter.x, y: qtyCenter.y, button: "left", clickCount: 1, pointerType: "mouse" });
    await call(home, "Input.dispatchMouseEvent", { type: "mouseReleased", x: qtyCenter.x, y: qtyCenter.y, button: "left", clickCount: 1, pointerType: "mouse" });
    await sleep(300);
    await typeText(home, "0.5");
    await sleep(200);
    const qtyValue = await evalOn(home, `document.querySelectorAll(".ycs-calc__input")[2].value`);
    check("数量输入 0.5 保留前导零", qtyValue === "0.5", `value='${qtyValue}'`);

    // ===== 输入合法后保存按钮应启用 =====
    const saveDisabled = await evalOn(home, `document.querySelector(".ycs-newpos__save")?.disabled ?? null`);
    check("保存按钮启用", saveDisabled === false, `disabled=${saveDisabled}`);

    // ===== 派生数值与实时计算（有行情时结果非占位） =====
    const entryValue = await evalOn(home, `document.querySelectorAll(".ycs-calc__input")[0].value`);
    const levValue = await evalOn(home, `document.querySelectorAll(".ycs-calc__input")[1].value`);
    const margin = await evalOn(home, `document.querySelector(".ycs-newpos__results .ycs-calc__result-value")?.textContent ?? null`);
    const price = await evalOn(home, `document.querySelector(".ycs-marketbar__price")?.textContent ?? null`);
    console.log("STATE:", JSON.stringify({ entryValue, levValue, margin, price }));
    check("杠杆默认值 10 保留", levValue === "10", `lev='${levValue}'`);

    console.log(`RESULT pass=${pass} fail=${fail}`);
    home.close();
    process.exit(fail > 0 ? 1 : 0);
}

main().catch((e) => {
    console.error("FAILED:", e.message);
    process.exit(1);
});