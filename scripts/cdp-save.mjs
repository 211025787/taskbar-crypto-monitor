// 验证新建表单保存仓位 → 持仓卡值正确 → 删除恢复默认表单（含跨套件清场）
const port = 9333;

async function main() {
    const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    let home = null;
    for (const t of targets.filter((x) => x.type === "page")) {
        const ws = new WebSocket(t.webSocketDebuggerUrl);
        await new Promise((r, j) => {
            ws.onopen = r;
            ws.onerror = j;
        });
        let id = 1;
        const pending = new Map();
        ws.addEventListener("message", (ev) => {
            const m = JSON.parse(String(ev.data));
            if (m.id && pending.has(m.id)) {
                pending.get(m.id)(m.result);
                pending.delete(m.id);
            }
        });
        const call = (method, params) => new Promise((resolve) => {
            const mid = id++;
            pending.set(mid, resolve);
            ws.send(JSON.stringify({ id: mid, method, params }));
        });
        const evalOn = async (expr) => {
            const r = await call("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true });
            if (r.exceptionDetails) {
                throw new Error(JSON.stringify(r.exceptionDetails).slice(0, 150));
            }
            return r.result?.value;
        };
        const label = await evalOn("window.__TAURI_INTERNALS__?.metadata?.currentWindow?.label");
        if (label === "home") {
            home = { call, evalOn };
        } else {
            ws.close();
        }
    }
    if (!home) {
        throw new Error("no home");
    }

    // 等待右栏面板渲染（无仓位 = 新建表单 / 有仓位 = 持仓卡，二态皆渲染 .ycs-panel）
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline) {
        if ((await home.evalOn(`document.querySelector(".ycs-panel") !== null`))) {
            break;
        }
        await new Promise((r) => setTimeout(r, 500));
    }
    await new Promise((r) => setTimeout(r, 800));

    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

    /** 程序化设值触发 React onChange（原生 value setter + input 事件，幂等） */
    const setInput = async (selector, value) => {
        await home.evalOn(
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
    };

    /** 坐标点击按钮：先 scrollIntoView（视口外坐标注入会被 CDP 静默丢弃），仍越界则兜底 el.click() */
    const clickBtn = async (selector) => {
        await home.evalOn(`document.querySelector(${JSON.stringify(selector)})?.scrollIntoView({ block: "center" })`);
        await sleep(250);
        const rect = await home.evalOn(
            `(() => { const el = document.querySelector(${JSON.stringify(selector)}); const r = el.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2, window.innerWidth, window.innerHeight]; })()`
        );
        if (rect[0] >= 0 && rect[1] >= 0 && rect[0] < rect[2] && rect[1] < rect[3]) {
            await home.call("Input.dispatchMouseEvent", { type: "mousePressed", x: rect[0], y: rect[1], button: "left", clickCount: 1, pointerType: "mouse" });
            await home.call("Input.dispatchMouseEvent", { type: "mouseReleased", x: rect[0], y: rect[1], button: "left", clickCount: 1, pointerType: "mouse" });
        } else {
            await home.evalOn(`document.querySelector(${JSON.stringify(selector)}).click()`);
        }
        await sleep(250);
    };

    // 清场：持久化仓位跨套件残留时先删除，保证从新建表单态开始
    if ((await home.evalOn(`document.querySelector(".ycs-newpos__remove") !== null`))) {
        await clickBtn(".ycs-newpos__remove");
        await sleep(600);
    }

    // ===== 程序化填写新仓位：开仓价 0.005134 / 杠杆 10 / 数量 0.5 → 保存 =====
    await setInput(`.ycs-newpos__form .ycs-calc__field:nth-child(2) input`, "0.005134");
    await setInput(`.ycs-newpos__form .ycs-calc__field:nth-child(3) input`, "10");
    await setInput(`.ycs-newpos__form .ycs-calc__field:nth-child(4) input`, "0.5");
    await sleep(300);
    await clickBtn(".ycs-newpos__save");
    await sleep(2000);

    // 持仓卡出现 + 均值回读（label -> value 映射）
    const poscard = await home.evalOn(
        `(() => {
            const out = {};
            for (const el of document.querySelectorAll(".ycs-poscard__row")) {
                const label = el.querySelector(".ycs-poscard__label")?.textContent ?? "";
                const value = el.querySelector(".ycs-poscard__value")?.textContent ?? "";
                out[label] = value;
            }
            return out;
        })()`
    );
    const hasRemove = await home.evalOn(`document.querySelector(".ycs-newpos__remove") !== null`);

    // ===== 删除仓位 → 回到新建表单（输入重置默认值） =====
    if (hasRemove) {
        await clickBtn(".ycs-newpos__remove");
        await sleep(2000);
    }
    const formBack = await home.evalOn(`document.querySelector(".ycs-newpos__form") !== null`);
    const entryReset = await home.evalOn(`document.querySelector(".ycs-newpos__form .ycs-calc__field:nth-child(2) input")?.value ?? null`);
    const levReset = await home.evalOn(`document.querySelector(".ycs-newpos__form .ycs-calc__field:nth-child(3) input")?.value ?? null`);
    const removeGone = await home.evalOn(`document.querySelector(".ycs-newpos__remove") === null`);

    let pass = 0;
    let fail = 0;
    const check = (name, ok, detail = "") => {
        if (ok) {
            pass++;
        } else {
            fail++;
        }
        console.log(`${ok ? "PASS" : "FAIL"} ${name} ${detail}`);
    };
    check("保存后持仓卡出现", "均价 / 数量" in poscard, `keys=${Object.keys(poscard).join(",")}`);
    check("保存后仓位值正确", (poscard["均价 / 数量"] ?? "").startsWith("0.005134"), `row='${poscard["均价 / 数量"]}'`);
    check("删除按钮出现", hasRemove, `remove=${hasRemove}`);
    check("删除后回到新建表单", formBack === true && entryReset === "" && levReset === "10" && removeGone, `form=${formBack} entry='${entryReset}' lev='${levReset}' removeGone=${removeGone}`);
    console.log(`RESULT pass=${pass} fail=${fail}`);
    process.exit(fail > 0 ? 1 : 0);
}

main().catch((e) => {
    console.error("FAILED:", e.message);
    process.exit(1);
});