// Color scheme switcher, like nixtml's docs theme.
//
// Switches between light and dark mode, storing the choice in localStorage.
// Without a saved choice the page follows the reader's system preference.
// An inline script in <head> applies the saved choice before the page is
// rendered, and the button's icon follows the dark: variant in CSS.
(() => {
  const script = document.currentScript;
  const key = script?.dataset.storageKey;
  const root = document.documentElement;
  const systemDark = window.matchMedia("(prefers-color-scheme: dark)");

  const storage = {
    get() {
      try {
        return window.localStorage.getItem(key);
      } catch {
        return null;
      }
    },
    set(value) {
      try {
        window.localStorage.setItem(key, value);
      } catch {}
    },
  };

  const current = () => {
    const scheme = root.getAttribute("data-theme");
    if (scheme === "light" || scheme === "dark") {
      return scheme;
    }
    return systemDark.matches ? "dark" : "light";
  };

  for (const switcher of document.querySelectorAll("[data-color-scheme-switcher]")) {
    const button = switcher.querySelector("button");

    const update = () => {
      const next = current() === "dark" ? "light" : "dark";
      const label = button.getAttribute(`data-label-${next}`);
      button.setAttribute("aria-label", label);
      button.dataset.tip = label;
    };

    const apply = (scheme) => {
      if (scheme === "light" || scheme === "dark") {
        root.setAttribute("data-theme", scheme);
      } else {
        root.removeAttribute("data-theme");
      }
      update();
    };

    button.addEventListener("click", () => {
      const scheme = current() === "dark" ? "light" : "dark";
      storage.set(scheme);
      apply(scheme);
    });

    // Keep other open pages of the website in sync.
    window.addEventListener("storage", (event) => {
      if (event.key === key) {
        apply(event.newValue);
      }
    });

    // Without a saved choice, the label follows system changes.
    systemDark.addEventListener("change", update);

    update();
    switcher.hidden = false;
  }
})();
