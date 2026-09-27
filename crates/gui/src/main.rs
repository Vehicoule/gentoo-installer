//! gentoo-installer GUI — libcosmic frontend over the headless NDJSON
//! protocol (docs/protocol.md). The Zig engine is spawned as a subprocess;
//! ops go to its stdin, events arrive on stdout.

use std::collections::HashMap;
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
}

struct Step {
    name: String,
    state: String,
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
    plan: Option<String>,
    errors: Vec<String>,
    log: Vec<String>,
    req_seq: u64,                       // monotonic request ids for set correlation
    pending_sets: HashMap<u64, String>, // req -> field; rejected sets restore engine truth
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
        send_op(json!({"op": "set", "req": self.req_seq, "field": field, "value": value}));
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
                    self.errors
                        .push(format!("confirmation does not match for {name}"));
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
            plan: None,
            errors: Vec::new(),
            log: vec![format!("spawn {}", engine_binary())],
            req_seq: 0,
            pending_sets: HashMap::new(),
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
                    self.errors.push(format!("cannot start engine: {e}"));
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
                    send_op(json!({"op": "page"}));
                }
                Some("page") => {
                    self.phase = Phase::Wizard;
                    // clear leftover errors on real navigation only — a
                    // same-page resync (after a rejected `set`) must keep
                    // the error it was triggered to display
                    let changed = self.page.as_ref().and_then(|p| p.get("page")) != v.get("page");
                    if changed {
                        self.errors.clear();
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
                    self.page = Some(v);
                }
                Some("validate") => {
                    self.errors = v
                        .get("errors")
                        .and_then(Value::as_array)
                        .map(|a| {
                            a.iter()
                                .filter_map(|e| {
                                    e.as_str()
                                        .or_else(|| e.get("message").and_then(Value::as_str))
                                        .map(String::from)
                                })
                                .collect()
                        })
                        .unwrap_or_default();
                    if v.get("ok").and_then(Value::as_bool) == Some(true) {
                        self.errors.clear();
                    }
                    // an install the engine's validation refuses arrives as
                    // `validate`+errors, not `error` — leave Pending or the
                    // UI would sit on 'Starting install…' forever
                    if matches!(self.phase, Phase::Pending) && !self.errors.is_empty() {
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
                        self.steps.push(Step { name, state });
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
                        self.inputs.remove(&field);
                        self.confirm_inputs.remove(&field);
                        send_op(json!({"op": "page"}));
                    }
                    self.errors.push(
                        v.get("error")
                            .and_then(Value::as_str)
                            .unwrap_or("unknown")
                            .to_string(),
                    );
                    // doInstall reports failure via `error` and returns
                    // without a `done` — don't leave the UI on Installing…
                    if matches!(self.phase, Phase::Pending | Phase::Running) {
                        self.phase = Phase::Failed;
                    }
                }
                Some("result") => {
                    // accepted set — clear the correlation entry
                    if let Some(req) = v.get("req").and_then(Value::as_u64) {
                        self.pending_sets.remove(&req);
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
                if ftype == "secret" {
                    // buffered — flush_secrets sends it on the next action
                } else {
                    let tv = self.typed_value(&name, &val);
                    self.send_set(&name, tv);
                    // a successful answer-file load replaces the whole engine
                    // config and jumps to Review — every local buffer is now
                    // stale, so clear before the re-fetch re-seeds
                    if name == "answer_file" {
                        self.inputs.clear();
                        self.confirm_inputs.clear();
                        self.selected.clear();
                        send_op(json!({"op": "page"}));
                    }
                }
            }
            Message::Toggle(name, val) => {
                self.send_set(&name, json!(val));
                // `set` doesn't re-emit the page, but a toggle can change
                // conditional fields (e.g. luks reveals its passphrase)
                send_op(json!({"op": "page"}));
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
                    send_op(json!({"op": "plan"}));
                }
            }
            Message::Install => {
                if !self.flush_secrets() {
                    return Task::none();
                }
                // the engine's confirm gate expects the user to have typed
                // the target disk's basename — never derive it silently
                let dev = self.disk_device.clone();
                let confirm = dev.rsplit('/').next().unwrap_or(&dev).to_string();
                if self.install_confirm != confirm || confirm.is_empty() {
                    self.errors
                        .push(format!("type '{confirm}' to confirm the install"));
                    return Task::none();
                }
                self.steps.clear();
                // leave the wizard synchronously — the engine queues ops, so
                // a second click before the first `step` would run the whole
                // wipe again
                self.phase = Phase::Pending;
                send_op(json!({"op": "install", "dry_run": false, "confirm": confirm}));
            }
            Message::DryRun => {
                // dry-run needs no confirm token — the engine skips
                // destructive gates entirely and only exercises the plan
                if !self.flush_secrets() {
                    return Task::none();
                }
                self.steps.clear();
                self.phase = Phase::Pending;
                send_op(json!({"op": "install", "dry_run": true}));
            }
        }
        Task::none()
    }

    fn view(&self) -> Element<'_, Self::Message> {
        let spacing = theme::spacing();
        let mut col = widget::column::with_capacity(4)
            .spacing(spacing.space_m)
            .padding(spacing.space_l);

        match self.phase {
            Phase::Boot => {
                col = col.push(widget::text::title2("Starting installer engine…"));
            }
            Phase::Dead => {
                col = col.push(widget::text::title2("Engine exited"));
            }
            Phase::Pending | Phase::Running | Phase::Done(_) | Phase::Failed => {
                col = col.push(widget::text::title2(match self.phase {
                    Phase::Pending => "Starting install…",
                    Phase::Running => "Installing…",
                    Phase::Done(true) => "Install complete — safe to reboot",
                    Phase::Done(false) => "Dry run complete",
                    Phase::Failed => "Installation failed",
                    _ => unreachable!(),
                }));
                for s in &self.steps {
                    let mark = match s.state.as_str() {
                        "done" => "✓",
                        "skipped" => "-",
                        "failed" => "✗",
                        _ => "…",
                    };
                    col = col.push(widget::text(format!("{mark} {}", s.name)));
                }
            }
            Phase::Wizard => {
                if let Some(p) = &self.page {
                    let title = p.get("title").and_then(Value::as_str).unwrap_or("");
                    let idx = p.get("index").and_then(Value::as_u64).unwrap_or(0);
                    let of = p.get("of").and_then(Value::as_u64).unwrap_or(0);
                    col = col.push(widget::text(format!("Step {idx} of {of}")));
                    col = col.push(widget::text::title2(title));
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
                            let gt = g.get("title").and_then(Value::as_str).unwrap_or("");
                            col = col.push(widget::text::title4(gt));
                            for it in g
                                .get("lines")
                                .and_then(Value::as_array)
                                .cloned()
                                .unwrap_or_default()
                            {
                                col = col.push(widget::text(it.as_str().unwrap_or("").to_string()));
                            }
                        }
                    }
                    let has_install = p
                        .get("actions")
                        .and_then(Value::as_array)
                        .map(|a| a.iter().any(|x| x.as_str() == Some("install")))
                        .unwrap_or(false);
                    if has_install {
                        // destructive gate: the engine wants the target disk's
                        // basename; make the user type it instead of
                        // auto-filling the confirm token.
                        let base = self
                            .disk_device
                            .rsplit('/')
                            .next()
                            .unwrap_or(&self.disk_device)
                            .to_string();
                        col = col.push(
                            widget::text_input(
                                format!("type '{base}' to confirm install"),
                                &self.install_confirm,
                            )
                            .on_input(Message::InstallConfirm),
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
                            "next" => {
                                widget::button::suggested("Next").on_press(Message::Op("next"))
                            }
                            "back" => {
                                widget::button::standard("Back").on_press(Message::Op("back"))
                            }
                            "quit" => {
                                widget::button::destructive("Quit").on_press(Message::Op("quit"))
                            }
                            "plan" => widget::button::standard("Plan").on_press(Message::Plan),
                            "export_answer" => widget::button::standard("Export")
                                .on_press(Message::Op("export_answer")),
                            "install" => {
                                let dry =
                                    widget::button::standard("Dry run").on_press(Message::DryRun);
                                row = row.push(dry);
                                let b = widget::button::destructive("Install");
                                let base = self
                                    .disk_device
                                    .rsplit('/')
                                    .next()
                                    .unwrap_or(&self.disk_device);
                                if !base.is_empty() && self.install_confirm == base {
                                    b.on_press(Message::Install)
                                } else {
                                    b
                                }
                            }
                            _ => continue,
                        };
                        row = row.push(btn);
                    }
                    col = col.push(row);
                }
            }
        }

        for e in &self.errors {
            col = col.push(widget::text::body(e).class(theme::Text::Custom(|t| {
                cosmic::iced::widget::text::Style {
                    color: Some(t.cosmic().destructive.base.into()),
                    ..Default::default()
                }
            })));
        }
        if let Some(plan) = &self.plan {
            col = col
                .push(widget::scrollable(widget::text(plan).size(11)).height(Length::Fixed(240.0)));
        }
        widget::scrollable(col).into()
    }
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
            widget::text_input(label, cur)
                .on_input({
                    let n = name.to_string();
                    move |v| Message::Input(n.clone(), v)
                })
                .into()
        }
    };
    col.push(control).into()
}
