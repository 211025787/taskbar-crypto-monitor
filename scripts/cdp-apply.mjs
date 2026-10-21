// 应用到仓位端到端验证：新建→保存→模拟减仓→两段式应用→持久化→删除恢复
// 用法：node scripts/cdp-apply.mjs [port]
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

/** 持仓卡 label→value 映射 */
function poscardExpr() {
    return `(() => {
        const out = {};
        for (const el of document.querySelectorAll(".ycs-poscard__row")) {
            const label = el.querySelector(".ycs-poscard__label")?.textContent ?? "";
            const value = el.querySelector(".ycs-poscard__value")?.textContent ?? "";
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

    // 等待渲染就绪（新建表单或持仓卡出现）
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline) {
        if ((await evalOn(home, `document.querySelector(".ycs-panel") !== null`))) {
            break;
        }
        await sleep(500);
    }
    await sleep(800);

    // ===== 0. 清场：若已有仓位先删除（幂等） =====
    if ((await evalOn(home, `document.querySelector(".ycs-newpos__remove") !== null`))) {
        await click(home, ".ycs-newpos__remove");
        await sleep(600);
    }

    // ===== 1. 新建仓位：做多 1.0 / 杠杆 10 / 数量 10 → 保存 =====
    await click(home, `.ycs-newpos__form .ycs-calc__direction button:first-child`);
    await setInput(home, `.ycs-newpos__form .ycs-calc__field:nth-child(2) input`, "1");
    await setInput(home, `.ycs-newpos__form .ycs-calc__field:nth-child(3) input`, "10");
    await setInput(home, `.ycs-newpos__form .ycs-calc__field:nth-child(4) input`, "10");
    await sleep(300);
    await click(home, ".ycs-newpos__save");
    await sleep(800);
    let card = await evalOn(home, poscardExpr());
    check("新建保存-持仓卡出现", "均价 / 数量" in card, `keys=${Object.keys(card).join(",")}`);
    check("新建保存-仓位值正确", (card["均价 / 数量"] ?? "").startsWith("1.0000000"), `row='${card["均价 / 数量"]}'`);

    // ===== 2. 模拟减仓 10 @ 0.9（全平）→ 两段式应用 =====
    await click(home, `.ycs-sim__form .ycs-calc__direction button:last-child`);
    await setInput(home, `.ycs-sim__form .ycs-calc__field:nth-child(2) input`, "0.9");
    await setInput(home, `.ycs-sim__form .ycs-calc__field:nth-child(3) input`, "10");
    await sleep(400);
    const simText = await evalOn(home, `document.querySelector(".ycs-sim__results")?.textContent ?? ""`);
    check("模拟预览-含本次已实现盈亏", simText.includes("本次已实现盈亏"), `text=${simText.slice(0, 80)}`);

    // 首击：按钮进入确认态
    await click(home, ".ycs-sim__apply");
    await sleep(300);
    const confirmText = await evalOn(home, `document.querySelector(".ycs-sim__apply")?.textContent ?? ""`);
    check("应用首击-按钮变确认态", confirmText.includes("确认应用"), `text='${confirmText}'`);

    // 二击：真正写入
    await click(home, ".ycs-sim__apply");
    await sleep(1000);
    card = await evalOn(home, poscardExpr());
    const closedBadge = await evalOn(home, `document.querySelector(".ycs-poscard__closed")?.textContent ?? ""`);
    check("应用二击-全平徽标", closedBadge.includes("已平仓"), `badge='${closedBadge}'`);
    check("应用二击-累计已实现 -1.00", (card["累计已实现盈亏"] ?? "").startsWith("-1.00"), `row='${card["累计已实现盈亏"]}'`);

    // ===== 3. 模拟卡全平占位 =====
    const simHint = await evalOn(home, `document.querySelector(".ycs-sim__hint")?.textContent ?? ""`);
    check("全平后-模拟卡占位提示", simHint.includes("已平"), `hint='${simHint}'`);

    // ===== 4. 删除仓位 → 回到新建表单 =====
    await click(home, ".ycs-newpos__remove");
    await sleep(600);
    const backToForm = await evalOn(home, `document.querySelector(".ycs-newpos__form") !== null`);
    check("删除仓位-回到新建表单", backToForm === true, `form=${backToForm}`);

    console.log(`RESULT pass=${pass} fail=${fail}`);
    home.close();
    process.exit(fail > 0 ? 1 : 0);
}

main().catch((e) => {
    console.error("FAILED:", e.message);
    process.exit(1);
});