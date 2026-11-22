//! Screen-edge handover from this machine: through the InputCapture portal (KDE Plasma 6.1+, GNOME 45+) we put
//! barriers on the edges that touch a neighbour. Pushing the cursor through one makes the compositor hand us
//! keyboard and mouse, which we forward to the server until it tells us to release them.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))] // the portal only exists on Linux
use crate::net::Screen;

/// x, y, width, height
pub type Rect = (i32, i32, i32, i32);

/// Barriers (x1, y1, x2, y2, inclusive) on my edges where an online neighbour touches, in zone coordinates.
/// `zone` is the compositor's desktop; my screen in the layout is the same desktop in logical pixels.
pub fn barriers(me: &str, layout: &[Screen], zone: Rect) -> Vec<(i32, i32, i32, i32)> {
    let Some(m) = layout.iter().find(|s| s.name == me) else { return vec![] };
    let (zx, zy, zw, zh) = zone;
    let sx = |v: i32| zx + (v as i64 * zw as i64 / m.w.max(1) as i64) as i32;
    let sy = |v: i32| zy + (v as i64 * zh as i64 / m.h.max(1) as i64) as i32;
    let mut out = vec![];
    for o in layout.iter().filter(|o| o.online && o.name != me) {
        let (x0, x1) = (o.x.max(m.x) - m.x, (o.x + o.w).min(m.x + m.w) - m.x);
        let (y0, y1) = (o.y.max(m.y) - m.y, (o.y + o.h).min(m.y + m.h) - m.y);
        if y1 > y0 && o.x + o.w == m.x {
            out.push((zx, sy(y0), zx, sy(y1) - 1));
        }
        if y1 > y0 && o.x == m.x + m.w {
            out.push((zx + zw, sy(y0), zx + zw, sy(y1) - 1));
        }
        if x1 > x0 && o.y + o.h == m.y {
            out.push((sx(x0), zy, sx(x1) - 1, zy));
        }
        if x1 > x0 && o.y == m.y + m.h {
            out.push((sx(x0), zy + zh, sx(x1) - 1, zy + zh));
        }
    }
    out
}

#[cfg(not(target_os = "linux"))]
pub fn spawn(
    _me: String,
    _tx: crate::net::SharedTx,
    _rx: async_channel::Receiver<crate::net::ToCapture>,
    _ui: async_channel::Sender<crate::net::ToUi>,
) {
}

#[cfg(target_os = "linux")]
pub use imp::spawn;

#[cfg(target_os = "linux")]
mod imp {
    use super::{Rect, barriers};
    use crate::net::{self, Control, Screen, SharedTx, ToCapture, ToUi};
    use ashpd::desktop::{
        Session,
        input_capture::{Barrier, BarrierID, Capabilities, CreateSessionOptions, InputCapture, ReleaseOptions},
    };
    use futures_util::StreamExt;
    use reis::{
        ei,
        event::{DeviceCapability, EiEvent},
    };
    use std::{error::Error, os::unix::net::UnixStream};

    pub fn spawn(me: String, tx: SharedTx, rx: async_channel::Receiver<ToCapture>, ui: async_channel::Sender<ToUi>) {
        std::thread::spawn(move || {
            let result = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .map_err(Into::into)
                .and_then(|rt| rt.block_on(run(&me, &tx, rx)));
            if let Err(e) = result {
                let _ = ui.send_blocking(ToUi::Status(format!(
                    "this machine's keyboard and mouse can't move to other screens (needs KDE Plasma 6.1+ or GNOME 45+): {e}"
                )));
            }
        });
    }

    fn msg_motion(dx: f32, dy: f32) -> Vec<u8> {
        [&[6u8][..], &dx.to_be_bytes(), &dy.to_be_bytes()].concat()
    }
    fn msg_key(code: u32, down: bool) -> Vec<u8> {
        [&[3u8][..], &(code as u16).to_be_bytes(), &[down as u8]].concat()
    }
    fn msg_scroll(dx: i32, dy: i32) -> Vec<u8> {
        [&[2u8][..], &(dx as i16).to_be_bytes(), &(dy as i16).to_be_bytes()].concat()
    }

    /// Sets barriers for the current layout and arms capture. Returns the compositor's desktop.
    async fn arm(ic: &InputCapture, session: &Session<InputCapture>, me: &str, layout: &[Screen]) -> Result<Rect, Box<dyn Error>> {
        let zones = ic.zones(session, Default::default()).await?.response()?;
        let r = zones.regions();
        let x0 = r.iter().map(|z| z.x_offset()).min().unwrap_or(0);
        let y0 = r.iter().map(|z| z.y_offset()).min().unwrap_or(0);
        let x1 = r.iter().map(|z| z.x_offset() + z.width() as i32).max().unwrap_or(1);
        let y1 = r.iter().map(|z| z.y_offset() + z.height() as i32).max().unwrap_or(1);
        let zone = (x0, y0, x1 - x0, y1 - y0);
        let list: Vec<Barrier> = barriers(me, layout, zone)
            .into_iter()
            .enumerate()
            .map(|(i, b)| Barrier::new(BarrierID::new(i as u32 + 1).unwrap(), b))
            .collect();
        ic.set_pointer_barriers(session, &list, zones.zone_set(), Default::default()).await?.response()?;
        ic.enable(session, Default::default()).await?;
        Ok(zone)
    }

    async fn release(ic: &InputCapture, session: &Session<InputCapture>, activation: Option<u32>, at: Option<(f64, f64)>) {
        let _ = ic.release(session, ReleaseOptions::default().set_activation_id(activation).set_cursor_position(at)).await;
    }

    async fn run(me: &str, tx: &SharedTx, rx: async_channel::Receiver<ToCapture>) -> Result<(), Box<dyn Error>> {
        let ic = InputCapture::new().await?;
        let (session, _) = ic
            .create_session(None, CreateSessionOptions::default().set_capabilities(Capabilities::KEYBOARD | Capabilities::POINTER))
            .await?;
        let stream = UnixStream::from(ic.connect_to_eis(&session, Default::default()).await?);
        stream.set_nonblocking(true)?;
        let context = ei::Context::new(stream)?;
        let _ = context.flush();
        let (_connection, mut events) = context.handshake_tokio("ubiquitas", ei::handshake::ContextType::Receiver).await?;
        let mut activations = ic.receive_activated().await?;
        let mut zones_changed = ic.receive_zones_changed().await?;

        let mut layout: Vec<Screen> = vec![];
        let mut zone: Rect = (0, 0, 1, 1);
        let mut captured: Option<Option<u32>> = None; // Some(activation id) while we hold keyboard and mouse
        let (mut ctrl, mut alt) = (false, false);
        let mut wheel = (0i32, 0i32); // scroll in 1/120 clicks not sent yet
        let (mut smooth, mut saw_discrete) = ((0f32, 0f32), false); // per frame: wheels also report smooth deltas

        // my layout coordinates <-> the compositor's
        let to_local = |layout: &[Screen], zone: Rect, x: f64, y: f64| match layout.iter().find(|s| s.name == me) {
            Some(m) => ((x - zone.0 as f64) * m.w as f64 / zone.2 as f64, (y - zone.1 as f64) * m.h as f64 / zone.3 as f64),
            None => (x, y),
        };
        let to_zone = |layout: &[Screen], zone: Rect, x: f64, y: f64| match layout.iter().find(|s| s.name == me) {
            Some(m) => (zone.0 as f64 + x * zone.2 as f64 / m.w as f64, zone.1 as f64 + y * zone.3 as f64 / m.h as f64),
            None => (x, y),
        };

        loop {
            tokio::select! {
                msg = rx.recv() => match msg? {
                    ToCapture::Layout(s) => {
                        layout = s;
                        zone = arm(&ic, &session, me, &layout).await?;
                    }
                    ToCapture::Release(x, y) => if let Some(id) = captured.take() {
                        release(&ic, &session, id, Some(to_zone(&layout, zone, x as f64, y as f64))).await;
                    },
                    // never keep keyboard and mouse captured without a server to send them to
                    ToCapture::Disconnected => if let Some(id) = captured.take() {
                        release(&ic, &session, id, None).await;
                    },
                },
                Some(_) = zones_changed.next() => zone = arm(&ic, &session, me, &layout).await?,
                Some(a) = activations.next() => {
                    let (x, y) = a.cursor_position().map(|(x, y)| (x as f64, y as f64)).unwrap_or_default();
                    let (x, y) = to_local(&layout, zone, x, y);
                    let enter = Control { t: "enter".into(), x: Some(x.round() as i32), y: Some(y.round() as i32), ..Default::default() };
                    if net::send(tx, &net::control(&enter)).is_ok() {
                        captured = Some(a.activation_id());
                        (ctrl, alt, wheel) = (false, false, (0, 0));
                    } else {
                        release(&ic, &session, a.activation_id(), None).await;
                    }
                },
                ev = events.next() => {
                    let ev = ev.ok_or("input capture connection closed")??;
                    if let EiEvent::SeatAdded(s) = &ev {
                        s.seat.bind_capabilities(DeviceCapability::Pointer | DeviceCapability::Keyboard | DeviceCapability::Button | DeviceCapability::Scroll);
                        let _ = context.flush();
                        continue;
                    }
                    if captured.is_none() {
                        continue;
                    }
                    let sent = match ev {
                        EiEvent::PointerMotion(m) => net::send(tx, &msg_motion(m.dx, m.dy)),
                        EiEvent::Button(b) => net::send(tx, &msg_key(b.button, b.state == ei::button::ButtonState::Press)),
                        EiEvent::KeyboardKey(k) => {
                            let down = k.state == ei::keyboard::KeyState::Press;
                            match k.key {
                                29 | 97 => ctrl = down,
                                56 | 100 => alt = down,
                                _ => {}
                            }
                            if k.key == 37 && down && ctrl && alt {
                                // ⌃⌥K: take this machine's keyboard and mouse back, whatever the server does
                                let _ = net::send(tx, &net::control(&Control { t: "release".into(), ..Default::default() }));
                                if let Some(id) = captured.take() { release(&ic, &session, id, None).await; }
                                continue;
                            }
                            net::send(tx, &msg_key(k.key, down))
                        }
                        EiEvent::ScrollDiscrete(s) => {
                            saw_discrete = true;
                            // libei: positive = down/right, 120 per click; protocol: +dy = up
                            wheel = (wheel.0 + s.discrete_dx, wheel.1 - s.discrete_dy);
                            Ok(())
                        }
                        EiEvent::ScrollDelta(s) => {
                            smooth = (smooth.0 + s.dx, smooth.1 + s.dy);
                            Ok(())
                        }
                        EiEvent::Frame(_) => {
                            if !saw_discrete {
                                // touchpads: about 15 px per wheel click
                                wheel = (wheel.0 + (smooth.0 * 8.0) as i32, wheel.1 - (smooth.1 * 8.0) as i32);
                            }
                            (smooth, saw_discrete) = ((0.0, 0.0), false);
                            let clicks = (wheel.0 / 120, wheel.1 / 120);
                            wheel = (wheel.0 % 120, wheel.1 % 120);
                            if clicks != (0, 0) { net::send(tx, &msg_scroll(clicks.0, clicks.1)) } else { Ok(()) }
                        }
                        _ => Ok(()),
                    };
                    if sent.is_err() {
                        if let Some(id) = captured.take() { release(&ic, &session, id, None).await; }
                    }
                },
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(name: &str, x: i32, y: i32, w: i32, h: i32, online: bool) -> Screen {
        Screen { name: name.into(), x, y, w, h, online }
    }

    #[test]
    fn barriers_only_where_an_online_neighbour_touches() {
        // pc sits on top of the mac, shifted 100 px right; the compositor runs at 2x (3840x2160 physical zone)
        let layout = [s("mac", 0, 0, 1512, 982, true), s("pc", 100, -1080, 1920, 1080, true)];
        assert_eq!(barriers("pc", &layout, (0, 0, 3840, 2160)), vec![(0, 2160, 2823, 2160)]);
        // a neighbour to the left, touching rows 200..700
        let layout = [s("pc", 0, 0, 1920, 1080, true), s("left", -800, 200, 800, 500, true)];
        assert_eq!(barriers("pc", &layout, (10, 20, 1920, 1080)), vec![(10, 220, 10, 719)]);
        // offline or not touching: nothing
        let layout = [s("pc", 0, 0, 1920, 1080, true), s("a", 1920, 0, 800, 600, false), s("b", 3000, 0, 800, 600, true)];
        assert!(barriers("pc", &layout, (0, 0, 1920, 1080)).is_empty());
    }
}
