"use strict";
// Vanilla bridge between the flyout UI and the C# host (WebView2). No framework.
// Out: window.chrome.webview.postMessage(JSON.stringify({cmd,...}))
// In : window.chrome.webview.addEventListener('message', e => JSON.parse(e.data))  -> {type:'state',...}

const host = window.chrome && window.chrome.webview;
function send(obj) { if (host) host.postMessage(JSON.stringify(obj)); }

const $ = (id) => document.getElementById(id);
let state = null;

function renderBands(bands, freqs, center) {
  const wrap = $("bands");
  wrap.innerHTML = "";
  const c = 42, step = 4; // same geometry as the design
  (bands || []).forEach((v, i) => {
    const col = document.createElement("div");
    col.style.cssText = "display:flex;flex-direction:column;align-items:center;gap:6px";
    const top = v >= 0 ? c - v * step : c, h = Math.abs(v) * step;
    col.innerHTML =
      '<div class="band"><div class="fill" style="top:' + top + 'px;height:' + h + 'px"></div>' +
      '<div class="knob" style="top:' + (c - v * step - 8) + 'px"></div></div>' +
      '<span class="hz">' + ((freqs && freqs[i]) || "") + "</span>";
    wrap.appendChild(col);
  });
}

function render(s) {
  state = s;
  $("name").textContent = s.name || "Headphones";
  $("offline").style.display = s.connected ? "none" : "block";
  $("sub").textContent = s.connected ? ("Connected" + (s.codec ? " · " + s.codec : "")) : "Not connected";
  $("batt").textContent = (s.battery != null ? s.battery + "%" : "—") + (s.charging ? " ⚡" : "");

  document.querySelectorAll(".qs").forEach((b) =>
    b.classList.toggle("on", b.dataset.anc === s.anc));
  $("ambrow").classList.toggle("hidden", s.anc !== "ambient");
  if (s.ambient != null) { $("amb").value = s.ambient; $("ambval").textContent = s.ambient; $("amb").style.setProperty("--p", Math.round((s.ambient - 1) / 19 * 100) + "%"); }

  const sel = $("eqp");
  if (s.eqPresets && sel.options.length !== s.eqPresets.length) {
    sel.innerHTML = "";
    s.eqPresets.forEach((n) => { const o = document.createElement("option"); o.value = n; o.textContent = n; sel.appendChild(o); });
  }
  if (s.eqPreset) sel.value = s.eqPreset;
  renderBands(s.eqBands, s.eqFrequencies, s.eqCenter);

  const on = !!s.dsee;
  $("dseets").classList.toggle("on", on);
  $("dsee").setAttribute("aria-checked", on);
  $("dseetxt").textContent = on ? "On" : "Off";

  $("fw").textContent = "Firmware " + (s.firmware && s.firmware !== "—" ? s.firmware : "—");
  $("fwdot").style.background = s.connected ? "#6CCB5F" : "#8a8a8a";
}

// ---- events ----
document.querySelectorAll(".qs").forEach((b) =>
  b.addEventListener("click", () => send({ cmd: "anc", mode: b.dataset.anc })));

$("amb").addEventListener("input", (e) => { $("ambval").textContent = e.target.value; e.target.style.setProperty("--p", Math.round((e.target.value - 1) / 19 * 100) + "%"); });
$("amb").addEventListener("change", (e) => send({ cmd: "anc", mode: "ambient", level: +e.target.value }));
$("eqp").addEventListener("change", (e) => send({ cmd: "eq", preset: e.target.value }));
$("dsee").addEventListener("click", () => send({ cmd: "dsee", on: !(state && state.dsee) }));

if (host) host.addEventListener("message", (e) => {
  let msg; try { msg = JSON.parse(e.data); } catch { return; }
  if (msg && msg.type === "state") render(msg);
});

// Ask the host for current state on load and whenever the flyout is reopened.
send({ cmd: "status" });
window.addEventListener("focus", () => send({ cmd: "status" }));
