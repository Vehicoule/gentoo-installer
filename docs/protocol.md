# Headless protocol — engine ↔ frontend contract

The engine is the only source of truth. Frontends (TUI, GUI, scripts,
future web UI) never implement install logic — they render page schemas
and ferry ops/events.

## Transport & framing

- `gentoo-installer --headless` — full session: detect → wizard → install.
- `gentoo-installer wizard --headless` — wizard only (review/export,
  no install).
- `gentoo-installer --config f.toml --headless` — prefilled config;
  still emits the event stream (CI/mass-install path).

Newline-delimited JSON: **ops on stdin, events on stdout**, one object
per line, UTF-8. stderr carries human debug logs only — never protocol
traffic. Every line is a complete JSON object; no length prefixes, no
multi-line payloads (embedded text is `\n`-escaped inside the object).

## Correlation

Every op may carry `"req": <int>` — a client-chosen correlation token
its terminal reply (`result`, `error`, or the solicited event itself)
echoes in `req`. Ops are processed in order, but **unsolicited
events** (`step`, `log`, `progress`, `ask`) interleave freely and
carry no `req` — frontends must not assume reply adjacency.
`req` is only correlation — object identity uses named fields: page
selection is `"page"`, ask/answer matching is `"ask"` (an opaque
token), both strings.

## Session lifecycle

```
hello ──► ready ──► (detect) ──► wizard ──► review ──► installing ──► done
                          ▲          │                      │
                          └──── BACK ┴── goto               ├─ done{ok:false}
                                        any time: cancel ──►┴─ cancelled
```

The `hello` reply **is** the ready signal — no separate `ready` event.
`installing` means the pipeline is running; terminal states are `done`
and `cancelled`. `--resume` enters at `installing` with a restored
journal. (`repair` in-protocol is the same engine path as the
`detect --repair` CLI — one implementation, two entry points.)

## Ops

| op | payload | reply | notes |
|---|---|---|---|
| `hello` | `version`, `client` | `hello` | version negotiation; engine refuses `version` it can't serve |
| `detect` | — | `env` | probe hardware/OSes; caches until `detect` again |
| `get_config` | — | `config` | secrets masked (`{"secret":true,"is_set":bool}`) |
| `set` | `field`, `value` | `result` + `validate` delta | dotted path (`disk.root_fs`); secrets accepted, never re-emitted |
| `set_config` | `config` | `result` + `validate` | bulk load (answer file import) |
| `page` | `page?` (name) | `page` | current page, or a *peek* at the named one — schema emitted but wizard position unchanged (`index` is its flow position, `0` when off-flow) |
| `next` | — | `page` or `review` | runs page VALIDATE first; `error` on failure |
| `back` | — | `page` | — |
| `goto` | `page` | `page` | rail jump — restricted to done/current flow pages; forward or off-flow pages get `error` (a forward hop would reach Review with gate pages unvalidated) |
| `plan` | — | `plan` | the DiskPlan/`Cmd` preview — dry-run identical |
| `validate` | — | `validate` | whole-config check (P7's gate backend) |
| `export_answer` | `path` | `result` | writes TOML mode 0600; passwords → hashes |
| `install` | `dry_run` | stream, ends `done` | enters `installing` |
| `answer` | `ask`, `value` | `result` | replies to `ask` events by token |
| `retry` / `skip` / `abort` | — | `result` | valid only during `step_failed` pause |
| `cancel` | — | `cancelled` when safe point hit | finishes the in-flight step first |
| `repair` | — | `env` + `plan` | in-protocol form of `detect --repair`: post-reboot diff of disk vs plan |
| `quit` | — | `bye` | clean close |

## Events

| ev | fields | when |
|---|---|---|
| `hello` | `engine`, `version`, `caps[]` | handshake reply — doubles as `ready` |
| `result` | `req?`, `ok:true`, `data?` | ack for mutation ops (`set`, `answer`, `retry`…); `req` omitted when the op didn't send one |
| `env` | `boot`, `arch`, `ram_mib`, `net`, `disks[]`, `oses[]`, `esps[]`, `gpus[]`, `live_media` | after `detect`; also pushed when hotplug changes disks |
| `config` | `config` (secrets masked) | `get_config` reply |
| `page` | `page` (name), `index`, `of`, `title`, `section`, `subtitle`, `nav[]`, `fields[]`, `actions[]`; review adds `summary[]`, `steps[]` | navigation replies |
| `validate` | `errors[]{field?,message}`, `warnings[]` | after `set`, `next`, `validate` |
| `plan` | `ops[]` (the partitioning doc's op list), `cmds[]` preview | `plan` reply |
| `step` | `i`, `of`, `name`, `state`(started/done/failed/skipped), `secs?` | pipeline progress |
| `progress` | `step`, `bytes?`, `pct?`, `label` | sub-step detail (downloads, rsync, emerge ETA) |
| `log` | `step`, `stream`(out/err), `line` | tool output, line-buffered |
| `ask` | `ask` (token), `kind`(choice/confirm/secret/string), `prompt`, `options[]?` | engine needs input mid-step (LUKS passphrase, retry choice) |
| `answer_needed` | `ask` | marker that a step is paused awaiting `answer` |
| `done` | `ok`, `summary?`, `failures[]?` | install finished |
| `error` | `code`, `message`, `hint`, `req?` | op failure or fatal step |
| `cancelled` | `completed_steps`, `resumable` | cancel finished |
| `bye` | — | quit acknowledged |

## Page schema

`page` events carry the field schema the frontend renders — the engine
owns labels, defaults, options, visibility:

```json
{"ev":"page","page":"disk","index":2,"of":7,"title":"Disk",
 "section":"Storage","subtitle":"pick the disk Gentoo installs onto",
 "nav":[{"id":"welcome","title":"Welcome","section":"Get started","state":"done"},
        {"id":"disk","title":"Disk","section":"Storage","state":"current"}],
 "fields":[
  {"name":"disk.device","type":"enum","label":"Target disk",
   "options":[{"v":"/dev/vdb","label":"vdb · 64 GiB"}],
   "value":"/dev/vdb","default":null}],
 "actions":["back","next"]}
```

Field types: `enum`, `bool`, `int`, `string`, `secret`, `list`, `record`,
`table`, `path`. Visibility predicates live **engine-side only**: the
emitted schema already omits fields and enum options whose conditions
are false (a machine with no detected other OS never sees `alongside`;
`disk.luks=false` hides the passphrase). Frontends get a fresh `page`
event whenever a `set` changes visibility; they never evaluate
predicates. `expert` fields are absent in Express flow.

`section` + `subtitle` drive the guided layout: `section` groups pages
on the nav rail (`Get started`, `Storage`, `Personalize`, `Software`,
`Install`), `subtitle` is the one-line "why am I here" under the title.
`nav[]` lists every page in the flow with `state` ∈ `done` / `current` /
`todo` — frontends draw the rail from it and jump with `goto`.

The `review` page additionally emits `summary[]` — `{title, edit,
lines[]}` groups where `edit` is the page id a frontend links its
"Change" button to (empty string for pages hidden by the current flow —
they render read-only, off-flow pages are unreachable by `goto`) — and
`steps[]` — `{id, title}` of every plan step,
so the install view can draw the timeline before `step` events arrive.

`validate` errors carry `field`: the dotted config path the message
belongs to (frontend renders it under that field), or `null` for
page-level errors rendered as a banner.

## Secrets

Secret values flow exactly once: frontend → engine via `set`
(`"value":"…"`, in-memory only) or `answer` to an `ask` of kind
`secret`. They are never in `config` events, the journal, `log` lines,
or `plan`/`Cmd` serialization. Answer-file export emits
`password_hash`/`luks` references, never plaintext.

## Errors

`error` events carry `{code, message, hint}` — `code` is stable
(`E_NO_DISKS`, `E_ESP_TOO_SMALL`, `E_NTFS_DIRTY`, `E_LUKS_WEAK`,
`E_NO_LOGIN_PATH`, `E_NET_REQUIRED`, `E_STEP_FAILED`…), `hint` is the
user-actionable fix. The TUI renders these inline/on an error page; the
GUI as dialogs; `--config` runs print and exit non-zero.

## Versioning & caps

`hello.version` is an integer; `caps[]` advertises optional surfaces
(`wizard`, `install`, `detect`, `repair`, `snapshots`). A frontend may
require caps and degrade otherwise. Adding ops/events/fields is a minor
bump — consumers ignore unknown keys; removing/renaming is a major bump.

Stability tiers: the **envelope** — stdin ops / stdout events, `op`/`ev`
keys, `req` correlation, the op and event vocabulary above — is stable:
frontends build against it now. **Payload fields** (per-field names
inside `env`, `page`, `plan`…) are still draft and may churn until the
first engine ships; at that point `version` becomes 1 and the semver
rules above apply. A frontend written to this doc should still pin the
doc revision it targets until then.

## Annotated session

```jsonl
→ {"op":"hello","version":1,"client":"gui-libcosmic"}
← {"ev":"hello","engine":"0.2.0","version":1,"caps":["wizard","install","detect","repair"]}
→ {"op":"detect","req":1}
← {"ev":"env","req":1,"boot":"uefi","arch":"amd64","ram_mib":15625,"net":true,"oses":[{"kind":"windows","disk":"/dev/nvme0n1"}],"disks":[{"path":"/dev/nvme0n1","size_gib":476,"model":"nvme"}],"esps":[{"part":"/dev/nvme0n1p1","free_mib":240}]}
→ {"op":"set","field":"mode","value":"express"}
→ {"op":"page","page":"disk","req":2}
← {"ev":"page","req":2,"page":"disk","index":1,"of":9,"fields":[{"name":"disk.device","type":"enum","options":[{"v":"/dev/nvme0n1","label":"nvme · 476 GiB"}]}],"actions":["next","back"]}
→ {"op":"set","field":"disk.device","value":"/dev/nvme0n1","req":3}
← {"ev":"result","req":3,"ok":true}
← {"ev":"validate","errors":[],"warnings":[{"code":"W_ESP","message":"existing ESP has 240 MiB free"}]}
→ {"op":"plan","req":4}
← {"ev":"plan","req":4,"ops":[{"op":"wipe_table","disk":"/dev/nvme0n1"},{"op":"create_part","name":"ESP","size_mib":512,"type":"EF00"}],"cmds":["sgdisk -Z /dev/nvme0n1","sgdisk -n1:1MiB:+512MiB -t1:EF00 /dev/nvme0n1"]}
→ {"op":"install","dry_run":false}
← {"ev":"step","i":1,"of":16,"name":"detect","state":"done","secs":0.8}
← {"ev":"step","i":2,"of":16,"name":"partition","state":"started"}
← {"ev":"ask","ask":"a1","kind":"confirm","prompt":"Wipe /dev/nvme0n1? type nvme0n1"}
→ {"op":"answer","ask":"a1","value":"nvme0n1","req":5}
← {"ev":"result","req":5,"ok":true}
← {"ev":"log","step":2,"stream":"out","line":"Created new GPT entries"}
← {"ev":"step","i":2,"state":"done","secs":3.1}
← {"ev":"done","ok":true,"summary":{"hostname":"gentoo","users":["larry"]}}
```

Same stream drives `--config` CI installs (ops prefilled; `ask` events
are auto-answered from the config or fail fast with `E_MISSING_INPUT`).
