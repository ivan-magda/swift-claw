import { writeFileSync } from "node:fs";

const [, , websocketURL, previewURL, outputPath] = process.argv;
if (!websocketURL || !previewURL || !outputPath) {
  throw new Error("usage: capture-preview.mjs <page-websocket-url> <preview-url> <output-path>");
}

const socket = new WebSocket(websocketURL);
let nextID = 0;
const pending = new Map();

socket.addEventListener("message", (event) => {
  const message = JSON.parse(event.data);
  if (!message.id) return;

  const waiter = pending.get(message.id);
  if (!waiter) return;

  pending.delete(message.id);
  if (message.error) {
    waiter.reject(new Error(JSON.stringify(message.error)));
  } else {
    waiter.resolve(message.result);
  }
});

await new Promise((resolve, reject) => {
  socket.addEventListener("open", resolve, { once: true });
  socket.addEventListener("error", reject, { once: true });
});

const call = (method, params = {}) =>
  new Promise((resolve, reject) => {
    const id = ++nextID;
    pending.set(id, { resolve, reject });
    socket.send(JSON.stringify({ id, method, params }));
  });

await call("Page.enable");
await call("Runtime.enable");
await call("Page.navigate", { url: previewURL });

let state;
const deadline = Date.now() + 120_000;
while (Date.now() < deadline) {
  const response = await call("Runtime.evaluate", {
    expression: `(() => ({
      status: document.body.dataset.previewStatus || "starting",
      probe: window.previewProbe || null
    }))()`,
    returnByValue: true,
  });

  state = response.result?.value;
  if (state?.status === "ready" || state?.status === "fatal") break;
  await new Promise((resolve) => setTimeout(resolve, 500));
}

if (state?.status !== "ready") {
  throw new Error(`preview failed to become ready: ${JSON.stringify(state)}`);
}

const screenshot = await call("Page.captureScreenshot", {
  format: "png",
  fromSurface: true,
  captureBeyondViewport: true,
});

writeFileSync(outputPath, Buffer.from(screenshot.data, "base64"));
console.log(JSON.stringify({ outputPath, state }));
socket.close();
