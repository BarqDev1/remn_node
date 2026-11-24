document.addEventListener("DOMContentLoaded", function () {
  var header = document.querySelector(".site-header");
  var inner = document.querySelector(".header-inner");
  var menu = document.getElementById("site-menu");
  var toggleBtn = document.getElementById("theme-toggle");
  var meta = document.querySelector('meta[name="color-scheme"]');

  if (!Object.hasOwn(HTMLElement.prototype, "popover") && menu) {
    var menuBtn = document.querySelector(".menu-button");
    if (menuBtn) {
      menuBtn.addEventListener("click", function () {
        menu.classList.toggle(":popover-open");
      });
    }
  }

  var lastCollapsedWidth = 0;
  function updateNavLayout() {
    if (!header || !inner || !menu) return;
    var wasWide = header.classList.contains("is-wide");
    var wasOpen = !wasWide && menu.matches(":popover-open, .\\:popover-open");
    if (!wasWide && lastCollapsedWidth > 0 && header.clientWidth <= lastCollapsedWidth) {
      return;
    }

    header.classList.add("is-measuring");
    header.classList.add("is-wide");
    menu.removeAttribute("popover");
    var wide = inner.scrollWidth <= inner.clientWidth;

    if (wide) {
      lastCollapsedWidth = 0;
    } else {
      header.classList.remove("is-wide");
      menu.setAttribute("popover", "auto");
      lastCollapsedWidth = header.clientWidth;
      if (wasOpen && typeof menu.showPopover === "function") {
        try { menu.showPopover(); } catch (e) {}
      }
    }
    requestAnimationFrame(function () {
      header.classList.remove("is-measuring");
    });
  }

  if (header && inner && menu) {
    updateNavLayout();
    if (typeof ResizeObserver === "function") {
      var ro = new ResizeObserver(function () { updateNavLayout(); });
      ro.observe(header);
      ro.observe(menu);
    }
  }

  var mq = window.matchMedia("(prefers-color-scheme: dark)");
  function applyScheme(value) {
    if (!meta) return;
    meta.content = value === "light" || value === "dark" ? value : "light dark";
  }

  if (toggleBtn && meta) {
    toggleBtn.addEventListener("click", function () {
      var sysScheme = mq.matches ? "dark" : "light";
      var rendered = (meta.content === "light" || meta.content === "dark") ? meta.content : sysScheme;
      var target = rendered === "dark" ? "light" : "dark";
      try {
        if (target === sysScheme) {
          localStorage.removeItem("color-scheme");
          applyScheme("light dark");
        } else {
          localStorage.setItem("color-scheme", target);
          applyScheme(target);
        }
      } catch (err) {
        applyScheme(target);
      }
      window.dispatchEvent(new CustomEvent("testnet:themechange"));
    });

    window.addEventListener("storage", function (ev) {
      if (ev.key === "color-scheme") {
        applyScheme(ev.newValue || "light dark");
        window.dispatchEvent(new CustomEvent("testnet:themechange"));
      }
    });
  }

  var yr = document.querySelector("[data-year]");
  if (yr) {
    yr.textContent = String(new Date().getFullYear());
  }

  var form = document.getElementById("contact-form");
  if (form) {
    form.addEventListener("submit", function (e) {
      e.preventDefault();
      var status = document.getElementById("form-status");
      var emailInput = document.getElementById("c-email");
      if (emailInput && !emailInput.checkValidity()) {
        if (status) status.textContent = "Проверьте корректность адреса электронной почты.";
        return;
      }
      if (status) {
        status.textContent = "Обращение зафиксировано. Служба поддержки ТестНет.рф ответит в рабочее время.";
      }
      form.reset();
    });
  }
});
