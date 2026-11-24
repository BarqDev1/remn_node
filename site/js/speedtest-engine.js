(function (global) {
  "use strict";

  function sleep(ms, signal) {
    return new Promise(function (resolve, reject) {
      var timer = setTimeout(resolve, ms);
      if (signal) {
        signal.addEventListener("abort", function () {
          clearTimeout(timer);
          reject(new DOMException("Aborted", "AbortError"));
        }, { once: true });
      }
    });
  }

  function trimmedMean(values) {
    if (!values.length) return 0;
    var sorted = values.slice().sort(function (a, b) { return a - b; });
    var start = Math.floor(sorted.length * 0.15);
    var end = Math.max(start + 1, Math.ceil(sorted.length * 0.92));
    var slice = sorted.slice(start, end);
    var sum = slice.reduce(function (acc, v) { return acc + v; }, 0);
    return sum / slice.length;
  }

  function percentile(sorted, p) {
    if (!sorted.length) return 0;
    var idx = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
    return sorted[idx];
  }

  async function fetchMeta(signal) {
    var nav = performance.getEntriesByType("navigation")[0];
    var fallbackProto = nav && nav.nextHopProtocol ? nav.nextHopProtocol.toUpperCase() : "HTTPS";
    try {
      var res = await fetch("/api/meta?t=" + Date.now(), { cache: "no-store", signal: signal });
      if (res.ok) {
        var data = await res.json();
        return {
          tls: data.tls || "TLSv1.3",
          http: data.http || fallbackProto,
          node: data.node || "RU-MSK-01"
        };
      }
    } catch (err) {
      if (err && err.name === "AbortError") throw err;
    }
    return { tls: "TLS 1.3", http: fallbackProto, node: "RU-MSK-01" };
  }

  async function measurePing(count, onSample, signal) {
    var total = count || 18;
    var rtts = [];
    var failed = 0;

    try {
      await fetch("/api/ping?warmup=" + Date.now(), { cache: "no-store", signal: signal });
    } catch (err) {
      if (err && err.name === "AbortError") throw err;
    }

    for (var i = 0; i < total; i += 1) {
      if (signal && signal.aborted) throw new DOMException("Aborted", "AbortError");
      var t0 = performance.now();
      try {
        var res = await fetch("/api/ping?i=" + i + "&t=" + Date.now(), { cache: "no-store", signal: signal });
        if (!res.ok) throw new Error("HTTP " + res.status);
        await res.arrayBuffer();
        var rtt = Math.max(0.2, performance.now() - t0);
        rtts.push(rtt);
        if (onSample) onSample({ index: i + 1, total: total, rtt: rtt, ok: true });
      } catch (err) {
        if (err && err.name === "AbortError") throw err;
        failed += 1;
        if (onSample) onSample({ index: i + 1, total: total, rtt: null, ok: false });
      }
      if (i + 1 < total) await sleep(55, signal);
    }

    var sorted = rtts.slice().sort(function (a, b) { return a - b; });
    var jitterSum = 0;
    for (var j = 1; j < rtts.length; j += 1) {
      jitterSum += Math.abs(rtts[j] - rtts[j - 1]);
    }
    var jitter = rtts.length > 1 ? jitterSum / (rtts.length - 1) : 0;
    return {
      samples: rtts,
      min: sorted.length ? sorted[0] : 0,
      median: percentile(sorted, 50),
      p95: percentile(sorted, 95),
      max: sorted.length ? sorted[sorted.length - 1] : 0,
      jitter: jitter,
      lossPct: (failed / total) * 100
    };
  }

  async function measureDownload(opts, onProgress, signal) {
    var durationMs = (opts && opts.durationMs) || 6800;
    var streams = (opts && opts.streams) || 4;
    var totalBytes = 0;
    var lastSampleBytes = 0;
    var start = performance.now();
    var lastTick = start;
    var history = [];
    var usedFallback = false;
    var stopAt = start + durationMs;

    var timer = setInterval(function () {
      var now = performance.now();
      var dt = (now - lastTick) / 1000;
      if (dt <= 0) return;
      var delta = totalBytes - lastSampleBytes;
      lastSampleBytes = totalBytes;
      lastTick = now;
      var mbps = (delta * 8) / (dt * 1e6);
      history.push(mbps);
      var pct = Math.min(100, ((now - start) / durationMs) * 100);
      if (onProgress) onProgress({ mbps: mbps, progress: pct, bytes: totalBytes, series: history.slice() });
    }, 200);

    async function worker(id) {
      var step = 0;
      while (performance.now() < stopAt && !(signal && signal.aborted)) {
        var file = step === 0 ? "/speed/payload-1m.bin" : "/speed/payload-4m.bin";
        var url = file + "?w=" + id + "&s=" + step + "&t=" + Date.now();
        try {
          var res = await fetch(url, { cache: "no-store", signal: signal });
          if (!res.ok) {
            if (file !== "/css/speedtest.css") {
              usedFallback = true;
              res = await fetch("/css/speedtest.css?t=" + Date.now(), { cache: "no-store", signal: signal });
            }
          }
          if (res.body && typeof res.body.getReader === "function") {
            var reader = res.body.getReader();
            while (true) {
              var chunk = await reader.read();
              if (chunk.done) break;
              totalBytes += chunk.value.byteLength;
              if (performance.now() >= stopAt) {
                try { await reader.cancel(); } catch (e) {}
                break;
              }
            }
          } else {
            var buf = await res.arrayBuffer();
            totalBytes += buf.byteLength;
          }
        } catch (err) {
          if (err && err.name === "AbortError") throw err;
          break;
        }
        step += 1;
      }
    }

    try {
      var tasks = [];
      for (var w = 0; w < streams; w += 1) tasks.push(worker(w));
      await Promise.all(tasks);
    } finally {
      clearInterval(timer);
    }

    var finalMbps = history.length >= 4 ? trimmedMean(history) : ((totalBytes * 8) / (Math.max(1, performance.now() - start) * 1000));
    return { mbps: Math.max(0.1, finalMbps), bytes: totalBytes, series: history, fallback: usedFallback };
  }

  function buildRandomBuffer(byteLength) {
    var buf = new Uint8Array(byteLength);
    var step = 65536;
    for (var offset = 0; offset < byteLength; offset += step) {
      var slice = buf.subarray(offset, Math.min(byteLength, offset + step));
      crypto.getRandomValues(slice);
    }
    return buf;
  }

  async function measureUpload(opts, onProgress, signal) {
    var durationMs = (opts && opts.durationMs) || 6200;
    var streams = Math.min(3, (opts && opts.streams) || 3);
    var payload = buildRandomBuffer(1024 * 1024);
    var activeLoaded = {};
    var completedBytes = 0;
    var lastSampleBytes = 0;
    var start = performance.now();
    var lastTick = start;
    var stopAt = start + durationMs;
    var history = [];
    var unsupported = false;

    function getTotalLoaded() {
      var sum = completedBytes;
      Object.keys(activeLoaded).forEach(function (k) { sum += activeLoaded[k]; });
      return sum;
    }

    var timer = setInterval(function () {
      var now = performance.now();
      var dt = (now - lastTick) / 1000;
      if (dt <= 0) return;
      var currentTotal = getTotalLoaded();
      var delta = Math.max(0, currentTotal - lastSampleBytes);
      lastSampleBytes = currentTotal;
      lastTick = now;
      var mbps = (delta * 8) / (dt * 1e6);
      history.push(mbps);
      var pct = Math.min(100, ((now - start) / durationMs) * 100);
      if (onProgress) onProgress({ mbps: mbps, progress: pct, bytes: currentTotal, series: history.slice() });
    }, 200);

    function sendChunk(workerId, seq) {
      return new Promise(function (resolve, reject) {
        if (signal && signal.aborted) {
          reject(new DOMException("Aborted", "AbortError"));
          return;
        }
        var xhr = new XMLHttpRequest();
        var key = workerId + "_" + seq;
        activeLoaded[key] = 0;
        var abortHandler = function () { xhr.abort(); };
        if (signal) signal.addEventListener("abort", abortHandler, { once: true });

        xhr.upload.onprogress = function (ev) {
          if (ev.lengthComputable) activeLoaded[key] = ev.loaded;
        };
        xhr.onload = function () {
          if (signal) signal.removeEventListener("abort", abortHandler);
          var sent = activeLoaded[key] || payload.byteLength;
          delete activeLoaded[key];
          if (xhr.status >= 200 && xhr.status < 300) {
            completedBytes += payload.byteLength;
            resolve(true);
          } else {
            completedBytes += sent;
            unsupported = true;
            resolve(false);
          }
        };
        xhr.onerror = function () {
          if (signal) signal.removeEventListener("abort", abortHandler);
          delete activeLoaded[key];
          resolve(false);
        };
        xhr.onabort = function () {
          delete activeLoaded[key];
          reject(new DOMException("Aborted", "AbortError"));
        };
        xhr.open("POST", "/api/upload?w=" + workerId + "&s=" + seq + "&t=" + Date.now(), true);
        xhr.setRequestHeader("Content-Type", "application/octet-stream");
        xhr.send(payload);
      });
    }

    async function worker(id) {
      var seq = 0;
      while (performance.now() < stopAt && !unsupported && !(signal && signal.aborted)) {
        var ok = await sendChunk(id, seq);
        if (!ok) break;
        seq += 1;
      }
    }

    try {
      var tasks = [];
      for (var w = 0; w < streams; w += 1) tasks.push(worker(w));
      await Promise.all(tasks);
    } finally {
      clearInterval(timer);
    }

    var totalSent = getTotalLoaded();
    var finalMbps = history.length >= 4 ? trimmedMean(history) : ((totalSent * 8) / (Math.max(1, performance.now() - start) * 1000));
    return { mbps: unsupported && totalSent === 0 ? 0 : Math.max(0.1, finalMbps), bytes: totalSent, series: history, unsupported: unsupported };
  }

  global.TestNetEngine = {
    fetchMeta: fetchMeta,
    measurePing: measurePing,
    measureDownload: measureDownload,
    measureUpload: measureUpload
  };
})(window);
