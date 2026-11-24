(function (global) {
  "use strict";

  var HISTORY_KEY = "testnet_history_v1";

  function loadHistory() {
    try {
      var raw = localStorage.getItem(HISTORY_KEY);
      return raw ? JSON.parse(raw) : [];
    } catch (e) {
      return [];
    }
  }

  function saveHistory(items) {
    try {
      localStorage.setItem(HISTORY_KEY, JSON.stringify(items.slice(0, 20)));
    } catch (e) {}
  }

  function clearHistory() {
    try {
      localStorage.removeItem(HISTORY_KEY);
    } catch (e) {}
  }

  function renderHistoryTable(tbody, formatSpeed, unitLabel) {
    if (!tbody) return;
    var items = loadHistory();
    tbody.replaceChildren();
    if (!items.length) {
      var emptyTr = document.createElement("tr");
      var emptyTh = document.createElement("th");
      emptyTh.scope = "row";
      emptyTh.colSpan = 6;
      emptyTh.textContent = "История пока пуста — запустите первый замер скорости.";
      emptyTr.appendChild(emptyTh);
      tbody.appendChild(emptyTr);
      return;
    }
    var uLabel = unitLabel();
    items.forEach(function (item) {
      var tr = document.createElement("tr");
      var th = document.createElement("th");
      th.scope = "row";
      th.textContent = item.date;
      tr.appendChild(th);

      [
        item.ping.toFixed(1) + " мс",
        item.jitter.toFixed(1) + " мс",
        formatSpeed(item.dl) + " " + uLabel,
        item.ul > 0 ? formatSpeed(item.ul) + " " + uLabel : "—",
        item.node
      ].forEach(function (val) {
        var td = document.createElement("td");
        td.textContent = val;
        tr.appendChild(td);
      });
      tbody.appendChild(tr);
    });
  }

  function exportCsv() {
    var items = loadHistory();
    if (!items.length) return;
    var rows = ["Дата,Пинг_мс,Джиттер_мс,Скачивание_Мбит,Отдача_Мбит,Узел"];
    items.forEach(function (i) {
      rows.push([i.date, i.ping.toFixed(1), i.jitter.toFixed(1), i.dl.toFixed(2), i.ul.toFixed(2), i.node].join(","));
    });
    var blob = new Blob([rows.join("\n")], { type: "text/csv;charset=utf-8" });
    var a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "testnet-history.csv";
    a.click();
    URL.revokeObjectURL(a.href);
  }

  function setBadge(id, text, cls) {
    var el = document.getElementById(id);
    if (!el) return;
    el.textContent = text;
    el.className = "badge " + cls;
  }

  function updateQualityCards(res) {
    if (!res) return;
    if (res.dl >= 35) setBadge("q-4k", "Отлично (до 2 потоков 4K)", "badge-ok");
    else if (res.dl >= 15) setBadge("q-4k", "Хорошо (1 поток 4K)", "badge-warn");
    else setBadge("q-4k", "Недостаточно (HD 1080p)", "badge-bad");

    if (res.ping <= 35 && res.jitter <= 8) setBadge("q-game", "Отлично (низкий отклик)", "badge-ok");
    else if (res.ping <= 70 && res.jitter <= 18) setBadge("q-game", "Стабильно", "badge-warn");
    else setBadge("q-game", "Возможны задержки", "badge-bad");

    if (res.dl >= 10 && res.ul >= 8 && res.jitter <= 15) setBadge("q-call", "Отлично (Full HD видео)", "badge-ok");
    else if (res.dl >= 4 && res.ul >= 3) setBadge("q-call", "Хорошо", "badge-warn");
    else setBadge("q-call", "Базовое качество", "badge-bad");

    if (res.dl >= 100 && res.ul >= 50) setBadge("q-cloud", "Отлично (быстрый обмен)", "badge-ok");
    else if (res.dl >= 30 && res.ul >= 15) setBadge("q-cloud", "Уверенно", "badge-warn");
    else setBadge("q-cloud", "Умеренно", "badge-neutral");
  }

  global.TestNetStore = {
    loadHistory: loadHistory,
    saveHistory: saveHistory,
    clearHistory: clearHistory,
    renderHistoryTable: renderHistoryTable,
    exportCsv: exportCsv,
    updateQualityCards: updateQualityCards
  };
})(window);
