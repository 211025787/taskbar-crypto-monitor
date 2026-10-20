import React from "react";
import ReactDOM from "react-dom/client";
import { getCurrentWindow } from "@tauri-apps/api/window";
import App from "./App";
import Settings from "./Settings";

// 双窗口路由：依据 Tauri 窗口 label 分流渲染
// capsule -> 任务栏行情胶囊；settings -> 设置面板
const root = ReactDOM.createRoot(document.getElementById("root") as HTMLElement);

if (getCurrentWindow().label === "settings") {
    root.render(
        <React.StrictMode>
            <Settings />
        </React.StrictMode>
    );
} else {
    root.render(
        <React.StrictMode>
            <App />
        </React.StrictMode>
    );
}