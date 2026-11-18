// Review page: pin comments on a photo region or a video timecode, approve or request changes.
(function () {
  const base = `/s/${window.SHARE}`;
  const list = document.getElementById("comments");
  const pins = document.getElementById("pins");
  const text = () => document.getElementById("comment-text").value || "(no text)";

  function timecode(t) {
    const f = Math.round(t * 30000 / 1001);           // 29.97 frame count
    const s = Math.floor(f / 30), fr = f % 30;
    return `${String(Math.floor(s / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}:${String(fr).padStart(2, "0")}`;
  }

  function show(c) {
    const li = document.createElement("li");
    li.className = "comment";
    if (c.t !== undefined) { li.dataset.t = c.t; li.textContent = `${timecode(c.t)} ${c.text}`; }
    else { li.dataset.x = c.x; li.dataset.y = c.y; li.textContent = `(${c.x.toFixed(2)}, ${c.y.toFixed(2)}) ${c.text}`; }
    list.appendChild(li);
    if (pins && c.x !== undefined) {
      const p = document.createElement("div");
      p.className = "pin";
      p.dataset.x = c.x; p.dataset.y = c.y;
      p.style.left = `${c.x * 100}%`; p.style.top = `${c.y * 100}%`;
      p.setAttribute("aria-label", c.text);
      pins.appendChild(p);
    }
  }

  async function post(path, body) {
    const r = await fetch(base + path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
    if (!r.ok) throw new Error(`${path}: ${r.status}`);
    return r.json();
  }

  fetch(base + "/comments").then(r => r.json()).then(cs => cs.forEach(show));

  const asset = document.getElementById("asset");
  if (window.KIND !== "video") {
    asset.addEventListener("click", async (e) => {
      const r = asset.getBoundingClientRect();
      const c = { text: text(), x: (e.clientX - r.left) / r.width, y: (e.clientY - r.top) / r.height };
      show(await post("/comments", c));
    });
  } else {
    document.getElementById("comment-at-time").addEventListener("click", async () => {
      show(await post("/comments", { text: text(), t: asset.currentTime }));
    });
  }

  for (const [id, status] of [["approve", "approved"], ["request-changes", "changes_requested"]]) {
    document.getElementById(id).addEventListener("click", async () => {
      const r = await post("/status", { status });
      document.getElementById("status").textContent = r.status;
    });
  }
  document.body.dataset.ready = "1";
})();
