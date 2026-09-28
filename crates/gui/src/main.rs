//! gentoo-installer GUI — libcosmic frontend over the headless NDJSON
//! protocol (docs/protocol.md). The Zig engine is spawned as a subprocess;
//! ops go to its stdin, events arrive on stdout.

use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::Mutex;

use cosmic::app::Task;
use cosmic::iced::Length;
use cosmic::iced::futures::SinkExt;
use cosmic::iced::stream;
use cosmic::{Element, theme, widget};
use serde_json::{Value, json};

static ENGINE_IN: Mutex<Option<ChildStdin>> = Mutex::new(None);

fn send_op(v: Value) {
    if let Some(stdin) = ENGINE_IN.lock().unwrap().as_mut() {
        let mut line = serde_json::to_string(&v).unwrap();
        line.push('\n');
        let _ = stdin.write_all(line.as_bytes());
        let _ = stdin.flush();
    }
}

/// Stream feeding engine stdout lines into the app as Messages. The child
/// spawn + line reads are blocking, so they run on a dedicated thread —
/// inside the async block they would starve the channel's receiver half.
fn engine_stream() -> impl cosmic::iced::futures::Stream<Item = Message> {
    use cosmic::iced::futures::channel::mpsc;
    use cosmic::iced::futures::executor::block_on;
    stream::channel(64, |tx: mpsc::Sender<Message>| async move {
        std::thread::spawn(move || {
            let mut tx = tx;
            let spawn = Command::new(engine_binary())
                .arg("headless")
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn();
            let mut child: Child = match spawn {
                Ok(c) => c,
                Err(e) => {
                    let _ = block_on(tx.send(Message::EngineLine(format!("__spawn_error:{e}"))));
                    return;
                }
            };
            *ENGINE_IN.lock().unwrap() = child.stdin.take();
            let stdout = child.stdout.take().unwrap();
            // stderr carries engine diagnostics — forward into the app log
            // instead of discarding, else a fatal exit leaves no trace.
            if let Some(stderr) = child.stderr.take() {
                let mut tx2 = tx.clone();
                std::thread::spawn(move || {
                    for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                        if block_on(tx2.send(Message::EngineLine(format!("__stderr:{line}"))))
                            .is_err()
                        {
                            break;
                        }
                    }
                });
            }
            let _ = block_on(tx.send(Message::EngineLine("__spawned".into())));
            for line in BufReader::new(stdout).lines() {
                match line {
                    Ok(l) => {
                        if block_on(tx.send(Message::EngineLine(l))).is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
            let _ = block_on(tx.send(Message::EngineLine("__eof".into())));
            let _ = child.kill();
        });
    })
}

fn engine_binary() -> String {
    std::env::var("GI_BIN").unwrap_or_else(|_| {
        // repo checkout: zig-out/bin/gentoo-installer next to the workspace root
        let exe = std::env::current_exe().unwrap_or_default();
        for p in exe.ancestors().skip(1) {
            let cand = p.join("zig-out/bin/gentoo-installer");
            if cand.exists() {
                return cand.display().to_string();
            }
        }
        "gentoo-installer".into()
    })
}

fn main() -> cosmic::iced::Result {
    cosmic::app::run::<Installer>(cosmic::app::Settings::default().transparent(false), ())?;
    Ok(())
}

#[derive(Clone, Debug)]
enum Message {
    Engine(Value),
    EngineLine(String),
    Input(String, String),
    ConfirmInput(String, String),
    InstallConfirm(String),
    Toggle(String, bool),
    Select(String, String),
    Op(&'static str),
    Install,
    DryRun,
    Plan,
    /// Enter pressed in a text field — used to commit answer_file loads.
    Submit(String),
    /// Sidebar rail entry clicked — engine `goto` (backward hops only;
    /// the engine refuses forward/off-flow pages).
    Goto(String),
}

struct Step {
    /// engine step id — `step` events key on it (`name` in the wire event)
    name: String,
    title: String,
    state: String,
}

/// One rail entry from the page event's `nav` array.
struct NavItem {
    id: String,
    title: String,
    section: String,
    state: String,
}

/// One `validate` error. The engine attributes each to its owning
/// wizard page (`page`); entries with `local` are GUI-generated and
/// always render wherever they were raised. A null `page` (unscoped
/// engine error) stays hidden until the whole-config gate fires.
struct VErr {
    message: String,
    page: Option<String>,
    local: bool,
}

impl VErr {
    fn local(message: String) -> Self {
        Self {
            message,
            page: None,
            local: true,
        }
    }
}

#[derive(Clone, Copy)]
enum Phase {
    Boot,    // waiting for hello/env
    Wizard,  // page events
    Pending, // install op sent, awaiting first step/error — no buttons
    Running, // step events during install
    Done(bool),
    Failed, // install error mid-run — distinct from a clean dry run
    Dead,   // engine stdout closed
}

struct Installer {
    core: cosmic::Core,
    phase: Phase,
    page: Option<Value>,
    inputs: HashMap<String, String>,         // text/secret buffers
    confirm_inputs: HashMap<String, String>, // second entry for confirm:true secrets
    selected: HashMap<String, String>,       // enum selections
    disk_device: String,                     // last disk.device seen — survives leaving its page
    install_confirm: String,                 // typed basename ack gating the Install button
    steps: Vec<Step>,
    nav: Vec<NavItem>, // page rail mirrored from the engine's nav state
    plan: Option<String>,
    errors: Vec<VErr>,
    errors_unscoped: bool, // install/export gate showed every error, not just this page's
    log: Vec<String>,
    req_seq: u64,                       // monotonic request ids for set correlation
    pending_sets: HashMap<u64, String>, // req -> field; rejected sets restore engine truth
    pending_gates: HashSet<u64>, // req -> whole-config gate op (plan); a validate carrying one unscopes its errors
    last_answer_req: Option<u64>, // newest outstanding answer_file set
    /// detected disks from the `env` event — path → MiB size, so the
    /// destructive confirm panel can say what it's wiping.
    disks: HashMap<String, u64>,
    /// current page index + count from the page event — rail footer.
    page_index: usize,
    page_of: usize,
}

impl Installer {
    /// `(type, confirm)` for a field on the current page.
    fn field_meta(&self, name: &str) -> (String, bool) {
        self.page
            .as_ref()
            .and_then(|p| p.get("fields"))
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .find(|f| f.get("name").and_then(Value::as_str) == Some(name))
            .map(|f| {
                (
                    f.get("type")
                        .and_then(Value::as_str)
                        .unwrap_or("string")
                        .to_string(),
                    f.get("confirm").and_then(Value::as_bool).unwrap_or(false),
                )
            })
            .unwrap_or_else(|| ("string".into(), false))
    }

    /// Send a `set` op with a correlation `req`, remembering which field
    /// it carries so a rejected edit can restore the engine's real value.
    fn send_set(&mut self, field: &str, value: Value) {
        self.req_seq += 1;
        self.pending_sets.insert(self.req_seq, field.to_string());
        if field == "answer_file" {
            self.last_answer_req = Some(self.req_seq);
        }
        send_op(json!({"op": "set", "req": self.req_seq, "field": field, "value": value}));
    }

    /// Send a buffered non-secret field once (answer_file): a load
    /// replaces the whole engine config, so it only goes out on an
    /// explicit commit — Enter in the field. Install/DryRun deliberately
    /// do NOT flush it: an install must run on the configuration the
    /// user reviewed, never on a path they haven't committed.
    fn flush_field(&mut self, name: &str) {
        if let Some(val) = self.inputs.get(name).cloned() {
            self.send_set(name, Value::String(val));
        }
    }

    /// Send any buffered secret inputs (secrets aren't streamed per
    /// keystroke — partial passwords are sensitive plaintext the engine
    /// doesn't need). Returns false when a confirm field mismatches.
    fn flush_secrets(&mut self) -> bool {
        let mut ok = true;
        let fields: Vec<String> = self
            .page
            .as_ref()
            .and_then(|p| p.get("fields"))
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter(|f| f.get("type").and_then(Value::as_str) == Some("secret"))
            .map(|f| {
                f.get("name")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string()
            })
            .collect();
        for name in &fields {
            let Some(val) = self.inputs.get(name.as_str()) else {
                continue;
            };
            let (_, needs_confirm) = self.field_meta(name);
            if needs_confirm {
                let c = self
                    .confirm_inputs
                    .get(name)
                    .map(String::as_str)
                    .unwrap_or("");
                if c != val.as_str() {
                    self.errors.push(VErr::local(format!(
                        "confirmation does not match for {name}"
                    )));
                    ok = false;
                }
            }
        }
        if !ok {
            return false;
        }
        // every confirm passed — only now send the secrets, so a blocked
        // navigation never stores partial credentials engine-side; drop
        // our plaintext copies once the engine has them (they can't be
        // displayed again anyway — the engine only echoes is_set=true)
        for name in fields {
            if let Some(val) = self.inputs.remove(&name) {
                self.confirm_inputs.remove(&name);
                self.send_set(&name, Value::String(val));
            }
        }
        true
    }

    /// Serialize a text-field edit to the JSON shape the engine expects:
    /// int → number, list/record/table → parsed JSON, otherwise a string.
    /// Unparseable values go out as strings so the engine's own error
    /// (shown in the error list) explains the rejection.
    fn typed_value(&self, name: &str, text: &str) -> Value {
        let (ftype, _) = self.field_meta(name);
        match ftype.as_str() {
            "int" => text
                .parse::<i64>()
                .map(Value::from)
                .unwrap_or_else(|_| Value::String(text.into())),
            "list" | "record" | "table" => {
                serde_json::from_str::<Value>(text).unwrap_or_else(|_| Value::String(text.into()))
            }
            _ => Value::String(text.into()),
        }
    }
}

impl cosmic::app::Application for Installer {
    type Executor = cosmic::executor::Default;
    type Flags = ();
    type Message = Message;
    const APP_ID: &'static str = "com.github.Vehicoule.GentooInstaller";

    fn core(&self) -> &cosmic::Core {
        &self.core
    }
    fn core_mut(&mut self) -> &mut cosmic::Core {
        &mut self.core
    }

    fn init(core: cosmic::Core, _flags: Self::Flags) -> (Self, Task<Self::Message>) {
        let app = Installer {
            core,
            phase: Phase::Boot,
            page: None,
            inputs: HashMap::new(),
            confirm_inputs: HashMap::new(),
            selected: HashMap::new(),
            disk_device: String::new(),
            install_confirm: String::new(),
            steps: Vec::new(),
            nav: Vec::new(),
            plan: None,
            errors: Vec::new(),
            errors_unscoped: false,
            log: vec![format!("spawn {}", engine_binary())],
            req_seq: 0,
            pending_sets: HashMap::new(),
            pending_gates: HashSet::new(),
            last_answer_req: None,
            disks: HashMap::new(),
            page_index: 0,
            page_of: 0,
        };
        (app, Task::none())
    }

    fn header_center(&self) -> Vec<Element<'_, Self::Message>> {
        vec![widget::text::title3("Gentoo Installer").into()]
    }

    fn subscription(&self) -> cosmic::iced::Subscription<Self::Message> {
        cosmic::iced::Subscription::run(engine_stream)
    }

    fn update(&mut self, message: Self::Message) -> Task<Self::Message> {
        match message {
            Message::EngineLine(l) => {
                if l == "__spawned" {
                    send_op(json!({"op": "detect"}));
                } else if l == "__eof" {
                    self.phase = Phase::Dead;
                } else if let Some(e) = l.strip_prefix("__spawn_error:") {
                    self.errors
                        .push(VErr::local(format!("cannot start engine: {e}")));
                } else if let Some(e) = l.strip_prefix("__stderr:") {
                    self.log.push(format!("engine: {e}"));
                    if self.log.len() > 64 {
                        self.log.remove(0);
                    }
                } else if let Ok(v) = serde_json::from_str::<Value>(&l) {
                    return self.update(Message::Engine(v));
                }
            }
            Message::Engine(v) => match v.get("ev").and_then(Value::as_str) {
                Some("hello") => {}
                Some("env") => {
                    self.log.push("env detected".into());
                    self.disks = v
                        .get("disks")
                        .and_then(Value::as_array)
                        .map(|a| {
                            a.iter()
                                .filter_map(|d| {
                                    Some((
                                        d.get("path").and_then(Value::as_str)?.to_string(),
                                        // prefer MiB — a sub-GiB disk
                                        // floors to "0 GiB" and reads
                                        // as broken
                                        d.get("size_mib").and_then(Value::as_u64).or_else(
                                            || {
                                                d.get("size_gib")
                                                    .and_then(Value::as_u64)
                                                    .map(|g| g * 1024)
                                            },
                                        )?,
                                    ))
                                })
                                .collect()
                        })
                        .unwrap_or_default();
                    send_op(json!({"op": "page"}));
                }
                Some("page") => {
                    self.phase = Phase::Wizard;
                    self.page_index = v
                        .get("index")
                        .and_then(Value::as_u64)
                        .map(|n| n as usize)
                        .unwrap_or(0);
                    self.page_of = v
                        .get("of")
                        .and_then(Value::as_u64)
                        .map(|n| n as usize)
                        .unwrap_or(0);
                    // clear leftover errors on real navigation only — a
                    // same-page resync (after a rejected `set`) must keep
                    // the error it was triggered to display
                    let changed = self.page.as_ref().and_then(|p| p.get("page")) != v.get("page");
                    if changed {
                        self.errors.clear();
                        self.errors_unscoped = false;
                    }
                    // disk.device isn't on the review page — remember the
                    // engine-side value so Install can confirm it later.
                    if let Some(dev) = v
                        .get("fields")
                        .and_then(Value::as_array)
                        .into_iter()
                        .flatten()
                        .find(|f| f.get("name").and_then(Value::as_str) == Some("disk.device"))
                        .and_then(|f| f.get("value").and_then(Value::as_str))
                    {
                        if self.disk_device != dev {
                            self.install_confirm.clear();
                        }
                        self.disk_device = dev.to_string();
                    }
                    // text-family fields with non-string values (ints,
                    // lists, records) would otherwise render blank — seed
                    // the input buffer with the serialized engine value.
                    let seeds: Vec<(String, String)> = v
                        .get("fields")
                        .and_then(Value::as_array)
                        .into_iter()
                        .flatten()
                        .filter_map(|f| {
                            let name = f.get("name").and_then(Value::as_str)?;
                            let t = f.get("type").and_then(Value::as_str).unwrap_or("");
                            if matches!(t, "enum" | "bool" | "secret") {
                                return None;
                            }
                            let val = f.get("value")?;
                            if val.is_null() {
                                return None;
                            }
                            let s = match val.as_str() {
                                Some(s) => s.to_string(),
                                None => serde_json::to_string(val).ok()?,
                            };
                            Some((name.to_string(), s))
                        })
                        .collect();
                    for (n, s) in seeds {
                        // keep an in-progress user edit over the re-emitted value
                        self.inputs.entry(n).or_insert(s);
                    }
                    // the page echo is authoritative for rendered fields —
                    // drop optimistic enum picks so engine-coerced values
                    // (e.g. libc=musl forcing init=openrc) can't show stale
                    for f in v
                        .get("fields")
                        .and_then(Value::as_array)
                        .into_iter()
                        .flatten()
                    {
                        if let Some(n) = f.get("name").and_then(Value::as_str) {
                            self.selected.remove(n);
                        }
                    }
                    // review's steps[] seeds the install timeline —
                    // upcoming stages are drawn 'todo' before any step
                    // event arrives
                    if let Some(steps) = v.get("steps").and_then(Value::as_array) {
                        self.steps = steps
                            .iter()
                            .map(|s| Step {
                                name: s
                                    .get("id")
                                    .and_then(Value::as_str)
                                    .unwrap_or("")
                                    .to_string(),
                                title: s
                                    .get("title")
                                    .and_then(Value::as_str)
                                    .unwrap_or("")
                                    .to_string(),
                                state: "todo".into(),
                            })
                            .collect();
                    }
                    self.nav = v
                        .get("nav")
                        .and_then(Value::as_array)
                        .map(|a| {
                            a.iter()
                                .map(|n| NavItem {
                                    id: n
                                        .get("id")
                                        .and_then(Value::as_str)
                                        .unwrap_or("")
                                        .to_string(),
                                    title: n
                                        .get("title")
                                        .and_then(Value::as_str)
                                        .unwrap_or("")
                                        .to_string(),
                                    section: n
                                        .get("section")
                                        .and_then(Value::as_str)
                                        .unwrap_or("")
                                        .to_string(),
                                    state: n
                                        .get("state")
                                        .and_then(Value::as_str)
                                        .unwrap_or("todo")
                                        .to_string(),
                                })
                                .collect()
                        })
                        .unwrap_or_default();
                    self.page = Some(v);
                }
                Some("validate") => {
                    let errs: Vec<VErr> = v
                        .get("errors")
                        .and_then(Value::as_array)
                        .map(|a| {
                            a.iter()
                                .filter_map(|e| {
                                    if let Some(s) = e.as_str() {
                                        return Some(VErr {
                                            message: s.to_string(),
                                            page: None,
                                            local: false,
                                        });
                                    }
                                    Some(VErr {
                                        message: e
                                            .get("message")
                                            .and_then(Value::as_str)?
                                            .to_string(),
                                        page: e
                                            .get("page")
                                            .and_then(Value::as_str)
                                            .map(String::from),
                                        local: false,
                                    })
                                })
                                .collect()
                        })
                        .unwrap_or_default();
                    // an install the engine's validation refuses arrives as
                    // `validate`+errors, not `error` — leave Pending or the
                    // UI would sit on 'Starting install…' forever; that gate
                    // applies to the whole config so all errors surface
                    // an install/plan refusal is a whole-config gate —
                    // the Pending phase covers install; plan/export go
                    // out req-tagged so this validate answers them
                    let gate_req = v
                        .get("req")
                        .and_then(Value::as_u64)
                        .map(|r| self.pending_gates.remove(&r))
                        .unwrap_or(false);
                    let gate =
                        (matches!(self.phase, Phase::Pending) || gate_req) && !errs.is_empty();
                    self.errors = if v.get("ok").and_then(Value::as_bool) == Some(true) {
                        Vec::new()
                    } else {
                        errs
                    };
                    self.errors_unscoped = gate;
                    if gate {
                        self.phase = Phase::Wizard;
                    }
                }
                // {"ev":"plan","cmds":[...]} — one generated command per entry
                Some("plan") => {
                    self.plan = v.get("cmds").and_then(Value::as_array).map(|a| {
                        a.iter()
                            .filter_map(|c| c.as_str())
                            .collect::<Vec<_>>()
                            .join("\n")
                    });
                }
                Some("step") => {
                    self.phase = Phase::Running;
                    let name = v
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    let state = v
                        .get("state")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    if let Some(s) = self.steps.iter_mut().find(|s| s.name == name) {
                        s.state = state;
                    } else {
                        self.steps.push(Step {
                            title: name.clone(),
                            name,
                            state,
                        });
                    }
                }
                Some("done") => {
                    self.phase = Phase::Done(
                        v.get("reboot_ready")
                            .and_then(Value::as_bool)
                            .unwrap_or(false),
                    );
                }
                Some("error") => {
                    // a rejected `set` leaves the old engine value — drop the
                    // unsent buffer and re-fetch the page so the field shows
                    // what the engine actually has, not the refused edit
                    if let Some(req) = v.get("req").and_then(Value::as_u64)
                        && let Some(field) = self.pending_sets.remove(&req)
                    {
                        // answer_file rejects on every incomplete path while
                        // typing — keep the text so the user can finish it
                        if field == "answer_file" {
                            // keep the path editable; if this was the latest
                            // attempt, resync so the page reflects the
                            // config the engine actually ended with
                            if Some(req) == self.last_answer_req {
                                self.last_answer_req = None;
                                send_op(json!({"op": "page"}));
                            }
                        } else {
                            self.inputs.remove(&field);
                            self.confirm_inputs.remove(&field);
                            send_op(json!({"op": "page"}));
                        }
                    }
                    self.errors.push(VErr {
                        message: v
                            .get("error")
                            .and_then(Value::as_str)
                            .unwrap_or("unknown")
                            .to_string(),
                        page: None,
                        local: true,
                    });
                    // doInstall reports failure via `error` and returns
                    // without a `done` — don't leave the UI on Installing…
                    if matches!(self.phase, Phase::Pending | Phase::Running) {
                        self.phase = Phase::Failed;
                    }
                }
                Some("result") => {
                    // accepted set — clear the correlation entry
                    if let Some(req) = v.get("req").and_then(Value::as_u64)
                        && let Some(field) = self.pending_sets.remove(&req)
                    {
                        // a confirmed answer-file load replaces the whole
                        // engine config and jumps to Review — finalize only
                        // when this reply is for the *latest* submitted path;
                        // a stale success while a newer attempt is pending
                        // must not navigate on an outdated load
                        if field == "answer_file" && Some(req) == self.last_answer_req {
                            self.last_answer_req = None;
                            self.inputs.clear();
                            self.confirm_inputs.clear();
                            self.selected.clear();
                            send_op(json!({"op": "page"}));
                            // the loaded config may target a different disk
                            // — refresh disk_device so the install confirm
                            // gate checks the imported target
                            send_op(json!({"op": "get_config"}));
                        }
                    }
                }
                Some("config") => {
                    // answer-file load refresh — adopt the imported target
                    // disk and force re-confirmation against it; an empty
                    // device still applies — it disables Install until the
                    // user picks a disk again
                    if let Some(dev) = v
                        .get("config")
                        .and_then(|c| c.get("disk"))
                        .and_then(|d| d.get("device"))
                        .and_then(Value::as_str)
                        && self.disk_device != dev
                    {
                        self.disk_device = dev.to_string();
                        self.install_confirm.clear();
                    }
                }
                Some("bye") => {}
                _ => {}
            },
            Message::ConfirmInput(name, val) => {
                self.confirm_inputs.insert(name, val);
            }
            Message::InstallConfirm(val) => {
                self.install_confirm = val;
            }
            Message::Input(name, val) => {
                let (ftype, _) = self.field_meta(&name);
                self.inputs.insert(name.clone(), val.clone());
                if name == "disk.device" {
                    self.disk_device = val.clone();
                    self.install_confirm.clear();
                }
                if ftype == "secret" || name == "answer_file" {
                    // buffered — secrets flush on the next action; the
                    // answer-file path flushes on Enter (Submit) so a
                    // half-typed path never loads an unintended file
                } else {
                    let tv = self.typed_value(&name, &val);
                    self.send_set(&name, tv);
                }
            }
            Message::Submit(name) => {
                // Enter in answer_file commits the buffered path
                self.flush_field(&name);
            }
            Message::Toggle(name, val) => {
                self.send_set(&name, json!(val));
                // `set` doesn't re-emit the page, but a toggle can change
                // conditional fields (e.g. luks reveals its passphrase)
                send_op(json!({"op": "page"}));
            }
            Message::Goto(page) => {
                send_op(json!({"op": "goto", "page": page}));
            }
            Message::Select(name, val) => {
                self.selected.insert(name.clone(), val.clone());
                if name == "disk.device" {
                    self.disk_device = val.clone();
                    self.install_confirm.clear();
                }
                self.send_set(&name, Value::String(val));
                send_op(json!({"op": "page"}));
            }
            Message::Op("export_answer") => {
                send_op(json!({"op": "export_answer", "path": "gentoo-installer-answers.toml"}))
            }
            Message::Op(op) => {
                if !self.flush_secrets() {
                    return Task::none();
                }
                send_op(json!({"op": op}));
            }
            Message::Plan => {
                if self.flush_secrets() {
                    // req-tagged: a refused plan comes back as
                    // `validate`+errors — the tag marks it a
                    // whole-config gate so its errors surface unscoped
                    self.req_seq += 1;
                    self.pending_gates.insert(self.req_seq);
                    send_op(json!({"op": "plan", "req": self.req_seq}));
                }
            }
            Message::Install => {
                if self.last_answer_req.is_some() {
                    self.errors.push(VErr::local(
                        "answer file is loading — wait for the Review refresh".into(),
                    ));
                    return Task::none();
                }
                if !self.flush_secrets() {
                    return Task::none();
                }
                // the engine's confirm gate expects the user to have typed
                // the target disk's basename — never derive it silently
                let dev = self.disk_device.clone();
                let confirm = dev.rsplit('/').next().unwrap_or(&dev).to_string();
                if self.install_confirm != confirm || confirm.is_empty() {
                    self.errors.push(VErr::local(format!(
                        "type '{confirm}' to confirm the install"
                    )));
                    return Task::none();
                }
                // reset the seeded timeline — step events light it up by id
                for s in &mut self.steps {
                    s.state = "todo".into();
                }
                // leave the wizard synchronously — the engine queues ops, so
                // a second click before the first `step` would run the whole
                // wipe again
                self.phase = Phase::Pending;
                send_op(json!({"op": "install", "dry_run": false, "confirm": confirm}));
            }
            Message::DryRun => {
                if self.last_answer_req.is_some() {
                    self.errors.push(VErr::local(
                        "answer file is loading — wait for the Review refresh".into(),
                    ));
                    return Task::none();
                }
                // dry-run needs no confirm token — the engine skips
                // destructive gates entirely and only exercises the plan
                if !self.flush_secrets() {
                    return Task::none();
                }
                for s in &mut self.steps {
                    s.state = "todo".into();
                }
                self.phase = Phase::Pending;
                send_op(json!({"op": "install", "dry_run": true}));
            }
        }
        Task::none()
    }

    fn view(&self) -> Element<'_, Self::Message> {
        match self.phase {
            Phase::Wizard => self.view_wizard(),
            _ => self.view_run(),
        }
    }
}

impl Installer {
    /// Left rail: section headers + one row per page (done/current are
    /// clickable — the engine's `goto` keeps flow order).
    fn rail(&self) -> Element<'_, Message> {
        let spacing = theme::spacing();
        let mut col = widget::column::with_capacity(self.nav.len() * 2)
            .spacing(spacing.space_xxs)
            .padding(spacing.space_m);
        let mut last_section = String::new();
        for n in &self.nav {
            if n.section != last_section {
                col = col.push(widget::text::caption(n.section.clone()).class(theme::Text::Accent));
                last_section = n.section.clone();
            }
            let glyph = match n.state.as_str() {
                "done" => "✓",
                "current" => "●",
                _ => "○",
            };
            let btn = widget::button::text(format!("{glyph}  {}", n.title))
                .width(Length::Fill)
                .class(if n.state == "current" {
                    theme::Button::Suggested
                } else {
                    theme::Button::Text
                });
            // only visited pages jump — a 'todo' hop would skip the
            // gate pages the linear flow is built around
            let btn = if n.state == "done" {
                btn.on_press(Message::Goto(n.id.clone()))
            } else {
                btn
            };
            col = col.push(btn);
        }
        // position footer — "N of M" under the rail so progress is
        // readable at a glance without scanning glyph states
        if self.page_of > 0 {
            col = col.push(widget::container(widget::text("")).height(Length::Fixed(12.0)));
            col = col.push(widget::divider::horizontal::light());
            col = col.push(widget::text::caption(format!(
                "page {} of {}",
                self.page_index, self.page_of
            )));
        }
        widget::container(col)
            .width(Length::Fixed(240.0))
            .height(Length::Fill)
            .class(theme::Container::Background)
            .into()
    }

    /// Install progress — step timeline + engine log tail + result.
    fn view_run(&self) -> Element<'_, Message> {
        let spacing = theme::spacing();
        let mut col = widget::column::with_capacity(8)
            .spacing(spacing.space_m)
            .padding(spacing.space_l);
        match self.phase {
            Phase::Boot => {
                col = col.push(widget::text::title2("Starting installer engine…"));
            }
            Phase::Dead => {
                col = col.push(widget::text::title2("Engine exited"));
            }
            _ => {
                let done_n = self
                    .steps
                    .iter()
                    .filter(|s| s.state == "done" || s.state == "skipped")
                    .count();
                let total = self.steps.len();
                let title = match self.phase {
                    Phase::Pending => "Starting install…".to_string(),
                    Phase::Running => format!("Installing… ({done_n}/{total})"),
                    Phase::Done(true) => "Install complete — safe to reboot".to_string(),
                    Phase::Done(false) => "Dry run complete".to_string(),
                    Phase::Failed => "Installation failed".to_string(),
                    _ => unreachable!(),
                };
                let title_el: Element<Message> = match self.phase {
                    Phase::Done(_) => widget::text::title2(title)
                        .class(theme::Text::Custom(|t| cosmic::iced::widget::text::Style {
                            color: Some(t.cosmic().success.base.into()),
                            ..Default::default()
                        }))
                        .into(),
                    Phase::Failed => widget::text::title2(title)
                        .class(theme::Text::Custom(|t| cosmic::iced::widget::text::Style {
                            color: Some(t.cosmic().destructive.base.into()),
                            ..Default::default()
                        }))
                        .into(),
                    _ => widget::text::title2(title).into(),
                };
                col = col.push(title_el);
                // progress bar — determinate once steps are known;
                // pending spins until the first step event lands
                if matches!(self.phase, Phase::Pending) {
                    col = col.push(
                        widget::progress_bar::indeterminate_linear()
                            .width(Length::Fill)
                            .girth(Length::Fixed(6.0)),
                    );
                } else if total > 0 {
                    col = col.push(
                        widget::progress_bar::determinate_linear(done_n as f32 / total as f32)
                            .width(Length::Fill)
                            .girth(Length::Fixed(6.0)),
                    );
                }
                // step timeline — a card per install stage, marked by state
                let mut steps_col =
                    widget::column::with_capacity(self.steps.len()).spacing(spacing.space_xxs);
                for s in &self.steps {
                    let (mark, done) = match s.state.as_str() {
                        "done" => ("✓", true),
                        "skipped" => ("—", false),
                        "failed" => ("✗", false),
                        _ => ("…", false),
                    };
                    let mut row = widget::row::with_capacity(2).spacing(spacing.space_s);
                    let mark_txt: Element<Message> = if done || s.state == "skipped" {
                        widget::text(mark)
                            .width(Length::Fixed(20.0))
                            .class(theme::Text::Custom(|t| cosmic::iced::widget::text::Style {
                                color: Some(t.cosmic().success.base.into()),
                                ..Default::default()
                            }))
                            .into()
                    } else if s.state == "failed" {
                        widget::text(mark)
                            .width(Length::Fixed(20.0))
                            .class(theme::Text::Custom(|t| cosmic::iced::widget::text::Style {
                                color: Some(t.cosmic().destructive.base.into()),
                                ..Default::default()
                            }))
                            .into()
                    } else {
                        widget::text(mark).width(Length::Fixed(20.0)).into()
                    };
                    row = row.push(mark_txt);
                    let shown = if s.title.is_empty() {
                        s.name.clone()
                    } else {
                        s.title.clone()
                    };
                    let name = widget::text(shown);
                    let name = if s.state == "started" {
                        name.class(theme::Text::Accent)
                    } else {
                        name
                    };
                    row = row.push(name);
                    steps_col = steps_col.push(row);
                }
                col = col.push(
                    widget::container(steps_col)
                        .padding(spacing.space_m)
                        .width(Length::Fill)
                        .class(theme::Container::Card),
                );
            }
        }
        if !self.errors.is_empty() {
            col = col.push(error_panel(self.errors.iter().map(|e| e.message.as_str())));
        }
        if let Some(plan) = &self.plan {
            col = col.push(plan_panel(plan));
        }
        widget::scrollable(col).into()
    }

    /// Wizard: rail + one-concept page (title, subtitle, fields/cards,
    /// actions) — the engine owns page order and validation.
    fn view_wizard(&self) -> Element<'_, Message> {
        let spacing = theme::spacing();
        let mut col = widget::column::with_capacity(8)
            .spacing(spacing.space_m)
            .padding(spacing.space_l);

        if let Some(p) = &self.page {
            let title = p.get("title").and_then(Value::as_str).unwrap_or("");
            let subtitle = p.get("subtitle").and_then(Value::as_str).unwrap_or("");
            col = col.push(widget::text::title2(title));
            if !subtitle.is_empty() {
                col = col.push(widget::text::caption(subtitle.to_string()));
            }
            col = col.push(widget::divider::horizontal::light());

            if let Some(fields) = p.get("fields").and_then(Value::as_array) {
                for f in fields {
                    col = col.push(field_widget(
                        f,
                        &self.inputs,
                        &self.confirm_inputs,
                        &self.selected,
                    ));
                }
            }
            if let Some(groups) = p.get("summary").and_then(Value::as_array) {
                for g in groups {
                    let gt = g
                        .get("title")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    let edit = g.get("edit").and_then(Value::as_str).unwrap_or("");
                    let mut head = widget::row::with_capacity(2).spacing(spacing.space_m);
                    head = head.push(widget::text::title4(gt));
                    if !edit.is_empty() {
                        head = head.push(
                            widget::button::text("Edit").on_press(Message::Goto(edit.to_string())),
                        );
                    }
                    let mut card = widget::column::with_capacity(4).spacing(spacing.space_xxs);
                    card = card.push(head);
                    for it in g
                        .get("lines")
                        .and_then(Value::as_array)
                        .cloned()
                        .unwrap_or_default()
                    {
                        card = card.push(widget::text(it.as_str().unwrap_or("").to_string()));
                    }
                    col = col.push(
                        widget::container(card)
                            .padding(spacing.space_m)
                            .width(Length::Fill)
                            .class(theme::Container::Card),
                    );
                }
            }
            let has_install = p
                .get("actions")
                .and_then(Value::as_array)
                .map(|a| a.iter().any(|x| x.as_str() == Some("install")))
                .unwrap_or(false);
            if has_install {
                // destructive gate: the engine wants the target disk's
                // basename typed — an emphasized warning panel, not a
                // bare input row.
                let base = self
                    .disk_device
                    .rsplit('/')
                    .next()
                    .unwrap_or(&self.disk_device)
                    .to_string();
                let dev = self.disk_device.clone();
                // the size says what is being erased — the bare path is
                // too easy to skim past
                let dev_shown = match self.disks.get(&dev) {
                    Some(&m) if m >= 1024 => format!("{dev} · {} GiB", m / 1024),
                    Some(&m) if m > 0 => format!("{dev} · {m} MiB"),
                    _ => dev.clone(),
                };
                let mut panel = widget::column::with_capacity(3).spacing(spacing.space_xs);
                panel = panel.push(
                    widget::text::title4(format!("Install onto {dev_shown}?")).class(
                        theme::Text::Custom(|t| cosmic::iced::widget::text::Style {
                            color: Some(t.cosmic().destructive.base.into()),
                            ..Default::default()
                        }),
                    ),
                );
                panel = panel.push(widget::text::body(
                    "All data on the disk will be erased.".to_string(),
                ));
                panel = panel.push(
                    widget::text_input(format!("type '{base}' to confirm"), &self.install_confirm)
                        .on_input(Message::InstallConfirm),
                );
                col = col.push(
                    widget::container(panel)
                        .padding(spacing.space_m)
                        .width(Length::Fill)
                        .class(theme::Container::Card),
                );
            }
            // actions
            let mut row = widget::row::with_capacity(4).spacing(spacing.space_s);
            for a in p
                .get("actions")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default()
            {
                let a = a.as_str().unwrap_or("");
                let btn = match a {
                    "next" => widget::button::suggested("Next").on_press(Message::Op("next")),
                    "back" => widget::button::standard("Back").on_press(Message::Op("back")),
                    "quit" => widget::button::destructive("Quit").on_press(Message::Op("quit")),
                    "plan" => widget::button::standard("Plan").on_press(Message::Plan),
                    "export_answer" => {
                        widget::button::standard("Export").on_press(Message::Op("export_answer"))
                    }
                    "install" => {
                        let dry = widget::button::standard("Dry run").on_press(Message::DryRun);
                        row = row.push(dry);
                        let base = self
                            .disk_device
                            .rsplit('/')
                            .next()
                            .unwrap_or(&self.disk_device);
                        // destructive styling only when armed — an
                        // unarmed red button reads as clickable while
                        // the gate silently eats the click
                        if !base.is_empty() && self.install_confirm == base {
                            widget::button::destructive("Install").on_press(Message::Install)
                        } else {
                            widget::button::standard("Install")
                        }
                    }
                    _ => continue,
                };
                row = row.push(btn);
            }
            col = col.push(row);
        }

        // only this page's errors surface — engine-attributed via
        // `page`, GUI-local always; the whole-config gate shows all
        let cur_id = self
            .page
            .as_ref()
            .and_then(|p| p.get("page"))
            .and_then(Value::as_str)
            .unwrap_or("");
        let page_errors: Vec<&str> = self
            .errors
            .iter()
            .filter(|e| self.errors_unscoped || e.local || e.page.as_deref() == Some(cur_id))
            .map(|e| e.message.as_str())
            .collect();
        if !page_errors.is_empty() {
            col = col.push(error_panel(page_errors.into_iter()));
        }
        if let Some(plan) = &self.plan {
            col = col.push(plan_panel(plan));
        }

        widget::row::with_capacity(3)
            .push(self.rail())
            .push(widget::divider::vertical::default())
            .push(widget::scrollable(col).height(Length::Fill))
            .height(Length::Fill)
            .into()
    }
}

fn error_text(e: String) -> Element<'static, Message> {
    widget::text::body(e)
        .class(theme::Text::Custom(|t| cosmic::iced::widget::text::Style {
            color: Some(t.cosmic().destructive.base.into()),
            ..Default::default()
        }))
        .into()
}

/// Grouped error list — a card-tinted block with a heading, so a gate
/// refusal reads as one coherent panel rather than stray red lines.
fn error_panel<'a>(errs: impl Iterator<Item = &'a str>) -> Element<'a, Message> {
    let spacing = theme::spacing();
    let msgs: Vec<String> = errs.map(str::to_string).collect();
    let mut col = widget::column::with_capacity(msgs.len() + 1).spacing(spacing.space_xxs);
    col = col.push(
        widget::text::title4("Problems").class(theme::Text::Custom(|t| {
            cosmic::iced::widget::text::Style {
                color: Some(t.cosmic().destructive.base.into()),
                ..Default::default()
            }
        })),
    );
    for m in msgs {
        col = col.push(error_text(format!("· {m}")));
    }
    widget::container(col)
        .padding(spacing.space_m)
        .width(Length::Fill)
        .class(theme::Container::Card)
        .into()
}

/// Plan commands inside a titled card — the scrollable gets a label so
/// it's clear these are the commands the install would run.
fn plan_panel(plan: &str) -> Element<'_, Message> {
    let spacing = theme::spacing();
    // "commands" = `     $` exec lines only — the stream also carries
    // step headings, notes and write_file lines
    let n = plan.lines().filter(|l| l.starts_with("     $")).count();
    let mut col = widget::column::with_capacity(2).spacing(spacing.space_xs);
    col = col.push(widget::text::title4(format!("Install plan — {n} commands")));
    col = col.push(
        widget::scrollable(widget::text(plan.to_string()).size(11)).height(Length::Fixed(240.0)),
    );
    widget::container(col)
        .padding(spacing.space_m)
        .width(Length::Fill)
        .class(theme::Container::Card)
        .into()
}

fn field_widget<'a>(
    f: &'a Value,
    inputs: &'a HashMap<String, String>,
    confirm_inputs: &'a HashMap<String, String>,
    selected: &'a HashMap<String, String>,
) -> Element<'a, Message> {
    let spacing = theme::spacing();
    let name: &str = f.get("name").and_then(Value::as_str).unwrap_or("");
    let label: &str = f.get("label").and_then(Value::as_str).unwrap_or(name);
    let ftype = f.get("type").and_then(Value::as_str).unwrap_or("string");
    let value = f.get("value").unwrap_or(&Value::Null);

    let mut col = widget::column::with_capacity(4).spacing(spacing.space_xxs);
    col = col.push(widget::text(label.to_string()));
    if let Some(h) = f.get("help").and_then(Value::as_str) {
        col = col.push(widget::text::caption(h));
    }

    let control: Element<Message> = match ftype {
        "enum" => {
            let opts: &[Value] = f
                .get("options")
                .and_then(Value::as_array)
                .map(Vec::as_slice)
                .unwrap_or(&[]);
            // local selection wins over the page snapshot so the radio
            // updates instantly; the next `page` event re-syncs `value`.
            let cur = selected
                .get(name)
                .map(String::as_str)
                .or_else(|| value.as_str());
            let cur_idx = opts
                .iter()
                .position(|o| o.get("v").and_then(Value::as_str) == cur)
                .unwrap_or(usize::MAX);
            let mut rc = widget::column::with_capacity(4).spacing(spacing.space_xxs);
            for (i, o) in opts.iter().enumerate() {
                let v: &str = o.get("v").and_then(Value::as_str).unwrap_or("");
                let l: &str = o.get("label").and_then(Value::as_str).unwrap_or(v);
                rc = rc.push(widget::radio(
                    widget::text(l.to_string()),
                    i,
                    Some(cur_idx),
                    {
                        let (n, v) = (name.to_string(), v.to_string());
                        move |_| Message::Select(n.clone(), v.clone())
                    },
                ));
            }
            rc.into()
        }
        "bool" => widget::toggler(value.as_bool().unwrap_or(false))
            .on_toggle({
                let n = name.to_string();
                move |v| Message::Toggle(n.clone(), v)
            })
            .into(),
        "secret" => {
            let cur: &str = inputs.get(name).map(String::as_str).unwrap_or("");
            let mut sc = widget::column::with_capacity(4).spacing(spacing.space_xxs);
            sc = sc.push(widget::secure_input(label, cur, None, true).on_input({
                let n = name.to_string();
                move |v| Message::Input(n.clone(), v)
            }));
            // confirm:true secrets ask twice; compared on the next action
            if f.get("confirm").and_then(Value::as_bool).unwrap_or(false) {
                let cur2: &str = confirm_inputs.get(name).map(String::as_str).unwrap_or("");
                sc = sc.push(
                    widget::secure_input("again to confirm", cur2, None, true).on_input({
                        let n = name.to_string();
                        move |v| Message::ConfirmInput(n.clone(), v)
                    }),
                );
            }
            sc.into()
        }
        _ => {
            let cur: &str = inputs
                .get(name)
                .map(String::as_str)
                .or_else(|| value.as_str())
                .unwrap_or("");
            let ti = widget::text_input(label, cur).on_input({
                let n = name.to_string();
                move |v| Message::Input(n.clone(), v)
            });
            let ti = if name == "answer_file" {
                // Enter commits the buffered path to the engine
                ti.on_submit({
                    let n = name.to_string();
                    move |_| Message::Submit(n.clone())
                })
            } else {
                ti
            };
            ti.into()
        }
    };
    col.push(control).into()
}
