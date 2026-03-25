const plugin = require("tailwindcss/plugin")

module.exports = {
  darkMode: "class",
  content: [
    "./js/**/*.js",
    "../lib/agent_ex_web.ex",
    "../lib/agent_ex_web/**/*.*ex",
    "../deps/salad_ui/lib/**/*.ex"
  ],
  theme: {
    extend: {
      colors: require("./tailwind.colors.json"),
    },
  },
  plugins: [
    require("./vendor/tailwindcss-animate"),
    plugin(({addVariant}) => addVariant("phx-click-loading", [".phx-click-loading&", ".phx-click-loading &"])),
    plugin(({addVariant}) => addVariant("phx-submit-loading", [".phx-submit-loading&", ".phx-submit-loading &"])),
    plugin(({addVariant}) => addVariant("phx-change-loading", [".phx-change-loading&", ".phx-change-loading &"])),
  ]
}
