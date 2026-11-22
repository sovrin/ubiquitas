//! Replays received input on this machine.

pub enum Event {
    /// Absolute position on this screen, 0..=65535 on both axes.
    Pointer(u16, u16),
    Scroll(i32, i32),
    Key(u16, bool),
}

pub fn decode(m: &[u8]) -> Option<Event> {
    let u16_at = |i: usize| Some(u16::from_be_bytes(m.get(i..i + 2)?.try_into().ok()?));
    match *m.first()? {
        1 => Some(Event::Pointer(u16_at(1)?, u16_at(3)?)),
        2 => Some(Event::Scroll(u16_at(1)? as i16 as i32, u16_at(3)? as i16 as i32)),
        3 => Some(Event::Key(u16_at(1)?, *m.get(3)? != 0)),
        _ => None,
    }
}

#[cfg(target_os = "linux")]
mod imp {
    use super::Event;
    use evdev::{
        AbsInfo, AbsoluteAxisCode, AttributeSet, EventType, InputEvent, KeyCode, RelativeAxisCode, UinputAbsSetup,
        uinput::VirtualDevice,
    };

    const BUTTONS: std::ops::RangeInclusive<u16> = 0x110..=0x114; // BTN_LEFT ..= BTN_EXTRA

    /// Two virtual devices so udev/libinput classify them cleanly as a keyboard and an absolute pointer
    /// (like a VM tablet), which every Wayland compositor maps onto the desktop.
    pub struct Sink {
        keyboard: VirtualDevice,
        pointer: VirtualDevice,
    }

    impl Sink {
        pub fn new() -> std::io::Result<Self> {
            let keys: AttributeSet<KeyCode> = (1..0x100).chain(0x160..0x2ff).map(KeyCode).collect();
            let keyboard = VirtualDevice::builder()?.name("ubiquitas keyboard").with_keys(&keys)?.build()?;

            let buttons: AttributeSet<KeyCode> = BUTTONS.map(KeyCode).collect();
            let abs = |axis| UinputAbsSetup::new(axis, AbsInfo::new(0, 0, 65535, 0, 0, 0));
            let wheels: AttributeSet<RelativeAxisCode> =
                [RelativeAxisCode::REL_WHEEL, RelativeAxisCode::REL_HWHEEL].into_iter().collect();
            let pointer = VirtualDevice::builder()?
                .name("ubiquitas pointer")
                .with_keys(&buttons)?
                .with_absolute_axis(&abs(AbsoluteAxisCode::ABS_X))?
                .with_absolute_axis(&abs(AbsoluteAxisCode::ABS_Y))?
                .with_relative_axes(&wheels)?
                .build()?;
            Ok(Sink { keyboard, pointer })
        }

        pub fn apply(&mut self, e: Event) -> std::io::Result<()> {
            let ev = |t: EventType, code: u16, v: i32| InputEvent::new(t.0, code, v);
            match e {
                Event::Pointer(x, y) => self.pointer.emit(&[
                    ev(EventType::ABSOLUTE, AbsoluteAxisCode::ABS_X.0, x as i32),
                    ev(EventType::ABSOLUTE, AbsoluteAxisCode::ABS_Y.0, y as i32),
                ]),
                Event::Scroll(dx, dy) => self.pointer.emit(&[
                    ev(EventType::RELATIVE, RelativeAxisCode::REL_HWHEEL.0, dx),
                    ev(EventType::RELATIVE, RelativeAxisCode::REL_WHEEL.0, dy),
                ]),
                Event::Key(code, down) if BUTTONS.contains(&code) => {
                    self.pointer.emit(&[ev(EventType::KEY, code, down as i32)])
                }
                Event::Key(code, down) => self.keyboard.emit(&[ev(EventType::KEY, code, down as i32)]),
            }
        }
    }
}

// shortcut: non-Linux builds only print events (for testing on a Mac), until the Windows client exists
#[cfg(not(target_os = "linux"))]
mod imp {
    use super::Event;
    pub struct Sink;
    impl Sink {
        pub fn new() -> std::io::Result<Self> {
            Ok(Sink)
        }
        pub fn apply(&mut self, e: Event) -> std::io::Result<()> {
            match e {
                Event::Pointer(x, y) => println!("pointer {x} {y}"),
                Event::Scroll(x, y) => println!("scroll {x} {y}"),
                Event::Key(c, d) => println!("key {c} {}", if d { "down" } else { "up" }),
            }
            Ok(())
        }
    }
}

pub use imp::Sink;
