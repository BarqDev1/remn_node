document.addEventListener("DOMContentLoaded", function () {
  var engine = window.TestNetEngine;
  var store = window.TestNetStore;
  if (!engine || !store) return;

  var startBtn = document.getElementById("start-test");
  var copyBtn = document.getElementById("copy-report");
  var exportBtn = document.getElementById("export-csv");
  var clearBtn = document.getElementById("clear-history");
  var progressEl = document.getElementById("speed-progress");
  var phaseEl = document.getElementById("gauge-phase");
  var speedEl = document.getElementById("gauge-speed");
  var unitEl = document.getElementById("gauge-unit");
  var chartEl = document.getElementById("throughput-chart");
  var statusLine = document.getElementById("session-status");
  var historyBody = document.getElementById("history-body");

  var pingValEl = document.getElementById("m-ping");
  var pingSubEl = document.getElementById("m-ping-sub");
  var jitterValEl = document.getElementById("m-jitter");
  var jitterSubEl = document.getElementById("m-jitter-sub");
  var dlValEl = document.getElementById("m-dl");
  var dlSubEl = document.getElementById("m-dl-sub");
  var ulValEl = document.getElementById("m-ul");
  var ulSubEl = document.getElementById("m-ul-sub");
  var metaProtoEl = document.getElementById("s-proto");
  var metaLossEl = document.getElementById("s-loss");
  var metaIdEl = document.getElementById("s-id");

  if (!startBtn || !progressEl) return;

  if (!CSS.supports("width: attr(value type(<number>))")) {
    var syncRing = function () {
      progressEl.style.setProperty("--value", progressEl.getAttribute("value") || "0");
    };
    syncRing();
    new MutationObserver(syncRing).observe(progressEl, { attributes: true, attributeFilter: ["value"] });
  }

  var state = {
    running: false,
    controller: null,
    unit: "mbps",
    profile: "standard",
    dlSeries: [],
    ulSeries: [],
    lastResult: null
  };

  var PROFILES = {
    express: { streams: 2, pingCount: 10, dlMs: 4200, ulMs: 3800, label: "Экспресс" },
    standard: { streams: 4, pingCount: 16, dlMs: 6500, ulMs: 5800, label: "Стандартный" },
    max: { streams: 6, pingCount: 20, dlMs: 8500, ulMs: 7200, label: "Максимум" }
  };

  function formatSpeed(mbps) {
    if (mbps === null || mbps === undefined || Number.isNaN(mbps)) return "—";
    var val = state.unit === "mbs" ? mbps / 8 : mbps;
    return val >= 100 ? val.toFixed(0) : val >= 10 ? val.toFixed(1) : val.toFixed(2);
  }

  function unitLabel() {
    return state.unit === "mbs" ? "МБ/с" : "Мбит/с";
  }

  function setProgress(pct, phase, textValue, speedNum) {
    var v = Math.max(0, Math.min(100, Math.round(pct)));
    progressEl.setAttribute("value", String(v));
    progressEl.setAttribute("data-phase", phase);
    progressEl.setAttribute("aria-valuetext", textValue);
    if (phaseEl) phaseEl.textContent = textValue;
    if (speedEl && speedNum !== undefined) speedEl.textContent = speedNum;
    if (unitEl) unitEl.textContent = unitLabel();
  }

  function drawChart() {
    if (!chartEl) return;
    var ctx = chartEl.getContext("2d");
    var dpr = window.devicePixelRatio || 1;
    var rect = chartEl.getBoundingClientRect();
    var w = Math.max(260, Math.round(rect.width));
    var h = Math.max(140, Math.round(rect.height));
    if (chartEl.width !== w * dpr || chartEl.height !== h * dpr) {
      chartEl.width = w * dpr;
      chartEl.height = h * dpr;
    }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);

    var styles = getComputedStyle(document.documentElement);
    var lineColor = styles.getPropertyValue("--line").trim() || "#334155";
    var mutedColor = styles.getPropertyValue("--muted").trim() || "#94a3b8";

    ctx.strokeStyle = lineColor;
    ctx.lineWidth = 1;
    for (var g = 1; g <= 3; g += 1) {
      var gy = Math.round((h / 4) * g) + 0.5;
      ctx.beginPath();
      ctx.moveTo(12, gy);
      ctx.lineTo(w - 12, gy);
      ctx.stroke();
    }

    var all = state.dlSeries.concat(state.ulSeries);
    var maxVal = Math.max(20, all.length ? Math.max.apply(null, all) * 1.15 : 100);
    ctx.fillStyle = mutedColor;
    ctx.font = "11px system-ui, sans-serif";
    ctx.fillText(formatSpeed(maxVal) + " " + unitLabel(), 14, 16);

    function drawLine(series, color) {
      if (series.length < 2) return;
      var padX = 14;
      var padY = 18;
      var usableW = w - padX * 2;
      var usableH = h - padY * 2;
      ctx.strokeStyle = color;
      ctx.lineWidth = 2.5;
      ctx.lineJoin = "round";
      ctx.beginPath();
      series.forEach(function (val, idx) {
        var x = padX + (idx / Math.max(1, series.length - 1)) * usableW;
        var y = h - padY - (Math.min(val, maxVal) / maxVal) * usableH;
        if (idx === 0) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
      });
      ctx.stroke();
    }

    drawLine(state.dlSeries, "#3b82f6");
    drawLine(state.ulSeries, "#8b5cf6");
  }

  function renderHistory() {
    store.renderHistoryTable(historyBody, formatSpeed, unitLabel);
  }

  function refreshDisplayedUnits() {
    if (unitEl) unitEl.textContent = unitLabel();
    if (state.lastResult) {
      if (dlValEl) dlValEl.textContent = formatSpeed(state.lastResult.dl);
      if (dlSubEl) dlSubEl.textContent = unitLabel();
      if (ulValEl) ulValEl.textContent = state.lastResult.ul > 0 ? formatSpeed(state.lastResult.ul) : "—";
      if (ulSubEl) ulSubEl.textContent = state.lastResult.ul > 0 ? unitLabel() : "Недоступно";
      if (!state.running && speedEl) speedEl.textContent = formatSpeed(state.lastResult.dl);
    }
    drawChart();
    renderHistory();
  }

  document.querySelectorAll("[data-unit]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      state.unit = btn.getAttribute("data-unit") || "mbps";
      document.querySelectorAll("[data-unit]").forEach(function (b) {
        b.setAttribute("aria-pressed", String(b === btn));
      });
      refreshDisplayedUnits();
    });
  });

  document.querySelectorAll("[data-profile]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      if (state.running) return;
      state.profile = btn.getAttribute("data-profile") || "standard";
      document.querySelectorAll("[data-profile]").forEach(function (b) {
        b.setAttribute("aria-pressed", String(b === btn));
      });
    });
  });

  async function runTest() {
    if (state.running && state.controller) {
      state.controller.abort();
      return;
    }
    var cfg = PROFILES[state.profile] || PROFILES.standard;
    state.running = true;
    state.controller = new AbortController();
    state.dlSeries = [];
    state.ulSeries = [];
    startBtn.textContent = "Остановить тест";
    if (copyBtn) copyBtn.disabled = true;
    if (statusLine) statusLine.textContent = "Выполняется диагностика канала (" + cfg.label + ")...";
    if (pingValEl) pingValEl.textContent = "…";
    if (jitterValEl) jitterValEl.textContent = "…";
    if (dlValEl) dlValEl.textContent = "…";
    if (ulValEl) ulValEl.textContent = "…";
    drawChart();

    try {
      var sig = state.controller.signal;
      var meta = await engine.fetchMeta(sig);
      if (metaProtoEl) metaProtoEl.textContent = meta.http + " / " + meta.tls;

      setProgress(5, "ping", "Измерение задержки", "0.0");
      var pingRes = await engine.measurePing(cfg.pingCount, function (s) {
        var pct = 5 + (s.index / s.total) * 15;
        setProgress(pct, "ping", "Пинг " + s.index + "/" + s.total, s.rtt ? s.rtt.toFixed(1) : "—");
      }, sig);
      if (pingValEl) pingValEl.textContent = pingRes.median.toFixed(1) + " мс";
      if (pingSubEl) pingSubEl.textContent = "мин " + pingRes.min.toFixed(1) + " / p95 " + pingRes.p95.toFixed(1) + " мс";
      if (jitterValEl) jitterValEl.textContent = pingRes.jitter.toFixed(1) + " мс";
      if (jitterSubEl) jitterSubEl.textContent = "разброс задержки";
      if (metaLossEl) metaLossEl.textContent = "Потери: " + pingRes.lossPct.toFixed(0) + "%";

      setProgress(22, "download", "Скачивание", "0.0");
      var dlRes = await engine.measureDownload({ durationMs: cfg.dlMs, streams: cfg.streams }, function (p) {
        state.dlSeries = p.series;
        setProgress(22 + p.progress * 0.4, "download", "Скачивание", formatSpeed(p.mbps));
        drawChart();
      }, sig);
      state.dlSeries = dlRes.series;
      if (dlValEl) dlValEl.textContent = formatSpeed(dlRes.mbps);
      if (dlSubEl) dlSubEl.textContent = unitLabel() + " (" + (dlRes.bytes / 1048576).toFixed(1) + " МиБ)";

      setProgress(64, "upload", "Отдача (Upload)", "0.0");
      var ulRes = await engine.measureUpload({ durationMs: cfg.ulMs, streams: cfg.streams }, function (p) {
        state.ulSeries = p.series;
        setProgress(64 + p.progress * 0.34, "upload", "Отдача", formatSpeed(p.mbps));
        drawChart();
      }, sig);
      state.ulSeries = ulRes.series;
      if (ulValEl) ulValEl.textContent = ulRes.mbps > 0 ? formatSpeed(ulRes.mbps) : "—";
      if (ulSubEl) {
        ulSubEl.textContent = ulRes.unsupported && ulRes.mbps === 0
          ? "Приёмник upload отключён"
          : unitLabel() + " (" + (ulRes.bytes / 1048576).toFixed(1) + " МиБ)";
      }

      var testId = "TN-" + Math.random().toString(36).slice(2, 8).toUpperCase();
      if (metaIdEl) metaIdEl.textContent = "ID: " + testId;
      state.lastResult = {
        id: testId,
        date: new Date().toLocaleString("ru-RU", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" }),
        ping: pingRes.median,
        jitter: pingRes.jitter,
        dl: dlRes.mbps,
        ul: ulRes.mbps,
        node: (meta && meta.node) ? meta.node : "Москва · MSK-IX"
      };
      setProgress(100, "done", "Замер завершён", formatSpeed(dlRes.mbps));
      store.updateQualityCards(state.lastResult);

      var items = store.loadHistory();
      items.unshift(state.lastResult);
      store.saveHistory(items);
      renderHistory();
      drawChart();
      if (copyBtn) copyBtn.disabled = false;
      if (statusLine) statusLine.textContent = "Замер завершён. Данные сохранены только в вашем браузере.";
    } catch (err) {
      if (err && err.name === "AbortError") {
        setProgress(0, "idle", "Тест остановлен", "0.0");
        if (statusLine) statusLine.textContent = "Измерение остановлено пользователем.";
      } else {
        setProgress(0, "idle", "Ошибка замера", "0.0");
        if (statusLine) statusLine.textContent = "Не удалось выполнить замер. Проверьте соединение и повторите.";
      }
    } finally {
      state.running = false;
      state.controller = null;
      startBtn.textContent = "Повторить тест";
    }
  }

  startBtn.addEventListener("click", runTest);
  if (copyBtn) {
    copyBtn.addEventListener("click", function () {
      if (!state.lastResult || !navigator.clipboard) return;
      var r = state.lastResult;
      var txt = "ТестНет.рф [" + r.id + "] | Пинг: " + r.ping.toFixed(1) + " мс | Джиттер: " + r.jitter.toFixed(1) +
        " мс | Скачивание: " + formatSpeed(r.dl) + " " + unitLabel() + " | Отдача: " + formatSpeed(r.ul) + " " + unitLabel();
      navigator.clipboard.writeText(txt).then(function () {
        if (statusLine) statusLine.textContent = "Отчёт скопирован в буфер обмена.";
      }).catch(function () {});
    });
  }
  if (exportBtn) {
    exportBtn.addEventListener("click", function () {
      store.exportCsv();
    });
  }
  if (clearBtn) {
    clearBtn.addEventListener("click", function () {
      store.clearHistory();
      renderHistory();
    });
  }

  window.addEventListener("testnet:themechange", drawChart);
  window.addEventListener("resize", drawChart);
  renderHistory();
  drawChart();
});
