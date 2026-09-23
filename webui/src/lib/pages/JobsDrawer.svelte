<script lang="ts">
  // JobsDrawer — list jobs, view their recorded output (paged via JobOutput),
  // watch a running job live, or kill it. On phones the list renders as cards
  // so the command never overflows the screen.
  import { onMount } from 'svelte'
  import { Button } from '$lib/components/ui/button'
  import { client, session, stripAnsi } from '$lib/session.svelte'
  import { watchJob } from '$lib/worker'

  let { onClose }: { onClose: () => void } = $props()

  interface Job {
    id: string
    command: string
    state: string
    exitCode: number
    startedAt: number
    finishedAt: number
  }

  let jobs = $state<Job[]>([])
  let loading = $state(false)
  let toast = $state('')

  // viewer
  let viewId = $state<string | null>(null)
  let viewLines = $state<string[]>([])
  let viewTotal = $state(0)
  let viewDone = $state(false)
  let viewStream = $state<'all' | 'stdout' | 'stderr'>('all')
  let watchAbort: AbortController | null = null

  const PAGE = 500

  function say(m: string) {
    toast = m
    setTimeout(() => (toast = ''), 2500)
  }

  async function load() {
    loading = true
    try {
      const r = await client().listJobs({ limit: 200 })
      jobs = (r.jobs ?? []).map(j => ({
        id: j.id,
        command: j.command,
        state: j.state,
        exitCode: j.exitCode,
        startedAt: Number(j.startedAt),
        finishedAt: Number(j.finishedAt),
      }))
    } catch (e) {
      say(String((e as Error)?.message ?? e))
    }
    loading = false
  }

  async function view(id: string, start = 0) {
    viewId = id
    try {
      const r = await client().jobOutput({ jobId: id, start, end: start + PAGE, stream: viewStream })
      viewLines = start === 0 ? [...r.lines] : [...viewLines, ...r.lines]
      viewTotal = r.totalLines
      viewDone = r.done
    } catch (e) {
      say(String((e as Error)?.message ?? e))
    }
  }

  async function reload() {
    if (viewId) await view(viewId, 0)
  }

  async function watch(id: string) {
    viewId = id
    viewLines = []
    viewTotal = 0
    viewDone = false
    const ac = new AbortController()
    watchAbort = ac
    try {
      await watchJob(session.token, id, (ev) => {
        if (ev.output !== undefined) viewLines = [...viewLines, stripAnsi(ev.output)]
        if (ev.done) {
          viewLines = [...viewLines, `[done exit=${ev.done.exitCode}]`]
          viewDone = true
        }
      }, ac.signal)
    } catch (e) {
      if ((e as Error)?.name !== 'AbortError') say(String((e as Error)?.message ?? e))
    } finally {
      watchAbort = null
    }
  }

  async function kill(id: string) {
    if (!confirm(`Kill job ${id}? Its whole process tree is terminated.`)) return
    try {
      await client().jobKill({ jobId: id })
      say('kill sent')
      await load()
    } catch (e) {
      say(String((e as Error)?.message ?? e))
    }
  }

  function back() {
    watchAbort?.abort()
    viewId = null
    viewLines = []
  }

  onMount(() => {
    void load()
  })
</script>

<div class="flex min-h-0 min-w-0 flex-1 flex-col">
  <div class="flex shrink-0 items-center gap-1 border-b border-border px-2 py-1.5">
    {#if viewId}<Button variant="ghost" size="sm" onclick={back}>← Jobs</Button>{/if}
    <span class="text-meta font-semibold">{viewId ? 'Output' : 'Jobs'}</span>
    <span class="ml-auto"></span>
    {#if viewId}
      <select
        bind:value={viewStream}
        onchange={reload}
        class="h-7 rounded-md border border-input bg-transparent px-1.5 text-micro"
      >
        <option value="all">all</option>
        <option value="stdout">stdout</option>
        <option value="stderr">stderr</option>
      </select>
      <Button variant="ghost" size="sm" onclick={reload}>Refresh</Button>
    {:else}
      <Button variant="ghost" size="sm" onclick={load}>Refresh</Button>
    {/if}
    <Button variant="ghost" size="sm" onclick={onClose}>×</Button>
  </div>

  {#if viewId}
    <div class="min-h-0 flex-1 overflow-auto p-2 font-mono text-meta">
      {#each viewLines as l, i (i)}
        <div class="term-line">{l}</div>
      {/each}
      {#if viewLines.length === 0}
        <p class="text-muted-foreground">no output</p>
      {/if}
    </div>
    <div class="flex shrink-0 items-center gap-2 border-t border-border px-2 py-1.5 text-micro text-muted-foreground">
      <span>{viewLines.length} / {viewTotal} lines {viewDone ? '· done' : '· running'}</span>
      <span class="ml-auto"></span>
      {#if !viewDone}
        <Button variant="ghost" size="sm" onclick={() => watch(viewId!)}>Watch live</Button>
        <Button variant="ghost" size="sm" class="text-destructive" onclick={() => kill(viewId!)}>Kill</Button>
      {/if}
      {#if viewLines.length < viewTotal}
        <Button variant="ghost" size="sm" onclick={() => view(viewId!, viewLines.length)}>Load more</Button>
      {/if}
    </div>
  {:else}
    <div class="min-h-0 flex-1 overflow-auto">
      {#if loading}
        <p class="p-3 text-meta text-muted-foreground">loading…</p>
      {:else if jobs.length === 0}
        <p class="p-3 text-meta text-muted-foreground">no jobs</p>
      {:else}
        <!-- phones: cards (command wraps, never overflows) -->
        <div class="flex flex-col gap-2 p-2 sm:hidden">
          {#each jobs as j (j.id)}
            <div class="rounded-md border border-border bg-card p-2">
              <div class="flex items-center gap-2 text-micro">
                <span class="font-mono">{j.id}</span>
                <span class="state-{j.state} font-semibold">{j.state}</span>
                {#if j.state !== 'running'}<span class="text-muted-foreground">exit {j.exitCode}</span>{/if}
              </div>
              <p class="mt-1 font-mono text-micro break-all whitespace-pre-wrap">{j.command}</p>
              <div class="mt-1.5 flex gap-1">
                <Button variant="outline" size="sm" onclick={() => view(j.id)}>View</Button>
                <Button variant="outline" size="sm" onclick={() => watch(j.id)}>Watch</Button>
                {#if j.state === 'running'}<Button variant="outline" size="sm" class="text-destructive" onclick={() => kill(j.id)}>Kill</Button>{/if}
              </div>
            </div>
          {/each}
        </div>
        <!-- desktop: table -->
        <table class="hidden w-full table-fixed border-collapse text-meta sm:table">
          <thead>
            <tr class="text-micro text-muted-foreground">
              <th class="w-[92px] px-2 py-1.5 text-left font-medium">id</th>
              <th class="w-[72px] px-2 py-1.5 text-left font-medium">state</th>
              <th class="w-[48px] px-2 py-1.5 text-left font-medium">exit</th>
              <th class="px-2 py-1.5 text-left font-medium">command</th>
              <th class="w-[150px] px-2 py-1.5"></th>
            </tr>
          </thead>
          <tbody>
            {#each jobs as j (j.id)}
              <tr class="border-t border-border">
                <td class="px-2 py-1.5 font-mono text-micro">{j.id}</td>
                <td class="state-{j.state} px-2 py-1.5">{j.state}</td>
                <td class="px-2 py-1.5">{j.state === 'running' ? '' : j.exitCode}</td>
                <td class="truncate px-2 py-1.5 font-mono text-micro" title={j.command}>{j.command}</td>
                <td class="px-2 py-1.5">
                  <div class="flex gap-1">
                    <Button variant="ghost" size="sm" onclick={() => view(j.id)}>View</Button>
                    <Button variant="ghost" size="sm" onclick={() => watch(j.id)}>Watch</Button>
                    {#if j.state === 'running'}<Button variant="ghost" size="sm" class="text-destructive" onclick={() => kill(j.id)}>Kill</Button>{/if}
                  </div>
                </td>
              </tr>
            {/each}
          </tbody>
        </table>
      {/if}
    </div>
  {/if}

  {#if toast}
    <div class="shrink-0 border-t border-border bg-popover px-3 py-1.5 text-micro">{toast}</div>
  {/if}
</div>
