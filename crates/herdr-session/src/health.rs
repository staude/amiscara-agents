//! The host's health for the dashboard (#306): what the host script
//! `amiscara-health` reports.

use serde::Deserialize;

/// One reading of `amiscara-health`. Only `v` is certain; a value the
/// host's system does not give is missing.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Health {
    /// Version of the line, 1 so far.
    pub v: u32,
    /// The operating system, e.g. `macOS 27.0` or `Linux 6.8.0`.
    pub os: Option<String>,
    /// Load average over one minute.
    pub load1: Option<f64>,
    /// Number of cores, to set the load against.
    pub cpus: Option<u32>,
    /// Memory in use (total minus what the system calls available), bytes.
    pub mem_used: Option<u64>,
    pub mem_total: Option<u64>,
    /// Free and total bytes of the volume holding the home directory.
    pub disk_free: Option<u64>,
    pub disk_total: Option<u64>,
    /// Seconds since boot.
    pub uptime: Option<u64>,
}

/// What a host answers when asked for its health.
#[derive(Debug, Clone, PartialEq)]
pub enum HealthStatus {
    Ready(Health),
    /// The key's line has the case, but `~/.amiscara-agents/bin/amiscara-health`
    /// is missing, not executable or printed nothing usable.
    ScriptMissing,
    /// The key's `authorized_keys` line predates the health case and needs
    /// to be renewed.
    KeyLineOld,
}

/// Parses a line of `amiscara-health`; `None` for anything but an object
/// with a version of at least 1.
pub fn parse(line: &str) -> Option<Health> {
    // An array would fill the fields in order, so only objects count.
    let value = serde_json::from_str::<serde_json::Value>(line.trim())
        .ok()
        .filter(serde_json::Value::is_object)?;
    serde_json::from_value::<Health>(value)
        .ok()
        .filter(|health| health.v > 0)
}

#[cfg(test)]
mod tests {
    use super::{Health, parse};

    #[test]
    fn full_lines_parse() {
        let health = parse(
            r#"{"v":1,"os":"macOS 27.0","load1":1.25,"cpus":10,"mem_used":8000,"mem_total":16000,"disk_free":10,"disk_total":100,"uptime":3600,"later":true}"#,
        )
        .expect("health");
        assert_eq!(
            health,
            Health {
                v: 1,
                os: Some("macOS 27.0".into()),
                load1: Some(1.25),
                cpus: Some(10),
                mem_used: Some(8000),
                mem_total: Some(16000),
                disk_free: Some(10),
                disk_total: Some(100),
                uptime: Some(3600),
            }
        );
    }

    #[test]
    fn missing_values_stay_empty() {
        let health = parse(r#"{"v":2,"disk_free":5}"#).expect("health");
        assert_eq!(health.v, 2);
        assert_eq!(health.disk_free, Some(5));
        assert!(health.load1.is_none() && health.os.is_none() && health.uptime.is_none());
    }

    #[test]
    fn other_lines_are_refused() {
        for line in [
            "",
            "{",
            "amiscara-health",
            "[1]",
            r#"{"os":"Linux"}"#,
            r#"{"v":0}"#,
            r#"{"v":1,"cpus":"many"}"#,
        ] {
            assert!(parse(line).is_none(), "{line}");
        }
    }
}
