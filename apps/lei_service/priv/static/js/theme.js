// Theme selection.
//
// Three states, not two: "dark", "light", and no stored choice at all, which
// follows the system. A two-state toggle cannot express "whatever my machine
// is doing", and that is the sensible default for someone who has never
// touched it.
(function () {
  var KEY = "lei-theme";

  function stored() {
    try {
      return localStorage.getItem(KEY);
    } catch (e) {
      // Private windows and blocked site data throw on access rather than
      // returning null. A theme preference is not worth breaking a page for.
      return null;
    }
  }

  function save(value) {
    try {
      if (value) {
        localStorage.setItem(KEY, value);
      } else {
        localStorage.removeItem(KEY);
      }
    } catch (e) {
      /* nothing to do; the choice simply will not persist */
    }
  }

  function systemPrefersDark() {
    return (
      window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches
    );
  }

  function effective() {
    return stored() || (systemPrefersDark() ? "dark" : "light");
  }

  function apply(value) {
    if (value) {
      document.documentElement.setAttribute("data-theme", value);
    } else {
      document.documentElement.removeAttribute("data-theme");
    }
  }

  // Applied before first paint by the inline snippet in each template; this
  // re-applies on load for pages that arrive from the cache.
  apply(stored());

  function label(button) {
    button.textContent = effective() === "dark" ? "Light mode" : "Dark mode";
    button.setAttribute(
      "aria-label",
      effective() === "dark" ? "Switch to light mode" : "Switch to dark mode"
    );
  }

  function wire() {
    var button = document.getElementById("theme-toggle");
    if (!button) return;

    label(button);

    button.addEventListener("click", function () {
      var next = effective() === "dark" ? "light" : "dark";
      save(next);
      apply(next);
      label(button);
    });

    // Follow the system while no explicit choice has been made.
    if (window.matchMedia) {
      window.matchMedia("(prefers-color-scheme: dark)").addEventListener(
        "change",
        function () {
          if (!stored()) label(button);
        }
      );
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", wire);
  } else {
    wire();
  }
})();
