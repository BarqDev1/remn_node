(function () {
  var meta = document.querySelector('meta[name="color-scheme"]');
  if (!meta) return;
  try {
    var saved = localStorage.getItem("color-scheme");
    if (saved === "light" || saved === "dark") {
      meta.content = saved;
    } else {
      meta.content = "light dark";
    }
  } catch (err) {
    meta.content = "light dark";
  }
})();
