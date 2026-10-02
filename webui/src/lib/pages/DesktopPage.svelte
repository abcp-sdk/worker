<script lang="ts">
  // DesktopPage — the sandbox's graphical desktop, embedded same-origin.
  //
  // The worker reverse-proxies the noVNC endpoint at its own origin (/novnc/),
  // so this is just an <iframe> to the same origin: no second port, no CORS,
  // and the browser only needs the worker token it already has. `path=` makes
  // noVNC's websocket go through the same /novnc prefix.
  import { AppIcons } from '$lib/icons'

  let { onClose }: { onClose: () => void } = $props()

  const src = '/novnc/vnc.html?autoconnect=1&resize=scale&path=/novnc/websocket'
</script>

<div class="flex min-h-0 flex-1 flex-col bg-background">
  <header class="flex h-10 shrink-0 items-center gap-2 border-b border-border bg-card px-3">
    <AppIcons.desktop class="size-4" />
    <span class="font-medium">Desktop</span>
    <span class="font-mono text-micro text-muted-foreground">/novnc/</span>
    <span class="ml-auto"></span>
    <button
      class="inline-flex items-center gap-1.5 rounded-md px-2 py-1 text-sm hover:bg-muted"
      onclick={onClose}
    >
      <AppIcons.close class="size-4" />Close
    </button>
  </header>
  <iframe
    title="Desktop (noVNC)"
    {src}
    class="min-h-0 w-full flex-1 border-0 bg-black"
    allow="clipboard-read; clipboard-write"
  ></iframe>
</div>
