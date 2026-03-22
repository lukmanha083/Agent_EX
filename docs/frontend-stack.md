# AgentEx Frontend Stack

Phoenix LiveView dashboard with open-source component libraries for building
an n8n-style agent orchestration UI.

## Stack Overview

| Layer | Library | Version | Purpose |
|---|---|---|---|
| Components | SaladUI | ~> 1.0.0-beta.3 | Buttons, forms, modals, tabs, cards, dropdowns (shadcn/ui port) |
| Flow Builder | LiveSvelte + Svelte Flow | ~> 0.17 / ~> 1.5 | Node/edge canvas for Pipe and Swarm visual editing |
| Drag & Drop | SortableJS | npm | List reordering (intervention pipelines, tool ordering) |
| Icons | Heroicons (built-in) | Phoenix 1.7+ | `hero-*` class names, no extra dep |
| Styling | Tailwind CSS | ~> 3.4 | Utility-first CSS, dark mode via class strategy |

## Why These Libraries

### SaladUI (chosen)

- shadcn/ui design language — modern, clean, matches dashboard aesthetics
- 30+ HEEX components with slots and attrs
- Native dark mode via Tailwind class strategy
- Two modes: library (use as-is) or local install (copy source for customization)
- 106K hex downloads, active development
- No Alpine.js dependency — pure LiveView + Tailwind

### LiveSvelte + Svelte Flow (Phase 6)

Pure LiveView can't do a proper node/edge canvas. LiveSvelte bridges to the
Svelte ecosystem, enabling Svelte Flow (xyflow) — the same engine behind
React Flow used by n8n, Langflow, and similar tools.

- Node dragging, zooming, panning
- Edge creation with custom routing
- Custom node components (AgentNode, TriggerNode, etc.)
- Minimap, controls, background grid
- Dark mode built-in
- 70K weekly npm installs, MIT license
- Server-side state management via LiveView websocket

### SortableJS (Phase 5)

For list-based drag-and-drop within LiveView (not canvas):
- Reorder intervention handler pipelines
- Reorder tool priority lists
- Drag tools into agent tool slots
- 150ms animation, ghost class styling

## Evaluated Alternatives

| Library | Hex Package | Why Not Chosen |
|---|---|---|
| PetalComponents | `petal_components` | Alpine.js dependency, partial dark mode, naming conflicts with CoreComponents |
| Mishka Chelekom | `mishka_chelekom` | Generator approach adds complexity, still pre-1.0 alpha |
| Sutra UI | `sutra_ui` | Requires Phoenix 1.8+, very new (1.9K downloads) |
| PhiaUI | `phia_ui` | Too new (345 downloads), component count unverified |
| daisyUI (Phoenix 1.8 built-in) | N/A | CSS classes only, no HEEX component abstractions |

## Installation Guide

### SaladUI

```elixir
# mix.exs deps
{:salad_ui, "~> 1.0.0-beta.3"}
```

```bash
mix deps.get
mix salad.setup  # library mode
```

```elixir
# config/config.exs
config :salad_ui, color_scheme: :default
```

```javascript
// assets/tailwind.config.js
module.exports = {
  darkMode: "class",
  content: [
    "./js/**/*.js",
    "../lib/agent_ex_web.ex",
    "../lib/agent_ex_web/**/*.*ex",
    "../deps/salad_ui/lib/**/*.ex"  // add this
  ]
}
```

### LiveSvelte (Phase 6)

```elixir
# mix.exs deps
{:live_svelte, "~> 0.17"}
```

```bash
mix deps.get
cd assets
npm install svelte @sveltejs/vite-plugin-svelte --save-dev
npm install @xyflow/svelte --save-dev
```

Requires Node.js 19+ for SSR. See LiveSvelte docs for esbuild/vite config.

### SortableJS (Phase 5)

```bash
cd assets
npm install sortablejs --save
```

Hook setup in `assets/js/hooks/sortable.js`:

```javascript
import Sortable from "sortablejs"

export default {
  mounted() {
    this.sortable = new Sortable(this.el, {
      animation: 150,
      ghostClass: "opacity-30",
      onEnd: (evt) => {
        const ids = Array.from(this.el.children).map(el => el.dataset.id)
        this.pushEvent("reorder", { ids })
      }
    })
  },
  destroyed() {
    this.sortable.destroy()
  }
}
```

Register in `assets/js/app.js`:

```javascript
import Sortable from "./hooks/sortable"
let Hooks = { ScrollBottom, Sortable }
```

## Component Usage Reference

### SaladUI Components

#### Buttons

```heex
<.button>Default</.button>
<.button variant="destructive">Delete</.button>
<.button variant="outline">Cancel</.button>
<.button variant="ghost" size="icon">
  <.icon name="hero-plus" class="w-4 h-4" />
</.button>
<.button variant="link">Learn more</.button>
```

#### Cards

```heex
<.card>
  <.card_header>
    <.card_title>Agent: Researcher</.card_title>
    <.card_description>gpt-5.4 | 3 tools | Tier 2 memory</.card_description>
  </.card_header>
  <.card_content>
    <p class="text-sm text-gray-400">Specializes in web research and data gathering.</p>
  </.card_content>
  <.card_footer class="flex justify-between">
    <.button variant="outline" size="sm">Edit</.button>
    <.button variant="ghost" size="sm">
      <.icon name="hero-trash" class="w-4 h-4 text-red-400" />
    </.button>
  </.card_footer>
</.card>
```

#### Tabs

```heex
<.tabs default_value="agents" class="w-full">
  <.tabs_list>
    <.tabs_trigger value="agents">Agents</.tabs_trigger>
    <.tabs_trigger value="tools">Tools</.tabs_trigger>
    <.tabs_trigger value="flows">Flows</.tabs_trigger>
    <.tabs_trigger value="memory">Memory</.tabs_trigger>
    <.tabs_trigger value="runs">Runs</.tabs_trigger>
  </.tabs_list>
  <.tabs_content value="agents"><!-- agent grid --></.tabs_content>
  <.tabs_content value="tools"><!-- tool list --></.tabs_content>
</.tabs>
```

#### Dialog / Modal

```heex
<.dialog>
  <.dialog_trigger>
    <.button>+ New Agent</.button>
  </.dialog_trigger>
  <.dialog_content>
    <.dialog_header>
      <.dialog_title>Create Agent</.dialog_title>
      <.dialog_description>Configure your agent's capabilities.</.dialog_description>
    </.dialog_header>
    <form phx-submit="create_agent" class="space-y-4">
      <.input field={@form[:name]} label="Name" placeholder="e.g. Researcher" />
      <.textarea field={@form[:system_prompt]} label="System Prompt" rows={4} />
      <.select name="provider">
        <.select_trigger><.select_value placeholder="Provider" /></.select_trigger>
        <.select_content>
          <.select_item value="openai">OpenAI</.select_item>
          <.select_item value="anthropic">Anthropic</.select_item>
        </.select_content>
      </.select>
      <.dialog_footer>
        <.button type="submit">Create</.button>
      </.dialog_footer>
    </form>
  </.dialog_content>
</.dialog>
```

#### Dropdown Menu

```heex
<.dropdown_menu>
  <.dropdown_menu_trigger>
    <.button variant="ghost" size="icon">
      <.icon name="hero-ellipsis-vertical" class="w-4 h-4" />
    </.button>
  </.dropdown_menu_trigger>
  <.dropdown_menu_content>
    <.dropdown_menu_label>Actions</.dropdown_menu_label>
    <.dropdown_menu_separator />
    <.dropdown_menu_item phx-click="edit" phx-value-id={@agent.id}>
      <.icon name="hero-pencil-square" class="w-4 h-4 mr-2" /> Edit
    </.dropdown_menu_item>
    <.dropdown_menu_item phx-click="duplicate" phx-value-id={@agent.id}>
      <.icon name="hero-document-duplicate" class="w-4 h-4 mr-2" /> Duplicate
    </.dropdown_menu_item>
    <.dropdown_menu_separator />
    <.dropdown_menu_item variant="destructive" phx-click="delete" phx-value-id={@agent.id}>
      <.icon name="hero-trash" class="w-4 h-4 mr-2" /> Delete
    </.dropdown_menu_item>
  </.dropdown_menu_content>
</.dropdown_menu>
```

#### Table

```heex
<.table>
  <.table_header>
    <.table_row>
      <.table_head>Name</.table_head>
      <.table_head>Provider</.table_head>
      <.table_head>Tools</.table_head>
      <.table_head class="text-right">Actions</.table_head>
    </.table_row>
  </.table_header>
  <.table_body>
    <.table_row :for={agent <- @agents}>
      <.table_cell class="font-medium">{agent.name}</.table_cell>
      <.table_cell><.badge>{agent.provider}</.badge></.table_cell>
      <.table_cell>{length(agent.tools)}</.table_cell>
      <.table_cell class="text-right">
        <!-- dropdown menu -->
      </.table_cell>
    </.table_row>
  </.table_body>
</.table>
```

#### Toast Notifications

```heex
<.toast_provider>
  <.toast :for={toast <- @toasts} variant={toast.variant}>
    <.toast_title>{toast.title}</.toast_title>
    <.toast_description>{toast.message}</.toast_description>
  </.toast>
</.toast_provider>
```

### Heroicons Reference

Built into Phoenix. No extra dependency needed.

```heex
<.icon name="hero-chat-bubble-left-right" class="w-5 h-5" />    <!-- outline -->
<.icon name="hero-chat-bubble-left-right-solid" class="w-5 h-5" /> <!-- solid -->
<.icon name="hero-chat-bubble-left-right-mini" class="w-5 h-5" />  <!-- mini 20x20 -->
```

Icon mapping for AgentEx navigation:

| Section | Icon Name |
|---|---|
| Dashboard | `hero-home` |
| Chat | `hero-chat-bubble-left-right` |
| Agents | `hero-user-circle` |
| Tools | `hero-wrench-screwdriver` |
| Flows | `hero-arrows-right-left` |
| Runs | `hero-play` |
| Memory | `hero-circle-stack` |
| Settings | `hero-cog-6-tooth` |

### Svelte Flow (Phase 6)

Custom agent node for the flow builder:

```svelte
<!-- assets/svelte/AgentNode.svelte -->
<script>
  import { Handle, Position } from '@xyflow/svelte'
  export let data  // { name, model, toolCount, status }
</script>

<div class="rounded-lg border border-gray-700 bg-gray-900 p-3 min-w-[180px] shadow-lg">
  <div class="flex items-center gap-2 mb-2">
    <div class="w-2 h-2 rounded-full"
         class:bg-green-500={data.status === 'active'}
         class:animate-pulse={data.status === 'active'}
         class:bg-gray-500={data.status !== 'active'} />
    <span class="text-sm font-medium text-white">{data.name}</span>
  </div>
  <div class="text-xs text-gray-400">{data.model}</div>
  <div class="text-xs text-gray-500 mt-1">{data.toolCount} tools</div>
  <Handle type="target" position={Position.Left} />
  <Handle type="source" position={Position.Right} />
</div>
```

Trigger node:

```svelte
<!-- assets/svelte/TriggerNode.svelte -->
<script>
  import { Handle, Position } from '@xyflow/svelte'
  export let data  // { type, config }

  const icons = {
    manual: 'M',
    cron: 'C',
    webhook: 'W',
    file: 'F',
    pubsub: 'P'
  }
</script>

<div class="rounded-lg border-2 border-indigo-600 bg-indigo-950 p-3 min-w-[160px]">
  <div class="flex items-center gap-2 mb-1">
    <span class="w-6 h-6 rounded bg-indigo-600 text-white text-xs flex items-center justify-center font-bold">
      {icons[data.type] || '?'}
    </span>
    <span class="text-sm font-medium text-white capitalize">{data.type}</span>
  </div>
  <div class="text-xs text-indigo-300">{data.config || 'Click to configure'}</div>
  <Handle type="source" position={Position.Right} />
</div>
```

## Responsive Breakpoints

All pages should be responsive across 3 breakpoints using Tailwind's mobile-first approach (target standard).

> **Status:** The current sidebar layout (`app.html.heex`) uses a fixed `w-56`.
> New pages should follow the responsive patterns below; the existing sidebar
> will be converted as part of the dashboard buildout.

| Breakpoint | Tailwind Prefix | Min Width | Target Devices |
|---|---|---|---|
| Mobile | (default, no prefix) | 0px | Phones in portrait (375px reference) |
| Tablet | `md:` | 768px | Tablets, small laptops |
| Desktop | `lg:` | 1024px | Desktops, wide monitors (1280px reference) |

### Sidebar Navigation

```
Mobile (< 768px)         Tablet (768-1023px)       Desktop (≥ 1024px)
┌──────────────────┐     ┌────┬─────────────┐     ┌─────────┬──────────────┐
│  ☰  Top bar      │     │ 🏠 │             │     │ 🏠 Home  │              │
├──────────────────┤     │ 👤 │   Content    │     │ 👤 Agents│   Content    │
│                  │     │ 🔧 │   area       │     │ 🔧 Tools │   area       │
│  Content area    │     │ ▶  │              │     │ ▶  Runs  │              │
│  (full width)    │     │    │              │     │          │              │
│                  │     │    │              │     │  v0.1.0  │              │
└──────────────────┘     └────┴─────────────┘     └─────────┴──────────────┘
 Hidden sidebar,          Icon-only rail            Full expanded sidebar
 hamburger toggle          (w-16)                    (w-64)
```

### Content Grid Patterns

- **Mobile**: single column (`grid-cols-1`), full-width cards
- **Tablet**: 2 columns (`md:grid-cols-2`)
- **Desktop**: 3–4 columns (`lg:grid-cols-3` or `lg:grid-cols-4`)

```heex
<div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3 md:gap-4 lg:gap-6">
  <.card :for={agent <- @agents}>...</.card>
</div>
```

### Tables on Mobile

Tables switch to a card-based layout on mobile for readability:

```heex
<!-- Mobile: stacked cards -->
<div class="block md:hidden space-y-3">
  <.card :for={row <- @data}><!-- compact card view --></.card>
</div>
<!-- Tablet+: standard table -->
<div class="hidden md:block overflow-x-auto">
  <.table><!-- full table --></.table>
</div>
```

### Responsive Rules

- **Mobile-first**: write base styles for mobile, then layer `md:` and `lg:` overrides
- **No fixed widths**: use `w-full md:w-96 lg:w-[500px]`, never bare `w-[500px]`
- **Touch targets**: minimum 44x44px on mobile (`min-h-[44px] min-w-[44px]`)
- **Button groups**: use `flex flex-col md:flex-row gap-2` so they stack on mobile
- **Modals**: full-screen sheet on mobile, centered modal on tablet+
- **Test at**: 375px (mobile), 768px (tablet), 1280px (desktop)

## Dark Theme Colors

AgentEx uses a consistent dark palette across all views:

```
Background:       bg-gray-950  (#030712)
Surface:          bg-gray-900  (#111827)
Elevated:         bg-gray-800  (#1f2937)
Border:           border-gray-700 (#374151) or border-gray-800 (#1f2937)
Text primary:     text-white
Text secondary:   text-gray-400  (#9ca3af)
Text muted:       text-gray-500  (#6b7280) or text-gray-600 (#4b5563)
Accent:           bg-indigo-600  (#4f46e5) / hover:bg-indigo-500
Destructive:      bg-red-600     (#dc2626) / hover:bg-red-500
Success:          bg-green-500   (#22c55e)
Warning:          bg-yellow-500  (#eab308)
Running/Active:   bg-yellow-500 animate-pulse
```

## Dashboard Layout Architecture

```
+-----------+--------------------------------------------------+
|           |  Top bar (breadcrumbs, user menu)                 |
|  Sidebar  +--------------------------------------------------+
|  (nav)    |                                                    |
|           |  Main content area                                 |
|  Agents   |  (changes per route)                               |
|  Tools    |                                                    |
|  Flows    |                                                    |
|  Runs     |                                                    |
|  Memory   |                                                    |
|           |                                                    |
|  v0.1.0   |                                                    |
+-----------+--------------------------------------------------+
```

Router structure:

```elixir
live_session :dashboard,
  on_mount: [{AgentExWeb.UserAuth, :require_authenticated}] do
  live "/", DashboardLive.Index
  live "/agents", AgentsLive.Index
  live "/agents/:id", AgentsLive.Show
  live "/tools", ToolsLive.Index
  live "/flows", FlowsLive.Index
  live "/flows/:id", FlowsLive.Show
  live "/runs", RunsLive.Index
  live "/runs/:id", RunsLive.Show
  live "/memory", MemoryLive.Index
end
```

Navigation uses `<.link navigate={~p"/path"}>` for cross-page navigation
(mounts new LiveView, keeps layout) and `<.link patch={~p"/path"}>` for
same-page URL updates (sends minimal diff).

## Phase Installation Timeline

| Phase | What to Install | When |
|---|---|---|
| Phase 5 | `salad_ui`, `sortablejs` (npm) | Before starting agent builder |
| Phase 6 | `live_svelte`, `@xyflow/svelte` (npm), `svelte` (npm) | Before starting flow builder |
| Phase 7 | `d3` (npm) or use LiveSvelte for KG graph | Before starting memory inspector |
