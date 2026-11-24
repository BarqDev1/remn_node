document.addEventListener("DOMContentLoaded", function () {
  var engine = window.TestNetEngine;
  var pingBtn = document.getElementById("run-ping-series");
  var pingCanvas = document.getElementById("ping-chart");
  var pingStatus = document.getElementById("ping-status");
  var speedInput = document.getElementById("calc-speed");
  var calcBody = document.getElementById("calc-body");

  var FILES = [
    { name: "Фотоархив и документы", label: "500 МБ", mb: 500 },
    { name: "Обновление системы / драйверы", label: "6 ГБ", mb: 6144 },
    { name: "Фильм 4K HDR", label: "25 ГБ", mb: 25600 },
    { name: "Современная игра / дистрибутив", label: "85 ГБ", mb: 87040 },
    { name: "Облачная резервная копия", label: "200 ГБ", mb: 204800 }
  ];

  function formatDuration(seconds) {
    if (!Number.isFinite(seconds) || seconds <= 0) return "—";
    if (seconds < 60) return Math.max(1, Math.round(seconds)) + " сек";
    var mins = Math.floor(seconds / 60);
    var secs = Math.round(seconds % 60);
    if (mins < 60) return mins + " мин " + secs + " сек";
    var hrs = Math.floor(mins / 60);
    return hrs + " ч " + (mins % 60) + " мин";
  }

  function renderCalc() {
    if (!calcBody || !speedInput) return;
    var mbps = parseFloat(speedInput.value);
    if (!Number.isFinite(mbps) || mbps <= 0) mbps = 100;
    var mbPerSec = mbps / 8;
    calcBody.replaceChildren();
    FILES.forEach(function (f) {
      var tr = document.createElement("tr");
      var th = document.createElement("th");
      th.scope = "row";
      th.textContent = f.name;
      tr.appendChild(th);

      var tdSize = document.createElement("td");
      tdSize.textContent = f.label;
      tr.appendChild(tdSize);

      var tdTime = document.createElement("td");
      tdTime.textContent = formatDuration(f.mb / mbPerSec);
      tr.appendChild(tdTime);
      calcBody.appendChild(tr);
    });
  }

  if (speedInput) {
    try {
      var raw = localStorage.getItem("testnet_history_v1");
      var hist = raw ? JSON.parse(raw) : [];
      if (hist.length && hist[0].dl > 0) {
        speedInput.value = String(Math.round(hist[0].dl));
      }
    } catch (e) {}
    speedInput.addEventListener("input", renderCalc);
    document.querySelectorAll("[data-preset-mbps]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        speedInput.value = btn.getAttribute("data-preset-mbps") || "100";
        renderCalc();
      });
    });
    renderCalc();
  }

  var samples = [];
  function drawPingBars() {
    if (!pingCanvas) return;
    var ctx = pingCanvas.getContext("2d");
    var dpr = window.devicePixelRatio || 1;
    var rect = pingCanvas.getBoundingClientRect();
    var w = Math.max(260, Math.round(rect.width));
    var h = Math.max(140, Math.round(rect.height));
    if (pingCanvas.width !== w * dpr || pingCanvas.height !== h * dpr) {
      pingCanvas.width = w * dpr;
      pingCanvas.height = h * dpr;
    }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);

    var styles = getComputedStyle(document.documentElement);
    var lineColor = styles.getPropertyValue("--line").trim() || "#334155";
    var mutedColor = styles.getPropertyValue("--muted").trim() || "#94a3b8";

    ctx.strokeStyle = lineColor;
    ctx.beginPath();
    ctx.moveTo(12, h - 22);
    ctx.lineTo(w - 12, h - 22);
    ctx.stroke();

    if (!samples.length) {
      ctx.fillStyle = mutedColor;
      ctx.font = "13px system-ui, sans-serif";
      ctx.fillText("Нажмите «Запустить серию (24 пакета)» для проверки стабильности отклика.", 16, h / 2);
      return;
    }

    var maxRtt = Math.max(25, Math.max.apply(null, samples) * 1.2);
    var slotW = (w - 28) / 24;
    var barW = Math.max(4, slotW - 4);
    samples.forEach(function (val, idx) {
      var barH = Math.max(6, ((val / maxRtt) * (h - 44)));
      var x = 14 + idx * slotW;
      var y = h - 22 - barH;
      ctx.fillStyle = val > 60 ? "#f59e0b" : "#10b981";
      ctx.fillRect(x, y, barW, barH);
    });
  }

  var activeCtrl = null;
  if (pingBtn && engine) {
    pingBtn.addEventListener("click", async function () {
      if (activeCtrl) {
        activeCtrl.abort();
        return;
      }
      activeCtrl = new AbortController();
      samples = [];
      pingBtn.textContent = "Остановить серию";
      if (pingStatus) pingStatus.textContent = "Отправка серии из 24 импульсов к узлу ТестНет.рф...";
      drawPingBars();

      try {
        var res = await engine.measurePing(24, function (s) {
          if (s.ok && s.rtt !== null) samples.push(s.rtt);
          drawPingBars();
        }, activeCtrl.signal);
        document.getElementById("d-min").textContent = res.min.toFixed(1) + " мс";
        document.getElementById("d-med").textContent = res.median.toFixed(1) + " мс";
        document.getElementById("d-p95").textContent = res.p95.toFixed(1) + " мс";
        document.getElementById("d-jit").textContent = res.jitter.toFixed(1) + " мс";
        if (pingStatus) {
          var verdict = res.jitter <= 8 && res.lossPct === 0
            ? "Канал стабильный, резких скачков задержки не выявлено."
            : "Наблюдается повышенный разброс (джиттер " + res.jitter.toFixed(1) + " мс). Возможна перегрузка Wi-Fi или маршрута.";
          pingStatus.textContent = "Серия завершена: потерь " + res.lossPct.toFixed(0) + "%. " + verdict;
        }
      } catch (err) {
        if (pingStatus) pingStatus.textContent = "Серийный замер остановлен.";
      } finally {
        activeCtrl = null;
        pingBtn.textContent = "Запустить серию (24 пакета)";
      }
    });
  }

  window.addEventListener("testnet:themechange", drawPingBars);
  window.addEventListener("resize", drawPingBars);
  drawPingBars();
});
