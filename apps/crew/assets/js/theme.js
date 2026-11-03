// The admin's light/dark theme. Loaded by root.html.heex as a classic,
// synchronous script in <head>, so data-theme is on <html> before the
// first paint in every browser; app.js is a module, and modules defer.
// Keep this file free of imports: it's an entry of the split admin
// build, and a shared chunk would turn it into a module.
{
  const store = (() => {
    try {
      return window.localStorage
    } catch (_error) {
      return null
    }
  })()

  const read = key => {
    try { return store?.getItem(key) ?? null } catch (_error) { return null }
  }

  const write = (key, value) => {
    try {
      if (value === null) store?.removeItem(key)
      else store?.setItem(key, value)
    } catch (_error) {}
  }

  const root = document.documentElement
  const darkQuery = matchMedia("(prefers-color-scheme: dark)")
  const systemTheme = () => (darkQuery.matches ? "dark" : "light")

  const setTheme = theme => {
    if (theme === "system") {
      write("phx:theme", null)
      root.setAttribute("data-theme", systemTheme())
      root.setAttribute("data-theme-source", "system")
    } else {
      write("phx:theme", theme)
      root.setAttribute("data-theme", theme)
      root.setAttribute("data-theme-source", "user")
    }
  }

  if (!root.hasAttribute("data-theme")) {
    setTheme(read("phx:theme") || "system")
  }

  window.addEventListener("storage", event => {
    if (event.key === "phx:theme") setTheme(event.newValue || "system")
  })
  window.addEventListener("phx:set-theme", event => setTheme(event.target.dataset.phxTheme))

  darkQuery.addEventListener("change", () => {
    if (root.getAttribute("data-theme-source") === "system") {
      root.setAttribute("data-theme", systemTheme())
    }
  })
}
