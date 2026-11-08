//! The observe surface: ls, logs, health, open, doctor, info, watch.

mod doctor;
mod health;
mod info;
mod logs;
mod ls;
mod open;
mod watch;

pub(crate) use doctor::doctor;
pub(crate) use health::health;
pub(crate) use info::info;
pub(crate) use logs::logs;
pub(crate) use ls::ls;
pub(crate) use open::open;
pub(crate) use watch::watch;
