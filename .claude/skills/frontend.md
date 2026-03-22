# Frontend Development Skill

When writing Phoenix LiveView frontend code for AgentEx, follow these conventions.

## Component Library: SaladUI

Use SaladUI (shadcn/ui port) for all UI components. Import from `SaladUI.*` modules.

### Buttons
```heex
<.button variant="default">Primary</.button>
<.button variant="destructive">Delete</.button>
<.button variant="outline">Secondary</.button>
<.button variant="ghost" size="icon"><.icon name="hero-plus" /></.button>
```

### Cards
```heex
<.card>
  <.card_header>
    <.card_title>Title</.card_title>
    <.card_description>Subtitle</.card_description>
  </.card_header>
  <.card_content>Content</.card_content>
  <.card_footer><.button>Action</.button></.card_footer>
</.card>
```

### Tabs
```heex
<.tabs default_value="tab1">
  <.tabs_list>
    <.tabs_trigger value="tab1">Tab 1</.tabs_trigger>
    <.tabs_trigger value="tab2">Tab 2</.tabs_trigger>
  </.tabs_list>
  <.tabs_content value="tab1">Content 1</.tabs_content>
  <.tabs_content value="tab2">Content 2</.tabs_content>
</.tabs>
```

### Dialogs/Modals
```heex
<.dialog>
  <.dialog_trigger><.button>Open</.button></.dialog_trigger>
  <.dialog_content>
    <.dialog_header>
      <.dialog_title>Title</.dialog_title>
      <.dialog_description>Description</.dialog_description>
    </.dialog_header>
    <!-- form content -->
  </.dialog_content>
</.dialog>
```

### Form Inputs
```heex
<.input field={@form[:name]} label="Name" placeholder="Enter name" />
<.select name="provider">
  <.select_trigger><.select_value placeholder="Choose" /></.select_trigger>
  <.select_content>
    <.select_item value="openai">OpenAI</.select_item>
  </.select_content>
</.select>
<.switch name="enabled" checked={@enabled} />
<.checkbox name="confirm" />
```

### Dropdown Menus
```heex
<.dropdown_menu>
  <.dropdown_menu_trigger><.button variant="ghost" size="icon"><.icon name="hero-ellipsis-vertical" /></.button></.dropdown_menu_trigger>
  <.dropdown_menu_content>
    <.dropdown_menu_item>Edit</.dropdown_menu_item>
    <.dropdown_menu_separator />
    <.dropdown_menu_item variant="destructive">Delete</.dropdown_menu_item>
  </.dropdown_menu_content>
</.dropdown_menu>
```

### Other Components
Badge, Alert, Accordion, Breadcrumb, Progress, Skeleton, Table, Toast, Tooltip, Popover, Sheet (side panel), Separator, Avatar, Slider, Toggle, Scroll Area, Pagination, Hover Card, Collapsible, Alert Dialog.

## Icons: Heroicons (built-in)

Use Phoenix built-in heroicons. No extra dependency.

```heex
<.icon name="hero-cog-6-tooth" class="w-5 h-5" />
<.icon name="hero-plus" class="w-4 h-4" />
<.icon name="hero-trash-solid" class="w-4 h-4 text-red-400" />
```

AgentEx icon conventions:
- Chat/Runs: `hero-chat-bubble-left-right`
- Agents: `hero-user-circle`
- Tools: `hero-wrench-screwdriver`
- Flows: `hero-arrows-right-left`
- Memory: `hero-circle-stack`
- Settings: `hero-cog-6-tooth`
- Play/Run: `hero-play`
- Stop/Cancel: `hero-stop`
- Add: `hero-plus`
- Delete: `hero-trash`
- Edit: `hero-pencil-square`

## Dark Theme

AgentEx is dark-first. Always use dark theme colors:

| Element | Class |
|---|---|
| Page background | `bg-gray-950` |
| Surface (sidebar, panels) | `bg-gray-900` |
| Elevated surface (cards, inputs) | `bg-gray-800` |
| Borders | `border-gray-700` or `border-gray-800` |
| Primary text | `text-white` |
| Secondary text | `text-gray-400` |
| Muted text | `text-gray-500` or `text-gray-600` |
| Accent | `bg-indigo-600 hover:bg-indigo-500` |
| Destructive | `bg-red-600 hover:bg-red-500` |
| Success indicator | `bg-green-500` |
| Warning indicator | `bg-yellow-500` |
| Running indicator | `bg-yellow-500 animate-pulse` |

## Flow Builder: LiveSvelte + Svelte Flow (Phase 6)

For the visual flow/pipeline editor, use LiveSvelte to embed Svelte Flow.

```heex
<.svelte name="FlowEditor" props={%{nodes: @nodes, edges: @edges}} socket={@socket} />
```

Server state drives the canvas. User interactions push events back via `pushEvent`.

## Drag & Drop: SortableJS (Phase 5)

For list reordering (intervention pipelines, tool ordering):

```heex
<div id="sortable-list" phx-hook="Sortable">
  <div :for={item <- @items} data-id={item.id}>...</div>
</div>
```

## Layout Pattern

All dashboard pages use `live_session` with shared auth and nav:

```elixir
live_session :dashboard,
  on_mount: [{AgentExWeb.UserAuth, :require_authenticated}] do
  live "/agents", AgentsLive.Index
  live "/tools", ToolsLive.Index
  # ...
end
```

Navigation uses `<.link navigate={~p"/path"}>` for page switches (keeps layout, mounts new LiveView).

## Responsive Design

All pages should be responsive across 3 breakpoints (target standard; the current sidebar in `app.html.heex` still uses fixed `w-56`):

| Breakpoint | Tailwind Prefix | Min Width | Target |
|---|---|---|---|
| Mobile | (default) | 0px | Phones (portrait) |
| Tablet | `md:` | 768px | Tablets, small laptops |
| Desktop | `lg:` | 1024px | Desktops, wide screens |

### Layout Behavior by Breakpoint

**Sidebar navigation:**
- Mobile: hidden, toggled via hamburger menu (`hero-bars-3` icon)
- Tablet: collapsed icon-only rail (w-16)
- Desktop: full expanded sidebar (w-64)

```heex
<!-- Sidebar wrapper -->
<aside class="hidden md:flex md:w-16 lg:w-64 md:flex-col bg-gray-900 border-r border-gray-800">
  <!-- Full label visible on desktop only -->
  <span class="hidden lg:inline">Agents</span>
</aside>

<!-- Mobile hamburger toggle -->
<button class="md:hidden" phx-click={JS.toggle(to: "#mobile-nav")}>
  <.icon name="hero-bars-3" class="w-6 h-6" />
</button>
```

**Content grids:**
- Mobile: single column, full width (`grid-cols-1`)
- Tablet: 2 columns (`md:grid-cols-2`)
- Desktop: 3-4 columns (`lg:grid-cols-3` or `lg:grid-cols-4`)

```heex
<div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
  <.card :for={agent <- @agents}>...</.card>
</div>
```

**Tables:**
- Mobile: card-based layout or horizontally scrollable (`overflow-x-auto`)
- Tablet+: standard table layout

```heex
<!-- Hide columns on mobile, show as stacked cards instead -->
<div class="block md:hidden">
  <.card :for={row <- @data}><!-- mobile card view --></.card>
</div>
<div class="hidden md:block overflow-x-auto">
  <.table><!-- full table --></.table>
</div>
```

**Dialogs/Modals:**
- Mobile: full-screen sheet (`class="w-full h-full"`)
- Tablet+: centered modal with max-width

**Typography & spacing:**
- Mobile: `text-sm`, `p-3`, `gap-3`
- Tablet: `md:text-base`, `md:p-4`, `md:gap-4`
- Desktop: `lg:text-base`, `lg:p-6`, `lg:gap-6`

### Rules for Responsive Code

- Always design mobile-first — write base styles for mobile, then add `md:` and `lg:` overrides
- Never use fixed widths (`w-[500px]`) — use responsive widths (`w-full md:w-96 lg:w-[500px]`)
- Touch targets on mobile must be at least 44x44px (`min-h-[44px] min-w-[44px]`)
- Use `flex-wrap` or `flex-col md:flex-row` for action button groups
- Test all pages at 375px (mobile), 768px (tablet), and 1280px (desktop)

## Rules

- Never use Alpine.js — use `Phoenix.LiveView.JS` for client-side interactions
- Always use SaladUI components instead of raw HTML for UI elements
- Keep LiveView assigns minimal — derive computed values in render
- Use `phx-hook` for JavaScript interop, not inline scripts
- Forms always use `phx-submit` with server-side validation
- Wrap selects in `<form phx-change="event_name">` for change events
- Use `phx-update="stream"` for large lists
- All interactive elements must have accessible labels (sr-only or aria-label)
