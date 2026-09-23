<script lang="ts">
  // FilesDrawer — browse/edit the worker filesystem (unconfined). A lazy tree
  // expands directories IN PLACE (children inserted, not a full re-list); a
  // breadcrumb navigates; drag-and-drop uploads FILES into the current dir.
  import { onMount } from 'svelte'
  import { Button } from '$lib/components/ui/button'
  import { Input } from '$lib/components/ui/input'
  import { client, session, normAbs, absOf, basename, fmtSize } from '$lib/session.svelte'

  let { onClose }: { onClose: () => void } = $props()

  interface Node {
    path: string
    name: string
    isDir: boolean
    size: number
    /** Children once expanded (null = not yet listed). */
    children: Node[] | null
    open: boolean
  }

  let root = $state('')
  let nodes = $state<Node[]>([])
  let loading = $state(false)
  let err = $state('')
  let dragging = $state(false)
  let toast = $state('')

  // editor
  let editing = $state<string | null>(null)
  let content = $state('')
  let saving = $state(false)

  function say(msg: string) {
    toast = msg
    setTimeout(() => (toast = ''), 2500)
  }

  function toNode(f: { path: string; size: number | bigint; isDir: boolean }): Node {
    const abs = absOf(f.path)
    return { path: abs, name: basename(abs), isDir: f.isDir, size: Number(f.size), children: null, open: false }
  }

  async function listDir(dir: string): Promise<Node[]> {
    const r = await client().fileList({ path: dir, depth: 1, limit: 2000 })
    return (r.files ?? []).map(toNode).sort((a, b) => (a.isDir === b.isDir ? a.name.localeCompare(b.name) : a.isDir ? -1 : 1))
  }

  async function loadRoot() {
    root = session.cwd || session.workspace || '/'
    loading = true
    err = ''
    try {
      nodes = await listDir(root)
    } catch (e) {
      err = String((e as Error)?.message ?? e)
    }
    loading = false
  }

  async function toggle(n: Node) {
    if (!n.isDir) {
      void openFile(n.path)
      return
    }
    if (n.open) {
      n.open = false
      return
    }
    if (n.children === null) {
      try {
        n.children = await listDir(n.path)
      } catch (e) {
        say(String((e as Error)?.message ?? e))
        return
      }
    }
    n.open = true
  }

  async function navigate(dir: string) {
    session.cwd = normAbs(dir)
    await loadRoot()
  }

  const crumbs = $derived(
    (() => {
      const parts = root.split('/').filter(Boolean)
      const out: { name: string; path: string }[] = [{ name: '/', path: '/' }]
      let acc = ''
      for (const p of parts) {
        acc += '/' + p
        out.push({ name: p, path: acc })
      }
      return out
    })(),
  )

  async function openFile(path: string) {
    editing = path
    content = ''
    try {
      const r = await client().fileRead({ path })
      content = new TextDecoder('utf-8', { fatal: false }).decode(r.content)
    } catch (e) {
      say(String((e as Error)?.message ?? e))
      editing = null
    }
  }

  async function save() {
    if (editing === null) return
    saving = true
    try {
      await client().fileWrite({ path: editing, content: new TextEncoder().encode(content) })
      say(`saved ${editing}`)
    } catch (e) {
      say(String((e as Error)?.message ?? e))
    }
    saving = false
  }

  async function del() {
    if (editing === null || !confirm(`Delete ${editing}?`)) return
    try {
      await client().fileDelete({ path: editing })
      editing = null
      await loadRoot()
    } catch (e) {
      say(String((e as Error)?.message ?? e))
    }
  }

  function download() {
    if (editing === null) return
    const bytes = new TextEncoder().encode(content)
    const url = URL.createObjectURL(new Blob([bytes]))
    const a = document.createElement('a')
    a.href = url
    a.download = basename(editing)
    a.click()
    URL.revokeObjectURL(url)
  }

  async function newFile() {
    const name = prompt(`new file path (absolute, or relative to ${root})`)
    if (!name) return
    const abs = name.startsWith('/') ? normAbs(name) : normAbs(root + '/' + name)
    editing = abs
    content = ''
  }

  // ---- drag & drop upload (files only) ----
  async function uploadFiles(files: File[]) {
    if (files.length === 0) return
    let ok = 0
    for (const f of files) {
      try {
        const buf = new Uint8Array(await f.arrayBuffer())
        await client().fileWrite({ path: normAbs(root + '/' + f.name), content: buf })
        ok++
      } catch (e) {
        say(`upload ${f.name}: ${String((e as Error)?.message ?? e)}`)
      }
    }
    if (ok > 0) {
      say(`uploaded ${ok} file(s)`)
      await loadRoot()
    }
  }

  function onDrop(e: DragEvent) {
    e.preventDefault()
    dragging = false
    const files = Array.from(e.dataTransfer?.files ?? [])
    void uploadFiles(files)
  }

  onMount(() => {
    void loadRoot()
  })
</script>

<div
  class="relative flex min-h-0 min-w-0 flex-1 flex-col"
  role="presentation"
  ondragover={(e) => {
    e.preventDefault()
    dragging = true
  }}
  ondragleave={() => (dragging = false)}
  ondrop={onDrop}
>
  {#if editing === null}
    <div class="flex shrink-0 items-center gap-1 border-b border-border px-2 py-1.5">
      <Button variant="ghost" size="sm" title="up one level" onclick={() => navigate(normAbs(root + '/..'))}>↑</Button>
      <Button variant="ghost" size="sm" title="workspace root" onclick={() => navigate(session.workspace || '/')}>⌂</Button>
      <Button variant="ghost" size="sm" onclick={newFile}>New</Button>
      <Button variant="ghost" size="sm" class="ml-auto" onclick={onClose}>×</Button>
    </div>
    <div class="flex shrink-0 flex-wrap items-center gap-0.5 border-b border-border px-2 py-1 font-mono text-micro text-muted-foreground">
      {#each crumbs as c, i (c.path)}
        {#if i > 0}<span>/</span>{/if}
        <button type="button" class="rounded px-1 hover:bg-muted hover:text-foreground" onclick={() => navigate(c.path)}>
          {c.name === '/' ? 'root' : c.name}
        </button>
      {/each}
    </div>

    <div class="min-h-0 flex-1 overflow-auto p-1.5 font-mono text-meta">
      {#if loading}
        <p class="p-2 text-muted-foreground">loading…</p>
      {:else if err}
        <p class="p-2 text-destructive">{err}</p>
      {:else if nodes.length === 0}
        <p class="p-2 text-muted-foreground">empty — drop files here to upload</p>
      {:else}
        {#snippet tree(list: Node[], depth: number)}
          {#each list as n (n.path)}
            <button
              type="button"
              class="flex w-full items-center gap-1.5 rounded px-1.5 py-0.5 text-left hover:bg-muted {n.isDir
                ? 'text-primary'
                : ''}"
              style="padding-left: {6 + depth * 14}px"
              onclick={() => toggle(n)}
            >
              <span class="w-3 shrink-0 text-muted-foreground">{n.isDir ? (n.open ? '▾' : '▸') : ''}</span>
              <span class="min-w-0 flex-1 truncate">{n.name}</span>
              <span class="shrink-0 text-micro text-muted-foreground">{n.isDir ? '' : fmtSize(n.size)}</span>
            </button>
            {#if n.isDir && n.open && n.children}
              {@render tree(n.children, depth + 1)}
            {/if}
          {/each}
        {/snippet}
        {@render tree(nodes, 0)}
      {/if}
    </div>
  {:else}
    <div class="flex shrink-0 items-center gap-1 border-b border-border px-2 py-1.5">
      <span class="min-w-0 flex-1 truncate font-mono text-micro">{editing}</span>
      <Button variant="ghost" size="sm" disabled={saving} onclick={save}>Save</Button>
      <Button variant="ghost" size="sm" onclick={download}>Download</Button>
      <Button variant="ghost" size="sm" class="text-destructive" onclick={del}>Delete</Button>
      <Button variant="ghost" size="sm" onclick={() => (editing = null)}>Back</Button>
    </div>
    <textarea
      bind:value={content}
      class="min-h-0 flex-1 resize-none rounded-none border-0 bg-transparent p-3 font-mono text-meta outline-none"
      spellcheck="false"
    ></textarea>
  {/if}

  {#if dragging}
    <div class="pointer-events-none absolute inset-0 flex items-center justify-center bg-primary/10 text-primary">
      <span class="rounded-md border border-primary bg-background px-3 py-1.5 text-meta">Drop files to upload</span>
    </div>
  {/if}
  {#if toast}
    <div class="absolute inset-x-0 bottom-0 bg-popover px-3 py-1.5 text-micro text-foreground">{toast}</div>
  {/if}
</div>
