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
                .stderr(Stdio::null())
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
    Toggle(String, bool),
    Select(String, String),
    Op(&'static str),
    Install,
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
    Running, // step events during install
    Done(bool),
    Dead, // engine stdout closed
}

struct Installer {
    core: cosmic::Core,
    phase: Phase,
    page: Option<Value>,
    inputs: HashMap<String, String>,   // text/secret/confirm buffers
    selected: HashMap<String, String>, // enum selections
    steps: Vec<Step>,
    plan: Option<String>,
    errors: Vec<String>,
    log: Vec<String>,
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
            selected: HashMap::new(),
            steps: Vec::new(),
            plan: None,
            errors: Vec::new(),
            log: vec![format!("spawn {}", engine_binary())],
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
                    self.errors.clear();
                    self.page = Some(v);
                }
                Some("validate") => {
                    self.errors = v
                        .get("errors")
                        .and_then(Value::as_array)
                        .map(|a| {
                            a.iter()
                                .filter_map(|e| e.as_str().map(String::from))
                                .collect()
                        })
                        .unwrap_or_default();
                    if v.get("ok").and_then(Value::as_bool) == Some(true) {
                        self.errors.clear();
                    }
                }
                Some("plan") => {
                    self.plan = v
                        .get("plan")
                        .map(|p| serde_json::to_string_pretty(p).unwrap_or_default());
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
                    self.errors.push(
                        v.get("error")
                            .and_then(Value::as_str)
                            .unwrap_or("unknown")
                            .to_string(),
                    );
                }
                Some("result") | Some("bye") => {}
                _ => {}
            },
            Message::Input(name, val) => {
                self.inputs.insert(name.clone(), val.clone());
                // secrets wait for confirm; non-secrets send immediately
                send_op(json!({"op": "set", "field": name, "value": val}));
            }
            Message::Toggle(name, val) => {
                send_op(json!({"op": "set", "field": name, "value": val}));
            }
            Message::Select(name, val) => {
                self.selected.insert(name.clone(), val.clone());
                send_op(json!({"op": "set", "field": name, "value": val}));
            }
            Message::Op("export_answer") => {
                send_op(json!({"op": "export_answer", "path": "gentoo-installer-answers.toml"}))
            }
            Message::Op(op) => send_op(json!({"op": op})),
            Message::Plan => send_op(json!({"op": "plan"})),
            Message::Install => {
                // confirm token is the basename of disk.device
                let dev = self
                    .page
                    .as_ref()
                    .and_then(|p| p.get("fields"))
                    .and_then(|f| f.as_array())
                    .map(|a| {
                        a.iter()
                            .find(|f| f.get("name").and_then(Value::as_str) == Some("disk.device"))
                            .and_then(|f| f.get("value").and_then(Value::as_str))
                            .unwrap_or("")
                    })
                    .unwrap_or("")
                    .to_string();
                let confirm = dev.rsplit('/').next().unwrap_or(&dev).to_string();
                self.steps.clear();
                send_op(json!({"op": "install", "dry_run": false, "confirm": confirm}));
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
            Phase::Running | Phase::Done(_) => {
                col = col.push(widget::text::title2(match self.phase {
                    Phase::Running => "Installing…",
                    Phase::Done(true) => "Install complete — safe to reboot",
                    Phase::Done(false) => "Dry run complete",
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
                            col = col.push(field_widget(f, &self.inputs, &self.selected));
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
                    // actions
                    let mut row = widget::row::with_capacity(4).spacing(spacing.space_s);
                    for a in p
                        .get("actions")
                        .and_then(Value::as_array)
                        .cloned()
                        .unwrap_or_default()
                    {
                        let a = a.as_str().unwrap_or("");
                        let btn =
                            match a {
                                "next" => {
                                    widget::button::suggested("Next").on_press(Message::Op("next"))
                                }
                                "back" => {
                                    widget::button::standard("Back").on_press(Message::Op("back"))
                                }
                                "quit" => widget::button::destructive("Quit")
                                    .on_press(Message::Op("quit")),
                                "plan" => widget::button::standard("Plan").on_press(Message::Plan),
                                "export_answer" => widget::button::standard("Export")
                                    .on_press(Message::Op("export_answer")),
                                "install" => widget::button::destructive("Install")
                                    .on_press(Message::Install),
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
            widget::secure_input(label, cur, None, true)
                .on_input({
                    let n = name.to_string();
                    move |v| Message::Input(n.clone(), v)
                })
                .into()
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
