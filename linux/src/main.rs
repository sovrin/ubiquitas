//! ubiquitas client: replays input from the server and shows the shared arrangement, text and file sending.
mod capture;
mod net;
mod sink;

use gtk::{gdk, gio, glib, prelude::*};
use net::{Control, Screen, SharedTx, ToUi};
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
    sync::{Arc, Mutex},
};

struct State {
    me: String,
    screens: Vec<Screen>,
    drag: Option<(usize, f64, f64)>, // screen index, offset in widget pixels
    fit: (f64, f64, f64),           // scale, x offset, y offset of the last drawing
}

fn parse_key(hex: &str) -> Option<[u8; 32]> {
    let hex = hex.trim();
    let mut key = [0u8; 32];
    if hex.len() != 64 || !hex.is_ascii() {
        return None;
    }
    for (i, b) in key.iter_mut().enumerate() {
        *b = u8::from_str_radix(&hex[2 * i..2 * i + 2], 16).ok()?;
    }
    Some(key)
}

fn main() -> glib::ExitCode {
    let Some(host) = std::env::args().nth(1) else {
        eprintln!("usage: UBIQUITAS_KEY=<hex key> ubiquitas <server-host>");
        return glib::ExitCode::FAILURE;
    };
    let Some(psk) = std::env::var("UBIQUITAS_KEY").ok().and_then(|k| parse_key(&k)) else {
        eprintln!("UBIQUITAS_KEY must be the 64-character hex key shown in the Mac app under \"Connect a client\"");
        return glib::ExitCode::FAILURE;
    };
    let app = gtk::Application::builder()
        .application_id("io.github.ubiquitas")
        .flags(gio::ApplicationFlags::NON_UNIQUE)
        .build();
    app.connect_activate(move |app| build(app, host.clone(), psk));
    app.run_with_args::<&str>(&[]) // our own arguments aren't GTK's
}

/// Logical size of the whole desktop (bounding box of all monitors).
fn desktop_size() -> (i32, i32) {
    let Some(display) = gdk::Display::default() else { return (1920, 1080) };
    let monitors = display.monitors();
    let rects: Vec<gdk::Rectangle> =
        (0..monitors.n_items()).filter_map(|i| monitors.item(i).and_downcast::<gdk::Monitor>()).map(|m| m.geometry()).collect();
    if rects.is_empty() {
        return (1920, 1080);
    }
    let x0 = rects.iter().map(|r| r.x()).min().unwrap();
    let y0 = rects.iter().map(|r| r.y()).min().unwrap();
    let x1 = rects.iter().map(|r| r.x() + r.width()).max().unwrap();
    let y1 = rects.iter().map(|r| r.y() + r.height()).max().unwrap();
    (x1 - x0, y1 - y0)
}

/// Scale and offset that fit all screens into a w×h area.
fn fit(screens: &[Screen], w: f64, h: f64) -> (f64, f64, f64) {
    if screens.is_empty() {
        return (1.0, 0.0, 0.0);
    }
    let x0 = screens.iter().map(|s| s.x).min().unwrap() as f64;
    let y0 = screens.iter().map(|s| s.y).min().unwrap() as f64;
    let x1 = screens.iter().map(|s| s.x + s.w).max().unwrap() as f64;
    let y1 = screens.iter().map(|s| s.y + s.h).max().unwrap() as f64;
    let s = (w / (x1 - x0)).min(h / (y1 - y0)) * 0.85;
    (s, (w - (x1 - x0) * s) / 2.0 - x0 * s, (h - (y1 - y0) * s) / 2.0 - y0 * s)
}

fn hit(st: &State, px: f64, py: f64) -> Option<usize> {
    let (s, ox, oy) = st.fit;
    st.screens.iter().position(|sc| {
        let (x, y) = (ox + sc.x as f64 * s, oy + sc.y as f64 * s);
        px >= x && px < x + sc.w as f64 * s && py >= y && py < y + sc.h as f64 * s
    })
}

fn build(app: &gtk::Application, host: String, psk: [u8; 32]) {
    let (w, h) = desktop_size();
    let me = std::env::var("UBIQUITAS_NAME").unwrap_or_else(|_| glib::host_name().to_string());
    let state = Rc::new(RefCell::new(State { me: me.clone(), screens: vec![], drag: None, fit: (1.0, 0.0, 0.0) }));
    let tx: SharedTx = Arc::new(Mutex::new(None));
    let (ui_tx, ui_rx) = async_channel::unbounded();
    {
        let (tx, ui_tx) = (tx.clone(), ui_tx.clone());
        let (capture, capture_rx) = async_channel::unbounded();
        capture::spawn(me.clone(), tx.clone(), capture_rx, ui_tx.clone());
        let cfg = net::Config { host, psk, name: me.clone(), w, h, capture };
        std::thread::spawn(move || net::run(cfg, tx, ui_tx));
    }

    // arrangement
    let area = gtk::DrawingArea::builder().content_height(220).vexpand(true).build();
    area.set_draw_func({
        let state = state.clone();
        move |a, cr, w, h| {
            let mut st = state.borrow_mut();
            st.fit = fit(&st.screens, w as f64, h as f64);
            let (s, ox, oy) = st.fit;
            let fg = a.color();
            for (i, sc) in st.screens.iter().enumerate() {
                let (dx, dy) = match st.drag {
                    Some((j, dx, dy)) if j == i => (dx, dy),
                    _ => (0.0, 0.0),
                };
                let (x, y) = (ox + sc.x as f64 * s + dx, oy + sc.y as f64 * s + dy);
                cr.rectangle(x, y, sc.w as f64 * s, sc.h as f64 * s);
                if sc.online { cr.set_source_rgba(0.21, 0.52, 0.89, 0.25) } else { cr.set_source_rgba(0.5, 0.5, 0.5, 0.15) }
                let _ = cr.fill_preserve();
                cr.set_source_rgba(fg.red() as f64, fg.green() as f64, fg.blue() as f64, 0.8);
                cr.set_line_width(if sc.name == st.me { 3.0 } else { 1.0 });
                let _ = cr.stroke();
                cr.move_to(x + 6.0, y + 16.0);
                let label = if sc.online { sc.name.clone() } else { format!("{} (offline)", sc.name) };
                let _ = cr.show_text(&label);
            }
        }
    });

    let drag = gtk::GestureDrag::new();
    drag.connect_drag_begin({
        let state = state.clone();
        move |_, x, y| {
            let mut st = state.borrow_mut();
            st.drag = hit(&st, x, y).map(|i| (i, 0.0, 0.0));
        }
    });
    drag.connect_drag_update({
        let (state, area) = (state.clone(), area.clone());
        move |_, dx, dy| {
            if let Some(d) = state.borrow_mut().drag.as_mut() {
                (d.1, d.2) = (dx, dy);
            }
            area.queue_draw();
        }
    });
    drag.connect_drag_end({
        let (state, area, tx) = (state.clone(), area.clone(), tx.clone());
        move |_, dx, dy| {
            let mut st = state.borrow_mut();
            if let Some((i, ..)) = st.drag.take() {
                // the server snaps the screen against its neighbours and sends the result to everyone
                let mut screens = st.screens.clone();
                screens[i].x += (dx / st.fit.0).round() as i32;
                screens[i].y += (dy / st.fit.0).round() as i32;
                let _ = net::send(&tx, &net::control(&Control { t: "layout".into(), screens: Some(screens), ..Default::default() }));
            }
            area.queue_draw();
        }
    });
    area.add_controller(drag);

    let drop = gtk::DropTarget::new(gdk::FileList::static_type(), gdk::DragAction::COPY);
    drop.connect_drop({
        let (state, tx, ui_tx) = (state.clone(), tx.clone(), ui_tx.clone());
        move |_, value, x, y| {
            let st = state.borrow();
            let Some(sc) = hit(&st, x, y).map(|i| st.screens[i].clone()) else { return false };
            let Ok(files) = value.get::<gdk::FileList>() else { return false };
            if !sc.online || sc.name == st.me {
                return false;
            }
            for path in files.files().iter().filter_map(|f| f.path()) {
                net::send_file(tx.clone(), path, sc.name.clone(), ui_tx.clone());
            }
            true
        }
    });
    area.add_controller(drop);

    // file sending without drag and drop
    let targets = gtk::StringList::new(&[]);
    let target = gtk::DropDown::builder().model(&targets).tooltip_text("Screen to send a file to").build();
    let send_button = gtk::Button::with_label("Send file…");
    send_button.connect_clicked({
        let (target, tx, ui_tx) = (target.clone(), tx.clone(), ui_tx.clone());
        move |button| {
            let Some(to) = target.selected_item().and_downcast::<gtk::StringObject>().map(|s| s.string().to_string()) else { return };
            let (tx, ui_tx) = (tx.clone(), ui_tx.clone());
            let window = button.root().and_downcast::<gtk::Window>();
            gtk::FileDialog::new().open(window.as_ref(), gio::Cancellable::NONE, move |res| {
                if let Some(path) = res.ok().and_then(|f| f.path()) {
                    net::send_file(tx, path, to, ui_tx);
                }
            });
        }
    });

    // shared text
    let text = gtk::TextView::builder().monospace(true).wrap_mode(gtk::WrapMode::WordChar).build();
    text.update_property(&[gtk::accessible::Property::Label("Shared text, editable on every computer")]);
    let applying_remote = Rc::new(Cell::new(false));
    text.buffer().connect_changed({
        let (tx, applying_remote) = (tx.clone(), applying_remote.clone());
        move |b| {
            if applying_remote.get() {
                return;
            }
            let t = b.text(&b.start_iter(), &b.end_iter(), false).to_string();
            let _ = net::send(&tx, &net::control(&Control { t: "clip".into(), text: Some(t), ..Default::default() }));
        }
    });

    let status = gtk::Label::builder().label("connecting…").xalign(0.0).wrap(true).build();

    let heading = |s: &str| gtk::Label::builder().label(s).xalign(0.0).css_classes(["heading"]).build();
    let hint = gtk::Label::builder()
        .label("Drag screens to arrange them. Drop a file on a screen to send it there.")
        .xalign(0.0)
        .css_classes(["dim-label"])
        .build();
    let file_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    file_row.append(&heading("Shared text"));
    file_row.append(&gtk::Box::builder().hexpand(true).build());
    file_row.append(&target);
    file_row.append(&send_button);

    let root = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(8)
        .margin_top(12)
        .margin_bottom(12)
        .margin_start(12)
        .margin_end(12)
        .build();
    root.append(&heading("Arrangement"));
    root.append(&hint);
    root.append(&area);
    root.append(&file_row);
    root.append(&gtk::ScrolledWindow::builder().child(&text).min_content_height(150).vexpand(true).has_frame(true).build());
    root.append(&status);

    gtk::ApplicationWindow::builder().application(app).title("ubiquitas").default_width(560).default_height(600).child(&root).build().present();

    // messages from the network thread
    let buffer = text.buffer();
    glib::spawn_future_local(async move {
        while let Ok(m) = ui_rx.recv().await {
            match m {
                ToUi::Status(s) => status.set_text(&s),
                ToUi::Layout(screens) => {
                    let others: Vec<&str> = screens.iter().filter(|s| s.online && s.name != me).map(|s| s.name.as_str()).collect();
                    targets.splice(0, targets.n_items(), &others);
                    send_button.set_sensitive(!others.is_empty());
                    state.borrow_mut().screens = screens;
                    area.queue_draw();
                }
                ToUi::Clip(t) => {
                    if buffer.text(&buffer.start_iter(), &buffer.end_iter(), false) != t {
                        applying_remote.set(true);
                        buffer.set_text(&t);
                        applying_remote.set(false);
                    }
                }
            }
        }
    });
}
