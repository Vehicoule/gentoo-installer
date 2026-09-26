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

Every op may carry `"id": <int>`; its terminal reply
(`result`/`error`/`answer_needed`) echoes that id. Ops are processed in
order, but **unsolicited events** (`step`, `log`, `progress`) interleave
freely and carry no id — frontends must not assume reply adjacency.
An `id`-less op gets the next reply; interactive frontends may omit ids.

## Session lifecycle

```
hello ──► ready ──► (detect) ──► wizard ──► review ──► installing ──► done
                          ▲          │                      │
                          └──── BACK ┴── goto               ├─ done{ok:false}
                                        any time: cancel ──►┴─ cancelled
```

`ready` means the engine accepted the handshake; `installing` means the
pipeline is running; terminal states are `done` and `cancelled`.
`--resume` enters at `installing` with a restored journal.

## Ops

| op | payload | reply | notes |
|---|---|---|---|
| `hello` | `version`, `client` | `hello` | version negotiation; engine refuses `version` it can't serve |
| `detect` | — | `env` | probe hardware/OSes; caches until `detect` again |
| `get_config` | — | `config` | secrets masked (`{"secret":true,"is_set":bool}`) |
| `set` | `field`, `value` | `result` + `validate` delta | dotted path (`disk.root_fs`); secrets accepted, never re-emitted |
| `set_config` | `config` | `result` + `validate` | bulk load (answer file import) |
| `page` | `id?` | `page` | current page or the named one |
| `next` | — | `page` or `review` | runs page VALIDATE first; `error` on failure |
| `back` | — | `page` | — |
| `goto` | `id` | `page` | review-page jump links; backward jumps only mutate nav |
| `plan` | — | `plan` | the DiskPlan/`Cmd` preview — dry-run identical |
| `validate` | — | `validate` | whole-config check (P7's gate backend) |
| `export_answer` | `path` | `result` | writes TOML mode 0600; passwords → hashes |
| `install` | `dry_run` | stream, ends `done` | enters `installing` |
| `answer` | `id`, `value` | `result` | replies to `ask` events |
| `retry` / `skip` / `abort` | — | `result` | valid only during `step_failed` pause |
| `cancel` | — | `cancelled` when safe point hit | finishes the in-flight step first |
| `repair` | — | `env` + `plan` | post-reboot path: diff disk vs plan |
| `quit` | — | `bye` | clean close |

## Events

| ev | fields | when |
|---|---|---|
| `hello` | `engine`, `version`, `caps[]` | handshake reply |
| `env` | `boot`, `arch`, `ram_mib`, `net`, `disks[]`, `oses[]`, `esps[]`, `live_media` | after `detect`; also pushed when hotplug changes disks |
| `config` | `config` (secrets masked) | `get_config` reply |
| `page` | `id`, `index`, `of`, `title`, `fields[]`, `actions[]` | navigation replies |
| `validate` | `errors[]{path,code,message,hint}`, `warnings[]` | after `set`, `next`, `validate` |
| `plan` | `ops[]` (the partitioning doc's op list), `cmds[]` preview | `plan` reply |
| `step` | `i`, `of`, `name`, `state`(started/done/failed/skipped), `secs?` | pipeline progress |
| `progress` | `step`, `bytes?`, `pct?`, `label` | sub-step detail (downloads, rsync, emerge ETA) |
| `log` | `step`, `stream`(out/err), `line` | tool output, line-buffered |
| `ask` | `id`, `kind`(choice/confirm/secret/string), `prompt`, `options[]?` | engine needs input mid-step (LUKS passphrase, retry choice) |
| `answer_needed` | `id` | marker that a step is paused on `ask` |
| `done` | `ok`, `summary?`, `failures[]?` | install finished |
| `error` | `code`, `message`, `hint`, `id?` | op failure or fatal step |
| `cancelled` | `completed_steps`, `resumable` | cancel finished |
| `bye` | — | quit acknowledged |

## Page schema

`page` events carry the field schema the frontend renders — the engine
owns labels, defaults, options, visibility:

```json
{"ev":"page","id":"disk","index":1,"of":9,"fields":[
  {"name":"disk.scheme","type":"enum","label":"Install mode",
   "options":[{"v":"normal","label":"Erase disk"},
              {"v":"alongside","label":"Install alongside Windows",
               "help":"Keeps your existing OS","hidden_if":"!oses"}],
   "value":"normal","default":"normal"},
  {"name":"disk.luks_passphrase","type":"secret","label":"Encryption passphrase",
   "visible_if":"disk.luks","min":8,"confirm":true}],
 "actions":["next","back"]}
```

Field types: `enum`, `bool`, `int`, `string`, `secret`, `list`, `record`,
`table`, `path`. `visible_if`/`hidden_if` are expressions evaluated by
the engine — frontends get a fresh `page` event whenever a `set` changes
visibility, so they never evaluate predicates themselves. `expert` fields
are simply absent in Express flow.

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

## Annotated session

```jsonl
→ {"op":"hello","version":1,"client":"gui-libcosmic"}
← {"ev":"hello","engine":"0.2.0","version":1,"caps":["wizard","install","detect","repair"]}
→ {"op":"detect","id":1}
← {"ev":"env","id":1,"boot":"uefi","arch":"amd64","ram_mib":15625,
   "net":true,"oses":[{"kind":"windows","disk":"/dev/nvme0n1"}],
   "disks":[{...}],"esps":[{...}]}
→ {"op":"set","field":"mode","value":"express"}
→ {"op":"page","id":2}
← {"ev":"page","id":"disk",...}
→ {"op":"set","field":"disk.device","value":"/dev/nvme0n1","id":3}
← {"ev":"validate","id":3,"errors":[],"warnings":[{"code":"W_ESP","message":"existing ESP has 240 MiB free"}]}
← {"ev":"page","id":"disk","fields":[... shrunk visibility update ...]}
→ {"op":"plan","id":4}
← {"ev":"plan","id":4,"ops":[{"op":"wipe_table",...}],"cmds":["sgdisk -Z /dev/nvme0n1", ...]}
→ {"op":"install","dry_run":false}
← {"ev":"step","i":1,"of":16,"name":"detect","state":"done","secs":0.8}
← {"ev":"step","i":2,"of":16,"name":"partition","state":"started"}
← {"ev":"ask","id":"a1","kind":"confirm","prompt":"Wipe /dev/nvme0n1? type nvme0n1"}
→ {"op":"answer","id":"a1","value":"nvme0n1"}
← {"ev":"log","step":2,"stream":"out","line":"Created new GPT entries"}
← {"ev":"step","i":2,"state":"done","secs":3.1}
← {"ev":"done","ok":true,"summary":{"hostname":"gentoo","users":["larry"]}}
```

Same stream drives `--config` CI installs (ops prefilled; `ask` events
are auto-answered from the config or fail fast with `E_MISSING_INPUT`).
